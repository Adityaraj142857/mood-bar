#!/bin/bash
# install.sh — build moodtool, create config.conf, load the launchd agent.
# Safe to re-run; it reloads rather than duplicating.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.arshukla.moodwallpaper"
AGENT_DIR="$HOME/Library/LaunchAgents"
PLIST="$AGENT_DIR/$LABEL.plist"

command -v /usr/bin/swiftc >/dev/null || {
	echo "swiftc not found. Install the Xcode command line tools:" >&2
	echo "    xcode-select --install" >&2
	exit 1
}

echo "==> Building moodtool"
mkdir -p "$ROOT/bin" "$ROOT/cache" "$ROOT/state"
/usr/bin/swiftc -O -o "$ROOT/bin/moodtool" "$ROOT/src/moodtool.swift"
chmod +x "$ROOT/bin/moodtool"

# A binary that builds but cannot run (wrong arch, missing framework) would
# otherwise only show up as a silent launchd failure every 15 minutes.
"$ROOT/bin/moodtool" screensize >/dev/null || {
	echo "moodtool built but will not run." >&2
	exit 1
}

# MOODBAR=0 ./install.sh for a strictly daemon-free setup.
MOODBAR="${MOODBAR:-1}"
if [[ "$MOODBAR" == "1" ]]; then
	echo "==> Building moodbar (menu bar indicator)"
	/usr/bin/swiftc -O -o "$ROOT/bin/moodbar" "$ROOT/src/moodbar.swift"
	chmod +x "$ROOT/bin/moodbar"
fi

echo "==> Marking scripts executable"
chmod +x "$ROOT/mood-wallpaper.sh" "$ROOT"/lib/*.sh "$ROOT/install.sh" "$ROOT/uninstall.sh" \
	"$ROOT/test.sh" 2>/dev/null || true

if [[ ! -f "$ROOT/config.conf" ]]; then
	cp "$ROOT/config.conf.example" "$ROOT/config.conf"
	chmod 600 "$ROOT/config.conf"
	echo "==> Created config.conf (add your API key there; see the comments in it)"
else
	# The file holds API keys and predates this check on older installs.
	chmod 600 "$ROOT/config.conf"
	echo "==> config.conf already exists, leaving it alone"
fi

echo "==> Installing launchd agent"
mkdir -p "$AGENT_DIR"

# How often launchd wakes the script. Each wake that lands inside the throttle
# costs ~0.01s and exits, so this only needs to be small enough that the script
# reacts promptly after a wake-from-sleep; MIN_INTERVAL_MINUTES in config.conf
# is what actually governs how often the wallpaper changes.
WAKE_SECONDS="${WAKE_SECONDS:-900}"
# The template is path-agnostic: this repo can live anywhere, so the agent is
# pointed at wherever install.sh is running from. Getting this wrong fails
# silently — launchd just exits 127 into the err log every 15 minutes.
/usr/bin/sed -e "s|__ROOT__|$ROOT|g" \
	-e "s|__WAKE_SECONDS__|$WAKE_SECONDS|g" \
	"$ROOT/$LABEL.plist" >"$PLIST"

/usr/bin/plutil -lint "$PLIST" >/dev/null || {
	echo "generated a malformed plist at $PLIST" >&2
	exit 1
}

# Start each install with clean crash logs, so anything in them afterwards is
# from this version and not from something fixed three installs ago.
: >"$ROOT/state/launchd.out.log"
: >"$ROOT/state/launchd.err.log"

# A lock left behind by a killed run would make every future run a no-op.
rm -rf "$ROOT/state/lock"

UID_NUM=$(id -u)
launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$PLIST"
launchctl enable "gui/$UID_NUM/$LABEL"

# The menu bar indicator is a second, separate agent — it is the only resident
# process here, and keeping it separate means it can be removed on its own.
BAR_LABEL="com.arshukla.moodbar"
BAR_PLIST="$AGENT_DIR/$BAR_LABEL.plist"
launchctl bootout "gui/$UID_NUM/$BAR_LABEL" 2>/dev/null || true
if [[ "$MOODBAR" == "1" ]]; then
	echo "==> Installing menu bar indicator"
	/usr/bin/sed -e "s|__ROOT__|$ROOT|g" "$ROOT/$BAR_LABEL.plist" >"$BAR_PLIST"
	/usr/bin/plutil -lint "$BAR_PLIST" >/dev/null || {
		echo "generated a malformed plist at $BAR_PLIST" >&2
		exit 1
	}
	: >"$ROOT/state/moodbar.out.log"
	: >"$ROOT/state/moodbar.err.log"
	launchctl bootstrap "gui/$UID_NUM" "$BAR_PLIST"
	launchctl enable "gui/$UID_NUM/$BAR_LABEL"
else
	rm -f "$BAR_PLIST"
	echo "==> Skipping the menu bar indicator (MOODBAR=0)"
fi

echo
echo "Installed."
echo "  Agent:  $PLIST"
echo "  Config: $ROOT/config.conf"
echo "  Wakes:  every ${WAKE_SECONDS}s (throttled inside the script)"
echo
echo "Next:"
echo "  1. Add an Unsplash or Pexels key to config.conf (links are in the file)."
echo "  2. Run: $ROOT/mood-wallpaper.sh --force"
echo "     macOS will ask for permission to control System Events / Music / Spotify."
echo "     Approve those once and it runs silently from then on."
echo
echo "To see what it is doing:"
echo "  $ROOT/mood-wallpaper.sh --explain    what it thinks you're doing, and why"
echo "  $ROOT/mood-wallpaper.sh --verify     confirm every Space really changed"
echo "  $ROOT/mood-wallpaper.sh --report     how it has been doing over time"
