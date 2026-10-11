#!/bin/zsh
# Installs the read-only MPC flight recorder as LaunchAgent com.savilion.mpc-watch (no sudo).
# Remove: launchctl bootout gui/$(id -u)/com.savilion.mpc-watch; rm ~/Library/LaunchAgents/com.savilion.mpc-watch.plist
set -e
cd "$(dirname $0)"
LABEL=com.savilion.mpc-watch
DEST="$HOME/Library/Application Support/MPC Touch Driver"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
./build-watch.sh
mkdir -p "$DEST"
launchctl bootout gui/$(id -u)/$LABEL 2>/dev/null || true
cp mpc_watch "$DEST/mpc_watch"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key><array><string>$DEST/mpc_watch</string></array>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><true/>
	<key>ThrottleInterval</key><integer>10</integer>
	<key>StandardOutPath</key><string>$HOME/Library/Logs/mpc_watch.log</string>
	<key>StandardErrorPath</key><string>$HOME/Library/Logs/mpc_watch.log</string>
</dict>
</plist>
PL
launchctl bootstrap gui/$(id -u) "$PLIST"
echo "watching → ~/Library/Logs/mpc_watch.log"
