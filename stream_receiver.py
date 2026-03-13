#!/usr/bin/env python3
"""
stream_receiver.py - Qt6 / Kirigami GUI client for the PPC audio stream server.

Connects to the PPC's PCM audio stream and plays it via QAudioSink,
with real-time waveform + spectrum visualisation, volume control,
and bitrate display.

Format: 16-bit signed LE, stereo, 44100 Hz (CD quality).

iTunes integration
-----------------
When connected, a background thread polls the Mac's itunes_server.py (HTTP on
port 7778) every 2 seconds and publishes now-playing metadata via Qt signals.

MPRIS2
------
An MPRIS2 D-Bus service (org.mpris.MediaPlayer2.G5Stream) is registered on the
session bus so the desktop environment sees "now playing" info and can control
iTunes via standard media keys / taskbar widgets.

The service is always present; when playing Line-In only (no iTunes track) it
reports Stopped.
"""

import os
import sys
import socket
import tempfile
import threading
import time
import urllib.request
import plistlib
from pathlib import Path

import numpy as np

from PyQt6.QtCore import (
    Qt,
    QObject,
    QThread,
    QTimer,
    QUrl,
    pyqtSignal,
    pyqtSlot,
    pyqtProperty,
)
from PyQt6.QtGui import (
    QGuiApplication,
    QPainter,
    QColor,
    QPen,
    QBrush,
)
from PyQt6.QtQml import QQmlApplicationEngine, qmlRegisterType
from PyQt6.QtQuick import QQuickPaintedItem
from PyQt6.QtMultimedia import QAudioSink, QAudioFormat, QMediaDevices

# ── Audio constants ────────────────────────────────────────────────────────────
RATE = 44100
CHANNELS = 2
BITS = 16
FRAME_BYTES = CHANNELS * (BITS // 8)  # 4 bytes per frame
BITRATE_KBPS = RATE * CHANNELS * BITS // 1000  # 1411 kbps

FFT_SIZE = 2048  # FFT window size (mono samples)
NUM_BARS = 64  # number of spectrum bars
GRAVITY = 0.012  # bar fall speed per frame
PEAK_HOLD = 18  # frames to hold peak dot
PEAK_FALL = 0.008  # peak dot gravity

ITUNES_PORT = 7778
ITUNES_POLL_S = 1.0

# ── MPRIS2 D-Bus constants ─────────────────────────────────────────────────────
_MPRIS_BUS_NAME = "org.mpris.MediaPlayer2.G5Stream"
_MPRIS_OBJ_PATH = "/org/mpris/MediaPlayer2"
_IFACE_MP2 = "org.mpris.MediaPlayer2"
_IFACE_PLAYER = "org.mpris.MediaPlayer2.Player"
_IFACE_PROPS = "org.freedesktop.DBus.Properties"


# ── MPRIS2 service ─────────────────────────────────────────────────────────────


def _try_register_mpris(itunes_backend):
    """Register MPRIS2 on the session bus. Returns MprisService or None."""
    try:
        import dbus
        import dbus.service
        import dbus.mainloop.glib

        dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
        bus = dbus.SessionBus()
        name = dbus.service.BusName(_MPRIS_BUS_NAME, bus)  # noqa: F841
        svc = MprisService(bus, itunes_backend)
        print("[MPRIS] Registered org.mpris.MediaPlayer2.G5Stream", file=sys.stderr)
        return svc
    except Exception as e:
        print(f"[MPRIS] Could not register D-Bus service: {e}", file=sys.stderr)
        return None


class MprisService:
    """
    Minimal MPRIS2 implementation.

    Both org.mpris.MediaPlayer2 and org.mpris.MediaPlayer2.Player live on a
    single dbus.service.Object at /org/mpris/MediaPlayer2.  dbus-python does
    not allow two Object instances at the same path, so everything must be on
    one class.

    The inner _Obj class is defined inside __init__ so it can close over 'svc'
    (self) and 'backend_ref' without needing them as class-level attributes,
    which dbus.service.Object's metaclass would not tolerate.
    """

    def __init__(self, bus, itunes_backend):
        import dbus
        import dbus.service

        # Store dbus module reference for use in update_* methods.
        self._d = dbus

        # Mutable playback state read by _Obj.GetAll via the 'svc' closure.
        self._playback_status = "Stopped"
        self._position_us = 0
        self._metadata = dbus.Dictionary(
            {
                "mpris:trackid": dbus.ObjectPath(
                    "/org/mpris/MediaPlayer2/TrackList/NoTrack"
                )
            },
            signature="sv",
        )

        svc = self  # closed over by _Obj methods
        backend_ref = itunes_backend

        class _Obj(dbus.service.Object):
            # ── org.mpris.MediaPlayer2 ────────────────────────────────────
            @dbus.service.method(dbus_interface=_IFACE_MP2)
            def Raise(self):
                pass

            @dbus.service.method(dbus_interface=_IFACE_MP2)
            def Quit(self):
                pass

            # ── org.mpris.MediaPlayer2.Player ─────────────────────────────
            @dbus.service.method(dbus_interface=_IFACE_PLAYER)
            def Play(self):
                backend_ref.send_command("play")

            @dbus.service.method(dbus_interface=_IFACE_PLAYER)
            def Pause(self):
                backend_ref.send_command("pause")

            @dbus.service.method(dbus_interface=_IFACE_PLAYER)
            def PlayPause(self):
                backend_ref.send_command("playpause")

            @dbus.service.method(dbus_interface=_IFACE_PLAYER)
            def Stop(self):
                backend_ref.send_command("stop")

            @dbus.service.method(dbus_interface=_IFACE_PLAYER)
            def Next(self):
                backend_ref.send_command("next")

            @dbus.service.method(dbus_interface=_IFACE_PLAYER)
            def Previous(self):
                backend_ref.send_command("prev")

            @dbus.service.method(dbus_interface=_IFACE_PLAYER, in_signature="x")
            def Seek(self, offset_us):
                backend_ref.send_seek(max(0.0, offset_us / 1_000_000.0))

            @dbus.service.method(dbus_interface=_IFACE_PLAYER, in_signature="ox")
            def SetPosition(self, track_id, position_us):
                backend_ref.send_seek(max(0.0, position_us / 1_000_000.0))

            # ── org.freedesktop.DBus.Properties ──────────────────────────
            @dbus.service.method(
                dbus_interface=_IFACE_PROPS,
                in_signature="ss",
                out_signature="v",
            )
            def Get(self, interface, prop):
                return self.GetAll(interface)[prop]

            @dbus.service.method(
                dbus_interface=_IFACE_PROPS,
                in_signature="s",
                out_signature="a{sv}",
            )
            def GetAll(self, interface):
                d = svc._d
                if interface == _IFACE_MP2:
                    return {
                        "CanQuit": d.Boolean(False),
                        "CanRaise": d.Boolean(False),
                        "HasTrackList": d.Boolean(False),
                        "Identity": d.String("G5 Stream Receiver"),
                        "SupportedUriSchemes": d.Array([], signature="s"),
                        "SupportedMimeTypes": d.Array([], signature="s"),
                    }
                # _IFACE_PLAYER (default)
                return {
                    "PlaybackStatus": d.String(svc._playback_status),
                    "LoopStatus": d.String("None"),
                    "Rate": d.Double(1.0),
                    "Shuffle": d.Boolean(False),
                    "Metadata": svc._metadata,
                    "Volume": d.Double(1.0),
                    "Position": d.Int64(svc._position_us),
                    "MinimumRate": d.Double(1.0),
                    "MaximumRate": d.Double(1.0),
                    "CanGoNext": d.Boolean(True),
                    "CanGoPrevious": d.Boolean(True),
                    "CanPlay": d.Boolean(True),
                    "CanPause": d.Boolean(True),
                    "CanSeek": d.Boolean(True),
                    "CanControl": d.Boolean(True),
                }

            @dbus.service.signal(
                dbus_interface=_IFACE_PROPS,
                signature="sa{sv}as",
            )
            def PropertiesChanged(self, interface, changed, invalidated):
                pass

        self._obj = _Obj(bus, _MPRIS_OBJ_PATH)

    # ── called from ITunesBackend (main thread) ───────────────────────────────

    def update_metadata(self, info: dict):
        d = self._d
        track_id = info.get("id", 0)
        obj_path = (
            f"/org/mpris/MediaPlayer2/Track/{track_id}"
            if track_id
            else "/org/mpris/MediaPlayer2/TrackList/NoTrack"
        )
        self._metadata = d.Dictionary(
            {
                "mpris:trackid": d.ObjectPath(obj_path),
                "mpris:length": d.Int64(int(info.get("duration", 0.0) * 1_000_000)),
                "xesam:title": d.String(info.get("title", "")),
                "xesam:artist": d.Array([info.get("artist", "")], signature="s"),
                "xesam:album": d.String(info.get("album", "")),
            },
            signature="sv",
        )
        self._emit_changed(
            {
                "Metadata": self._metadata,
                "PlaybackStatus": d.String(self._playback_status),
            }
        )

    def update_playback_state(self, state: str):
        self._playback_status = state
        self._emit_changed({"PlaybackStatus": self._d.String(state)})

    def update_position(self, pos_s: float):
        self._position_us = int(pos_s * 1_000_000)

    def _emit_changed(self, changed: dict):
        self._obj.PropertiesChanged(_IFACE_PLAYER, changed, [])


# ── iTunes HTTP client backend ─────────────────────────────────────────────────


class ITunesBackend(QObject):
    """
    Polls the Mac's itunes_server.py and exposes now-playing info as Qt signals.
    Also sends control commands (play/pause/next/prev/seek) back to the Mac.
    """

    trackChanged = pyqtSignal()
    stateChanged = pyqtSignal()
    positionChanged = pyqtSignal()
    artworkChanged = pyqtSignal()
    repeatChanged = pyqtSignal()

    # Private cross-thread signals: daemon thread emits, main thread handles.
    _statusReceived = pyqtSignal(str, str, str, str, float, float, int, str)
    _playlistReceived = pyqtSignal(object)
    _artworkReceived = pyqtSignal(str)

    def __init__(self, parent=None):
        super().__init__(parent)
        self._base_url = ""
        self._title = ""
        self._artist = ""
        self._album = ""
        self._duration = 0.0
        self._position = 0.0
        self._state = "Stopped"
        self._track_id = 0
        self._repeat = "off"
        self._playlist: list[dict] = []
        self._artwork_url = ""
        self._artwork_dir = tempfile.mkdtemp(prefix="g5art_")
        self._mpris: MprisService | None = None

        self._poll_timer = QTimer(self)
        self._poll_timer.setInterval(int(ITUNES_POLL_S * 1000))
        self._poll_timer.timeout.connect(self._poll)

        self._statusReceived.connect(self._apply_status)
        self._playlistReceived.connect(self._apply_playlist)
        self._artworkReceived.connect(self._apply_artwork)

    # -- setup / teardown ---------------------------------------------------

    def start(self, host: str):
        self._base_url = f"http://{host}:{ITUNES_PORT}"
        self._poll_timer.start()
        self._poll()
        self._fetch_playlist()
        self._fetch_artwork()

    def stop(self):
        self._poll_timer.stop()
        self._base_url = ""
        self._title = self._artist = self._album = ""
        self._duration = self._position = 0.0
        self._state = "Stopped"
        self._track_id = 0
        self._repeat = "off"
        self._playlist = []
        self._artwork_url = ""
        self.trackChanged.emit()
        self.stateChanged.emit()
        self.artworkChanged.emit()
        self.repeatChanged.emit()
        if self._mpris:
            self._mpris.update_playback_state("Stopped")

    def attach_mpris(self, svc: MprisService):
        self._mpris = svc

    # -- QML properties -----------------------------------------------------

    @pyqtProperty(str, notify=trackChanged)
    def title(self):
        return self._title

    @pyqtProperty(str, notify=trackChanged)
    def artist(self):
        return self._artist

    @pyqtProperty(str, notify=trackChanged)
    def album(self):
        return self._album

    @pyqtProperty(float, notify=trackChanged)
    def duration(self):
        return self._duration

    @pyqtProperty(float, notify=positionChanged)
    def position(self):
        return self._position

    @pyqtProperty(str, notify=stateChanged)
    def playbackState(self):
        return self._state

    @pyqtProperty(int, notify=trackChanged)
    def currentTrackId(self):
        return self._track_id

    @pyqtProperty(str, notify=artworkChanged)
    def artworkUrl(self):
        return self._artwork_url

    @pyqtProperty(str, notify=repeatChanged)
    def repeatMode(self):
        return self._repeat

    @pyqtProperty(list, notify=trackChanged)
    def playlist(self):
        return self._playlist

    # -- QML-invokable controls ---------------------------------------------

    @pyqtSlot()
    def play(self):
        self.send_command("play")

    @pyqtSlot()
    def pause(self):
        self.send_command("pause")

    @pyqtSlot()
    def playPause(self):
        self.send_command("playpause")

    @pyqtSlot()
    def next(self):
        self.send_command("next")

    @pyqtSlot()
    def previous(self):
        self.send_command("prev")

    @pyqtSlot()
    def stopPlayback(self):
        self.send_command("stop")

    @pyqtSlot(int)
    def playById(self, db_id: int):
        threading.Thread(
            target=self._post_then_poll, args=(f"/play?id={db_id}",), daemon=True
        ).start()

    @pyqtSlot(float)
    def seekTo(self, pos_s: float):
        self.send_seek(pos_s)

    @pyqtSlot()
    def cycleRepeat(self):
        """POST /repeat (no mode param = cycle) then re-poll."""
        threading.Thread(
            target=self._post_then_poll, args=("/repeat",), daemon=True
        ).start()

    # -- internal -----------------------------------------------------------

    def send_seek(self, pos_s: float):
        """Seek iTunes to an absolute position (seconds) and re-poll."""
        if not self._base_url:
            return
        threading.Thread(
            target=self._post_then_poll,
            args=(f"/seek?pos={pos_s:.2f}",),
            daemon=True,
        ).start()

    def send_command(self, cmd: str):
        if not self._base_url:
            return
        threading.Thread(
            target=self._post_then_poll, args=(f"/{cmd}",), daemon=True
        ).start()

    def _post_then_poll(self, path: str):
        """POST a command, then immediately poll status so the UI updates."""
        self._post(path)
        time.sleep(0.3)
        self._do_poll()

    def _post(self, path: str):
        try:
            urllib.request.urlopen(
                urllib.request.Request(self._base_url + path, method="POST", data=b""),
                timeout=4,
            )
        except Exception:
            pass

    def _get_plist(self, path: str):
        try:
            with urllib.request.urlopen(self._base_url + path, timeout=4) as r:
                return plistlib.loads(r.read())
        except Exception:
            return None

    def _poll(self):
        if not self._base_url:
            return
        threading.Thread(target=self._do_poll, daemon=True).start()

    def _do_poll(self):
        """Runs on daemon thread — emits signal to hand data to main thread."""
        data = self._get_plist("/status")
        if data is None:
            return
        self._statusReceived.emit(
            str(data.get("state", "Stopped")),
            str(data.get("title", "")),
            str(data.get("artist", "")),
            str(data.get("album", "")),
            float(data.get("duration", 0.0)),
            float(data.get("position", 0.0)),
            int(data.get("id", 0)),
            str(data.get("repeat", "off")),
        )

    @pyqtSlot(str, str, str, str, float, float, int, str)
    def _apply_status(
        self,
        new_state,
        new_title,
        new_artist,
        new_album,
        new_dur,
        new_pos,
        new_id,
        new_repeat,
    ):
        """Runs on main thread via queued signal."""
        track_changed = (
            new_title != self._title
            or new_artist != self._artist
            or new_album != self._album
            or new_dur != self._duration
            or new_id != self._track_id
        )
        state_changed = new_state != self._state
        repeat_changed = new_repeat != self._repeat

        self._state = new_state
        self._title = new_title
        self._artist = new_artist
        self._album = new_album
        self._duration = new_dur
        self._position = new_pos
        self._track_id = new_id
        self._repeat = new_repeat

        if repeat_changed:
            self.repeatChanged.emit()

        if track_changed:
            self.trackChanged.emit()
            self._fetch_playlist()
            self._fetch_artwork()
            if self._mpris:
                self._mpris.update_metadata(
                    {
                        "id": new_id,
                        "title": new_title,
                        "artist": new_artist,
                        "album": new_album,
                        "duration": new_dur,
                    }
                )
        if state_changed:
            self.stateChanged.emit()
            if self._mpris:
                self._mpris.update_playback_state(new_state)
        else:
            self.positionChanged.emit()

    def _fetch_playlist(self):
        threading.Thread(target=self._do_fetch_playlist, daemon=True).start()

    def _do_fetch_playlist(self):
        data = self._get_plist("/playlist")
        if not isinstance(data, list):
            return
        parsed = [
            {
                "id": int(t.get("id", 0)),
                "title": str(t.get("title", "")),
                "artist": str(t.get("artist", "")),
                "album": str(t.get("album", "")),
                "duration": float(t.get("duration", 0.0)),
            }
            for t in data
        ]
        self._playlistReceived.emit(parsed)

    @pyqtSlot(object)
    def _apply_playlist(self, parsed: list):
        self._playlist = parsed
        self.trackChanged.emit()

    def _fetch_artwork(self):
        threading.Thread(target=self._do_fetch_artwork, daemon=True).start()

    def _do_fetch_artwork(self):
        if not self._base_url:
            return
        try:
            with urllib.request.urlopen(self._base_url + "/artwork", timeout=5) as r:
                ct = r.headers.get("Content-Type", "image/jpeg")
                ext = ".png" if "png" in ct else ".jpg"
                img_data = r.read()
                # Use track ID in filename so QML sees a new source URL per track
                out_path = os.path.join(self._artwork_dir, f"art_{self._track_id}{ext}")
                with open(out_path, "wb") as f:
                    f.write(img_data)
                self._artworkReceived.emit(QUrl.fromLocalFile(out_path).toString())
        except Exception:
            self._artworkReceived.emit("")

    @pyqtSlot(str)
    def _apply_artwork(self, url: str):
        if url != self._artwork_url:
            self._artwork_url = url
            self.artworkChanged.emit()


# ── Monstercat-style spectrum bar visualiser ───────────────────────────────────


class AudioVisualizerItem(QQuickPaintedItem):
    """QML-usable painted item: smoothed spectrum bars with falling peak dots."""

    connectedChanged = pyqtSignal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._connected = False
        self._bars = np.zeros(NUM_BARS, dtype=np.float64)
        self._peaks = np.zeros(NUM_BARS, dtype=np.float64)
        self._peak_hold = np.zeros(NUM_BARS, dtype=np.int32)
        self._peak_vel = np.zeros(NUM_BARS, dtype=np.float64)
        self._remainder = b""

        nyquist = RATE / 2
        lo_hz, hi_hz = 100.0, min(15000.0, nyquist)
        edges = np.logspace(np.log10(lo_hz), np.log10(hi_hz), NUM_BARS + 1)
        bin_freq = RATE / FFT_SIZE
        self._bin_lo = np.clip(
            (edges[:-1] / bin_freq).astype(int), 0, FFT_SIZE // 2 - 1
        )
        self._bin_hi = np.maximum(
            np.clip((edges[1:] / bin_freq).astype(int), 1, FFT_SIZE // 2),
            self._bin_lo + 1,
        )
        center_hz = (edges[:-1] + edges[1:]) / 2.0
        self._eq = np.clip(np.sqrt(center_hz / hi_hz), 0.35, 1.0)
        self.setAntialiasing(True)

    @pyqtProperty(bool, notify=connectedChanged)
    def connected(self):
        return self._connected

    @connected.setter
    def connected(self, v):
        if self._connected != v:
            self._connected = v
            if not v:
                self._bars[:] = 0
                self._peaks[:] = 0
                self._peak_hold[:] = 0
                self._peak_vel[:] = 0
                self._remainder = b""
            self.connectedChanged.emit()
            self.update()

    @pyqtSlot(bytes)
    def pushSamples(self, pcm_bytes: bytes):
        data = self._remainder + pcm_bytes
        excess = len(data) % 2
        if excess:
            self._remainder = data[-excess:]
            data = data[:-excess]
        else:
            self._remainder = b""
        if len(data) < 4:
            return

        arr = np.frombuffer(data, dtype=np.int16).astype(np.float32) / 32768.0
        if len(arr) < 2:
            return
        if len(arr) % 2:
            arr = arr[:-1]

        mono = (arr[0::2] + arr[1::2]) * 0.5
        n = min(len(mono), FFT_SIZE)
        window = np.hanning(n)
        fft_mag = np.abs(np.fft.rfft(mono[-n:] * window, n=FFT_SIZE))

        raw = (
            np.array(
                [
                    np.mean(fft_mag[int(self._bin_lo[i]) : int(self._bin_hi[i])])
                    for i in range(NUM_BARS)
                ]
            )
            * self._eq
        )

        raw = np.sqrt(raw * 40.0) / np.sqrt(FFT_SIZE * 0.25)
        raw = np.clip(raw - 0.03, 0, None) / (1.0 - 0.03)
        raw = np.clip(raw, 0, 1) ** 1.4

        rising = raw > self._bars
        self._bars[rising] = raw[rising] * 0.7 + self._bars[rising] * 0.3
        self._bars[~rising] = np.maximum(self._bars[~rising] - GRAVITY, raw[~rising])

        new_peak = self._bars > self._peaks
        self._peaks[new_peak] = self._bars[new_peak]
        self._peak_hold[new_peak] = PEAK_HOLD
        self._peak_vel[new_peak] = 0.0

        held = ~new_peak
        self._peak_hold[held] = np.maximum(self._peak_hold[held] - 1, 0)
        falling = held & (self._peak_hold == 0)
        self._peak_vel[falling] += PEAK_FALL
        self._peaks[falling] -= self._peak_vel[falling]
        self._peaks = np.maximum(self._peaks, 0)

        self.update()

    def paint(self, p: QPainter):
        w, h = int(self.width()), int(self.height())
        if w < 10 or h < 10:
            return

        p.fillRect(0, 0, w, h, QColor("#0d0d0d"))

        if not self._connected:
            p.setPen(QPen(QColor("#555"), 1))
            p.drawText(0, 0, w, h, Qt.AlignmentFlag.AlignCenter, "Not connected")
            return

        margin = 4
        total_w = w - margin * 2
        gap = max(1, int(total_w * 0.008))
        bar_w = max(4, (total_w - gap * (NUM_BARS - 1)) // NUM_BARS)
        x_start = margin + (total_w - (bar_w + gap) * NUM_BARS + gap) // 2
        bottom = h - margin
        max_h = h - margin * 2

        p.setPen(Qt.PenStyle.NoPen)
        for i in range(NUM_BARS):
            bx = x_start + i * (bar_w + gap)
            bh = max(1, int(self._bars[i] * max_h))
            p.fillRect(bx, bottom - bh, bar_w, bh, QBrush(QColor("#ffffff")))
            ph = int(self._peaks[i] * max_h)
            if ph > 1:
                p.fillRect(bx, bottom - ph - 2, bar_w, 2, QBrush(QColor("#aaaaaa")))


# ── Stream backend ─────────────────────────────────────────────────────────────


class StreamBackend(QObject):
    """TCP receive → QAudioSink playback, with signals for QML."""

    connectionStateChanged = pyqtSignal()
    bitrateChanged = pyqtSignal()
    statusMessageChanged = pyqtSignal()
    pcmChunk = pyqtSignal(bytes)

    def __init__(self, itunes: ITunesBackend, parent=None):
        super().__init__(parent)
        self._itunes = itunes
        self._is_connected = False
        self._status_msg = "Disconnected"
        self._actual_kbps = 0.0
        self._volume = 1.0
        self._worker: _NetWorker | None = None
        self._thread: QThread | None = None
        self._audio_sink: QAudioSink | None = None
        self._audio_device = None

    @pyqtProperty(bool, notify=connectionStateChanged)
    def isConnected(self):
        return self._is_connected

    @pyqtProperty(str, notify=statusMessageChanged)
    def statusMessage(self):
        return self._status_msg

    @pyqtProperty(float, notify=bitrateChanged)
    def actualKbps(self):
        return self._actual_kbps

    @pyqtProperty(str, constant=True)
    def formatString(self):
        return f"{RATE} Hz \u00b7 {BITS}-bit LE \u00b7 Stereo"

    @pyqtProperty(int, constant=True)
    def nominalKbps(self):
        return BITRATE_KBPS

    @pyqtSlot(str, int)
    def connectToServer(self, host: str, port: int):
        if self._is_connected:
            return
        self._set_status("Connecting\u2026")
        self._start_audio_sink()
        self._worker = _NetWorker(host, port)
        self._thread = QThread()
        self._worker.moveToThread(self._thread)
        self._thread.started.connect(self._worker.run)
        self._worker.connected.connect(self._on_connected)
        self._worker.disconnected.connect(self._on_disconnected)
        self._worker.dataReady.connect(self._on_data)
        self._worker.bytesPerSec.connect(self._on_bps)
        self._thread.start()
        self._itunes.start(host)

    @pyqtSlot()
    def disconnectFromServer(self):
        if self._worker:
            self._worker.stop()
        self._itunes.stop()

    @pyqtSlot(float)
    def setVolume(self, v: float):
        self._volume = max(0.0, min(v, 1.0))
        if self._audio_sink:
            self._audio_sink.setVolume(self._volume)

    def _start_audio_sink(self):
        fmt = QAudioFormat()
        fmt.setSampleRate(RATE)
        fmt.setChannelCount(CHANNELS)
        fmt.setSampleFormat(QAudioFormat.SampleFormat.Int16)
        dev = QMediaDevices.defaultAudioOutput()
        self._audio_sink = QAudioSink(dev, fmt)
        self._audio_sink.setBufferSize(FRAME_BYTES * RATE // 10)
        self._audio_sink.setVolume(self._volume)
        self._audio_device = self._audio_sink.start()

    def _stop_audio_sink(self):
        if self._audio_sink:
            self._audio_sink.stop()
            self._audio_sink = None
            self._audio_device = None

    def _set_status(self, msg: str):
        self._status_msg = msg
        self.statusMessageChanged.emit()

    def _on_connected(self):
        self._is_connected = True
        self._set_status("Connected")
        self.connectionStateChanged.emit()

    def _on_disconnected(self, reason: str):
        self._is_connected = False
        self._actual_kbps = 0.0
        self._set_status(reason)
        self.connectionStateChanged.emit()
        self.bitrateChanged.emit()
        self._stop_audio_sink()
        if self._thread:
            self._thread.quit()
            self._thread.wait()
        self._thread = None
        self._worker = None

    def _on_data(self, data: bytes):
        if self._audio_device:
            self._audio_device.write(data)
        self.pcmChunk.emit(data)

    def _on_bps(self, bps: float):
        self._actual_kbps = bps * 8 / 1000
        self.bitrateChanged.emit()

    def cleanup(self):
        if self._worker:
            self._worker.stop()
        if self._thread:
            self._thread.quit()
            self._thread.wait(2000)
        self._stop_audio_sink()


# ── Network reader thread ──────────────────────────────────────────────────────


class _NetWorker(QObject):
    connected = pyqtSignal()
    disconnected = pyqtSignal(str)
    dataReady = pyqtSignal(bytes)
    bytesPerSec = pyqtSignal(float)

    def __init__(self, host, port):
        super().__init__()
        self._host = host
        self._port = port
        self._stop_flag = threading.Event()

    @pyqtSlot()
    def run(self):
        self._stop_flag.clear()
        sock = None
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(5.0)
            sock.connect((self._host, self._port))
            sock.settimeout(0.5)
            self.connected.emit()

            CHUNK = FRAME_BYTES * 2048
            t_start = time.monotonic()
            byte_acc = 0

            while not self._stop_flag.is_set():
                try:
                    data = sock.recv(CHUNK)
                except socket.timeout:
                    continue
                except OSError:
                    break
                if not data:
                    break
                byte_acc += len(data)
                self.dataReady.emit(data)
                now = time.monotonic()
                elapsed = now - t_start
                if elapsed >= 1.0:
                    self.bytesPerSec.emit(byte_acc / elapsed)
                    byte_acc = 0
                    t_start = now

        except ConnectionRefusedError:
            self.disconnected.emit("Connection refused")
            return
        except socket.timeout:
            self.disconnected.emit("Connection timed out")
            return
        except OSError as e:
            self.disconnected.emit(str(e))
            return
        finally:
            if sock:
                try:
                    sock.close()
                except Exception:
                    pass

        self.disconnected.emit(
            "Stopped" if self._stop_flag.is_set() else "Stream ended"
        )

    def stop(self):
        self._stop_flag.set()


# ── Entry point ────────────────────────────────────────────────────────────────


def main():
    if not os.environ.get("QT_QUICK_CONTROLS_STYLE"):
        os.environ["QT_QUICK_CONTROLS_STYLE"] = "org.kde.desktop"

    app = QGuiApplication(sys.argv)
    app.setApplicationName("PPC Stream Receiver")
    app.setOrganizationName("PPC")
    app.setDesktopFileName("ppc-stream-receiver")
    app.addLibraryPath("/usr/lib/qt6/plugins")

    qmlRegisterType(AudioVisualizerItem, "G5Audio", 1, 0, "AudioVisualizer")

    engine = QQmlApplicationEngine()
    engine.addImportPath("/usr/lib/qt6/qml")

    itunes = ITunesBackend()
    backend = StreamBackend(itunes)

    mpris = _try_register_mpris(itunes)
    if mpris:
        itunes.attach_mpris(mpris)

    engine.rootContext().setContextProperty("backend", backend)
    engine.rootContext().setContextProperty("itunes", itunes)

    qml_path = Path(__file__).resolve().parent / "qml" / "Main.qml"
    engine.load(QUrl.fromLocalFile(str(qml_path)))

    if not engine.rootObjects():
        print("Error: failed to load QML", file=sys.stderr)
        sys.exit(1)

    root = engine.rootObjects()[0]
    vis = root.findChild(AudioVisualizerItem, "visualizer")
    if vis:
        backend.pcmChunk.connect(vis.pushSamples)

    ret = app.exec()
    backend.cleanup()
    sys.exit(ret)


if __name__ == "__main__":
    main()
