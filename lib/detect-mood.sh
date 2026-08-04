#!/bin/bash
# detect-mood.sh — decide the current mood from observed signals.
#
#   detect-mood.sh              print "<mood>\t<source>\t<detail>"
#   detect-mood.sh --explain    print every signal, every vote and the scores
#
# source is one of: override | night | signals
#
# HOW IT DECIDES
#
# Signals (see signals.sh) cast weighted votes for moods; the highest total
# wins. Nothing is a first-match cutoff, so a weak clock prior can be overruled
# by strong evidence, and every vote survives into --explain. Two hard rules sit
# outside the scoring: a manual --set-mood override, and the night window.
#
# Scores are integer tenths throughout (30 = 3.0 points) because macOS ships
# bash 3.2, which has neither floating point nor associative arrays.
#
# WHAT IT CANNOT KNOW
#
# There is no affect sensing here. The machine can see what you are using, how
# long since you touched it, and what is playing — that is genuinely correlated
# with focus, load and tiredness, and honestly unrelated to sadness or romance.
# So `sad`, `romantic` and `horny` are reachable only from music keywords or a
# manual override, and nothing infers them from your behaviour.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"

EXPLAIN=0
[[ "${1:-}" == "--explain" ]] && EXPLAIN=1

NIGHT_START="${NIGHT_START:-23}"
NIGHT_END="${NIGHT_END:-6}"
# Points the leader must beat the previous mood by before the wallpaper moves.
# Stops two near-tied moods swapping back and forth every half hour.
HYSTERESIS="${MW_HYSTERESIS:-5}"

# Tie-break order: earlier entries win an exact tie. Ordered so that the moods
# driven by real evidence beat the ones that are mostly clock priors.
MOODS=(focused stressed energetic happy calm tired sad romantic horny night)
SCORES=(0 0 0 0 0 0 0 0 0 0)
EVIDENCE=()

score_index() {
	local want="$1" i
	for i in "${!MOODS[@]}"; do
		[[ "${MOODS[$i]}" == "$want" ]] && {
			printf '%s' "$i"
			return 0
		}
	done
	return 1
}

# vote <mood> <tenths> <signal> <detail>
vote() {
	local mood="$1" points="$2" signal="$3" detail="$4" i
	i=$(score_index "$mood") || return 0
	SCORES[$i]=$((SCORES[i] + points))
	EVIDENCE+=("$(printf '%s\t%s\t%s\t%s' "$signal" "$mood" "$points" "$detail")")
}

# 35 -> "3.5"
tenths() { printf '%d.%d' $(($1 / 10)) $(($1 % 10)); }

# ---------------------------------------------------------------- read signals
SIGNALS=$(bash "$HERE/signals.sh") || {
	echo "detect-mood: could not sample signals" >&2
	exit 1
}

# One pass, no subprocesses. The previous version ran `awk` once per key, which
# is eleven forks on the hot path to read eleven short strings that were already
# in memory. `read` is a builtin, so this walks the sample entirely inside bash.
hour="" idle="" front_bundle="" front_name="" app_count="" apps=""
m_app="" m_title="" m_artist="" m_album="" m_genre=""
while IFS=$'\t' read -r key value; do
	case "$key" in
	hour) hour="$value" ;;
	idle_seconds) idle="$value" ;;
	frontmost_bundle) front_bundle="$value" ;;
	frontmost_name) front_name="$value" ;;
	app_count) app_count="$value" ;;
	apps) apps="$value" ;;
	music_app) m_app="$value" ;;
	music_title) m_title="$value" ;;
	music_artist) m_artist="$value" ;;
	music_album) m_album="$value" ;;
	music_genre) m_genre="$value" ;;
	esac
done <<<"$SIGNALS"

# Signals are advisory, never fatal: a garbled value becomes a neutral one.
[[ "$hour" =~ ^[0-9]+$ ]] || hour=$(date +%-H)
[[ "$idle" =~ ^[0-9]+$ ]] || idle=0
[[ "$app_count" =~ ^[0-9]+$ ]] || app_count=0

emit() {
	local mood="$1" source="$2" detail="$3"
	printf '%s\t%s\t%s\n' "$mood" "$source" "$detail"
}

# ---------------------------------------------------------------- hard rule: override
# state/override holds "<mood>\t<expiry-epoch>", written by --set-mood.
OVERRIDE_FILE="$ROOT/state/override"
if [[ -f "$OVERRIDE_FILE" ]]; then
	IFS=$'\t' read -r ov_mood ov_expiry <"$OVERRIDE_FILE" || true
	now=$(date +%s)
	if [[ -n "${ov_mood:-}" && "${ov_expiry:-}" =~ ^[0-9]+$ ]] && ((now < ov_expiry)); then
		mins=$(((ov_expiry - now) / 60))
		if ((EXPLAIN)); then
			echo "mood:   $ov_mood"
			echo "source: override (pinned by hand, ${mins}m left)"
			echo
			echo "Scoring was skipped entirely — a pinned mood wins outright."
			echo "Clear it with: mood-wallpaper.sh --clear-mood"
			exit 0
		fi
		emit "$ov_mood" "override" "manual, ${mins}m left"
		exit 0
	fi
	rm -f "$OVERRIDE_FILE" # expired
fi

# ---------------------------------------------------------------- hard rule: night
in_night=0
if ((NIGHT_START > NIGHT_END)); then
	((hour >= NIGHT_START || hour < NIGHT_END)) && in_night=1
else
	((NIGHT_START != NIGHT_END)) && ((hour >= NIGHT_START && hour < NIGHT_END)) && in_night=1
fi
if ((in_night)); then
	if ((EXPLAIN)); then
		echo "mood:   night"
		echo "source: night window (${NIGHT_START}:00-${NIGHT_END}:00, now ${hour}:00)"
		echo
		echo "Scoring was skipped — inside the night window the mood is always"
		echo "'night', so a 3am playlist can't throw a bright wallpaper at you."
		echo "Change the window with NIGHT_START / NIGHT_END in config.conf."
		exit 0
	fi
	emit night "night" "${hour}h inside night window ${NIGHT_START}-${NIGHT_END}"
	exit 0
fi

# ---------------------------------------------------------------- S1: clock prior
# Deliberately the weakest signal in the model. It only decides the outcome
# when nothing else has an opinion.
if ((hour < 9)); then
	vote calm 10 time "${hour}h early morning"
	vote focused 5 time "${hour}h early morning"
elif ((hour < 12)); then
	vote focused 12 time "${hour}h late morning"
	vote energetic 4 time "${hour}h late morning"
elif ((hour < 17)); then
	vote energetic 10 time "${hour}h afternoon"
	vote focused 8 time "${hour}h afternoon"
elif ((hour < 20)); then
	vote happy 10 time "${hour}h evening"
	vote calm 5 time "${hour}h evening"
else
	vote calm 10 time "${hour}h wind-down"
	vote tired 4 time "${hour}h wind-down"
fi

# ---------------------------------------------------------------- S2: idle time
# The single most reliable thing the machine knows about you.
if ((idle >= 1800)); then
	vote tired 30 idle "$((idle / 60))m since you touched it"
	vote calm 10 idle "$((idle / 60))m since you touched it"
elif ((idle >= 600)); then
	vote tired 15 idle "$((idle / 60))m since you touched it"
	vote calm 10 idle "$((idle / 60))m since you touched it"
fi
active=0
((idle < 300)) && active=1

# ---------------------------------------------------------------- S3: frontmost app
# Category of whatever has focus. Bundle IDs, not names, so a renamed or
# localised app still classifies.
app_category() {
	case "$1" in
	com.microsoft.VSCode | com.apple.dt.Xcode | com.jetbrains.* | com.sublimetext.* | \
		dev.zed.Zed | com.todesktop.* | com.exafunction.windsurf | com.visualstudio.code.oss)
		echo dev ;;
	com.apple.Terminal | com.googlecode.iterm2 | dev.warp.Warp-Stable | com.github.wez.wezterm | \
		net.kovidgoyal.kitty | com.mitchellh.ghostty)
		echo terminal ;;
	us.zoom.xos | com.microsoft.teams2 | com.cisco.webexmeetingsapp | com.readdle.Spark.meet)
		echo meeting ;;
	com.tinyspeck.slackmacgap | com.microsoft.teams | net.whatsapp.WhatsApp | com.hnc.Discord | \
		com.apple.mail | ru.keepcoder.Telegram | org.telegram.desktop | com.apple.MobileSMS | \
		com.readdle.smartemail.Mac)
		echo comms ;;
	com.figma.Desktop | com.adobe.* | com.bohemiancoding.sketch3 | com.seriflabs.affinity*)
		echo design ;;
	com.apple.TV | com.netflix.Netflix | org.videolan.vlc | com.colliderli.iina | \
		com.apple.QuickTimePlayerX | tv.plex.desktop)
		echo media ;;
	com.valvesoftware.steam | com.epicgames.EpicGamesLauncher | com.riotgames.*)
		echo gaming ;;
	notion.id | md.obsidian | com.apple.Notes | com.apple.iWork.* | com.microsoft.Word | \
		com.microsoft.Excel | com.microsoft.Powerpoint | com.apple.Preview)
		echo docs ;;
	com.apple.Safari | com.google.Chrome | com.brave.Browser | org.mozilla.firefox | \
		com.microsoft.edgemac | company.thebrowser.Browser)
		echo browser ;;
	"") echo none ;;
	*) echo other ;;
	esac
}

front_cat=$(app_category "$front_bundle")
front_label="${front_name:-$front_bundle}"
# Only counts while you are actually at the machine — the frontmost app of a
# laptop you walked away from an hour ago says nothing about you now.
if ((active)); then
	case "$front_cat" in
	dev | terminal) vote focused 30 app "$front_label (${front_cat})" ;;
	design)
		vote focused 20 app "$front_label (design)"
		vote energetic 5 app "$front_label (design)"
		;;
	docs) vote focused 20 app "$front_label (docs)" ;;
	meeting)
		vote stressed 25 app "$front_label (meeting)"
		vote focused 10 app "$front_label (meeting)"
		;;
	comms)
		vote stressed 15 app "$front_label (comms)"
		vote focused 5 app "$front_label (comms)"
		;;
	media)
		vote happy 20 app "$front_label (media)"
		vote calm 5 app "$front_label (media)"
		;;
	gaming)
		vote energetic 25 app "$front_label (gaming)"
		vote happy 10 app "$front_label (gaming)"
		;;
	# A browser is genuinely ambiguous — it is work and leisure in equal
	# measure — so it gets a nudge, not a verdict.
	browser) vote focused 5 app "$front_label (browser)" ;;
	esac
fi

# ---------------------------------------------------------------- S4: load
# How many things you have going at once, as a proxy for context-switching cost.
if ((app_count >= 12)); then
	vote stressed 15 load "${app_count} apps open"
elif ((app_count >= 8)); then
	vote stressed 7 load "${app_count} apps open"
fi

comms_open=0
for b in com.tinyspeck.slackmacgap com.microsoft.teams com.microsoft.teams2 \
	net.whatsapp.WhatsApp com.hnc.Discord com.apple.mail org.telegram.desktop; do
	[[ " $apps " == *" $b "* ]] && comms_open=$((comms_open + 1))
done
((comms_open >= 3)) && vote stressed 10 load "${comms_open} chat apps running"

# ---------------------------------------------------------------- S5: music
# Ordered keyword table; the first mood whose pattern hits the track metadata
# wins the music vote. Distinctive moods come before broad catch-alls, so
# "sad" is tested before "pop".
haystack=$(printf '%s %s %s %s' "$m_title" "$m_artist" "$m_album" "$m_genre" |
	tr '[:upper:]' '[:lower:]')

music_mood=""
music_kw=""
if [[ -n "$m_app" && -n "$haystack" ]]; then
	while IFS='|' read -r mood pattern; do
		[[ -z "$mood" || "$mood" == \#* ]] && continue
		# head -1 caps matches, not lines: a title hitting two keywords would
		# otherwise put a newline into the tab-separated record printed below.
		if hit=$(printf '%s' "$haystack" | grep -oE "$pattern" | head -1) && [[ -n "$hit" ]]; then
			music_mood="$mood"
			music_kw="$hit"
			break
		fi
	done <<'TABLE'
energetic|edm|remix|hype|bass|pump|workout|metal|punk|techno|rave|banger|trap|dubstep|hard rock|drum ?& ?bass|adrenaline|hardstyle|phonk|breakcore
horny|seduc|sensual|sultry|lust|desire|temptation|aphrodisiac|foreplay|bedroom eyes|body heat|turn me on
romantic|love|heart|kiss|amour|romance|slow jam|valentine|beloved|darling|r&b|crush|sweetheart
tired|lullaby|drowsy|nocturne|dream|half asleep|slowed|reverb|bedtime|sleepy
sad|sad|blues|cry|alone|lonely|melancholy|requiem|sorrow|goodbye|broken|tears|grief|elegy|heartbreak|miss you
focused|instrumental|study|classical|minimal|deep focus|concentrat|baroque|mozart|bach|chopin|white noise|soundtrack|score|post-rock
calm|lofi|lo-fi|chill|ambient|piano|acoustic|sleep|rain|meditat|spa|serene|jazz|bossa|folk|nature
happy|happy|sunshine|dance|party|feel good|pop|smile|joy|celebrat|good vibes|summer|funk|disco|upbeat
TABLE
fi

if [[ -n "$music_mood" ]]; then
	vote "$music_mood" 35 music "${m_app}: ${m_artist:-?} — ${m_title:-?} [kw:${music_kw}]"
elif [[ -n "$m_app" ]]; then
	# Playing, but nothing matched. That is still evidence you are up and
	# doing something, just not evidence of which mood.
	vote energetic 5 music "${m_app}: ${m_artist:-?} — ${m_title:-?} [no keyword]"
	vote happy 5 music "${m_app}: ${m_artist:-?} — ${m_title:-?} [no keyword]"
fi

# ---------------------------------------------------------------- S6: burning the candle
if ((active)) && ((hour >= 22 || hour < 5)); then
	vote tired 15 late "still active at ${hour}h"
fi

# ---------------------------------------------------------------- pick a winner
best_i=0
for i in "${!MOODS[@]}"; do
	# Strict >, so an exact tie is broken by MOODS order (documented above).
	((SCORES[i] > SCORES[best_i])) && best_i=$i
done
WINNER="${MOODS[$best_i]}"
WINNER_SCORE="${SCORES[$best_i]}"

# Hysteresis: hold the previous mood unless the new leader clears it by a
# margin. Without this two moods a fraction of a point apart trade the
# wallpaper back and forth every interval.
HELD=""
HELD_SCORE=0
PREV=""
[[ -f "$ROOT/state/last-mood" ]] && PREV=$(<"$ROOT/state/last-mood")
if [[ -n "$PREV" && "$PREV" != "$WINNER" ]] && prev_i=$(score_index "$PREV"); then
	if ((WINNER_SCORE - SCORES[prev_i] < HYSTERESIS)); then
		HELD="$WINNER"
		HELD_SCORE="$WINNER_SCORE"
		WINNER="$PREV"
		WINNER_SCORE="${SCORES[$prev_i]}"
		best_i=$prev_i
	fi
fi

# After hysteresis, not before: the runner-up has to be relative to whichever
# mood actually won, or a held mood gets reported as the runner-up to itself.
runner_i=-1
for i in "${!MOODS[@]}"; do
	((i == best_i)) && continue
	if ((runner_i < 0)) || ((SCORES[i] > SCORES[runner_i])); then runner_i=$i; fi
done

# ---------------------------------------------------------------- output
if ((EXPLAIN)); then
	echo "mood:   $WINNER"
	echo "source: signals"
	echo
	echo "SIGNALS OBSERVED"
	printf '  %-18s %s\n' "time" "${hour}:00"
	printf '  %-18s %ss%s\n' "idle" "$idle" "$( ((active)) && echo " (at the machine)" || echo " (away)")"
	printf '  %-18s %s\n' "frontmost" "${front_label:-none} [${front_cat}]"
	printf '  %-18s %s\n' "apps open" "$app_count"
	if [[ -n "$m_app" ]]; then
		printf '  %-18s %s\n' "playing" "$m_app: ${m_artist:-?} — ${m_title:-?}"
	else
		printf '  %-18s %s\n' "playing" "nothing"
	fi
	echo
	echo "VOTES CAST"
	if ((${#EVIDENCE[@]} == 0)); then
		echo "  (none)"
	else
		for e in "${EVIDENCE[@]}"; do
			IFS=$'\t' read -r s m p d <<<"$e"
			printf '  %-8s %-10s %+5s   %s\n' "$s" "$m" "$(tenths "$p")" "$d"
		done
	fi
	echo
	echo "SCORES"
	# Descending, so the shape of the decision is obvious at a glance.
	for i in "${!MOODS[@]}"; do
		printf '%s\t%s\n' "${SCORES[$i]}" "${MOODS[$i]}"
	done | sort -rn | while IFS=$'\t' read -r p m; do
		marker="  "
		[[ "$m" == "$WINNER" ]] && marker="->"
		printf '  %s %-10s %s\n' "$marker" "$m" "$(tenths "$p")"
	done
	if [[ -n "$HELD" ]]; then
		echo
		echo "HELD: '$HELD' scored highest ($(tenths "$HELD_SCORE")) but did not beat the"
		echo "      current mood '$PREV' ($(tenths "$WINNER_SCORE")) by the $(tenths "$HYSTERESIS")-point"
		echo "      hysteresis margin, so the wallpaper stays put. Tune with MW_HYSTERESIS."
	fi
	exit 0
fi

detail="$(tenths "$WINNER_SCORE")"
if ((runner_i >= 0)); then
	detail="$detail over ${MOODS[$runner_i]} $(tenths "${SCORES[$runner_i]}")"
fi
# The two or three votes that actually carried it, biggest first.
top=$(
	for e in "${EVIDENCE[@]}"; do
		IFS=$'\t' read -r s m p d <<<"$e"
		[[ "$m" == "$WINNER" ]] && printf '%s\t%s:%s\n' "$p" "$s" "$(tenths "$p")"
	done | sort -rn | head -3 | cut -f2 | paste -sd' ' -
)
[[ -n "$top" ]] && detail="$detail [$top]"
[[ -n "$HELD" ]] && detail="$detail (kept; $HELD led $(tenths "$HELD_SCORE") but not by $(tenths "$HYSTERESIS"))"

emit "$WINNER" "signals" "$detail"
