PREFIX       ?= /opt/g5-stream-server
DESKTOP_DIR  ?= /usr/share/applications

# ── build ─────────────────────────────────────────────────────────────────────
# Runs the build script (Mac OS X / PPC only — compiles the C server binaries).

build:
	./build.sh

# ── install-client ────────────────────────────────────────────────────────────
# Installs the Linux Qt6/Kirigami stream receiver.

install-client:
	install -d $(DESTDIR)$(PREFIX)
	install -d $(DESTDIR)$(PREFIX)/qml
	install -m 755 stream_receiver.py $(DESTDIR)$(PREFIX)/stream_receiver.py
	install -m 644 qml/Main.qml       $(DESTDIR)$(PREFIX)/qml/Main.qml
	install -d $(DESTDIR)$(DESKTOP_DIR)
	install -m 644 ppc-stream-receiver.desktop $(DESTDIR)$(DESKTOP_DIR)/ppc-stream-receiver.desktop

# ── install-server ────────────────────────────────────────────────────────────
# Installs the Power Mac G5 server components (run after `make build`).

install-server:
	install -d $(DESTDIR)$(PREFIX)
	install -d $(DESTDIR)$(PREFIX)/bin
	install -d $(DESTDIR)$(PREFIX)/tools
	install -m 755 bin/audio_stream_server $(DESTDIR)$(PREFIX)/bin/audio_stream_server
	install -m 755 bin/audio_capture       $(DESTDIR)$(PREFIX)/bin/audio_capture
	install -m 755 bin/set_input           $(DESTDIR)$(PREFIX)/bin/set_input
	install -m 755 bin/audio_info          $(DESTDIR)$(PREFIX)/bin/audio_info
	install -m 755 itunes_server.py        $(DESTDIR)$(PREFIX)/itunes_server.py
	install -m 755 start_server.sh         $(DESTDIR)$(PREFIX)/start_server.sh

.PHONY: build install-client install-server
