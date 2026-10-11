#!/bin/zsh
# Koala Link (a copy of Paper Cut's script, same driver and LaunchAgents): installs (or updates) the MPC Touch touch driver, the flight recorder and the helper
# tools for the current user, and starts them. Run by the installer as the logged-in user; safe to
# run again by hand. Nothing is replaced unless it changed, and a replaced file is kept as
# <name>.before-install. Exit code 10 means the touch driver changed (macOS asks for the
# Accessibility permission once for a new driver build).
set -u
SRC="${PAPERCUT_SOURCE:-/Library/Application Support/Koala Touch/TouchDriver}"
[[ -d "$SRC" ]] || SRC="/Applications/Koala Link.app/Contents/Resources/TouchDriver"
# PAPERCUT_DRY_RUN=1: only print what launchctl would change (for testing).
lc() {
  if [[ -n "${PAPERCUT_DRY_RUN:-}" && "$1" != print ]]; then echo "would run: launchctl $*"; return 0; fi
  launchctl "$@"
}
DEST="$HOME/Library/Application Support/MPC Touch Driver"
AGENTS="$HOME/Library/LaunchAgents"
LOGS="$HOME/Library/Logs"
ME=$(id -u)
mkdir -p "$DEST" "$AGENTS" "$LOGS"

changed_driver=0
changed_watch=0
for tool in mpc_touchd mpc_replug mpc_diag mpc_watch; do
  [[ -f "$SRC/$tool" ]] || continue
  if [[ -f "$DEST/$tool" ]] && cmp -s "$SRC/$tool" "$DEST/$tool"; then continue; fi
  [[ -f "$DEST/$tool" ]] && mv -f "$DEST/$tool" "$DEST/$tool.before-install"
  cp "$SRC/$tool" "$DEST/$tool" && chmod 755 "$DEST/$tool"
  [[ $tool == mpc_touchd ]] && changed_driver=1
  [[ $tool == mpc_watch ]] && changed_watch=1
done

write_agent() {
  local label=$1 program=$2 log=$3 interactive=$4
  local extra=""
  local args=""
  [[ $interactive == yes ]] && extra=$'\n\t<key>ProcessType</key>\n\t<string>Interactive</string>'
  [[ $label == com.savilion.mpc-touchd ]] && args=$'\n\t\t<string>--pinch-gain</string>\n\t\t<string>500</string>'
  cat > "$AGENTS/$label.plist.new" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$label</string>
	<key>ProgramArguments</key>
	<array>
		<string>$program</string>$args
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ThrottleInterval</key>
	<integer>5</integer>$extra
	<key>StandardOutPath</key>
	<string>$log</string>
	<key>StandardErrorPath</key>
	<string>$log</string>
</dict>
</plist>
EOF
  # Only replace an agent whose settings differ (so a running driver isn't disturbed).
  if [[ -f "$AGENTS/$label.plist" ]] && cmp -s "$AGENTS/$label.plist.new" "$AGENTS/$label.plist"; then
    rm -f "$AGENTS/$label.plist.new"; return 1
  fi
  mv -f "$AGENTS/$label.plist.new" "$AGENTS/$label.plist"; return 0
}

start_agent() {
  local label=$1 changed=$2
  if lc print "gui/$ME/$label" >/dev/null 2>&1; then
    if [[ $changed == 1 ]]; then
      lc bootout "gui/$ME/$label" 2>/dev/null; sleep 1
      lc bootstrap "gui/$ME" "$AGENTS/$label.plist"
    fi
  else
    lc bootstrap "gui/$ME" "$AGENTS/$label.plist"
  fi
}

write_agent com.savilion.mpc-touchd "$DEST/mpc_touchd" "$LOGS/mpc_touchd.log" yes && changed_driver=1
write_agent com.savilion.mpc-watch "$DEST/mpc_watch" "$LOGS/mpc_watch.log" no && changed_watch=1
start_agent com.savilion.mpc-touchd $changed_driver
start_agent com.savilion.mpc-watch $changed_watch

if [[ $changed_driver == 1 ]]; then echo "Koala Link: touch driver installed/updated"; exit 10; fi
echo "Koala Link: touch driver already up to date"
exit 0
