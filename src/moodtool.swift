// moodtool — native helper for mood-wallpaper.
//
// Subcommands:
//   moodtool gradient <mood> <out.png> [seed]   generate an offline wallpaper
//   moodtool wallpaper <path>                   set the desktop picture everywhere
//   moodtool wallpaper-current                  report what the store says is set
//   moodtool signals                            sample the machine for mood signals
//   moodtool json <keypath>                     extract a value from stdin JSON
//   moodtool screensize                         print "<width>x<height>" in pixels
//   moodtool accent <index> <highlight>         set accent + highlight color
//   moodtool notify-appearance                  poke apps to re-read the accent color
//
// Compiled once at install time. Each invocation runs for a few milliseconds
// and exits; nothing stays resident.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Mood palettes

struct Palette {
    let stops: [(r: Double, g: Double, b: Double)]
    let angle: Double  // degrees, base direction of the gradient
    let grain: Double  // 0…1 amount of noise speckle
}

// Colors are chosen to sit behind desktop icons without fighting them:
// light moods stay high-key, dark moods stay genuinely dark.
let palettes: [String: Palette] = [
    "happy": Palette(
        stops: [(1.00, 0.78, 0.30), (0.99, 0.55, 0.35), (0.85, 0.32, 0.45)],
        angle: 115, grain: 0.030),
    "calm": Palette(
        stops: [(0.62, 0.80, 0.88), (0.78, 0.87, 0.90), (0.90, 0.91, 0.86)],
        angle: 90, grain: 0.022),
    "energetic": Palette(
        stops: [(0.98, 0.28, 0.42), (0.96, 0.52, 0.16), (1.00, 0.82, 0.24)],
        angle: 135, grain: 0.040),
    "focused": Palette(
        stops: [(0.10, 0.12, 0.16), (0.16, 0.20, 0.27), (0.24, 0.30, 0.36)],
        angle: 105, grain: 0.026),
    "sad": Palette(
        stops: [(0.16, 0.20, 0.28), (0.28, 0.34, 0.44), (0.44, 0.49, 0.56)],
        angle: 80, grain: 0.030),
    "tired": Palette(
        stops: [(0.14, 0.13, 0.22), (0.28, 0.24, 0.38), (0.42, 0.38, 0.50)],
        angle: 70, grain: 0.034),
    "romantic": Palette(
        stops: [(0.95, 0.55, 0.62), (0.86, 0.42, 0.60), (0.55, 0.30, 0.52)],
        angle: 120, grain: 0.028),
    // Deeper and hotter than romantic's pinks: crimson into burgundy, kept
    // dark enough to stay behind icons.
    "horny": Palette(
        stops: [(0.62, 0.06, 0.16), (0.40, 0.05, 0.18), (0.20, 0.03, 0.14)],
        angle: 125, grain: 0.032),
    "night": Palette(
        stops: [(0.03, 0.05, 0.12), (0.07, 0.11, 0.24), (0.14, 0.20, 0.36)],
        angle: 95, grain: 0.020),
    "stressed": Palette(
        stops: [(0.36, 0.46, 0.44), (0.56, 0.66, 0.60), (0.78, 0.82, 0.76)],
        angle: 100, grain: 0.026),
]

// MARK: - Deterministic RNG (seeded, so a run is reproducible from its log)

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func die(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

// MARK: - screensize

func pixelSize() -> (Int, Int) {
    guard let screen = NSScreen.main else { return (2560, 1440) }
    let scale = screen.backingScaleFactor
    return (Int(screen.frame.width * scale), Int(screen.frame.height * scale))
}

// MARK: - gradient

func makeGradient(mood: String, out: String, seed: UInt64) {
    guard let p = palettes[mood] else { die("moodtool: unknown mood '\(mood)'") }
    var rng = SplitMix64(seed: seed)

    let (w, h) = pixelSize()
    let space = CGColorSpaceCreateDeviceRGB()
    guard
        let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { die("moodtool: could not create bitmap context") }

    // Jitter each stop slightly so repeated runs of the same mood differ.
    let jitter = { (v: Double) -> Double in
        min(1.0, max(0.0, v + Double.random(in: -0.045...0.045, using: &rng)))
    }
    var comps: [CGFloat] = []
    for s in p.stops {
        comps += [CGFloat(jitter(s.r)), CGFloat(jitter(s.g)), CGFloat(jitter(s.b)), 1.0]
    }
    let locations: [CGFloat] = p.stops.count == 3 ? [0.0, 0.55, 1.0] : [0.0, 1.0]
    guard let gradient = CGGradient(colorSpace: space, colorComponents: comps,
                                    locations: locations, count: p.stops.count)
    else { die("moodtool: could not build gradient") }

    // Rotate the gradient axis a little each run.
    let angle = (p.angle + Double.random(in: -18...18, using: &rng)) * .pi / 180
    let cx = Double(w) / 2, cy = Double(h) / 2
    let reach = (Double(w) + Double(h)) / 2
    let start = CGPoint(x: cx - cos(angle) * reach, y: cy - sin(angle) * reach)
    let end = CGPoint(x: cx + cos(angle) * reach, y: cy + sin(angle) * reach)
    ctx.drawLinearGradient(gradient, start: start, end: end,
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // A few soft radial blooms for depth — cheap, and stops it looking like a
    // flat CSS gradient.
    let blooms = Int.random(in: 2...4, using: &rng)
    for _ in 0..<blooms {
        let bx = Double.random(in: 0...Double(w), using: &rng)
        let by = Double.random(in: 0...Double(h), using: &rng)
        let radius = Double.random(in: 0.20...0.55, using: &rng) * Double(min(w, h))
        let light = Double.random(in: 0...1, using: &rng) > 0.45
        let tint: CGFloat = light ? 1.0 : 0.0
        let alpha = CGFloat(Double.random(in: 0.05...0.14, using: &rng))
        let bloomComps: [CGFloat] = [tint, tint, tint, alpha, tint, tint, tint, 0.0]
        if let bloom = CGGradient(colorSpace: space, colorComponents: bloomComps,
                                  locations: [0.0, 1.0], count: 2) {
            ctx.drawRadialGradient(
                bloom, startCenter: CGPoint(x: bx, y: by), startRadius: 0,
                endCenter: CGPoint(x: bx, y: by), endRadius: CGFloat(radius), options: [])
        }
    }

    // Vignette so the menu bar and Dock edges settle down.
    let vig: [CGFloat] = [0, 0, 0, 0.0, 0, 0, 0, 0.22]
    if let v = CGGradient(colorSpace: space, colorComponents: vig,
                          locations: [0.55, 1.0], count: 2) {
        ctx.drawRadialGradient(
            v, startCenter: CGPoint(x: cx, y: cy), startRadius: 0,
            endCenter: CGPoint(x: cx, y: cy), endRadius: CGFloat(reach * 0.75), options: [])
    }

    // Film grain, drawn as sparse 2px dots — avoids per-pixel work on a 5K buffer.
    if p.grain > 0 {
        let dots = Int(Double(w * h) * p.grain / 900.0)
        for _ in 0..<dots {
            let gx = Double.random(in: 0...Double(w), using: &rng)
            let gy = Double.random(in: 0...Double(h), using: &rng)
            let bright = Double.random(in: 0...1, using: &rng) > 0.5
            let a = CGFloat(Double.random(in: 0.02...0.07, using: &rng))
            ctx.setFillColor(red: bright ? 1 : 0, green: bright ? 1 : 0,
                             blue: bright ? 1 : 0, alpha: a)
            ctx.fill(CGRect(x: gx, y: gy, width: 2, height: 2))
        }
    }

    guard let image = ctx.makeImage() else { die("moodtool: could not render image") }
    let url = URL(fileURLWithPath: out)
    // JPEG by default — a full-screen gradient is ~500 KB as JPEG against
    // ~6 MB as PNG, and there is no detail here that lossy compression hurts.
    let isPNG = url.pathExtension.lowercased() == "png"
    let type = (isPNG ? "public.png" : "public.jpeg") as CFString
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil)
    else { die("moodtool: could not open \(out) for writing") }
    let props: [CFString: Any] = isPNG ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.9]
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { die("moodtool: could not write \(out)") }
    print(out)
}

// MARK: - wallpaper
//
// macOS 14+ keeps the desktop picture in a per-Space store owned by
// WallpaperAgent:
//
//   ~/Library/Application Support/com.apple.wallpaper/Store/Index.plist
//
// The tree holds one "Desktop" slot per Space *and* per display, plus
// SystemDefault (which new Spaces inherit from). Neither of the obvious APIs
// reaches all of them:
//
//   * NSWorkspace.setDesktopImageURL writes a legacy location the agent ignores.
//   * `System Events` -> `set picture` enumerates *displays*, not Spaces, so it
//     only touches whichever Space is active right now. Every other Space keeps
//     its old picture and repaints it the moment you switch to it or unlock —
//     which reads as "the wallpaper reverted by itself".
//
// So the store is edited directly and WallpaperAgent is restarted to re-read it.
// Verified on macOS 26.5: 16 slots rewritten, agent restarted, every Space
// shows the new picture and the write survives the restart.

let storePath = NSHomeDirectory()
    + "/Library/Application Support/com.apple.wallpaper/Store/Index.plist"

/// The inner plist WallpaperAgent stores for a still-image choice.
func imageConfiguration(for url: URL) throws -> Data {
    let inner: [String: Any] = [
        "type": "imageFile",
        "url": ["relative": url.absoluteString],
    ]
    return try PropertyListSerialization.data(
        fromPropertyList: inner, format: .binary, options: 0)
}

/// Rewrite every "Desktop" slot anywhere in the tree, leaving "Idle" (the
/// screen saver), placement options and background colors untouched.
func rewriteDesktopSlots(_ node: Any, config: Data, now: Date,
                         count: inout Int, isDesktopSlot: Bool = false) -> Any {
    guard let dict = node as? [String: Any] else { return node }
    var out = dict

    if isDesktopSlot, var content = dict["Content"] as? [String: Any] {
        content["Choices"] = [[
            "Provider": "com.apple.wallpaper.choice.image",
            "Files": [Any](),
            "Configuration": config,
        ]]
        out["Content"] = content
        out["LastSet"] = now
        count += 1
        return out
    }

    for (key, value) in dict {
        out[key] = rewriteDesktopSlots(
            value, config: config, now: now, count: &count, isDesktopSlot: key == "Desktop")
    }
    return out
}

/// Every file URL the store currently has in a Desktop slot.
func desktopSlotURLs(_ node: Any, isDesktopSlot: Bool = false) -> [String] {
    guard let dict = node as? [String: Any] else { return [] }

    if isDesktopSlot,
       let content = dict["Content"] as? [String: Any],
       let choices = content["Choices"] as? [[String: Any]] {
        return choices.compactMap { choice in
            guard let blob = choice["Configuration"] as? Data, !blob.isEmpty,
                  let inner = try? PropertyListSerialization.propertyList(
                      from: blob, options: [], format: nil) as? [String: Any],
                  let urlDict = inner["url"] as? [String: Any],
                  let relative = urlDict["relative"] as? String
            else { return nil }
            return relative
        }
    }

    return dict.flatMap { key, value in
        desktopSlotURLs(value, isDesktopSlot: key == "Desktop")
    }
}

/// The one true spelling of a path.
///
/// Necessary because Foundation and the shell disagree: `/var` is a symlink to
/// `/private/var`, `pwd -P` resolves it one way and `standardizedFileURL`
/// resolves it back the other, so the same file reaches the store under a
/// different name than the caller passed in. Comparing raw strings across that
/// boundary reports every Space as stale. Both sides get folded through this.
func canonicalPath(_ path: String) -> String {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        .resolvingSymlinksInPath().standardizedFileURL.path
}

func loadStore() throws -> Any {
    let data = try Data(contentsOf: URL(fileURLWithPath: storePath))
    var format = PropertyListSerialization.PropertyListFormat.binary
    return try PropertyListSerialization.propertyList(
        from: data, options: [.mutableContainersAndLeaves], format: &format)
}

@discardableResult
func run(_ launchPath: String, _ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return -1 }
    process.waitUntilExit()
    return process.terminationStatus
}

/// Legacy path: no store on this system (pre-Sonoma), or the store write failed.
func setWallpaperViaNSWorkspace(_ url: URL) -> Bool {
    let ws = NSWorkspace.shared
    let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
        .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
        .allowClipping: true,
    ]
    var succeeded = 0
    for screen in NSScreen.screens {
        if (try? ws.setDesktopImageURL(url, for: screen, options: options)) != nil {
            succeeded += 1
        }
    }
    return succeeded > 0
}

func setWallpaper(_ path: String) {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    guard FileManager.default.fileExists(atPath: url.path) else {
        die("moodtool: no such file: \(url.path)")
    }

    guard FileManager.default.fileExists(atPath: storePath) else {
        if setWallpaperViaNSWorkspace(url) {
            print("method=nsworkspace slots=0 verified=unknown")
            exit(0)
        }
        die("moodtool: no wallpaper store and NSWorkspace refused")
    }

    let target = url.absoluteString

    // Two attempts: WallpaperAgent can be mid-flush on the first one, in which
    // case its own write lands on top of ours and verification catches it.
    for attempt in 1...2 {
        do {
            let root = try loadStore()
            var slots = 0
            let updated = rewriteDesktopSlots(
                root, config: try imageConfiguration(for: url), now: Date(), count: &slots)
            guard slots > 0 else { die("moodtool: wallpaper store has no Desktop slots") }

            let data = try PropertyListSerialization.data(
                fromPropertyList: updated, format: .binary, options: 0)
            try data.write(to: URL(fileURLWithPath: storePath), options: .atomic)

            // The agent caches the store in memory; restarting is what makes it
            // re-read and repaint. It is an on-demand LaunchAgent, so it comes
            // straight back. (launchctl kickstart is blocked by SIP.)
            run("/usr/bin/killall", ["WallpaperAgent"])
            usleep(600_000)

            // Verify against the file the agent has now had a chance to rewrite.
            let after = desktopSlotURLs(try loadStore())
            let stale = after.filter { $0 != target }.count
            if stale == 0 && !after.isEmpty {
                print("method=store slots=\(slots) verified=\(after.count)")
                exit(0)
            }
            if attempt == 2 {
                die("moodtool: wallpaper store kept \(stale) stale slot(s) after 2 attempts")
            }
            usleep(400_000)
        } catch {
            if attempt == 2 {
                // Last resort, so at least the current Space changes.
                if setWallpaperViaNSWorkspace(url) {
                    print("method=nsworkspace slots=0 verified=unknown")
                    exit(0)
                }
                die("moodtool: wallpaper store unusable (\(error.localizedDescription))")
            }
            usleep(400_000)
        }
    }
}

/// What every Desktop slot currently points at, canonicalised.
func currentDesktopPaths() -> [String] {
    guard FileManager.default.fileExists(atPath: storePath) else {
        die("moodtool: no wallpaper store on this system")
    }
    guard let root = try? loadStore() else { die("moodtool: could not read wallpaper store") }
    let urls = desktopSlotURLs(root)
    guard !urls.isEmpty else { die("moodtool: wallpaper store has no Desktop slots") }
    return urls.map { canonicalPath(URL(string: $0)?.path ?? $0) }
}

/// Report what the store believes is set, so callers can verify independently.
func reportCurrentWallpaper() {
    var counts: [String: Int] = [:]
    for p in currentDesktopPaths() { counts[p, default: 0] += 1 }
    // Most common first, then alphabetically, so the output is stable.
    for (path, n) in counts.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }) {
        print("\(n)\t\(path)")
    }
}

/// Is `path` what every Space is actually showing? Exits non-zero if not.
///
/// This lives here rather than in the shell because only this side can spell a
/// path the same way the store does.
func verifyWallpaper(_ path: String) {
    let want = canonicalPath(path)
    var matched = 0
    var stale = 0
    for p in currentDesktopPaths() {
        if p == want { matched += 1 } else { stale += 1 }
    }
    print("matched=\(matched) stale=\(stale)")
    exit(stale == 0 && matched > 0 ? 0 : 1)
}

// MARK: - signals
//
// Everything here is readable without a TCC prompt: idle time and lock state
// come from CoreGraphics, the app list from NSWorkspace, power from IOKit.
// (EventKit calendar access was deliberately left out — it needs a signed app
// bundle, and an unsigned CLI silently gets "notDetermined" forever.)

func emitSignals() {
    var out: [(String, String)] = []

    let idle = CGEventSource.secondsSinceLastEventType(
        .hidSystemState, eventType: .init(rawValue: ~0)!)
    out.append(("idle_seconds", String(Int(idle.isFinite && idle > 0 ? idle : 0))))

    // CGSSessionScreenIsLocked is absent entirely while unlocked.
    var locked = false
    var onConsole = true
    if let session = CGSessionCopyCurrentDictionary() as? [String: Any] {
        locked = (session["CGSSessionScreenIsLocked"] as? Int ?? 0) == 1
        onConsole = (session["kCGSSessionOnConsoleKey"] as? Int ?? 1) == 1
    }
    out.append(("screen_locked", locked ? "1" : "0"))
    out.append(("on_console", onConsole ? "1" : "0"))
    out.append(("display_asleep", CGDisplayIsAsleep(CGMainDisplayID()) != 0 ? "1" : "0"))

    let ws = NSWorkspace.shared
    let front = ws.frontmostApplication
    out.append(("frontmost_bundle", front?.bundleIdentifier ?? ""))
    out.append(("frontmost_name", front?.localizedName ?? ""))

    // .regular = has a Dock icon. Excludes the hundreds of background agents.
    let apps = ws.runningApplications
        .filter { $0.activationPolicy == .regular }
        .compactMap { $0.bundleIdentifier }
        .sorted()
    out.append(("app_count", String(apps.count)))
    out.append(("apps", apps.joined(separator: " ")))

    let (w, h) = pixelSize()
    out.append(("screen", "\(w)x\(h)"))

    for (key, value) in out {
        // Tab-separated, one per line: the shell side reads this with `read`.
        print("\(key)\t\(value)")
    }
}

// MARK: - json
//
// Keypath syntax: dotted keys, [n] for index, [*] for "pick one at random".
// e.g.  urls.raw          photos[*].src.original

func jsonExtract(_ keypath: String) {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let root = try? JSONSerialization.jsonObject(with: data) else {
        die("moodtool: stdin is not valid JSON")
    }
    var node: Any? = root
    // Split "photos[*].src" into ["photos", "[*]", "src"] style tokens.
    var tokens: [String] = []
    for part in keypath.split(separator: ".") {
        var name = ""
        var i = part.startIndex
        while i < part.endIndex, part[i] != "[" {
            name.append(part[i])
            i = part.index(after: i)
        }
        if !name.isEmpty { tokens.append(name) }
        while i < part.endIndex, part[i] == "[" {
            guard let close = part[i...].firstIndex(of: "]") else { die("moodtool: bad keypath") }
            tokens.append(String(part[part.index(after: i)..<close]))
            i = part.index(after: close)
        }
    }

    for token in tokens {
        if let dict = node as? [String: Any], Int(token) == nil, token != "*" {
            node = dict[token]
        } else if let arr = node as? [Any] {
            if token == "*" {
                guard !arr.isEmpty else { die("moodtool: empty array at '\(token)'") }
                node = arr.randomElement()
            } else if let idx = Int(token), idx >= 0, idx < arr.count {
                node = arr[idx]
            } else {
                die("moodtool: index out of range at '\(token)'")
            }
        } else {
            die("moodtool: no value at '\(token)'")
        }
        if node == nil { die("moodtool: no value at '\(token)'") }
    }

    switch node {
    case let s as String: print(s)
    case let n as NSNumber: print(n.stringValue)
    default: die("moodtool: value at '\(keypath)' is not a scalar")
    }
}

// MARK: - main

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else {
    die("""
        usage: moodtool <command>
          gradient <mood> <out.png> [seed]   wallpaper <path>
          wallpaper-current                  wallpaper-verify <path>
          signals                            screensize
          json <keypath>                     accent <index> <highlight>
          notify-appearance
        """)
}

switch cmd {
case "gradient":
    guard args.count >= 3 else { die("usage: moodtool gradient <mood> <out.png> [seed]") }
    let seed = args.count >= 4 ? (UInt64(args[3]) ?? UInt64(Date().timeIntervalSince1970))
                               : UInt64(Date().timeIntervalSince1970)
    makeGradient(mood: args[1], out: args[2], seed: seed)
case "wallpaper":
    guard args.count >= 2 else { die("usage: moodtool wallpaper <path>") }
    setWallpaper(args[1])
case "wallpaper-current":
    reportCurrentWallpaper()
case "wallpaper-verify":
    guard args.count >= 2 else { die("usage: moodtool wallpaper-verify <path>") }
    verifyWallpaper(args[1])
case "signals":
    emitSignals()
case "json":
    guard args.count >= 2 else { die("usage: moodtool json <keypath>") }
    jsonExtract(args[1])
case "screensize":
    let (w, h) = pixelSize()
    print("\(w)x\(h)")
case "accent":
    // Set the accent + highlight color the same way System Settings does:
    // write into .GlobalPreferences via CFPreferences, synchronize so cfprefsd
    // publishes the new value, and only then tell apps to re-read. Doing this
    // with `defaults write` leaves running apps reading a stale cache, which
    // is why the accent appeared not to change.
    guard args.count >= 3 else { die("usage: moodtool accent <index> <highlight-string>") }
    guard let idx = Int(args[1]) else { die("moodtool: accent index must be an integer") }
    let domain = kCFPreferencesAnyApplication
    CFPreferencesSetValue("AppleAccentColor" as CFString, idx as CFNumber, domain,
                          kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    CFPreferencesSetValue("AppleHighlightColor" as CFString, args[2] as CFString, domain,
                          kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    // Pre-Big Sur key some controls still consult: 1 = blue, 6 = graphite.
    CFPreferencesSetValue("AppleAquaColorVariant" as CFString, (idx == -1 ? 6 : 1) as CFNumber,
                          domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
        die("moodtool: could not synchronize global preferences")
    }
    fallthrough
case "notify-appearance":
    // Same notification macOS posts when you change the accent color in
    // System Settings. Running apps that listen will repaint; ones that don't
    // pick the new accent up on next launch.
    let dnc = DistributedNotificationCenter.default()
    dnc.postNotificationName(
        NSNotification.Name("AppleColorPreferencesChangedNotification"),
        object: nil, userInfo: nil, deliverImmediately: true)
    dnc.postNotificationName(
        NSNotification.Name("AppleAquaColorVariantChanged"),
        object: nil, userInfo: nil, deliverImmediately: true)
    // AppKit invalidates cached NSColor.controlAccentColor on this one.
    dnc.postNotificationName(
        NSNotification.Name("NSSystemColorsDidChangeNotification"),
        object: nil, userInfo: nil, deliverImmediately: true)
    // Give cfprefsd and the notification queue a moment before we exit —
    // a process that dies immediately can drop the delivery.
    usleep(250_000)
default:
    die("moodtool: unknown subcommand '\(cmd)'")
}
