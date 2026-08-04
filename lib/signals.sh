#!/bin/bash
# signals.sh — sample everything the mood engine is allowed to know about.
#
# Prints one "<key>\t<value>" line per signal. Values never contain tabs or
# newlines (both are stripped), so the whole file can be read back with a
# plain `while read -r key value`.
#
# Keys:
#   now_epoch hour weekday          clock
#   idle_seconds                    seconds since the last keyboard/mouse event
#   screen_locked on_console        1/0 — is anyone actually looking at this?
#   display_asleep                  1/0
#   frontmost_bundle frontmost_name what has focus right now
#   app_count apps                  regular (Dock-icon) apps currently running
#   screen                          "<w>x<h>" in pixels
#   music_app music_title music_artist music_album music_genre
#
# Everything here reads without a TCC prompt. Calendar access is deliberately
# absent: EventKit needs a signed app bundle, and an unsigned CLI just gets
# "notDetermined" forever, so it would have been a permanently dead signal.
#
# Set MW_SIGNALS_FILE to a file of the same format to replay a fixed sample
# instead of reading the machine. That is how the engine is unit-tested.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
MOODTOOL="$ROOT/bin/moodtool"

# Replay mode: hand back a recorded sample verbatim.
if [[ -n "${MW_SIGNALS_FILE:-}" ]]; then
	if [[ -r "$MW_SIGNALS_FILE" ]]; then
		cat "$MW_SIGNALS_FILE"
		exit 0
	fi
	echo "signals.sh: MW_SIGNALS_FILE not readable: $MW_SIGNALS_FILE" >&2
	exit 1
fi

# One value, sanitised. Printed even when empty so consumers can rely on the
# key existing rather than testing for its absence.
emit() {
	local key="$1" value="${2:-}"
	value="${value//$'\t'/ }"
	value="${value//$'\n'/ }"
	printf '%s\t%s\n' "$key" "$value"
}

# ------------------------------------------------------------------ clock
# One `date` for all three fields: three separate calls were three forks for
# information the first one already had.
IFS=$'\t' read -r now hour weekday < <(date '+%s	%-H	%u')
emit now_epoch "$now"
emit hour "$hour"
emit weekday "$weekday" # 1=Monday .. 7=Sunday

# ------------------------------------------------------------------ machine
# moodtool emits its own "key\tvalue" lines; pass them straight through, but
# only if it actually ran, so a missing binary degrades instead of exploding.
machine=""
if [[ -x "$MOODTOOL" ]] && machine=$("$MOODTOOL" signals 2>/dev/null); then
	printf '%s\n' "$machine"
else
	# Conservative defaults: assume someone is present and active, so a broken
	# moodtool can never make the engine think the machine is idle and asleep.
	emit idle_seconds 0
	emit screen_locked 0
	emit on_console 1
	emit display_asleep 0
	emit frontmost_bundle ""
	emit frontmost_name ""
	emit app_count 0
	emit apps ""
	emit screen "2560x1440"
fi

# ------------------------------------------------------------------ music
# Never launches a music app; reports only what is already running and playing.
#
# The AppleScript costs 0.2-0.6s, by far the most expensive thing in a run, and
# most of that is asking System Events whether Spotify or Music is running. We
# already know: moodtool listed every running app a moment ago, for free, from
# NSWorkspace. So the whole round-trip is skipped unless a music app is actually
# open — which on a typical machine is most of the time.
np=""
if [[ "${MW_READ_MUSIC:-1}" == "1" ]]; then
	music_running=1
	if [[ -n "$machine" ]]; then
		music_running=0
		case "$machine" in
		*com.spotify.client* | *com.apple.Music* | *com.apple.iTunes*) music_running=1 ;;
		esac
	fi
	if ((music_running)); then
		np=$(/usr/bin/osascript "$HERE/nowplaying.applescript" 2>/dev/null) || np=""
	fi
fi
if [[ -n "$np" ]]; then
	IFS=$'\t' read -r m_app m_title m_artist m_album m_genre <<<"$np"
	emit music_app "${m_app:-}"
	emit music_title "${m_title:-}"
	emit music_artist "${m_artist:-}"
	emit music_album "${m_album:-}"
	emit music_genre "${m_genre:-}"
else
	emit music_app ""
	emit music_title ""
	emit music_artist ""
	emit music_album ""
	emit music_genre ""
fi
