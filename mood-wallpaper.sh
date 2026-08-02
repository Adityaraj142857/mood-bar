#!/bin/bash
# mood-wallpaper — read the machine for signs of what you're doing, pick a mood,
# then match the wallpaper, appearance and accent color to it. Runs for a couple
# of seconds and exits. No daemon.
#
#   mood-wallpaper.sh                 run the pipeline (throttled)
#   mood-wallpaper.sh --force         run now, ignoring the throttle
#   mood-wallpaper.sh --offline       skip the APIs (your images, else gradient)
#   mood-wallpaper.sh --dry-run       report what it would do, change nothing
#   mood-wallpaper.sh --explain       show every signal and vote, change nothing
#
#   mood-wallpaper.sh --set-mood <mood> [hours]   pin a mood (default 3h)
#   mood-wallpaper.sh --clear-mood    drop a pinned mood
#   mood-wallpaper.sh --pause         stop auto-switching
#   mood-wallpaper.sh --resume        start auto-switching again
#
#   mood-wallpaper.sh --status        current state
#   mood-wallpaper.sh --verify        confirm the desktop really shows our image
#   mood-wallpaper.sh --history [n]   the last n runs (default 20)
#   mood-wallpaper.sh --feedback right|wrong [mood]   grade the last decision
#   mood-wallpaper.sh --report        how it has actually been doing

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$ROOT/lib"
STATE="$ROOT/state"
LOG="$ROOT/mood.log"
HISTORY="$STATE/history.tsv"
LOCK="$STATE/lock"
MOODTOOL="$ROOT/bin/moodtool"

MOODS="happy calm energetic focused sad tired romantic horny night stressed"

mkdir -p "$STATE" "$ROOT/cache"

# ----------------------------------------------------------------- config
# Keys and tunables live in config.conf, which is never committed.
MIN_INTERVAL_MINUTES=30
MAX_LOG_BYTES=1048576
MAX_HISTORY_ROWS=2000
# shellcheck source=/dev/null
[[ -f "$ROOT/config.conf" ]] && source "$ROOT/config.conf"

# A typo in config.conf must not turn into arithmetic errors three files down.
sane_int() {
	local name="$1" value="$2" fallback="$3"
	if [[ "$value" =~ ^[0-9]+$ ]]; then
		printf '%s' "$value"
	else
		printf '%s' "$fallback"
	fi
}
MIN_INTERVAL_MINUTES=$(sane_int MIN_INTERVAL_MINUTES "$MIN_INTERVAL_MINUTES" 30)
MAX_LOG_BYTES=$(sane_int MAX_LOG_BYTES "$MAX_LOG_BYTES" 1048576)
MAX_HISTORY_ROWS=$(sane_int MAX_HISTORY_ROWS "$MAX_HISTORY_ROWS" 2000)

# Everything the lib/ scripts read comes through the environment, so config.conf
# stays the single source of truth.
export UNSPLASH_ACCESS_KEY="${UNSPLASH_ACCESS_KEY:-}"
export PEXELS_API_KEY="${PEXELS_API_KEY:-}"
export NIGHT_START="${NIGHT_START:-23}"
export NIGHT_END="${NIGHT_END:-6}"
export MAX_CACHE_PER_MOOD="${MAX_CACHE_PER_MOOD:-5}"
export FALLBACK_USE_CACHE="${FALLBACK_USE_CACHE:-1}"
export PREFER_OWN_IMAGES="${PREFER_OWN_IMAGES:-1}"
export ANIME_SHARE="${ANIME_SHARE:-50}"
export MW_SET_DARKMODE="${MW_SET_DARKMODE:-1}"
export MW_SET_ACCENT="${MW_SET_ACCENT:-1}"
export LIGHT_MOODS="${LIGHT_MOODS-happy energetic}"
export CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-4}"
export CURL_MAX_TIME="${CURL_MAX_TIME:-15}"
export MW_HYSTERESIS="${MW_HYSTERESIS:-5}"
export MW_SKIP_WHEN_LOCKED="${MW_SKIP_WHEN_LOCKED:-1}"

# ----------------------------------------------------------------- plumbing
# Rotate before writing, so a long-lived install can't fill the disk with log.
rotate_log() {
	[[ -f "$LOG" ]] || return 0
	local size
	size=$(/usr/bin/stat -f%z "$LOG" 2>/dev/null || echo 0)
	((size > MAX_LOG_BYTES)) || return 0
	/bin/mv -f "$LOG" "$LOG.1" 2>/dev/null || true
}

log() {
	rotate_log
	printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG"
}

# Write via a temp file in the same directory, so a reader never catches a
# half-written state file and a crash mid-write leaves the old value intact.
write_state() {
	local file="$1" content="$2" tmp
	tmp=$(/usr/bin/mktemp "${file}.XXXXXX") || return 1
	printf '%s\n' "$content" >"$tmp" && /bin/mv -f "$tmp" "$file"
}

emoji_for() {
	case "$1" in
	happy) echo "😊" ;; calm) echo "🌊" ;; energetic) echo "⚡" ;;
	focused) echo "🎯" ;; sad) echo "🌧" ;; tired) echo "😴" ;;
	romantic) echo "💗" ;; horny) echo "🔥" ;; night) echo "🌙" ;;
	stressed) echo "🫧" ;;
	*) echo "🎨" ;;
	esac
}

is_mood() { [[ " $MOODS " == *" ${1:-} "* ]]; }

die() {
	echo "mood-wallpaper: $*" >&2
	exit 1
}

# Only one run at a time. launchd's interval fire, its wake-from-sleep catch-up
# and a manual run can all land together; without this they interleave and race
# over state files and the wallpaper store.
LOCK_HELD=0
release_lock() { ((LOCK_HELD)) && rm -rf "$LOCK"; }
acquire_lock() {
	# mkdir is atomic on every filesystem macOS mounts; flock(1) does not exist.
	if mkdir "$LOCK" 2>/dev/null; then
		echo $$ >"$LOCK/pid"
		LOCK_HELD=1
		trap release_lock EXIT INT TERM
		return 0
	fi
	local pid
	pid=$(cat "$LOCK/pid" 2>/dev/null || true)
	# A lock whose owner is gone (killed, panicked, rebooted) is stale.
	if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
		return 1
	fi
	rm -rf "$LOCK"
	mkdir "$LOCK" 2>/dev/null || return 1
	echo $$ >"$LOCK/pid"
	LOCK_HELD=1
	trap release_lock EXIT INT TERM
	return 0
}

# One row per real run, so there is something to check the tool against later.
# Columns: epoch mood source detail img_source img_file wallpaper appearance feedback
record_history() {
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "" >>"$HISTORY"
	local rows
	rows=$(/usr/bin/wc -l <"$HISTORY" 2>/dev/null | tr -d ' ')
	if [[ "$rows" =~ ^[0-9]+$ ]] && ((rows > MAX_HISTORY_ROWS)); then
		local tmp
		tmp=$(/usr/bin/mktemp "${HISTORY}.XXXXXX") &&
			/usr/bin/tail -n "$MAX_HISTORY_ROWS" "$HISTORY" >"$tmp" &&
			/bin/mv -f "$tmp" "$HISTORY"
	fi
}

signal_value() {
	# One signal out of a captured sample.
	printf '%s\n' "$1" | /usr/bin/awk -F'\t' -v k="$2" '$1==k{sub(/^[^\t]*\t/,"");print;exit}'
}

# ----------------------------------------------------------------- flags
FORCE=0
DRY=0
EXPLAIN=0
export FORCE_OFFLINE=0

while [[ $# -gt 0 ]]; do
	case "$1" in
	--force)
		FORCE=1
		shift
		;;
	--offline)
		FORCE_OFFLINE=1
		shift
		;;
	--dry-run)
		DRY=1
		FORCE=1
		shift
		;;
	--explain)
		EXPLAIN=1
		shift
		;;

	--set-mood)
		mood="${2:-}"
		hours="${3:-3}"
		is_mood "$mood" || die "unknown mood '${mood:-}'; one of: $MOODS"
		[[ "$hours" =~ ^[0-9]+$ ]] && ((hours > 0)) || die "hours must be a positive integer"
		write_state "$STATE/override" "$(printf '%s\t%s' "$mood" "$(($(date +%s) + hours * 3600))")"
		log "OVERRIDE set mood=$mood for ${hours}h"
		echo "Pinned mood to $mood $(emoji_for "$mood") for ${hours}h."
		exec "$ROOT/mood-wallpaper.sh" --force
		;;
	--clear-mood)
		rm -f "$STATE/override"
		log "OVERRIDE cleared"
		echo "Cleared pinned mood."
		exit 0
		;;
	--pause)
		: >"$STATE/paused"
		log "PAUSED"
		echo "Auto-switching paused. Resume with: $0 --resume"
		exit 0
		;;
	--resume)
		rm -f "$STATE/paused"
		log "RESUMED"
		echo "Auto-switching resumed."
		exit 0
		;;

	--status)
		if [[ -f "$STATE/paused" ]]; then echo "state:    paused"; else echo "state:    active"; fi
		if [[ -f "$STATE/override" ]]; then
			IFS=$'\t' read -r m e <"$STATE/override"
			if [[ "${e:-}" =~ ^[0-9]+$ ]] && ((e > $(date +%s))); then
				echo "pinned:   $m until $(date -r "$e" '+%H:%M')"
			else
				echo "pinned:   none (expired)"
			fi
		else
			echo "pinned:   none"
		fi
		[[ -f "$STATE/last-mood" ]] && echo "mood:     $(cat "$STATE/last-mood")"
		[[ -f "$STATE/last-image" ]] && echo "image:    $(basename "$(cat "$STATE/last-image")")"
		if [[ -f "$STATE/last-run" ]]; then
			lr=$(cat "$STATE/last-run")
			[[ "$lr" =~ ^[0-9]+$ ]] && echo "last run: $(date -r "$lr" '+%Y-%m-%d %H:%M:%S') ($((($(date +%s) - lr) / 60))m ago)"
		fi
		echo "interval: ${MIN_INTERVAL_MINUTES}m minimum between changes"
		echo "keys:     unsplash=$([[ -n "$UNSPLASH_ACCESS_KEY" ]] && echo yes || echo no) pexels=$([[ -n "$PEXELS_API_KEY" ]] && echo yes || echo no)"
		[[ -f "$HISTORY" ]] && echo "history:  $(/usr/bin/wc -l <"$HISTORY" | tr -d ' ') runs recorded"
		exit 0
		;;

	--verify)
		# Independent of anything this run did: ask the store what every Space
		# is actually showing and compare it with the image we last set.
		[[ -x "$MOODTOOL" ]] || die "moodtool not built. Run: $ROOT/install.sh"
		want=""
		[[ -f "$STATE/last-image" ]] && want=$(cat "$STATE/last-image")
		if [[ -z "$want" ]]; then
			echo "Nothing set yet — run: $0 --force"
			exit 1
		fi
		current=$("$MOODTOOL" wallpaper-current 2>&1) || die "$current"
		echo "expected: $want"
		echo
		echo "what each Space is showing:"
		printf '%s\n' "$current" | while IFS=$'\t' read -r n path; do
			mark=" "
			# moodtool canonicalises both sides; comparing here is only for
			# the tick in the listing, never for the verdict below.
			[[ "$path" == "$want" ]] && mark="✓"
			printf '  %s %2s space(s)  %s\n' "$mark" "$n" "$path"
		done
		echo
		if verdict=$("$MOODTOOL" wallpaper-verify "$want" 2>/dev/null); then
			echo "OK — every Space shows the expected picture (${verdict})."
			exit 0
		fi
		echo "MISMATCH — ${verdict:-some Spaces show something else}."
		echo "Re-apply with: $0 --force"
		exit 1
		;;

	--history)
		n="${2:-20}"
		[[ "$n" =~ ^[0-9]+$ ]] || n=20
		[[ -f "$HISTORY" ]] || die "no history yet"
		printf '%-16s  %-9s  %-8s  %-9s  %-7s  %s\n' WHEN MOOD SOURCE IMAGE GRADE DETAIL
		/usr/bin/tail -n "$n" "$HISTORY" | while IFS=$'\t' read -r ep mood src detail isrc ifile wp app fb; do
			printf '%-16s  %-9s  %-8s  %-9s  %-7s  %s\n' \
				"$(date -r "$ep" '+%m-%d %H:%M' 2>/dev/null || echo "$ep")" \
				"$mood" "$src" "$isrc" "${fb:--}" "$detail"
		done
		exit 0
		;;

	--feedback)
		verdict="${2:-}"
		actual="${3:-}"
		[[ "$verdict" == right || "$verdict" == wrong ]] ||
			die "usage: $0 --feedback right|wrong [actual-mood]"
		[[ -s "$HISTORY" ]] || die "no history to grade yet"
		if [[ -n "$actual" ]]; then
			is_mood "$actual" || die "unknown mood '$actual'; one of: $MOODS"
		fi
		note="$verdict"
		[[ "$verdict" == wrong && -n "$actual" ]] && note="wrong:$actual"
		tmp=$(/usr/bin/mktemp "${HISTORY}.XXXXXX") || die "could not write history"
		# Stamp the grade onto the final column of the most recent row only.
		/usr/bin/awk -F'\t' -v OFS='\t' -v note="$note" '
			{ rows[NR] = $0 }
			END {
				for (i = 1; i <= NR; i++) {
					if (i == NR) { n = split(rows[i], f, "\t"); f[9] = note
						line = f[1]; for (j = 2; j <= 9; j++) line = line OFS f[j]
						print line
					} else print rows[i]
				}
			}' "$HISTORY" >"$tmp" && /bin/mv -f "$tmp" "$HISTORY"
		graded=$(/usr/bin/tail -1 "$HISTORY" | /usr/bin/cut -f2)
		log "FEEDBACK $note on mood=$graded"
		echo "Recorded: the last decision ($graded) was $note."
		echo "See the running tally with: $0 --report"
		exit 0
		;;

	--report)
		[[ -s "$HISTORY" ]] || die "no history yet — let it run, then come back"
		# Formatted here, not in awk: strftime() is a gawk extension and macOS
		# ships BSD awk, where calling it aborts the whole report.
		first_ep=$(/usr/bin/head -1 "$HISTORY" | /usr/bin/cut -f1)
		last_ep=$(/usr/bin/tail -1 "$HISTORY" | /usr/bin/cut -f1)
		span=""
		if [[ "$first_ep" =~ ^[0-9]+$ && "$last_ep" =~ ^[0-9]+$ ]]; then
			span="$(date -r "$first_ep" '+%Y-%m-%d') to $(date -r "$last_ep" '+%Y-%m-%d')"
		fi
		/usr/bin/awk -F'\t' -v span="$span" '
			{
				total++
				mood[$2]++
				source[$3]++
				if ($5 != "") image[$5]++
				if ($7 !~ /^ok/) failed++
				if ($9 != "") {
					graded++
					if ($9 == "right") right++
					else {
						wrong++
						split($9, w, ":")
						if (w[2] != "") {
							# Counted explicitly: length(array) is a gawk
							# extension and this has to run under BSD awk.
							if (!(w[2] in corrected)) ncorrected++
							corrected[w[2]]++
						}
					}
				}
			}
			function bar(n, t,   i, s, w) {
				w = (t > 0) ? int(n * 24 / t) : 0
				s = ""; for (i = 0; i < w; i++) s = s "#"
				return s
			}
			END {
				printf "%d runs recorded", total
				if (span != "") printf ", %s", span
				printf "\n\n"

				print "WHAT DECIDED THE MOOD"
				for (s in source)
					printf "  %-10s %5d  %5.1f%%  %s\n", s, source[s], source[s]*100/total, bar(source[s], total)
				print "\n  signals = read from what you were doing; night/override = fixed rules."

				print "\nMOODS CHOSEN"
				for (m in mood)
					printf "  %-10s %5d  %5.1f%%  %s\n", m, mood[m], mood[m]*100/total, bar(mood[m], total)

				print "\nWHERE THE PICTURES CAME FROM"
				for (i in image)
					printf "  %-10s %5d  %5.1f%%\n", i, image[i], image[i]*100/total

				printf "\nWALLPAPER APPLIED\n  %d ok, %d failed\n", total - failed, failed

				print "\nYOUR GRADING"
				if (graded == 0) {
					print "  Nothing graded yet."
					print "  After a run that felt right or wrong, say so:"
					print "    mood-wallpaper.sh --feedback right"
					print "    mood-wallpaper.sh --feedback wrong tired"
					print "  That is the only way to know whether it reads you correctly."
				} else {
					printf "  %d of %d runs graded — %d right, %d wrong (%.0f%% accurate)\n",
						graded, total, right, wrong, right*100/graded
					if (ncorrected > 0) {
						print "\n  When it was wrong, you said it should have been:"
						for (c in corrected) printf "    %-10s %d\n", c, corrected[c]
					}
				}
			}' "$HISTORY"
		exit 0
		;;

	-h | --help)
		# The header block above, up to the first line that isn't a comment.
		# A line range would silently start leaking code the next time the
		# header grows or shrinks.
		/usr/bin/awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"
		exit 0
		;;
	*)
		die "unknown option: $1"
		;;
	esac
done

# ----------------------------------------------------------------- explain
# Read-only: never takes the lock, never touches the throttle.
if ((EXPLAIN)); then
	[[ -x "$MOODTOOL" ]] || die "moodtool not built. Run: $ROOT/install.sh"
	bash "$LIB/detect-mood.sh" --explain
	exit $?
fi

# ----------------------------------------------------------------- guards
[[ -x "$MOODTOOL" ]] || {
	log "ERROR moodtool missing — run install.sh"
	die "moodtool not built. Run: $ROOT/install.sh"
}

if ! acquire_lock; then
	log "SKIP another run is in progress"
	exit 0
fi

if [[ -f "$STATE/paused" && $FORCE -eq 0 ]]; then
	log "SKIP paused"
	exit 0
fi

# Throttle: launchd may wake us more often than we want to act (interval fire
# plus a wake-from-sleep catch-up), so the cap lives here rather than in the plist.
NOW=$(date +%s)
if [[ $FORCE -eq 0 && -f "$STATE/last-run" ]]; then
	LAST=$(cat "$STATE/last-run" 2>/dev/null || echo 0)
	[[ "$LAST" =~ ^[0-9]+$ ]] || LAST=0
	AGE=$((NOW - LAST))
	if ((AGE >= 0 && AGE < MIN_INTERVAL_MINUTES * 60)); then
		log "SKIP throttled (${AGE}s since last run, cap ${MIN_INTERVAL_MINUTES}m)"
		exit 0
	fi
fi

# Sample the machine once and let the engine replay it, rather than each of us
# asking independently. Halves the AppleScript round-trips, and — more to the
# point — the gate below and the mood decision then judge the same instant
# instead of two samples a second apart.
SIGNALS=$(bash "$LIB/signals.sh" 2>/dev/null || true)
if [[ -n "$SIGNALS" ]]; then
	SAMPLE=$(/usr/bin/mktemp "$STATE/signals.XXXXXX") && {
		printf '%s\n' "$SIGNALS" >"$SAMPLE"
		export MW_SIGNALS_FILE="$SAMPLE"
		# Chain onto the lock's cleanup so the sample never outlives the run.
		trap 'rm -f "${SAMPLE:-}"; release_lock' EXIT INT TERM
	}
fi

# Nobody is looking. Reading "what are they doing" off a locked machine gives a
# meaningless answer, and burning an API call to repaint a screen no one can see
# is pure waste — so wait for the next fire after they come back.
if [[ "$MW_SKIP_WHEN_LOCKED" == "1" && $FORCE -eq 0 && -n "$SIGNALS" ]]; then
	locked=$(signal_value "$SIGNALS" screen_locked)
	asleep=$(signal_value "$SIGNALS" display_asleep)
	console=$(signal_value "$SIGNALS" on_console)
	if [[ "$locked" == "1" || "$asleep" == "1" || "$console" == "0" ]]; then
		log "SKIP screen unavailable (locked=$locked asleep=$asleep console=$console)"
		exit 0
	fi
fi

# ----------------------------------------------------------------- pipeline
IFS=$'\t' read -r MOOD MOOD_SRC MOOD_DETAIL < <(bash "$LIB/detect-mood.sh")
if ! is_mood "${MOOD:-}"; then
	log "ERROR mood detection produced '${MOOD:-}'"
	die "mood detection failed"
fi

if ((DRY)); then
	echo "mood:   $MOOD $(emoji_for "$MOOD")"
	echo "source: $MOOD_SRC ($MOOD_DETAIL)"
	echo "(dry run — nothing changed)"
	exit 0
fi

IFS=$'\t' read -r IMG IMG_SRC IMG_WHY < <(bash "$LIB/fetch-wallpaper.sh" "$MOOD")
if [[ -z "${IMG:-}" || ! -f "$IMG" ]]; then
	log "ERROR mood=$MOOD wallpaper fetch failed entirely"
	die "could not produce a wallpaper for '$MOOD'"
fi

WP_OK=$(bash "$LIB/set-wallpaper.sh" "$IMG")
WP_RC=$?

IFS=$'\t' read -r MODE ACCENT < <(bash "$LIB/set-appearance.sh" "$MOOD")

# last-image only advances when the picture really went up, so --verify keeps
# comparing against the last thing actually applied rather than the last thing
# attempted.
if ((WP_RC == 0)); then
	write_state "$STATE/last-image" "$(cd "$(dirname "$IMG")" && printf '%s/%s' "$(pwd -P)" "$(basename "$IMG")")"
fi
write_state "$STATE/last-mood" "$MOOD"
write_state "$STATE/last-run" "$NOW"

log "RUN mood=$MOOD via=$MOOD_SRC ($MOOD_DETAIL) | image=$IMG_SRC ($IMG_WHY) | file=$(basename "$IMG") | set=$WP_OK | appearance=$MODE accent=$ACCENT"
record_history "$NOW" "$MOOD" "$MOOD_SRC" "$MOOD_DETAIL" "$IMG_SRC" "$(basename "$IMG")" "$WP_OK" "$MODE/$ACCENT"

if ((WP_RC != 0)); then
	echo "$(emoji_for "$MOOD")  $MOOD — but the wallpaper did not apply: $WP_OK" >&2
	exit 1
fi

echo "$(emoji_for "$MOOD")  $MOOD — $IMG_SRC image, $MODE mode, $ACCENT accent — $WP_OK"
