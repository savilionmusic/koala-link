#!/bin/zsh
# Installs mpc_touchd v3 for this user (no sudo) and (re)starts its LaunchAgent.
# Leaves /usr/local/bin/mpc_touchd and /usr/local/bin/mpc_touchd.v1-backup untouched.
set -e
cd "$(dirname $0)"
LABEL=com.savilion.mpc-touchd
DEST="$HOME/Library/Application Support/MPC Touch Driver"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/mpc_touchd.log"

./build.sh
mkdir -p "$DEST"
# Keep the LaunchAgent that was there before v3 (once), for rollback.
if [[ -f "$PLIST" && ! -f "$DEST/previous-launchagent.plist" ]]; then
  cp "$PLIST" "$DEST/previous-launchagent.plist"
fi
launchctl bootout gui/$(id -u)/$LABEL 2>/dev/null || true
cp mpc_touchd "$DEST/mpc_touchd"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$DEST/mpc_touchd</string>
		<string>--pinch-gain</string>
		<string>500</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ThrottleInterval</key>
	<integer>5</integer>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardOutPath</key>
	<string>$LOG</string>
	<key>StandardErrorPath</key>
	<string>$LOG</string>
</dict>
</plist>
EOF

launchctl bootstrap gui/$(id -u) "$PLIST"
echo "installed: $DEST/mpc_touchd"
echo "log:       $LOG"
sleep 4
tail -8 "$LOG"
