#!/usr/bin/env python3
"""
stream_receiver.py — Qt6 / Kirigami GUI client for the PPC audio stream server.

Connects to the PPC's PCM audio stream and plays it via QAudioSink,
with real-time waveform + spectrum visualisation, volume control,
and bitrate display.

Format: 16-bit signed LE, stereo, 44100 Hz (CD quality).
"""

import os
import sys
import socket
import threading
import time
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
    QLinearGradient,
    QPainterPath,
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
GRAVITY = 0.012  # how fast bars fall per frame (0–1 units)
PEAK_HOLD = 18  # frames to hold peak dot before it falls
PEAK_FALL = 0.008  # peak dot gravity


# ── Monstercat-style spectrum bar visualiser ───────────────────────────────────
class AudioVisualizerItem(QQuickPaintedItem):
    """QML-usable painted item: smoothed spectrum bars with falling peak dots."""

    connectedChanged = pyqtSignal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._connected = False

        # Current displayed bar heights and velocity (for smooth gravity)
        self._bars = np.zeros(NUM_BARS, dtype=np.float64)
        self._peaks = np.zeros(NUM_BARS, dtype=np.float64)
        self._peak_hold = np.zeros(NUM_BARS, dtype=np.int32)
        self._peak_vel = np.zeros(NUM_BARS, dtype=np.float64)

        self._remainder = b""

        # Pre-compute which FFT bins map to each bar (log-spaced).
        # Start at 60 Hz to skip the sub-bass mud that tends to sit
        # at a constant level and doesn't move interestingly.
        nyquist = RATE / 2
        lo_hz, hi_hz = 100.0, min(15000.0, nyquist)
        log_lo = np.log10(lo_hz)
        log_hi = np.log10(hi_hz)
        edges = np.logspace(log_lo, log_hi, NUM_BARS + 1)
        bin_freq = RATE / FFT_SIZE
        self._bin_lo = np.clip(
            (edges[:-1] / bin_freq).astype(int), 0, FFT_SIZE // 2 - 1
        )
        self._bin_hi = np.clip((edges[1:] / bin_freq).astype(int), 1, FFT_SIZE // 2)
        # ensure each bar spans at least one bin
        self._bin_hi = np.maximum(self._bin_hi, self._bin_lo + 1)

        # Per-bar EQ weight: attenuate the naturally louder low/mid
        # frequencies so the display is balanced across the spectrum.
        # Low bars get ~0.35x, highs get ~1.0x.
        center_hz = (edges[:-1] + edges[1:]) / 2.0
        self._eq = np.sqrt(center_hz / hi_hz)
        self._eq = np.clip(self._eq, 0.35, 1.0)

        self.setAntialiasing(True)

    # -- QML property --
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

    # -- called from Python backend --
    @pyqtSlot(bytes)
    def pushSamples(self, pcm_bytes: bytes):
        # Prepend leftover bytes to keep int16 alignment
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

        # Mono mix
        mono = (arr[0::2] + arr[1::2]) * 0.5
        n = min(len(mono), FFT_SIZE)

        # Windowed FFT
        window = np.hanning(n)
        fft_mag = np.abs(np.fft.rfft(mono[-n:] * window, n=FFT_SIZE))

        # Bin → bar mapping (log-spaced), take mean magnitude per bar
        raw = np.zeros(NUM_BARS, dtype=np.float64)
        for i in range(NUM_BARS):
            lo, hi = int(self._bin_lo[i]), int(self._bin_hi[i])
            raw[i] = np.mean(fft_mag[lo:hi])

        # Apply per-bar EQ to tame the naturally louder low/mid range
        raw = raw * self._eq

        # Normalise: boost, sqrt compression, power curve.
        raw = raw * 40.0
        raw = np.sqrt(raw)
        raw = raw / np.sqrt(FFT_SIZE * 0.25)
        raw = np.clip(raw - 0.03, 0, None)
        raw = raw / (1.0 - 0.03)
        raw = np.clip(raw, 0, 1)
        raw = raw**1.4

        # Smooth rise (fast attack) and gravity fall
        rising = raw > self._bars
        self._bars[rising] = raw[rising] * 0.7 + self._bars[rising] * 0.3
        self._bars[~rising] = np.maximum(self._bars[~rising] - GRAVITY, raw[~rising])

        # Peak dots: hold then fall
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

    # -- painting ---------------------------------------------------------------
    def paint(self, p: QPainter):
        w = int(self.width())
        h = int(self.height())
        if w < 10 or h < 10:
            return

        p.fillRect(0, 0, w, h, QColor("#0d0d0d"))

        if not self._connected:
            p.setPen(QPen(QColor("#555"), 1))
            p.drawText(0, 0, w, h, Qt.AlignmentFlag.AlignCenter, "Not connected")
            return

        margin = 4
        total_w = w - margin * 2
        gap = max(1, int(total_w * 0.008))  # narrow gaps → thick bars
        bar_w = max(4, (total_w - gap * (NUM_BARS - 1)) // NUM_BARS)
        x_start = margin + (total_w - (bar_w + gap) * NUM_BARS + gap) // 2
        bottom = h - margin
        max_h = h - margin * 2

        bar_brush = QBrush(QColor("#ffffff"))

        p.setPen(Qt.PenStyle.NoPen)

        for i in range(NUM_BARS):
            bx = x_start + i * (bar_w + gap)
            bh = int(self._bars[i] * max_h)
            if bh < 1:
                bh = 1

            p.fillRect(bx, bottom - bh, bar_w, bh, bar_brush)


# ── Stream backend (exposed to QML as a context property) ──────────────────────
class StreamBackend(QObject):
    """TCP receive → QAudioSink playback, with signals for QML."""

    # Signals for QML
    connectionStateChanged = pyqtSignal()
    bitrateChanged = pyqtSignal()
    statusMessageChanged = pyqtSignal()
    pcmChunk = pyqtSignal(bytes)

    def __init__(self, parent=None):
        super().__init__(parent)
        self._is_connected = False
        self._status_msg = "Disconnected"
        self._actual_kbps = 0.0
        self._volume = 1.0

        self._worker: _NetWorker | None = None
        self._thread: QThread | None = None

        # QAudioSink
        self._audio_sink: QAudioSink | None = None
        self._audio_device = None  # QIODevice returned by sink.start()

    # -- QML properties ---------------------------------------------------------
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
        return f"{RATE} Hz · {BITS}-bit LE · Stereo"

    @pyqtProperty(int, constant=True)
    def nominalKbps(self):
        return BITRATE_KBPS

    # -- QML-invokable slots ----------------------------------------------------
    @pyqtSlot(str, int)
    def connectToServer(self, host: str, port: int):
        if self._is_connected:
            return
        self._set_status("Connecting…")
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

    @pyqtSlot()
    def disconnectFromServer(self):
        if self._worker:
            self._worker.stop()

    @pyqtSlot(float)
    def setVolume(self, v: float):
        self._volume = max(0.0, min(v, 1.0))
        if self._audio_sink:
            self._audio_sink.setVolume(self._volume)

    # -- internal ---------------------------------------------------------------
    def _start_audio_sink(self):
        fmt = QAudioFormat()
        fmt.setSampleRate(RATE)
        fmt.setChannelCount(CHANNELS)
        fmt.setSampleFormat(QAudioFormat.SampleFormat.Int16)

        dev = QMediaDevices.defaultAudioOutput()
        self._audio_sink = QAudioSink(dev, fmt)
        self._audio_sink.setBufferSize(FRAME_BYTES * RATE // 10)  # ~100 ms
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
        # Write to audio sink
        if self._audio_device:
            self._audio_device.write(data)
        # Forward to visualiser
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


# ── Network reader (runs in QThread) ──────────────────────────────────────────
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
            sock.settimeout(0.5)  # allow periodic stop-flag checks
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

        reason = "Stopped" if self._stop_flag.is_set() else "Stream ended"
        self.disconnected.emit(reason)

    def stop(self):
        self._stop_flag.set()


# ── Entry point ────────────────────────────────────────────────────────────────
def main():
    # ── Ensure PyQt6 can find KDE/system Qt plugins and QML modules ────────
    # PyQt6 bundles its own Qt, so its default search paths do not include
    # the system directories where Kirigami, qqc2-desktop-style, and Breeze
    # live.  We add them before QGuiApplication is constructed so that the
    # org.kde.desktop QQC2 style (native Breeze controls) is available.
    if not os.environ.get("QT_QUICK_CONTROLS_STYLE"):
        os.environ["QT_QUICK_CONTROLS_STYLE"] = "org.kde.desktop"

    app = QGuiApplication(sys.argv)
    app.setApplicationName("PPC Stream Receiver")
    app.setOrganizationName("PPC")
    app.setDesktopFileName("ppc-stream-receiver")

    # Add system plugin path so Qt can find the org.kde.desktop style plugin
    app.addLibraryPath("/usr/lib/qt6/plugins")

    # Register the painted-item type so QML can instantiate it
    qmlRegisterType(AudioVisualizerItem, "G5Audio", 1, 0, "AudioVisualizer")

    engine = QQmlApplicationEngine()
    # Add system QML import path for Kirigami and qqc2-desktop-style
    engine.addImportPath("/usr/lib/qt6/qml")

    # Backend singleton exposed to QML
    backend = StreamBackend()
    engine.rootContext().setContextProperty("backend", backend)

    # Load QML
    qml_path = Path(__file__).resolve().parent / "qml" / "Main.qml"
    engine.load(QUrl.fromLocalFile(str(qml_path)))

    if not engine.rootObjects():
        print("Error: failed to load QML", file=sys.stderr)
        sys.exit(1)

    # Connect pcmChunk to visualiser once root is up
    root = engine.rootObjects()[0]
    vis = root.findChild(AudioVisualizerItem, "visualizer")
    if vis:
        backend.pcmChunk.connect(vis.pushSamples)

    ret = app.exec()
    backend.cleanup()
    sys.exit(ret)


if __name__ == "__main__":
    main()
