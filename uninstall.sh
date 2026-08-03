#!/bin/bash
# uninstall.sh — unload and remove the launchd agent. Leaves the project
# directory, your config.conf, your wallpapers and the cache untouched.
#
#   uninstall.sh              stop the agent
#   uninstall.sh --restore    stop it and put back the wallpaper you had before

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.arshukla.moodwallpaper"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_NUM=$(id -u)

BAR_LABEL="com.arshukla.moodbar"
BAR_PLIST="$HOME/Library/LaunchAgents/$BAR_LABEL.plist"

launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
rm -f "$PLIST"

# The menu bar indicator is the only resident process; boot it out too, and
# kill any copy started by hand that launchd doesn't know about.
launchctl bootout "gui/$UID_NUM/$BAR_LABEL" 2>/dev/null || true
rm -f "$BAR_PLIST"
/usr/bin/pkill -f "$ROOT/bin/moodbar" 2>/dev/null || true

# A lock left behind by the last run would block a future reinstall's first run.
rm -rf "$ROOT/state/lock"

echo "Removed $PLIST and $BAR_PLIST."

if [[ "${1:-}" == "--restore" ]]; then
	# Put the system-wide icon style back the way it was before the first run.
	if [[ -f "$ROOT/state/original-icon-appearance" && -x "$ROOT/bin/moodtool" ]]; then
		IFS=$'\t' read -r theme tint <"$ROOT/state/original-icon-appearance"
		if [[ -n "${theme:-}" ]] && "$ROOT/bin/moodtool" icon-theme "$theme" "${tint:-}" >/dev/null 2>&1; then
			echo "Restored the icon style to ${theme}/${tint:-none}."
		fi
	fi

	# The wallpaper this tool set stays on screen after the agent is gone, and
	# it lives in cache/, which is not somewhere you want your desktop picture
	# pointing at long-term. Hand the desktop back to a macOS default.
	DEFAULT="/System/Library/Desktop Pictures/Sonoma Graphic.heic"
	[[ -f "$DEFAULT" ]] || DEFAULT=$(/usr/bin/find "/System/Library/Desktop Pictures" \
		-maxdepth 1 -type f \( -name '*.heic' -o -name '*.jpg' \) 2>/dev/null | /usr/bin/head -1)
	if [[ -n "$DEFAULT" && -x "$ROOT/bin/moodtool" ]]; then
		"$ROOT/bin/moodtool" wallpaper "$DEFAULT" >/dev/null &&
			echo "Restored the desktop picture to $(basename "$DEFAULT")."
	else
		echo "Could not find a system wallpaper to restore; set one in System Settings." >&2
	fi
fi

echo "Project files in $ROOT were left in place."
echo "To remove everything: rm -rf \"$ROOT\""
