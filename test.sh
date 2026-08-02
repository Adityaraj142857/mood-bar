#!/bin/bash
# test.sh — exercise every path through the pipeline.
#
# Hermetic by construction:
#   * orchestrator tests run against a throwaway copy of the project in $TMPDIR,
#     so your real mood.log, state/ and history never move;
#   * mood-engine tests replay recorded signal samples through MW_SIGNALS_FILE
#     instead of reading the machine, so they give the same answer at 3am as at
#     noon and on a machine with nothing playing;
#   * the one test that genuinely has to touch the desktop saves the current
#     picture first and puts it back at the end.
#
# No API key required. Network tests degrade to a SKIP when offline.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOODTOOL="$ROOT/bin/moodtool"
PASS=0
FAIL=0
SKIP=0

ok() {
	printf '  \033[32mPASS\033[0m %s\n' "$1"
	PASS=$((PASS + 1))
}
no() {
	printf '  \033[31mFAIL\033[0m %s\n' "$1"
	FAIL=$((FAIL + 1))
}
skip() {
	printf '  \033[33mSKIP\033[0m %s\n' "$1"
	SKIP=$((SKIP + 1))
}
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1 (got '$2', want '$3')"; fi; }
contains() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else no "$1 (got '$2', want it to contain '$3')"; fi; }

ALL_MOODS="happy calm energetic focused sad tired romantic horny night stressed"

# ------------------------------------------------------------------ sandbox
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mwtest.XXXXXX") || exit 1
# $TMPDIR usually ends in a slash, and macOS symlinks /var to /private/var, so
# the raw path compares unequal to the one every other tool hands back.
WORK=$(cd "$WORK" && pwd -P)
SANDBOX="$WORK/project"
mkdir -p "$SANDBOX"/lib "$SANDBOX"/bin "$SANDBOX"/src \
	"$SANDBOX"/state "$SANDBOX"/cache "$SANDBOX"/wallpapers
cp "$ROOT"/mood-wallpaper.sh "$SANDBOX/"
cp "$ROOT"/lib/* "$SANDBOX/lib/"
cp "$ROOT"/src/* "$SANDBOX/src/"
[[ -x "$MOODTOOL" ]] && cp "$MOODTOOL" "$SANDBOX/bin/"
# Deliberately no config.conf: the sandbox must not inherit real API keys.

# The desktop picture is global state. Remember it and put it back.
ORIGINAL_WALLPAPER=""
if [[ -x "$MOODTOOL" ]]; then
	ORIGINAL_WALLPAPER=$("$MOODTOOL" wallpaper-current 2>/dev/null | /usr/bin/head -1 | /usr/bin/cut -f2)
fi

cleanup() {
	if [[ -n "$ORIGINAL_WALLPAPER" && -f "$ORIGINAL_WALLPAPER" ]]; then
		"$MOODTOOL" wallpaper "$ORIGINAL_WALLPAPER" >/dev/null 2>&1 &&
			printf '\nrestored the original wallpaper (%s)\n' "$(basename "$ORIGINAL_WALLPAPER")"
	fi
	rm -rf "$WORK"
}
trap cleanup EXIT

# Write a signal sample for the engine to replay.
# fixture <hour> <idle> <bundle> <name> <app_count> <apps> <music_app> <music_title>
fixture() {
	cat >"$WORK/signals" <<EOF
now_epoch	$(date +%s)
hour	$1
weekday	3
idle_seconds	$2
screen_locked	0
on_console	1
display_asleep	0
frontmost_bundle	$3
frontmost_name	$4
app_count	$5
apps	$6
screen	2560x1440
music_app	$7
music_title	$8
music_artist
music_album
music_genre
EOF
}

# Run the engine over the current fixture with hysteresis off, so a result
# depends only on the fixture and not on whatever mood happens to be current.
engine() {
	MW_SIGNALS_FILE="$WORK/signals" MW_HYSTERESIS=0 bash "$SANDBOX/lib/detect-mood.sh" "$@"
}
engine_mood() { engine | /usr/bin/cut -f1; }

echo "== moodtool"
if [[ -x "$MOODTOOL" ]]; then ok "binary present"; else
	no "binary missing — run install.sh"
	echo
	echo "cannot continue without moodtool"
	exit 1
fi
"$MOODTOOL" screensize | /usr/bin/grep -qE '^[0-9]+x[0-9]+$' && ok "screensize" || no "screensize"
"$MOODTOOL" bogus-subcommand >/dev/null 2>&1 && no "unknown subcommand rejected" || ok "unknown subcommand rejected"

echo "== signals"
sig=$("$MOODTOOL" signals 2>/dev/null)
for key in idle_seconds screen_locked on_console display_asleep frontmost_bundle app_count apps screen; do
	printf '%s\n' "$sig" | /usr/bin/grep -q "^${key}	" && ok "moodtool emits $key" || no "moodtool emits $key"
done
idle=$(printf '%s\n' "$sig" | /usr/bin/awk -F'\t' '$1=="idle_seconds"{print $2}')
[[ "$idle" =~ ^[0-9]+$ ]] && ok "idle_seconds is a number ($idle)" || no "idle_seconds is a number (got '$idle')"

full=$(bash "$SANDBOX/lib/signals.sh" 2>/dev/null)
for key in hour weekday music_app music_title; do
	printf '%s\n' "$full" | /usr/bin/grep -q "^${key}	" && ok "signals.sh adds $key" || no "signals.sh adds $key"
done
# Every line must be "key<TAB>value" (value possibly empty) or the engine's
# field-based parser silently reads the wrong thing.
bad=$(printf '%s\n' "$full" | /usr/bin/awk -F'\t' 'NF!=2{n++}END{print n+0}')
check "every signal line is key<TAB>value" "$bad" "0"
fixture 14 5 com.apple.Safari Safari 3 "" "" ""
check "MW_SIGNALS_FILE replays a sample" \
	"$(MW_SIGNALS_FILE="$WORK/signals" bash "$SANDBOX/lib/signals.sh" | /usr/bin/awk -F'\t' '$1=="hour"{print $2}')" "14"

echo "== JSON extraction (real API response shapes)"
U='{"id":"a1","urls":{"raw":"https://images.unsplash.com/photo-1?ixid=M3w","full":"https://f"},"user":{"name":"X"}}'
check "unsplash urls.raw" "$(printf '%s' "$U" | "$MOODTOOL" json urls.raw)" \
	"https://images.unsplash.com/photo-1?ixid=M3w"
P='{"page":1,"photos":[{"id":1,"src":{"original":"https://images.pexels.com/photos/1/a.jpeg"}}],"total_results":1}'
check "pexels photos[*].src.original" "$(printf '%s' "$P" | "$MOODTOOL" json 'photos[*].src.original')" \
	"https://images.pexels.com/photos/1/a.jpeg"
check "wallhaven data[*].path" \
	"$(printf '%s' '{"data":[{"path":"https://w.wallhaven.cc/full/a/x.jpg"}]}' | "$MOODTOOL" json 'data[*].path')" \
	"https://w.wallhaven.cc/full/a/x.jpg"
printf '%s' '{"errors":["OAuth error"]}' | "$MOODTOOL" json urls.raw >/dev/null 2>&1 &&
	no "error response should not parse" || ok "error response rejected"
printf '%s' 'not json' | "$MOODTOOL" json urls.raw >/dev/null 2>&1 &&
	no "garbage should not parse" || ok "garbage rejected"
printf '%s' '{"a":{"b":1}}' | "$MOODTOOL" json a >/dev/null 2>&1 &&
	no "a non-scalar value is rejected" || ok "a non-scalar value is rejected"

echo "== gradient generation (every mood, offline)"
for m in $ALL_MOODS; do
	f="$WORK/g-$m.jpg"
	if "$MOODTOOL" gradient "$m" "$f" 1234 >/dev/null 2>&1 && /usr/bin/sips -g pixelWidth "$f" >/dev/null 2>&1; then
		ok "gradient $m"
	else
		no "gradient $m"
	fi
done
"$MOODTOOL" gradient bogus "$WORK/x.jpg" 2>/dev/null && no "unknown mood rejected" || ok "unknown mood rejected"

echo "== seeded randomness"
"$MOODTOOL" gradient calm "$WORK/s1.png" 11 >/dev/null
"$MOODTOOL" gradient calm "$WORK/s2.png" 11 >/dev/null
"$MOODTOOL" gradient calm "$WORK/s3.png" 99 >/dev/null
/usr/bin/cmp -s "$WORK/s1.png" "$WORK/s2.png" && ok "same seed -> same image" || no "same seed -> same image"
/usr/bin/cmp -s "$WORK/s1.png" "$WORK/s3.png" && no "different seed -> different image" || ok "different seed -> different image"

echo "== mood engine: signals drive the answer"
fixture 14 5 com.microsoft.VSCode Code 4 "" "" ""
check "coding at 2pm -> focused" "$(engine_mood)" "focused"
fixture 14 5 com.apple.Terminal Terminal 4 "" "" ""
check "a terminal -> focused" "$(engine_mood)" "focused"
fixture 15 5 us.zoom.xos zoom.us 13 "com.tinyspeck.slackmacgap com.apple.mail com.hnc.Discord" "" ""
check "a call plus a full Dock -> stressed" "$(engine_mood)" "stressed"
fixture 19 5 com.valvesoftware.steam Steam 4 "" "" ""
check "gaming -> energetic" "$(engine_mood)" "energetic"
fixture 19 5 com.apple.TV TV 4 "" "" ""
check "watching TV -> happy" "$(engine_mood)" "happy"
fixture 10 5 com.figma.Desktop Figma 4 "" "" ""
check "a design app -> focused" "$(engine_mood)" "focused"

echo "== mood engine: idle beats whatever you were doing"
fixture 14 2700 com.microsoft.VSCode Code 4 "" "" ""
check "away 45m -> tired" "$(engine_mood)" "tired"
fixture 14 900 com.microsoft.VSCode Code 4 "" "" ""
check "away 15m -> tired" "$(engine_mood)" "tired"
# The frontmost app of a machine nobody is sitting at proves nothing.
fixture 14 2700 us.zoom.xos zoom.us 4 "" "" ""
contains "an idle machine ignores the frontmost app" "$(engine --explain)" "away"

echo "== mood engine: music"
fixture 15 5 com.apple.Safari Safari 4 "" spotify "Lonely Tears"
check "a sad song overrides the clock" "$(engine_mood)" "sad"
fixture 15 5 com.apple.Safari Safari 4 "" spotify "Hardstyle Rave Banger"
check "a rave track -> energetic" "$(engine_mood)" "energetic"
fixture 15 5 com.apple.Safari Safari 4 "" spotify "Lofi Chill Beats"
check "lofi -> calm" "$(engine_mood)" "calm"
fixture 15 5 com.microsoft.VSCode Code 4 "" spotify "Some Unmatched Title"
check "an unmatched track leaves the app in charge" "$(engine_mood)" "focused"
# A title hitting two keywords must not put a newline into the output record.
fixture 15 5 com.apple.Safari Safari 4 "" spotify "Sad Lonely Blues Tears"
check "a multi-keyword title stays one record" "$(engine | /usr/bin/wc -l | tr -d ' ')" "1"

echo "== mood engine: hard rules"
fixture 2 5 com.valvesoftware.steam Steam 4 "" "" ""
check "the night window beats every signal" "$(engine_mood)" "night"
check "the night window reports its source" "$(engine | /usr/bin/cut -f2)" "night"
fixture 14 5 com.microsoft.VSCode Code 4 "" "" ""
printf 'romantic\t%s\n' "$(($(date +%s) + 600))" >"$SANDBOX/state/override"
check "an override beats every signal" "$(engine_mood)" "romantic"
check "an override reports its source" "$(engine | /usr/bin/cut -f2)" "override"
printf 'romantic\t%s\n' "$(($(date +%s) - 600))" >"$SANDBOX/state/override"
check "an expired override is discarded" "$(engine_mood)" "focused"
[[ -f "$SANDBOX/state/override" ]] && no "an expired override file is removed" || ok "an expired override file is removed"
# A corrupt override must not wedge the engine.
printf 'garbage-not-a-mood\tnot-a-number\n' >"$SANDBOX/state/override"
out=$(engine_mood)
[[ " $ALL_MOODS " == *" $out "* ]] && ok "a corrupt override falls through ($out)" ||
	no "a corrupt override falls through (got '$out')"
rm -f "$SANDBOX/state/override"

echo "== mood engine: robustness"
fixture 14 5 com.microsoft.VSCode Code 4 "" "" ""
check "output is exactly three tab-separated fields" \
	"$(engine | /usr/bin/awk -F'\t' '{print NF}')" "3"
printf 'hour\tnonsense\nidle_seconds\tnonsense\napp_count\tnonsense\n' >"$WORK/signals"
out=$(engine_mood)
[[ " $ALL_MOODS " == *" $out "* ]] && ok "garbage signals still yield a valid mood ($out)" ||
	no "garbage signals still yield a valid mood (got '$out')"
fixture 14 5 com.microsoft.VSCode Code 4 "" "" ""
contains "--explain shows the votes" "$(engine --explain)" "VOTES CAST"
contains "--explain shows the scores" "$(engine --explain)" "SCORES"
# A mood must never be reported as its own runner-up.
w=$(engine_mood)
d=$(engine | /usr/bin/cut -f3)
[[ "$d" == *"over $w "* ]] && no "the winner is not its own runner-up" || ok "the winner is not its own runner-up"

echo "== mood engine: hysteresis"
# Safari is a deliberately weak signal, so the top two moods sit close together.
fixture 14 5 com.apple.Safari Safari 4 "" "" ""
echo energetic >"$SANDBOX/state/last-mood"
held=$(MW_SIGNALS_FILE="$WORK/signals" MW_HYSTERESIS=50 bash "$SANDBOX/lib/detect-mood.sh" | /usr/bin/cut -f1)
check "a wide margin holds the previous mood" "$held" "energetic"
moved=$(MW_SIGNALS_FILE="$WORK/signals" MW_HYSTERESIS=0 bash "$SANDBOX/lib/detect-mood.sh" | /usr/bin/cut -f1)
[[ "$moved" != "energetic" ]] && ok "no margin lets the mood move ($moved)" || no "no margin lets the mood move"
rm -f "$SANDBOX/state/last-mood"

echo "== fallback ladder"
res=$(FORCE_OFFLINE=1 PREFER_OWN_IMAGES=0 FALLBACK_USE_CACHE=0 \
	bash "$SANDBOX/lib/fetch-wallpaper.sh" sad)
check "forced offline -> gradient" "$(printf '%s' "$res" | /usr/bin/cut -f2)" "gradient"
res=$(UNSPLASH_ACCESS_KEY=bogus PEXELS_API_KEY=bogus FALLBACK_USE_CACHE=0 PREFER_OWN_IMAGES=0 ANIME_SHARE=0 \
	bash "$SANDBOX/lib/fetch-wallpaper.sh" sad)
check "bad keys -> gradient" "$(printf '%s' "$res" | /usr/bin/cut -f2)" "gradient"
why=$(printf '%s' "$res" | /usr/bin/cut -f3)
if [[ "$why" == *401* ]]; then ok "the failure reason is logged ($why)"; else skip "failure reason (offline: $why)"; fi
# Whatever happened, the path handed back must be a real, usable image.
img=$(printf '%s' "$res" | /usr/bin/cut -f1)
[[ -f "$img" ]] && /usr/bin/sips -g pixelWidth "$img" >/dev/null 2>&1 &&
	ok "the ladder always returns a usable image" || no "the ladder always returns a usable image"

echo "== cache rung"
CD="$SANDBOX/cache/stressed"
mkdir -p "$CD"
"$MOODTOOL" gradient stressed "$CD/stressed-fake.jpg" 5 >/dev/null 2>&1
res=$(FORCE_OFFLINE=1 FALLBACK_USE_CACHE=1 PREFER_OWN_IMAGES=0 \
	bash "$SANDBOX/lib/fetch-wallpaper.sh" stressed)
check "APIs down plus a cache -> cache" "$(printf '%s' "$res" | /usr/bin/cut -f2)" "cache"

echo "== own images rung"
UD="$SANDBOX/wallpapers/_testmood"
mkdir -p "$UD"
"$MOODTOOL" gradient calm "$UD/mine.png" 7 >/dev/null 2>&1
res=$(UNSPLASH_ACCESS_KEY=bogus PEXELS_API_KEY=bogus ANIME_SHARE=0 \
	bash "$SANDBOX/lib/fetch-wallpaper.sh" _testmood)
check "own images beat the APIs" "$(printf '%s' "$res" | /usr/bin/cut -f2)" "own"
# A .png specifically: the glob was once *.jpg only, which made hand-placed
# PNGs invisible to the picker while still counting toward the cache trim.
[[ "$(printf '%s' "$res" | /usr/bin/cut -f1)" == *"/mine.png" ]] &&
	ok "a .png is selectable" || no "a .png is selectable"
mkdir -p "$SANDBOX/cache/_testmood"
"$MOODTOOL" gradient calm "$SANDBOX/cache/_testmood/_testmood-cached.jpg" 9 >/dev/null 2>&1
res=$(FORCE_OFFLINE=1 PREFER_OWN_IMAGES=0 FALLBACK_USE_CACHE=1 \
	bash "$SANDBOX/lib/fetch-wallpaper.sh" _testmood)
check "PREFER_OWN_IMAGES=0 skips the rung" "$(printf '%s' "$res" | /usr/bin/cut -f2)" "cache"

echo "== not re-picking the picture already on screen"
RD="$SANDBOX/wallpapers/_repeat"
mkdir -p "$RD"
"$MOODTOOL" gradient calm "$RD/a.jpg" 1 >/dev/null 2>&1
"$MOODTOOL" gradient calm "$RD/b.jpg" 2 >/dev/null 2>&1
echo "$RD/a.jpg" >"$SANDBOX/state/last-image"
repeats=0
for _ in 1 2 3 4 5 6 7 8; do
	got=$(ANIME_SHARE=0 FORCE_OFFLINE=1 bash "$SANDBOX/lib/fetch-wallpaper.sh" _repeat | /usr/bin/cut -f1)
	[[ "$got" == "$RD/a.jpg" ]] && repeats=$((repeats + 1))
done
check "never re-picks the current image when another exists" "$repeats" "0"
# ...but a mood with exactly one picture must still use it.
SD="$SANDBOX/wallpapers/_single"
mkdir -p "$SD"
"$MOODTOOL" gradient calm "$SD/only.jpg" 3 >/dev/null 2>&1
echo "$SD/only.jpg" >"$SANDBOX/state/last-image"
check "a single-image mood still uses it" \
	"$(ANIME_SHARE=0 FORCE_OFFLINE=1 bash "$SANDBOX/lib/fetch-wallpaper.sh" _single | /usr/bin/cut -f1)" \
	"$SD/only.jpg"
rm -f "$SANDBOX/state/last-image"

echo "== cache trim"
TD="$SANDBOX/cache/_trim"
mkdir -p "$TD"
# The trim must never reach a file it did not download, however full the dir is.
touch "$TD/keep-me.jpg" "$TD/also-keep.png"
for i in 1 2 3 4 5 6 7; do
	"$MOODTOOL" gradient calm "$TD/_trim-2026010$i-12000$i.jpg" "$i" >/dev/null 2>&1
done
MAX_CACHE_PER_MOOD=3 FORCE_OFFLINE=1 PREFER_OWN_IMAGES=0 \
	bash "$SANDBOX/lib/fetch-wallpaper.sh" _trim >/dev/null 2>&1
[[ -f "$TD/keep-me.jpg" && -f "$TD/also-keep.png" ]] &&
	ok "the trim leaves hand-placed files alone" || no "the trim leaves hand-placed files alone"
# MAX_CACHE_PER_MOOD=0 used to delete the file that had just been installed,
# and `head -n 0` is an error on BSD head rather than an empty result, which
# broke the cache rung outright. A real mood, so the gradient rung can catch it.
res=$(MAX_CACHE_PER_MOOD=0 FORCE_OFFLINE=1 PREFER_OWN_IMAGES=0 FALLBACK_USE_CACHE=1 \
	bash "$SANDBOX/lib/fetch-wallpaper.sh" stressed 2>"$WORK/trim.err")
img=$(printf '%s' "$res" | /usr/bin/cut -f1)
[[ -f "$img" ]] && ok "MAX_CACHE_PER_MOOD=0 still returns a real file" ||
	no "MAX_CACHE_PER_MOOD=0 still returns a real file"
check "MAX_CACHE_PER_MOOD=0 produces no errors" "$(cat "$WORK/trim.err")" ""

echo "== anime rung"
res=$(ANIME_SHARE=0 FORCE_OFFLINE=1 PREFER_OWN_IMAGES=0 FALLBACK_USE_CACHE=0 \
	bash "$SANDBOX/lib/fetch-wallpaper.sh" sad)
check "ANIME_SHARE=0 never fetches anime" "$(printf '%s' "$res" | /usr/bin/cut -f2)" "gradient"
AD="$SANDBOX/wallpapers/_animetest"
mkdir -p "$AD"
"$MOODTOOL" gradient calm "$AD/mine.jpg" 3 >/dev/null 2>&1
res=$(ANIME_SHARE=100 bash "$SANDBOX/lib/fetch-wallpaper.sh" _animetest 2>/dev/null)
src=$(printf '%s' "$res" | /usr/bin/cut -f2)
if [[ "$src" == "anime" ]]; then
	# ANIME_SHARE=100 must beat a curated mood, otherwise wallpapers/ shadows
	# anime forever on exactly the moods you cared enough to curate.
	ok "anime outranks a curated mood"
	f=$(printf '%s' "$res" | /usr/bin/cut -f1)
	SCREEN=$("$MOODTOOL" screensize)
	SW="${SCREEN%x*}"
	SH="${SCREEN#*x}"
	w=$(/usr/bin/sips -g pixelWidth "$f" 2>/dev/null | awk '/pixelWidth/{print $2}')
	h=$(/usr/bin/sips -g pixelHeight "$f" 2>/dev/null | awk '/pixelHeight/{print $2}')
	if [[ -n "$w" && -n "$h" ]] && ((w >= SW || h >= SH)); then
		ok "the anime image is downscaled to cover the screen (${w}x${h})"
	else
		no "the anime image covers the screen (got ${w}x${h}, want >=${SW}x${SH})"
	fi
else
	skip "anime rung (wallhaven unreachable, fell back to '$src')"
	skip "anime downscale (offline)"
fi

echo "== appearance"
for m in night happy; do
	out=$(MW_SET_DARKMODE=0 MW_SET_ACCENT=0 bash "$SANDBOX/lib/set-appearance.sh" "$m")
	check "disabled knobs report off ($m)" "$out" "$(printf 'off\toff')"
done
out=$(MW_SET_DARKMODE=0 MW_SET_ACCENT=0 bash "$SANDBOX/lib/set-appearance.sh" bogus-mood)
check "an unknown mood still returns two fields" \
	"$(printf '%s' "$out" | /usr/bin/awk -F'\t' '{print NF}')" "2"

echo "== wallpaper: every Space, verified"
TESTIMG="$WORK/wallpaper-test.jpg"
"$MOODTOOL" gradient night "$TESTIMG" 42 >/dev/null 2>&1
if out=$(bash "$SANDBOX/lib/set-wallpaper.sh" "$TESTIMG" 2>&1); then
	contains "set-wallpaper reports ok" "$out" "ok"
	# The entire point of the exercise: no Space left behind. Asked through
	# wallpaper-verify rather than by comparing strings, because /var vs
	# /private/var makes a raw compare report every Space as stale.
	verdict=$("$MOODTOOL" wallpaper-verify "$TESTIMG")
	rc=$?
	check "no Space is left on the old picture" "$rc" "0"
	contains "every Space matches" "$verdict" "stale=0"
	slots=$("$MOODTOOL" wallpaper-current | /usr/bin/awk -F'\t' '{n+=$1}END{print n+0}')
	((slots > 0)) && ok "the store reports $slots Space slot(s)" || no "the store reports Space slots"
	# A picture that was never set must not verify clean.
	"$MOODTOOL" wallpaper-verify "$WORK/s1.png" >/dev/null 2>&1 &&
		no "verification rejects the wrong picture" || ok "verification rejects the wrong picture"
else
	no "set-wallpaper failed: $out"
fi
out=$(bash "$SANDBOX/lib/set-wallpaper.sh" "$WORK/does-not-exist.jpg" 2>&1)
contains "a missing file is reported, not swallowed" "$out" "FAILED"

echo "== orchestrator (sandboxed)"
mw() { bash "$SANDBOX/mood-wallpaper.sh" "$@"; }
check "an unknown flag is rejected" "$(mw --nonsense 2>&1 >/dev/null | /usr/bin/head -1)" \
	"mood-wallpaper: unknown option: --nonsense"
contains "--set-mood rejects an unknown mood" "$(mw --set-mood not-a-mood 2>&1 >/dev/null)" "unknown mood"
contains "--set-mood rejects bad hours" "$(mw --set-mood happy abc 2>&1 >/dev/null)" "positive integer"
contains "--dry-run changes nothing" "$(FORCE_OFFLINE=1 mw --dry-run)" "dry run"
contains "--explain works without touching state" "$(mw --explain)" "SIGNALS OBSERVED"
[[ -f "$SANDBOX/state/last-run" ]] && no "--dry-run and --explain leave no last-run" ||
	ok "--dry-run and --explain leave no last-run"

echo "== orchestrator: throttle, pause, lock"
mw --offline --force >/dev/null 2>&1
[[ -f "$SANDBOX/state/last-run" ]] && ok "a real run records last-run" || no "a real run records last-run"
mw --offline >/dev/null 2>&1
/usr/bin/tail -1 "$SANDBOX/mood.log" | /usr/bin/grep -q "SKIP throttled" &&
	ok "a second run inside the interval is throttled" || no "a second run inside the interval is throttled"
mw --pause >/dev/null
mw --offline >/dev/null 2>&1
/usr/bin/tail -1 "$SANDBOX/mood.log" | /usr/bin/grep -q "SKIP paused" &&
	ok "paused blocks runs" || no "paused blocks runs"
mw --resume >/dev/null
[[ ! -f "$SANDBOX/state/paused" ]] && ok "resume clears pause" || no "resume clears pause"
# A lock held by a live process must make a concurrent run a no-op, not a race.
mkdir -p "$SANDBOX/state/lock"
echo $$ >"$SANDBOX/state/lock/pid"
mw --offline --force >/dev/null 2>&1
/usr/bin/tail -1 "$SANDBOX/mood.log" | /usr/bin/grep -q "another run is in progress" &&
	ok "a held lock stops a concurrent run" || no "a held lock stops a concurrent run"
# A lock owned by a process that no longer exists is stale and must be broken.
echo 999999 >"$SANDBOX/state/lock/pid"
mw --offline --force >/dev/null 2>&1
/usr/bin/tail -1 "$SANDBOX/mood.log" | /usr/bin/grep -q "another run is in progress" &&
	no "a stale lock is broken" || ok "a stale lock is broken"
[[ -d "$SANDBOX/state/lock" ]] && no "the lock is released on exit" || ok "the lock is released on exit"

echo "== orchestrator: history and reporting"
[[ -s "$SANDBOX/state/history.tsv" ]] && ok "runs are recorded in history" || no "runs are recorded in history"
check "a history row has 9 columns" \
	"$(/usr/bin/tail -1 "$SANDBOX/state/history.tsv" | /usr/bin/awk -F'\t' '{print NF}')" "9"
contains "--history renders" "$(mw --history 5)" "WHEN"
contains "--status renders" "$(mw --status)" "last run:"
mw --feedback right >/dev/null
check "feedback lands on the last row" \
	"$(/usr/bin/tail -1 "$SANDBOX/state/history.tsv" | /usr/bin/cut -f9)" "right"
mw --feedback wrong tired >/dev/null
check "a correction records the intended mood" \
	"$(/usr/bin/tail -1 "$SANDBOX/state/history.tsv" | /usr/bin/cut -f9)" "wrong:tired"
contains "feedback rejects an unknown verdict" "$(mw --feedback maybe 2>&1 >/dev/null)" "usage"
contains "feedback rejects an unknown mood" "$(mw --feedback wrong not-a-mood 2>&1 >/dev/null)" "unknown mood"
# Grading must not corrupt the rest of the file.
rows_before=$(/usr/bin/wc -l <"$SANDBOX/state/history.tsv" | tr -d ' ')
mw --feedback right >/dev/null
rows_after=$(/usr/bin/wc -l <"$SANDBOX/state/history.tsv" | tr -d ' ')
check "grading does not add or drop rows" "$rows_after" "$rows_before"
check "every history row stays 9 columns" \
	"$(/usr/bin/awk -F'\t' 'NF!=9{n++}END{print n+0}' "$SANDBOX/state/history.tsv")" "0"
# The report is pure BSD awk; a gawk-only builtin aborts it halfway through.
report=$(mw --report 2>&1)
contains "--report renders" "$report" "WHAT DECIDED THE MOOD"
contains "--report counts grades" "$report" "YOUR GRADING"
[[ "$report" == *"undefined function"* || "$report" == *"awk:"* ]] &&
	no "--report is BSD-awk clean" || ok "--report is BSD-awk clean"
contains "--verify renders" "$(mw --verify 2>&1)" "what each Space is showing"

echo "== orchestrator: log rotation"
/usr/bin/head -c 200000 /dev/zero | /usr/bin/tr '\0' 'x' >"$SANDBOX/mood.log"
echo "MAX_LOG_BYTES=1000" >"$SANDBOX/config.conf"
mw --pause >/dev/null 2>&1
[[ -f "$SANDBOX/mood.log.1" ]] && ok "an oversized log is rotated" || no "an oversized log is rotated"
rm -f "$SANDBOX/config.conf"
mw --resume >/dev/null 2>&1

echo "== menu bar indicator"
if [[ -f "$ROOT/src/moodbar.swift" ]]; then
	if /usr/bin/swiftc -O -o "$WORK/moodbar" "$ROOT/src/moodbar.swift" 2>"$WORK/moodbar.build"; then
		ok "moodbar compiles"
		# It is a GUI process, so the useful assertions are that it starts,
		# stays up, says nothing on stderr, and dies when asked.
		"$WORK/moodbar" >"$WORK/moodbar.out" 2>"$WORK/moodbar.err" &
		barpid=$!
		/bin/sleep 2
		if kill -0 "$barpid" 2>/dev/null; then
			ok "moodbar stays running"
			check "moodbar is silent on stderr" "$(cat "$WORK/moodbar.err")" ""
			kill -TERM "$barpid" 2>/dev/null
			/bin/sleep 1
			kill -0 "$barpid" 2>/dev/null && {
				no "moodbar exits on SIGTERM"
				kill -9 "$barpid" 2>/dev/null
			} || ok "moodbar exits on SIGTERM"
		else
			no "moodbar stays running ($(cat "$WORK/moodbar.err" | /usr/bin/head -1))"
		fi
		wait "$barpid" 2>/dev/null
	else
		no "moodbar compiles ($(/usr/bin/head -1 "$WORK/moodbar.build"))"
	fi
else
	skip "moodbar (src/moodbar.swift not present)"
fi
# Every mood the engine can return needs an emoji, or the menu bar silently
# falls back to a generic one for that mood.
for m in $ALL_MOODS; do
	/usr/bin/grep -q "case \"$m\":" "$ROOT/src/moodbar.swift" ||
		no "moodbar has an emoji for $m"
done
ok "moodbar has an emoji for every mood"

echo "== shell syntax"
for f in "$ROOT"/mood-wallpaper.sh "$ROOT"/lib/*.sh "$ROOT"/install.sh "$ROOT"/uninstall.sh "$ROOT"/test.sh; do
	bash -n "$f" 2>/dev/null && ok "parses: $(basename "$f")" || no "parses: $(basename "$f")"
done

echo
printf 'passed %d, failed %d, skipped %d\n' "$PASS" "$FAIL" "$SKIP"
[[ $FAIL -eq 0 ]]
