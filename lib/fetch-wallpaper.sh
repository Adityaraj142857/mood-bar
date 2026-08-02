#!/bin/bash
# fetch-wallpaper.sh <mood> — produce a wallpaper image for a mood.
#
# Prints one tab-separated line:
#   <image-path>\t<source>\t<reason>
# where source is one of: anime | own | unsplash | pexels | cache | gradient
#
# ANIME_SHARE percent of runs try Wallhaven's anime category first. Otherwise,
# and whenever that fails: your own images in wallpapers/<mood>/ -> Unsplash ->
# Pexels -> a recent cached image -> offline Swift/Core Graphics gradient. The
# gradient path has no network, no API key and no dependencies, so it can never
# fail to produce something.
#
# wallpapers/ is yours and is never written to or pruned. cache/ is scratch
# space this script owns.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
MOODTOOL="$ROOT/bin/moodtool"

MOOD="${1:?usage: fetch-wallpaper.sh <mood>}"
FORCE_OFFLINE="${FORCE_OFFLINE:-0}"
MAX_CACHE_PER_MOOD="${MAX_CACHE_PER_MOOD:-5}"
CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-4}"
CURL_MAX_TIME="${CURL_MAX_TIME:-15}"

CACHE_DIR="$ROOT/cache/$MOOD"
USER_DIR="$ROOT/wallpapers/$MOOD"
mkdir -p "$CACHE_DIR"

# Every format macOS will accept as a desktop picture. Matched case-insensitively
# because files off a camera or a download tend to arrive as .JPG.
list_images() {
	[[ -d "$1" ]] || return 0
	/usr/bin/find "$1" -maxdepth 1 -type f \
		\( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \
		-o -iname '*.heic' -o -iname '*.tiff' -o -iname '*.tif' \) 2>/dev/null
}

# Newest first. Uses stat rather than `ls -t` so filenames containing spaces
# survive the trip through the pipe.
newest_first() {
	list_images "$1" | while IFS= read -r f; do
		printf '%s\t%s\n' "$(/usr/bin/stat -f%m "$f")" "$f"
	done | /usr/bin/sort -rn | /usr/bin/cut -f2-
}

# Random line from stdin. Deliberately not awk: bare srand() seeds from the
# clock in whole seconds, and macOS awk's rand() stays correlated across nearby
# seeds, so both produced the same "random" pick run after run. bash's $RANDOM
# indexing an array has neither problem. The seed is taken as an argument so it
# is expanded by the calling shell rather than inside the pipeline subshell.
pick_random() {
	local seed="${1:-$RANDOM}" line n
	local lines=()
	while IFS= read -r line; do lines+=("$line"); done
	n=${#lines[@]}
	((n)) || return 1
	printf '%s\n' "${lines[$((seed % n))]}"
}

# Search keywords: abstract/textural for the light moods so they sit quietly
# behind icons, literal night & low-light photography for the dark ones.
mood_queries() {
	case "$1" in
	happy) printf '%s\n' "golden sunlight abstract" "warm minimal gradient" "sunny sky minimal" ;;
	calm) printf '%s\n' "soft fog pastel minimal" "misty lake morning" "calm water minimal" ;;
	energetic) printf '%s\n' "vivid neon gradient" "neon city street night" "bold abstract color" ;;
	focused) printf '%s\n' "dark minimal geometry" "muted minimal architecture" "dark quiet library" ;;
	sad) printf '%s\n' "rainy window grey" "muted grey minimal" "overcast sea" ;;
	tired) printf '%s\n' "foggy dawn mountain" "dim soft blurred light" "low light texture" ;;
	romantic) printf '%s\n' "warm pink dusk" "soft warm bokeh" "sunset coast pastel" ;;
	horny) printf '%s\n' "red silk fabric folds" "deep red neon low light" "warm candlelight dark bokeh" ;;
	night) printf '%s\n' "milky way desert" "dark starry night sky" "deep blue night city" ;;
	stressed) printf '%s\n' "calm negative space" "soft neutral minimal" "empty quiet horizon" ;;
	*) printf '%s\n' "minimal abstract gradient" ;;
	esac
}

pick_query() {
	mood_queries "$MOOD" | pick_random "$RANDOM"
}

# Wallhaven search terms. Unsplash and Pexels are stock *photo* libraries with
# essentially no anime in them, so anime comes from Wallhaven's anime category
# instead. Terms lean on scenery and mood rather than named series, which keeps
# the results wallpaper-shaped instead of character close-ups.
anime_queries() {
	case "$1" in
	happy) printf '%s\n' "anime sky bright" "slice of life scenery" "anime summer field" ;;
	calm) printf '%s\n' "anime scenery lake" "anime clouds peaceful" "anime countryside" ;;
	energetic) printf '%s\n' "anime vivid city" "anime neon street" "anime dynamic sky" ;;
	focused) printf '%s\n' "anime minimal dark" "anime room desk" "anime quiet library" ;;
	sad) printf '%s\n' "anime rain melancholy" "anime alone window" "anime grey mood" ;;
	tired) printf '%s\n' "anime night sleepy" "anime dim room" "anime dusk quiet" ;;
	romantic) printf '%s\n' "anime couple sunset" "anime warm evening" "anime festival night" ;;
	horny) printf '%s\n' "anime red elegant" "anime silk warm light" "anime dark crimson" ;;
	night) printf '%s\n' "anime starry night" "anime night city" "anime moon sky" ;;
	stressed) printf '%s\n' "anime calm scenery" "anime empty horizon" "anime soft minimal" ;;
	*) printf '%s\n' "anime scenery" ;;
	esac
}

# Wallhaven serves originals — 7000px and 1–3 MB is normal — so unlike the photo
# APIs there is no server-side crop and we downscale locally. Scales to *cover*
# the screen (the smaller of the two ratios wins) so macOS crops rather than
# letterboxes.
fit_to_screen() {
	local f="$1" w h
	w=$(/usr/bin/sips -g pixelWidth "$f" 2>/dev/null | awk '/pixelWidth/{print $2}')
	h=$(/usr/bin/sips -g pixelHeight "$f" 2>/dev/null | awk '/pixelHeight/{print $2}')
	[[ -n "$w" && -n "$h" && "$w" -gt 0 && "$h" -gt 0 ]] || return 1
	# Already smaller than the screen in both directions: leave it be, upscaling
	# only costs bytes and softness.
	((w <= SW && h <= SH)) && return 0
	if ((w * SH >= h * SW)); then
		/usr/bin/sips --resampleHeight "$SH" -s format jpeg -s formatOptions 82 \
			"$f" --out "$f" >/dev/null 2>&1 || return 1
	else
		/usr/bin/sips --resampleWidth "$SW" -s format jpeg -s formatOptions 82 \
			"$f" --out "$f" >/dev/null 2>&1 || return 1
	fi
}

# Percent-encode everything outside the unreserved set, rather than the three
# characters the search terms happen to use today. Bytes above 0x7F are not
# handled; every query in this file is ASCII by construction.
urlencode() {
	local s="$1" out="" c i
	for ((i = 0; i < ${#s}; i++)); do
		c="${s:i:1}"
		case "$c" in
		[a-zA-Z0-9.~_-]) out="$out$c" ;;
		*) out="$out$(printf '%%%02X' "'$c")" ;;
		esac
	done
	printf '%s' "$out"
}

# The picture that is on screen right now, so the pickers can avoid handing
# back the same one and making a run look like it did nothing.
LAST_IMAGE=""
[[ -f "$ROOT/state/last-image" ]] && LAST_IMAGE=$(<"$ROOT/state/last-image")

# Drop the current picture from a candidate list — but only when something else
# is left, so a mood with exactly one image still uses it.
drop_last() {
	local line lines=() kept=()
	while IFS= read -r line; do lines+=("$line"); done
	((${#lines[@]})) || return 0
	for line in "${lines[@]}"; do
		[[ "$line" == "$LAST_IMAGE" ]] || kept+=("$line")
	done
	if ((${#kept[@]})); then
		printf '%s\n' "${kept[@]}"
	else
		printf '%s\n' "${lines[@]}"
	fi
}

# Screen pixel size, used to ask the API for an appropriately sized crop
# instead of downloading a 30MP original.
SCREEN=$("$MOODTOOL" screensize 2>/dev/null || echo "2560x1440")
SW="${SCREEN%x*}"
SH="${SCREEN#*x}"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/moodwp.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# Considers a download valid only if it is a real, non-trivial image file.
valid_image() {
	local f="$1"
	[[ -s "$f" ]] || return 1
	[[ $(/usr/bin/stat -f%z "$f") -gt 20000 ]] || return 1
	/usr/bin/sips -g pixelWidth "$f" >/dev/null 2>&1
}

install_to_cache() {
	local src="$1" ext="$2" dest
	# $$ disambiguates two runs landing in the same second — --force in a loop
	# used to have the second run overwrite the first one's file.
	dest="$CACHE_DIR/${MOOD}-$(date +%Y%m%d-%H%M%S)-$$.${ext}"
	/bin/mv "$src" "$dest" || return 1
	# Keep only the newest N per mood so repeats vary without the cache growing.
	# Restricted to the download naming pattern: anything else in here was put
	# there by hand and is not ours to delete. Floored at 1 so a stray
	# MAX_CACHE_PER_MOOD=0 cannot delete the file we just installed.
	local keep=$MAX_CACHE_PER_MOOD
	((keep >= 1)) || keep=1
	newest_first "$CACHE_DIR" |
		/usr/bin/grep -E "/${MOOD}-[0-9]{8}-[0-9]{6}(-[0-9]+)?\.[^/]+$" |
		tail -n +$((keep + 1)) |
		while IFS= read -r old; do rm -f "$old"; done
	[[ -f "$dest" ]] || return 1
	printf '%s' "$dest"
}

# Your own images, if you've put any in wallpapers/<mood>/. Nothing writes to
# or prunes that directory, so whatever you drop in stays until you remove it.
try_own() {
	local pick
	pick=$(list_images "$USER_DIR" | drop_last | pick_random "$RANDOM")
	[[ -n "$pick" ]] || return 1
	printf '%s' "$pick"
}

try_unsplash() {
	[[ -n "${UNSPLASH_ACCESS_KEY:-}" ]] || {
		echo "no key configured"
		return 1
	}
	local q json raw url out
	q=$(pick_query)
	json=$(/usr/bin/curl -sS -f \
		--connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
		-H "Authorization: Client-ID ${UNSPLASH_ACCESS_KEY}" \
		-H "Accept-Version: v1" \
		"https://api.unsplash.com/photos/random?query=$(urlencode "$q")&orientation=landscape&content_filter=high" \
		2>"$TMP/uerr") || {
		echo "api error: $(tr -d '\n' <"$TMP/uerr" | cut -c1-120)"
		return 1
	}
	raw=$(printf '%s' "$json" | "$MOODTOOL" json urls.raw 2>/dev/null) || {
		echo "unexpected response shape"
		return 1
	}
	url="${raw}&w=${SW}&h=${SH}&fit=crop&crop=entropy&fm=jpg&q=82"
	out="$TMP/dl.jpg"
	/usr/bin/curl -sS -fL --connect-timeout "$CURL_CONNECT_TIMEOUT" \
		--max-time "$CURL_MAX_TIME" -o "$out" "$url" 2>/dev/null || {
		echo "download failed"
		return 1
	}
	valid_image "$out" || {
		echo "download not a valid image"
		return 1
	}
	# path TAB query — these run in a command substitution, so a variable
	# assignment here would never reach the caller. A failed install must
	# return non-zero, otherwise the caller takes an empty path as success and
	# the whole ladder stops instead of falling through to the next rung.
	local cached
	cached=$(install_to_cache "$out" jpg) || {
		echo "could not store the download"
		return 1
	}
	printf '%s\t%s' "$cached" "$q"
	return 0
}

try_pexels() {
	[[ -n "${PEXELS_API_KEY:-}" ]] || {
		echo "no key configured"
		return 1
	}
	local q json orig url out
	q=$(pick_query)
	json=$(/usr/bin/curl -sS -f \
		--connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
		-H "Authorization: ${PEXELS_API_KEY}" \
		"https://api.pexels.com/v1/search?query=$(urlencode "$q")&orientation=landscape&per_page=30" \
		2>"$TMP/perr") || {
		echo "api error: $(tr -d '\n' <"$TMP/perr" | cut -c1-120)"
		return 1
	}
	# [*] picks a random photo out of the result page, for variety.
	orig=$(printf '%s' "$json" | "$MOODTOOL" json 'photos[*].src.original' 2>/dev/null) || {
		echo "no results"
		return 1
	}
	url="${orig}?auto=compress&cs=tinysrgb&fit=crop&w=${SW}&h=${SH}"
	out="$TMP/dl.jpg"
	/usr/bin/curl -sS -fL --connect-timeout "$CURL_CONNECT_TIMEOUT" \
		--max-time "$CURL_MAX_TIME" -o "$out" "$url" 2>/dev/null || {
		echo "download failed"
		return 1
	}
	valid_image "$out" || {
		echo "download not a valid image"
		return 1
	}
	local cached
	cached=$(install_to_cache "$out" jpg) || {
		echo "could not store the download"
		return 1
	}
	printf '%s\t%s' "$cached" "$q"
	return 0
}

# Wallhaven needs no API key for SFW search. purity=100 and categories=010 are
# hardcoded, not configurable: SFW-only, anime-only. Raising purity on this
# endpoint requires an account API key, which this tool deliberately doesn't
# support — including for the "horny" mood, which gets styling, not explicit art.
try_anime() {
	local q json url out
	q=$(anime_queries "$MOOD" | pick_random "$RANDOM")
	# atleast is the screen size, not a fixed 1080p floor: anything smaller would
	# be left alone by fit_to_screen (which won't upscale) and then stretched by
	# macOS. Still ~100 results per query at 2940x1912.
	json=$(/usr/bin/curl -sS -f \
		--connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
		"https://wallhaven.cc/api/v1/search?q=$(urlencode "$q")&categories=010&purity=100&sorting=random&ratios=landscape&atleast=${SW}x${SH}" \
		2>"$TMP/aerr") || {
		echo "api error: $(tr -d '\n' <"$TMP/aerr" | cut -c1-120)"
		return 1
	}
	url=$(printf '%s' "$json" | "$MOODTOOL" json 'data[*].path' 2>/dev/null) || {
		echo "no results for '$q'"
		return 1
	}
	[[ -n "$url" ]] || {
		echo "no results for '$q'"
		return 1
	}
	out="$TMP/anime.jpg"
	/usr/bin/curl -sS -fL --connect-timeout "$CURL_CONNECT_TIMEOUT" \
		--max-time "$CURL_MAX_TIME" -o "$out" "$url" 2>/dev/null || {
		echo "download failed"
		return 1
	}
	valid_image "$out" || {
		echo "download not a valid image"
		return 1
	}
	fit_to_screen "$out" || {
		echo "resize failed"
		return 1
	}
	local cached
	cached=$(install_to_cache "$out" jpg) || {
		echo "could not store the download"
		return 1
	}
	printf '%s\t%s' "$cached" "$q"
	return 0
}

try_cache() {
	local pick keep="$MAX_CACHE_PER_MOOD"
	# `head -n 0` is an error on BSD head, not an empty result, so a
	# MAX_CACHE_PER_MOOD of 0 used to break this rung instead of narrowing it.
	[[ "$keep" =~ ^[0-9]+$ ]] && ((keep >= 1)) || keep=1
	pick=$(newest_first "$CACHE_DIR" | head -n "$keep" | drop_last | pick_random "$RANDOM")
	[[ -n "$pick" ]] || return 1
	printf '%s' "$pick"
}

make_gradient() {
	local out="$ROOT/cache/offline-${MOOD}.jpg"
	"$MOODTOOL" gradient "$MOOD" "$out" "$(date +%s)" >/dev/null || return 1
	printf '%s' "$out"
}

# ------------------------------------------------------------------ dispatch
reasons=()

# ANIME_SHARE percent of runs go looking for anime first — including for moods
# you've curated, otherwise those folders would shadow it forever and "anime in
# every mood" wouldn't hold. The rest of the time the normal ladder runs. Rolled
# per run, so both kinds keep showing up.
ANIME_SHARE="${ANIME_SHARE:-50}"
roll=$((RANDOM % 100))
if [[ "$FORCE_OFFLINE" != "1" ]] && ((ANIME_SHARE > 0 && roll < ANIME_SHARE)); then
	if out=$(try_anime); then
		IFS=$'\t' read -r path query <<<"$out"
		printf '%s\t%s\t%s\n' "$path" "anime" "query: $query"
		exit 0
	fi
	reasons+=("anime: $out")
fi

# Your own images come first and need no network, so this runs even when the
# APIs are skipped. A mood with an empty (or missing) wallpapers/ folder falls
# straight through to the API chain below.
if [[ "${PREFER_OWN_IMAGES:-1}" == "1" ]] && path=$(try_own); then
	printf '%s\t%s\t%s\n' "$path" "own" "$(basename "$path") from wallpapers/$MOOD"
	exit 0
fi
reasons+=("own: nothing in wallpapers/$MOOD")

if [[ "$FORCE_OFFLINE" == "1" ]]; then
	reasons+=("forced offline")
else
	if out=$(try_unsplash); then
		IFS=$'\t' read -r path query <<<"$out"
		printf '%s\t%s\t%s\n' "$path" "unsplash" "query: $query"
		exit 0
	fi
	reasons+=("unsplash: $out")

	if out=$(try_pexels); then
		IFS=$'\t' read -r path query <<<"$out"
		printf '%s\t%s\t%s\n' "$path" "pexels" "query: $query"
		exit 0
	fi
	reasons+=("pexels: $out")
fi

why=$(
	IFS='; '
	echo "${reasons[*]}"
)

if [[ "${FALLBACK_USE_CACHE:-1}" == "1" ]] && path=$(try_cache); then
	printf '%s\t%s\t%s\n' "$path" "cache" "$why -> reused cached image"
	exit 0
fi

if path=$(make_gradient); then
	printf '%s\t%s\t%s\n' "$path" "gradient" "$why -> offline gradient"
	exit 0
fi

echo "fetch-wallpaper: every source failed ($why)" >&2
exit 1
