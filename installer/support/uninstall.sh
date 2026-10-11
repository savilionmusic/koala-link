#!/bin/zsh
# Removes Koala Touch. The MPC Touch's touch driver and flight recorder are shared with Paper Cut: they are removed too,
# unless Paper Cut is still installed. Koala, its songs and settings are not touched.
ME=$(id -u)
osascript -e 'tell application id "com.savilion.koala-touch" to quit' >/dev/null 2>&1
if [[ ! -d "/Applications/Paper Cut.app" ]]; then
  for label in com.savilion.mpc-touchd com.savilion.mpc-watch; do
    launchctl bootout "gui/$ME/$label" 2>/dev/null
    rm -f "$HOME/Library/LaunchAgents/$label.plist"
  done
  rm -rf "$HOME/Library/Application Support/MPC Touch Driver"
  echo "The touch driver was removed too (Paper Cut isn't installed)."
else
  echo "The touch driver stays: Paper Cut uses it."
fi
echo "Removing the app needs your Mac password:"
sudo rm -rf "/Applications/Koala Touch.app" "/Library/Application Support/Koala Touch"
sudo pkgutil --forget com.savilion.koalatouch >/dev/null 2>&1
echo "Koala Touch is removed. Koala and your songs were not touched."
