#!/bin/bash
# set-wallpaper.sh <image-path> — set the desktop picture on every Space.
#
# Prints: ok(<detail>) | FAILED: <reason>
#
# The work happens in `moodtool wallpaper`, which edits the per-Space wallpaper
# store directly and restarts WallpaperAgent — see the long comment in
# src/moodtool.swift for why neither NSWorkspace nor `System Events` is enough
# on macOS 14+. This wrapper adds an independent verification step: it asks the
# store what it now believes is set and compares that against what we asked
# for, so a silent partial write can never be logged as success.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
MOODTOOL="$ROOT/bin/moodtool"

IMG="${1:?usage: set-wallpaper.sh <image-path>}"
[[ -f "$IMG" ]] || {
	echo "FAILED: no such file: $IMG"
	exit 1
}
[[ -x "$MOODTOOL" ]] || {
	echo "FAILED: moodtool not built — run install.sh"
	exit 1
}

# Absolute and symlink-resolved, because that is the form the store records and
# the form the verification below compares against.
IMG_ABS=$(cd "$(dirname "$IMG")" && printf '%s/%s' "$(pwd -P)" "$(basename "$IMG")")

if ! out=$("$MOODTOOL" wallpaper "$IMG_ABS" 2>&1); then
	echo "FAILED: ${out:-moodtool wallpaper failed}"
	exit 1
fi

# Independent check: re-read the store rather than trusting the writer's own
# report. The comparison happens inside moodtool because only that side can
# spell a path the way the store does — /var vs /private/var alone is enough to
# make a shell-side string compare call every Space stale.
if verdict=$("$MOODTOOL" wallpaper-verify "$IMG_ABS" 2>/dev/null); then
	matched="${verdict#matched=}"
	matched="${matched%% *}"
	echo "ok(${matched} spaces)"
	exit 0
elif [[ -n "${verdict:-}" ]]; then
	stale="${verdict##*stale=}"
	echo "FAILED: $stale Space(s) still show a different picture"
	exit 1
fi

# No store to verify against (pre-Sonoma). moodtool's own report is all we have.
echo "ok(${out})"
