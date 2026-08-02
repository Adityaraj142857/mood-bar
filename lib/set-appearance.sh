#!/bin/bash
# set-appearance.sh <mood> — match macOS light/dark mode and accent color to a mood.
#
# Prints:  <light|dark|light!|dark!|off>\t<accent-name|accent-name!|off>
#
# A trailing "!" means the change was requested but the system did not end up in
# that state — same principle as the wallpaper setter: never report a change we
# did not confirm. "off" means the knob is disabled in config.conf.
#
# Dark mode flips immediately. The accent color is written to the global domain
# and a change notification is posted; apps that listen repaint right away, the
# rest pick it up next launch. That is how System Settings behaves too.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
MOODTOOL="$ROOT/bin/moodtool"

MOOD="${1:?usage: set-appearance.sh <mood>}"

# AppleAccentColor: -1 graphite, 0 red, 1 orange, 2 yellow, 3 green,
#                    4 blue, 5 purple, 6 pink.
case "$MOOD" in
happy) ACCENT=2 ACCENT_NAME=yellow ;;
calm) ACCENT=4 ACCENT_NAME=blue ;;
energetic) ACCENT=1 ACCENT_NAME=orange ;;
focused) ACCENT=-1 ACCENT_NAME=graphite ;;
sad) ACCENT=4 ACCENT_NAME=blue ;;
tired) ACCENT=5 ACCENT_NAME=purple ;;
romantic) ACCENT=6 ACCENT_NAME=pink ;;
horny) ACCENT=0 ACCENT_NAME=red ;;
night) ACCENT=5 ACCENT_NAME=purple ;;
stressed) ACCENT=3 ACCENT_NAME=green ;;
*) ACCENT=4 ACCENT_NAME=blue ;;
esac

# Dark is the default; only the moods listed in LIGHT_MOODS go light. Set
# LIGHT_MOODS="" in config.conf for dark mode always.
LIGHT_MOODS="${LIGHT_MOODS-happy energetic}"
if [[ " $LIGHT_MOODS " == *" $MOOD "* ]]; then WANT_DARK=false; else WANT_DARK=true; fi

case "$ACCENT_NAME" in
red) HL="1.000000 0.733333 0.721569 Red" ;;
orange) HL="1.000000 0.874510 0.701961 Orange" ;;
yellow) HL="1.000000 0.937255 0.690196 Yellow" ;;
green) HL="0.752941 0.964706 0.678431 Green" ;;
blue) HL="0.698039 0.843137 1.000000 Blue" ;;
purple) HL="0.968627 0.831373 1.000000 Purple" ;;
pink) HL="1.000000 0.749020 0.823529 Pink" ;;
graphite) HL="0.847059 0.847059 0.862745 Graphite" ;;
*) HL="0.698039 0.843137 1.000000 Blue" ;;
esac

# ------------------------------------------------------------------ dark mode
# AppleInterfaceStyle is "Dark" when dark and absent entirely when light, which
# is why this tests for the key rather than comparing two values.
is_dark_now() {
	[[ "$(/usr/bin/defaults read -g AppleInterfaceStyle 2>/dev/null)" == "Dark" ]]
}

MODE="off"
if [[ "${MW_SET_DARKMODE:-1}" == "1" ]]; then
	[[ "$WANT_DARK" == "true" ]] && MODE=dark || MODE=light
	if [[ "$WANT_DARK" == "true" ]] && is_dark_now; then
		: # already there
	elif [[ "$WANT_DARK" == "false" ]] && ! is_dark_now; then
		: # already there
	else
		/usr/bin/osascript -e \
			"tell application \"System Events\" to tell appearance preferences to set dark mode to ${WANT_DARK}" \
			>/dev/null 2>&1
		# Give the change a moment to land before reading it back.
		/bin/sleep 0.3
		if [[ "$WANT_DARK" == "true" ]] && ! is_dark_now; then
			MODE="dark!"
			echo "set-appearance: could not switch to dark mode (needs Automation permission for System Events)" >&2
		elif [[ "$WANT_DARK" == "false" ]] && is_dark_now; then
			MODE="light!"
			echo "set-appearance: could not switch to light mode (needs Automation permission for System Events)" >&2
		fi
	fi
fi

# ------------------------------------------------------------------ accent
accent_now() { /usr/bin/defaults read -g AppleAccentColor 2>/dev/null || echo none; }

ACCENT_OUT="off"
if [[ "${MW_SET_ACCENT:-1}" == "1" ]]; then
	ACCENT_OUT="$ACCENT_NAME"
	if [[ "$(accent_now)" != "$ACCENT" ]]; then
		# moodtool writes via CFPreferences and synchronizes before notifying,
		# so running apps re-read the new value instead of a stale cache.
		if [[ -x "$MOODTOOL" ]] && "$MOODTOOL" accent "$ACCENT" "$HL" >/dev/null 2>&1; then
			[[ "$(accent_now)" == "$ACCENT" ]] || ACCENT_OUT="${ACCENT_NAME}!"
		else
			ACCENT_OUT="${ACCENT_NAME}!"
			echo "set-appearance: accent change failed" >&2
		fi
	fi
fi

printf '%s\t%s\n' "$MODE" "$ACCENT_OUT"
