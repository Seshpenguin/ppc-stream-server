#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
itunes_server.py - iTunes HTTP control server for Mac OS X Leopard (Python 2.5)

Runs a lightweight HTTP server (default port 7778) that exposes iTunes state
and control.  Responses are Apple Property List (plist) XML, readable on the
Linux side with Python 3's built-in plistlib — no extra dependencies on either
end.

Endpoints:
  GET  /status          current track info + player state + position
  GET  /playlist        all tracks in the current playlist
  POST /play            resume playback
  POST /pause           pause playback
  POST /playpause       toggle play/pause
  POST /next            skip to next track
  POST /prev            go to previous track
  POST /stop            stop playback
  POST /play?id=<dbid>  play a specific track by its iTunes database ID
  POST /volume?v=0-100  set iTunes sound volume
  POST /seek?pos=<sec>  seek to position in seconds

Usage: python itunes_server.py [port]
"""

import BaseHTTPServer
import cgi
import os
import plistlib
import subprocess
import sys
import urlparse

DEFAULT_PORT = 7778


# ---------------------------------------------------------------------------
# AppleScript runner
# ---------------------------------------------------------------------------

def run_applescript(script):
    """Run an AppleScript snippet; return stripped stdout or None on failure."""
    try:
        p = subprocess.Popen(
            ['osascript', '-e', script],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        out, _err = p.communicate()
        if p.returncode != 0:
            return None
        return out.strip()
    except Exception:
        return None


# ---------------------------------------------------------------------------
# iTunes queries
# ---------------------------------------------------------------------------

def get_status():
    """Return a dict describing current player state and track metadata."""
    script = '''
tell application "iTunes"
    set ps to player state as string
    set sr to song repeat of current playlist as string
    if ps is "stopped" then
        return "stopped||||||0|0|100|" & sr
    end if
    try
        set t to current track
        set tName   to name of t
        set tArtist to artist of t
        set tAlbum  to album of t
        set tDur    to duration of t as string
        set tID     to database ID of t as string
        set tPos    to player position as string
        set tVol    to sound volume as string
        return ps & "|" & tName & "|" & tArtist & "|" & tAlbum & "|" & tDur & "|" & tID & "|" & tPos & "|" & tVol & "|" & sr
    on error
        return ps & "|||||||0|100|off"
    end try
end tell
'''
    raw = run_applescript(script)
    if raw is None:
        return {'error': 'iTunes not responding', 'state': 'stopped',
                'title': '', 'artist': '', 'album': '',
                'duration': 0.0, 'id': 0, 'position': 0.0, 'volume': 100,
                'repeat': 'off'}

    parts = raw.split('|')
    while len(parts) < 9:
        parts.append('')

    state_map = {'playing': 'Playing', 'paused': 'Paused', 'stopped': 'Stopped'}
    state = state_map.get(parts[0].strip(), parts[0].strip().capitalize())

    def _float(s):
        try:
            return float(s)
        except (ValueError, TypeError):
            return 0.0

    def _int(s):
        try:
            return int(float(s))
        except (ValueError, TypeError):
            return 0

    repeat_val = parts[8].strip() if parts[8].strip() in ('off', 'all', 'one') else 'off'

    return {
        'state':    state,
        'title':    parts[1],
        'artist':   parts[2],
        'album':    parts[3],
        'duration': _float(parts[4]),
        'id':       _int(parts[5]),
        'position': _float(parts[6]),
        'volume':   _int(parts[7]),
        'repeat':   repeat_val,
    }


def get_playlist():
    """Return a list of dicts for every track in the current playlist."""
    script = '''
tell application "iTunes"
    set output to ""
    repeat with t in tracks of current playlist
        set output to output & (database ID of t as string) & "|" & name of t & "|" & artist of t & "|" & album of t & "|" & (duration of t as string) & "\n"
    end repeat
    return output
end tell
'''
    raw = run_applescript(script)
    if raw is None:
        return []

    tracks = []
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split('|')
        if len(parts) < 5:
            continue
        try:
            dur = float(parts[4])
        except ValueError:
            dur = 0.0
        try:
            db_id = int(float(parts[0]))
        except ValueError:
            db_id = 0
        tracks.append({
            'id':       db_id,
            'title':    parts[1],
            'artist':   parts[2],
            'album':    parts[3],
            'duration': dur,
        })
    return tracks


# ---------------------------------------------------------------------------
# iTunes control commands
# ---------------------------------------------------------------------------

_SIMPLE_COMMANDS = {
    'play':      'tell application "iTunes" to play',
    'pause':     'tell application "iTunes" to pause',
    'playpause': 'tell application "iTunes" to playpause',
    'next':      'tell application "iTunes" to next track',
    'prev':      'tell application "iTunes" to previous track',
    'stop':      'tell application "iTunes" to stop',
}


def play_track_by_id(db_id):
    """Play a specific track by iTunes database ID; return True on success."""
    script = '''
tell application "iTunes"
    repeat with t in tracks of current playlist
        if database ID of t is %d then
            play t
            return true
        end if
    end repeat
    return false
end tell
''' % int(db_id)
    return run_applescript(script) == 'true'


def set_itunes_volume(vol):
    run_applescript(
        'tell application "iTunes" to set sound volume to %d' % int(vol)
    )


def seek_to(pos):
    run_applescript(
        'tell application "iTunes" to set player position to %f' % float(pos)
    )


_REPEAT_CYCLE = {'off': 'all', 'all': 'one', 'one': 'off'}


def set_repeat(mode):
    """Set repeat mode to 'off', 'all', or 'one'."""
    if mode not in ('off', 'all', 'one'):
        return 'off'
    run_applescript(
        'tell application "iTunes" to set song repeat of current playlist to %s' % mode
    )
    return mode


def cycle_repeat():
    """Cycle repeat: off -> all -> one -> off. Returns the new mode."""
    raw = run_applescript(
        'tell application "iTunes" to get song repeat of current playlist as string'
    )
    current = raw.strip() if raw else 'off'
    new_mode = _REPEAT_CYCLE.get(current, 'off')
    return set_repeat(new_mode)


# ---------------------------------------------------------------------------
# Artwork
# ---------------------------------------------------------------------------

_ARTWORK_TMP = '/tmp/itunes_artwork'

_FALLBACK_PNG = '/tmp/g5-stream-fallback-artwork.png'
_FALLBACK_ICNS = (
    '/System/Library/CoreServices/CoreTypes.bundle'
    '/Contents/Resources/GenericSongDocument.icns'
)


def _ensure_fallback():
    """Convert the system music icon to a cached PNG via sips (once)."""
    if os.path.exists(_FALLBACK_PNG):
        return
    if os.path.exists(_FALLBACK_ICNS):
        subprocess.call([
            'sips', '-s', 'format', 'png',
            _FALLBACK_ICNS, '--out', _FALLBACK_PNG,
        ])


def get_artwork():
    """Return (image_bytes, mime_type) or (None, None)."""
    script = '''
tell application "iTunes"
    if player state is not stopped then
        set t to current track
        if (count of artworks of t) > 0 then
            set artData to raw data of artwork 1 of t
            set artFmt to format of artwork 1 of t as string
            if artFmt starts with "JPEG" then
                set ext to ".jpg"
            else if artFmt starts with "PNG" then
                set ext to ".png"
            else
                set ext to ".bmp"
            end if
            set outPath to "%s" & ext
        else
            return "NO_ART"
        end if
    else
        return "NO_ART"
    end if
end tell
set outFile to open for access outPath with write permission
set eof of outFile to 0
write artData to outFile
close access outFile
return outPath
''' % _ARTWORK_TMP

    raw = run_applescript(script)
    if raw and raw != 'NO_ART' and os.path.exists(raw):
        ext = os.path.splitext(raw)[1].lower()
        mime_map = {'.jpg': 'image/jpeg', '.png': 'image/png', '.bmp': 'image/bmp'}
        mime = mime_map.get(ext, 'image/jpeg')
        f = open(raw, 'rb')
        data = f.read()
        f.close()
        return data, mime

    # Fallback to system icon
    _ensure_fallback()
    if os.path.exists(_FALLBACK_PNG):
        f = open(_FALLBACK_PNG, 'rb')
        data = f.read()
        f.close()
        return data, 'image/png'

    return None, None


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------

class ITunesHandler(BaseHTTPServer.BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        pass  # silence per-request access log; errors still reach stderr

    # -- response helpers ---------------------------------------------------

    def _send_plist(self, code, obj):
        body = plistlib.writePlistToString(obj)
        self.send_response(code)
        self.send_header('Content-Type', 'application/x-plist')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _ok(self, msg='ok'):
        self._send_plist(200, {'ok': True, 'message': msg})

    def _err(self, code, msg):
        self._send_plist(code, {'ok': False, 'error': msg})

    def _send_binary(self, code, data, content_type):
        self.send_response(code)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    # -- GET ----------------------------------------------------------------

    def do_GET(self):
        parsed = urlparse.urlparse(self.path)
        path   = parsed.path.rstrip('/')

        if path == '/status':
            self._send_plist(200, get_status())

        elif path == '/playlist':
            self._send_plist(200, get_playlist())

        elif path == '/artwork':
            data, mime = get_artwork()
            if data:
                self._send_binary(200, data, mime)
            else:
                self._err(404, 'No artwork available')

        else:
            self._err(404, 'Unknown endpoint: ' + path)

    # -- POST ---------------------------------------------------------------

    def do_POST(self):
        parsed = urlparse.urlparse(self.path)
        path   = parsed.path.rstrip('/')
        params = cgi.parse_qs(parsed.query)

        if path == '/play':
            if 'id' in params:
                try:
                    db_id = int(params['id'][0])
                except (ValueError, IndexError):
                    self._err(400, 'Invalid id parameter')
                    return
                if play_track_by_id(db_id):
                    self._ok('Playing track %d' % db_id)
                else:
                    self._err(404, 'Track %d not found' % db_id)
            else:
                run_applescript(_SIMPLE_COMMANDS['play'])
                self._ok('Playing')

        elif path in ('/pause', '/playpause', '/next', '/prev', '/stop'):
            run_applescript(_SIMPLE_COMMANDS[path.lstrip('/')])
            self._ok(path.lstrip('/'))

        elif path == '/volume':
            try:
                vol = max(0, min(100, int(params['v'][0])))
            except (KeyError, IndexError, ValueError):
                self._err(400, 'Missing or invalid v parameter (0-100)')
                return
            set_itunes_volume(vol)
            self._ok('Volume set to %d' % vol)

        elif path == '/seek':
            try:
                pos = float(params['pos'][0])
            except (KeyError, IndexError, ValueError):
                self._err(400, 'Missing or invalid pos parameter')
                return
            seek_to(pos)
            self._ok('Seeked to %.2f' % pos)

        elif path == '/repeat':
            if 'mode' in params:
                mode = params['mode'][0]
                if mode not in ('off', 'all', 'one'):
                    self._err(400, 'Invalid mode (off, all, one)')
                    return
                new_mode = set_repeat(mode)
            else:
                new_mode = cycle_repeat()
            self._send_plist(200, {'ok': True, 'repeat': new_mode})

        else:
            self._err(404, 'Unknown endpoint: ' + path)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    port = DEFAULT_PORT
    if len(sys.argv) > 1:
        try:
            port = int(sys.argv[1])
        except ValueError:
            pass

    server = BaseHTTPServer.HTTPServer(('', port), ITunesHandler)
    print 'iTunes control server listening on port %d' % port
    sys.stdout.flush()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print '\nShutting down.'


if __name__ == '__main__':
    main()
