#!/bin/sh
#
# install.sh - install fnkeys and start it at login
#
# Answering the question directly: a shell script alone cannot start at login.
# macOS starts login items through launchd, so what a .sh script can do is be
# the thing launchd runs. That is what this does - it installs the binary and
# writes the launchd job that points at it.
#
# Why launchd and not a Login Item or a shell profile:
#
#   ~/.zshrc        only runs when a terminal opens. A background key listener
#                   has to start before anything is typed into.
#   Login Items     need an .app bundle, which needs a code signature to run
#                   without a warning, which is the thing we are avoiding.
#   launchd         runs a plain executable. No bundle, no signature.
#
# Run:  sh install.sh          install and start
#       sh install.sh --remove uninstall
#
# The job is per-user (LaunchAgent), not system-wide, because reading HID input
# for the console user needs no root and running it as root would only make the
# backlight write fail for a different reason.

set -e

LABEL="local.fnkeys"
BIN_DIR="$HOME/.local/bin"
BIN="$BIN_DIR/fnkeys"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST="$PLIST_DIR/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs"
LOG="$LOG_DIR/fnkeys.log"
SRC_DIR=$(cd "$(dirname "$0")" && pwd)

remove() {
    echo "removing $LABEL"
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || \
        launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    echo "  job removed"
    echo "  binary left at $BIN (delete it yourself if you want it gone)"
    exit 0
}

[ "$1" = "--remove" ] && remove

# --- binary ----------------------------------------------------------------

if [ ! -f "$SRC_DIR/fnkeys" ]; then
    echo "error: fnkeys binary not found next to this script." >&2
    echo "       build it first:" >&2
    echo "         swiftc -O -target x86_64-apple-macos11.0 \\" >&2
    echo "           -framework IOKit -framework CoreFoundation \\" >&2
    echo "           -o fnkeys fnkeys.swift" >&2
    exit 1
fi

mkdir -p "$BIN_DIR" "$PLIST_DIR" "$LOG_DIR"
cp "$SRC_DIR/fnkeys" "$BIN"
chmod +x "$BIN"
echo "installed binary: $BIN"

# --- launchd job -----------------------------------------------------------

# KeepAlive with RunAtLoad means it starts now and restarts if it ever exits.
# That matters because the tool owns no state: if it dies, the Fn keys go dead
# silently, and a restart is cheaper than noticing.
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>

    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <!-- A key listener that restarts in a tight loop would spam the log and
         burn CPU, so a crash has to stay down for ten seconds first. -->
    <key>ThrottleInterval</key>
    <integer>10</integer>

    <key>StandardOutPath</key>
    <string>$LOG</string>
    <key>StandardErrorPath</key>
    <string>$LOG</string>

    <!-- Same session as the console user: HID access is per-session and a
         background job without this can end up in a different one. -->
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
</dict>
</plist>
PLIST_EOF

echo "wrote job:        $PLIST"

# --- load it ---------------------------------------------------------------

# bootout first so a re-run replaces a running instance instead of failing with
# "service already loaded".
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || \
    launchctl load -w "$PLIST"

echo ""
echo "started. check it:"
echo "  launchctl list | grep $LABEL"
echo "  tail -f $LOG"
echo ""
echo "then press Fn+F2 / Fn+F3 and watch the log."
echo ""
echo "remove with:  sh $0 --remove"
