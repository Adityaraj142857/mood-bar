# mood-bar

A macOS wallpaper that follows what you're actually doing. It reads the machine
for signs of focus, load and tiredness, picks a mood from them, and matches your
wallpaper, light/dark mode and accent color to it — with a one-emoji indicator in
the menu bar so you always know which mood is on screen.

<p align="center">
  <img src="docs/menu-bar.png" alt="The mood indicator in the macOS menu bar" width="360">
</p>

```console
$ mood-wallpaper.sh --explain
mood:   focused
source: signals

SIGNALS OBSERVED
  time               13:00
  idle               0s (at the machine)
  frontmost          Code [dev]
  apps open          9
  playing            nothing

VOTES CAST
  time     energetic    1.0   13h afternoon
  time     focused      0.8   13h afternoon
  app      focused      3.0   Code (dev)
  load     stressed     0.7   9 apps open

SCORES
  -> focused    3.8
     energetic  1.0
     stressed   0.7
```

The work is daemon-free: `launchd` wakes a shell script every 15 minutes, it
does its job in ~1–3 seconds and exits. The only thing that stays resident is
the menu bar indicator, which is optional.

**Requirements:** macOS 14 or newer (tested on 26.5), Xcode command line tools
for `swiftc`. No Homebrew, no Python, no runtime dependencies.

---

## Install

```sh
git clone https://github.com/Adityaraj142857/mood-bar.git
cd mood-bar
./install.sh
```

That builds the two Swift binaries, creates `config.conf`, and loads the launchd
agents. Then add an API key (optional, see below) and run it once by hand:

```sh
./mood-wallpaper.sh --force
```

The first run triggers macOS permission prompts — Automation → System Events,
and Music/Spotify if they're open. Approve them once; it's silent afterwards.

To remove: `./uninstall.sh`, or `./uninstall.sh --restore` to also hand the
desktop picture back to a macOS default.

> The launchd agents are labelled `com.arshukla.*`. Rename them in the two
> `.plist` files and `install.sh` if you'd rather they carried your own domain.

---

## What it can and cannot know

This is the honest version, because the word "mood" oversells it.

It is **not** affect sensing. There is no camera, no microphone, no sentiment
model. What it reads is behavioural:

| Signal | Source | Permission |
|---|---|---|
| Seconds since your last keystroke or click | CoreGraphics | none |
| Which app has focus, and how many are open | NSWorkspace | none |
| Screen locked / display asleep | CoreGraphics | none |
| Time of day | the clock | none |
| Currently playing track | Spotify / Music via AppleScript | Automation (asked once) |

Those correlate genuinely with **focus, load and tiredness**. They are honestly
unrelated to sadness or romance. So `sad`, `romantic` and `horny` are reachable
only from music keywords or a manual `--set-mood` — nothing tries to infer them
from your behaviour.

Calendar was deliberately left out. EventKit needs a signed app bundle; an
unsigned CLI silently gets `notDetermined` forever, so it would have been a dead
signal pretending to be a live one.

### How a mood is chosen

Signals cast weighted votes and the highest total wins. Nothing is a first-match
cutoff, so a weak clock prior loses to strong evidence and every vote survives
into `--explain`. Two hard rules sit outside the scoring:

1. a mood pinned with `--set-mood` wins outright;
2. inside the night window (23:00–06:00 by default) the mood is always `night`,
   so a 3am playlist can't throw a bright wallpaper at you.

A hysteresis margin (`MW_HYSTERESIS`) stops two near-tied moods trading the
wallpaper back and forth every half hour.

---

## Checking whether it actually works

Four commands, because "it changed the wallpaper" and "it read me correctly" are
different claims and both deserve evidence.

```sh
./mood-wallpaper.sh --explain    # every signal, every vote, the full score table
./mood-wallpaper.sh --verify     # confirm every Space really shows our picture
./mood-wallpaper.sh --history 20 # the last 20 decisions
./mood-wallpaper.sh --report     # how it has been doing over time
```

`--report` answers "is this reading me, or just reading a clock?" — it breaks
down what decided each mood, so a tool that had quietly degraded into a clock
would show up as entirely time-driven.

It also tracks your grading. After a run that felt right or wrong, say so:

```sh
./mood-wallpaper.sh --feedback right
./mood-wallpaper.sh --feedback wrong tired   # it guessed X, you were tired
```

That is the only ground truth there is — the machine cannot grade itself. After a
few dozen graded runs, `--report` shows an accuracy figure and which moods it
keeps confusing, which is what you'd tune the weights in `lib/detect-mood.sh`
against.

---

## The menu bar indicator

A single emoji shows the mood currently on your wallpaper — 🎯 focused, 😴 tired,
🌙 night, 🫧 stressed. One character wide, about as much room as the battery icon.
It dims when auto-switching is paused, and the tooltip gives the mood in words
plus any pin expiry.

Clicking it opens a small menu: the current mood and when it last changed,
**Change now**, **Why this mood?** (the full `--explain` in a scrollable panel),
**Pin a mood** (any of the ten, current one ticked), and **Pause** / **Resume**.

Every entry shells out to `mood-wallpaper.sh`, so the menu can't drift from what
the command line does.

**This is the one resident process.** Everything else wakes, works and exits — a
menu bar item can't, because the item exists only as long as its process. It's
cheap about it: accessory-policy app, no Dock icon, no window, asleep on a kqueue
watch over `state/`, waking only when a run rewrites it. To skip it entirely:

```sh
MOODBAR=0 ./install.sh
```

---

## Why setting a wallpaper needs a Swift binary

On macOS 14+ the desktop picture lives in a per-Space store owned by
`WallpaperAgent`:

```
~/Library/Application Support/com.apple.wallpaper/Store/Index.plist
```

That tree holds **one slot per Space and per display**, plus a `SystemDefault`
that new Spaces inherit. Neither obvious API reaches all of them:

- `NSWorkspace.setDesktopImageURL` writes a legacy location the agent ignores.
- `System Events` → `set picture` enumerates **displays, not Spaces**. With eight
  Mission Control desktops open, `count of desktops` still returns `1`. It
  updates whichever Space is active and leaves the other seven alone.

The visible symptom, and the bug that motivated most of this code: the lock
screen (which reads `SystemDefault`) shows the new picture, you unlock onto a
Space whose own slot was never touched, and the old wallpaper comes back. It
looks like the wallpaper reverted by itself.

So `moodtool wallpaper` edits every `Desktop` slot in the store directly and
restarts `WallpaperAgent` to re-read it. `Idle` slots (the screen saver),
placement options and background colors are left alone. Verified on macOS 26.5:
16 slots rewritten, agent restarted, every Space shows the new picture, and the
write survives the restart.

`launchctl kickstart` on that agent is blocked by SIP; `killall WallpaperAgent`
is not, and launchd brings it straight back because it's an on-demand agent.

**Everything is verified, nothing is assumed.** The wallpaper setter re-reads the
store afterwards and fails loudly if any Space is stale. The appearance setter
reads back `AppleInterfaceStyle` and `AppleAccentColor` and marks the result with
a `!` if the system didn't end up where it was told to go.

---

## Where the pictures come from

Each run walks a ladder, stopping at the first rung that yields a usable image:

```
anime (Wallhaven) → your own images → Unsplash → Pexels → recent cache → gradient
```

The last rung is a Core Graphics gradient generated locally per mood, so the tool
can never fail to produce something — no network, no API key, no dependencies.

### API keys (optional)

Both are free and neither needs a credit card. With neither configured everything
still works; it just leans on your own images and the gradient.

- **Unsplash** — <https://unsplash.com/developers> → register → New Application →
  copy the **Access Key** (not the Secret Key). 50 requests/hour; this uses ~2.
- **Pexels** — <https://www.pexels.com/api/> → Get Started. 200 requests/hour.

Put whichever you have into `config.conf` (created by `install.sh`, `chmod 600`,
and gitignored).

**Wallhaven** needs no key at all. `ANIME_SHARE` percent of runs (50 by default)
fetch from its anime category instead. That request is hardcoded to SFW-only and
anime-only; there is no setting to change it.

### Your own images

Drop files into `wallpapers/<mood>/` — `jpg`, `jpeg`, `png`, `heic`, `tiff`. A
mood with any of them uses one at random without touching the APIs. That folder
is yours: nothing ever writes to it or deletes from it. `cache/` is scratch space
the tool owns and prunes.

The picture currently on screen is excluded from the next pick, so a run always
visibly does something — unless a mood has exactly one image, which then repeats.

> The repo ships the folder layout but no images: they're large, and usually
> third-party art that isn't ours to redistribute.

---

## The moods

`happy` `calm` `energetic` `focused` `sad` `tired` `romantic` `horny` `night`
`stressed`

Each maps to a wallpaper folder, a set of search queries, an accent color and a
light/dark preference. Dark is the default; only `LIGHT_MOODS` go light.

Override the machine when it gets it wrong:

```sh
./mood-wallpaper.sh --set-mood calm 2    # calm for the next 2 hours
./mood-wallpaper.sh --clear-mood
./mood-wallpaper.sh --pause              # stop auto-switching entirely
./mood-wallpaper.sh --resume
```

---

## Configuration

Everything lives in `config.conf` — see `config.conf.example` for the annotated
list. The knobs you're most likely to touch:

| Setting | Default | What it does |
|---|---|---|
| `MIN_INTERVAL_MINUTES` | `30` | Minimum minutes between wallpaper changes |
| `ANIME_SHARE` | `50` | Percent of runs that fetch anime from Wallhaven |
| `NIGHT_START` / `NIGHT_END` | `23` / `6` | Hours forced to the `night` mood |
| `MW_HYSTERESIS` | `5` | How much better a new mood must score to win, in tenths |
| `MW_SKIP_WHEN_LOCKED` | `1` | Don't run while the screen is locked or asleep |
| `LIGHT_MOODS` | `happy energetic` | Moods that go light; everything else dark |
| `MW_SET_DARKMODE` / `MW_SET_ACCENT` | `1` | Set to `0` to leave appearance alone |

---

## Layout

```
mood-wallpaper.sh        orchestrator: locking, throttle, logging, reporting
lib/signals.sh           samples the machine; MW_SIGNALS_FILE replays a sample
lib/detect-mood.sh       the scoring engine
lib/fetch-wallpaper.sh   the image ladder
lib/set-wallpaper.sh     sets, then verifies
lib/set-appearance.sh    dark mode + accent, also verified
lib/nowplaying.applescript
src/moodtool.swift       wallpaper store, signals, gradients, JSON, accent
src/moodbar.swift        the menu bar indicator
test.sh                  132 tests, hermetic
state/history.tsv        one row per run — what --report reads
mood.log                 human-readable log, self-rotating
```

Two launchd agents: `com.arshukla.moodwallpaper` (wakes every 15 min, exits) and
`com.arshukla.moodbar` (resident, optional).

---

## Tests

```sh
./test.sh
```

132 tests, no API key required; network tests degrade to `SKIP` when offline.

They're hermetic. Orchestrator tests run against a throwaway copy of the project
in `$TMPDIR`, so your real `mood.log`, `state/` and history never move. Engine
tests replay recorded signal samples through `MW_SIGNALS_FILE` rather than
reading the machine, so they give the same answer at 3am as at noon on a laptop
with nothing playing. The one test that genuinely has to touch the desktop saves
the current picture and puts it back.

---

## License

MIT — see [LICENSE](LICENSE).
