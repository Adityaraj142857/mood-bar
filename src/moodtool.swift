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

    // Already showing everywhere? Then don't rewrite the store and don't
    // restart the agent. Restarting WallpaperAgent makes every Space repaint,
    // which is real work and a visible flicker, and doing it to arrive at the
    // picture already on screen is pure waste.
    let wanted = canonicalPath(url.path)
    let existing = desktopSlotURLs((try? loadStore()) ?? [:])
    if !existing.isEmpty,
        existing.allSatisfy({ canonicalPath(URL(string: $0)?.path ?? $0) == wanted })
    {
        print("method=store slots=\(existing.count) verified=\(existing.count) unchanged=1")
        exit(0)
    }

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

            // Poll rather than sleeping a flat 600ms. The agent usually settles
            // in well under that, and on the occasions it needs longer a fixed
            // wait would have been too short anyway.
            var after: [String] = []
            var stale = 1
            for _ in 0..<20 {
                usleep(50_000)
                after = desktopSlotURLs((try? loadStore()) ?? [:])
                stale = after.filter { $0 != target }.count
                if stale == 0 && !after.isEmpty { break }
            }
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

// MARK: - icon appearance (macOS 26+)
//
// macOS 26 added "Icon & widget style" — Default / Dark / Clear / Tinted with a
// tint color — which restyles every app icon system-wide: the Dock, the desktop,
// Launchpad, Finder sidebars. Driving it from the mood is the only way to theme
// the Dock at all: Dock icons live inside each .app bundle, system ones are
// SIP-protected, and editing third-party ones breaks their code signature.
//
// The three AppleIconAppearance* keys in NSGlobalDomain are only a mirror of the
// real state. Writing them with `defaults` changes nothing on screen — the
// System Settings pane goes through SLSIconAppearanceConfiguration in SkyLight,
// and so does this. The enum values below were established empirically by
// setting each one and reading back the string it mirrors into the domain.
//
// SkyLight is private. Everything here is written to fail soft: if the class or
// its selectors ever go away, this reports that and exits non-zero, and the
// caller treats icon theming as unavailable rather than the run as failed.

let iconThemes: [String: Int] = [
    "default": 1,  // the stock multicolour icons
    "dark": 2,  // "RegularDark"
    "clear": 3, "clear-light": 4, "clear-dark": 5,
    "tinted": 6, "tinted-light": 7, "tinted-dark": 8,
]
let iconTints: [String: Int] = [
    "hardware": 1, "red": 2, "orange": 3, "yellow": 4, "green": 5,
    "blue": 6, "purple": 7, "pink": 8, "graphite": 9, "other": 10,
]

/// "#rrggbb" -> CGColor, for the "Other" tint slot.
///
/// The colour space is stated explicitly, and that matters. CGColor's
/// convenience initialiser builds a *Generic RGB* colour — the legacy gamma-1.8
/// space — and macOS stores the tint as sRGB, so it silently gamma-converted
/// everything on the way in: #3366cc (0.20, 0.40, 0.80) came back out as
/// (0.25, 0.49, 0.84), a visibly lighter tint than the wallpaper it was read
/// from. Building the colour in sRGB to begin with makes it round-trip exactly.
func parseHexColor(_ text: String) -> CGColor? {
    let hex = text.hasPrefix("#") ? String(text.dropFirst()) : text
    guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
    let components: [CGFloat] = [
        CGFloat((value >> 16) & 0xFF) / 255,
        CGFloat((value >> 8) & 0xFF) / 255,
        CGFloat(value & 0xFF) / 255,
        1,
    ]
    guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    return CGColor(colorSpace: srgb, components: components)
}

func iconThemeName(_ value: Int) -> String {
    iconThemes.first { $0.value == value }?.key ?? "unknown(\(value))"
}
func iconTintName(_ value: Int) -> String {
    iconTints.first { $0.value == value }?.key ?? "none"
}

/// The live configuration object, or nil if this macOS has no such concept.
func currentIconConfiguration() -> AnyObject? {
    _ = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_LAZY)
    guard let cls = NSClassFromString("SLSIconAppearanceConfiguration") else { return nil }
    // As AnyObject, so the metaclass takes the ObjC `perform` rather than
    // Swift's AnyClass, which has no such method.
    let factory = cls as AnyObject
    let fetch = NSSelectorFromString("fetchCurrentIconAppearanceConfiguration")
    guard factory.responds(to: fetch) else { return nil }
    return factory.perform(fetch)?.takeUnretainedValue()
}

func reportIconAppearance() {
    guard let cfg = currentIconConfiguration() else {
        die("moodtool: this macOS has no icon appearance setting")
    }
    let theme = cfg.value(forKey: "iconAppearanceTheme") as? Int ?? -1
    let tint = cfg.value(forKey: "iconTintColorName") as? Int ?? -1
    print("\(iconThemeName(theme))\t\(iconTintName(tint))")
}

// MARK: - reading a color out of the wallpaper
//
// The mood's accent color is a fixed choice per mood, which is fine for the
// highlight color but wrong for tinting icons: a "stressed" green sitting on
// top of a blue wallpaper reads as a mistake, because it is one. The picture is
// the thing everyone is looking at, so the picture decides the color.

struct HSB {
    var hue: Double  // 0..1
    var saturation: Double
    var brightness: Double
}

func rgbToHSB(_ r: Double, _ g: Double, _ b: Double) -> HSB {
    let maxV = max(r, g, b), minV = min(r, g, b)
    let delta = maxV - minV
    var hue = 0.0
    if delta > 0 {
        if maxV == r {
            hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxV == g {
            hue = (b - r) / delta + 2
        } else {
            hue = (r - g) / delta + 4
        }
        hue /= 6
        if hue < 0 { hue += 1 }
    }
    return HSB(hue: hue, saturation: maxV == 0 ? 0 : delta / maxV, brightness: maxV)
}

func hsbToRGB(_ c: HSB) -> (Double, Double, Double) {
    let h = c.hue * 6
    let i = floor(h)
    let f = h - i
    let p = c.brightness * (1 - c.saturation)
    let q = c.brightness * (1 - c.saturation * f)
    let t = c.brightness * (1 - c.saturation * (1 - f))
    switch Int(i) % 6 {
    case 0: return (c.brightness, t, p)
    case 1: return (q, c.brightness, p)
    case 2: return (p, c.brightness, t)
    case 3: return (p, q, c.brightness)
    case 4: return (t, p, c.brightness)
    default: return (c.brightness, p, q)
    }
}

/// The colour an image "reads as".
///
/// A plain average is useless here — averaging a blue sky against orange skin
/// gives mud. Instead the hue is a *circular* mean (hues wrap at 360°, so
/// averaging 350° and 10° has to give 0°, not 180°), weighted by how colourful
/// each pixel is, with washed-out and near-black pixels excluded from the vote
/// entirely because their hue is meaningless.
func dominantTint(ofImage path: String) -> HSB? {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

    // 64x64 is plenty: this is a hue histogram, not a thumbnail.
    let side = 64

    // Decode straight to thumbnail size. Fully decoding a 4K wallpaper to
    // immediately throw 99.9% of the pixels away costs about ten times as much,
    // and JPEG can scale during decode for free.
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: side * 2,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
    ]
    guard
        let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    let space = CGColorSpaceCreateDeviceRGB()
    guard
        let ctx = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

    var x = 0.0, y = 0.0, weightSum = 0.0
    var satSum = 0.0, brightSum = 0.0, counted = 0.0
    for i in stride(from: 0, to: pixels.count, by: 4) {
        let c = rgbToHSB(
            Double(pixels[i]) / 255, Double(pixels[i + 1]) / 255, Double(pixels[i + 2]) / 255)
        // Greys have no hue to contribute, and near-black pixels report wild
        // hues from tiny channel differences.
        guard c.saturation > 0.18, c.brightness > 0.15 else { continue }
        let weight = c.saturation * c.brightness
        let angle = c.hue * 2 * .pi
        x += cos(angle) * weight
        y += sin(angle) * weight
        weightSum += weight
        satSum += c.saturation
        brightSum += c.brightness
        counted += 1
    }

    // A genuinely monochrome picture: say so rather than inventing a hue.
    guard counted > 0, weightSum > 0 else {
        return HSB(hue: 0, saturation: 0, brightness: 0.5)
    }

    var hue = atan2(y, x) / (2 * .pi)
    if hue < 0 { hue += 1 }

    // How much the hues agreed. A picture spread evenly across the wheel gets a
    // short resultant vector, and deserves a muted tint rather than a confident
    // one plucked from the average of everything.
    let coherence = sqrt(x * x + y * y) / weightSum
    let meanSat = satSum / counted
    let meanBright = brightSum / counted

    return HSB(
        hue: hue,
        saturation: min(0.95, max(0.35, meanSat * (0.5 + coherence))),
        brightness: min(0.95, max(0.55, meanBright * 1.15)))
}

/// macOS's eight accent colors, as hues. The accent can only be one of these,
/// so a wallpaper-derived color has to snap to the closest.
let accentHues: [(name: String, index: Int, hue: Double)] = [
    ("red", 0, 0.006), ("orange", 1, 0.075), ("yellow", 2, 0.128),
    ("green", 3, 0.306), ("blue", 4, 0.586), ("purple", 5, 0.806),
    ("pink", 6, 0.944),
]

func nearestAccent(to color: HSB) -> (name: String, index: Int) {
    // Too grey to call: graphite is the honest answer, and macOS has one.
    if color.saturation < 0.15 { return ("graphite", -1) }
    var best = accentHues[0]
    var bestDistance = 1.0
    for candidate in accentHues {
        // Circular distance: red at 0.006 must be near pink at 0.944.
        let raw = abs(candidate.hue - color.hue)
        let distance = min(raw, 1 - raw)
        if distance < bestDistance {
            bestDistance = distance
            best = candidate
        }
    }
    return (best.name, best.index)
}

/// Print what an image should tint to: exact RGB, plus the nearest named accent.
func reportImageTint(_ path: String) {
    guard FileManager.default.fileExists(atPath: path) else {
        die("moodtool: no such file: \(path)")
    }
    guard let color = dominantTint(ofImage: path) else {
        die("moodtool: could not read a color out of \(path)")
    }
    let (r, g, b) = hsbToRGB(color)
    let accent = nearestAccent(to: color)
    let hex = String(
        format: "#%02x%02x%02x",
        Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    // "<#rrggbb>\t<accent-name>\t<accent-index>" — the exact color for the icon
    // tint, and the nearest of the eight for the accent, which can't take more.
    print("\(hex)\t\(accent.name)\t\(accent.index)")
}

/// The custom tint currently in effect. Not KVC-compliant — the getter returns
/// a CGColorRef — so it is reached through its IMP.
func currentOtherTintColor(_ cfg: AnyObject) -> CGColor? {
    let sel = NSSelectorFromString("otherIconTintColor")
    guard let method = class_getInstanceMethod(type(of: cfg), sel) else { return nil }
    typealias GetColor = @convention(c) (AnyObject, Selector) -> Unmanaged<CGColor>?
    let imp = unsafeBitCast(method_getImplementation(method), to: GetColor.self)
    return imp(cfg, sel)?.takeUnretainedValue()
}

/// Equal to within a 1/255 step — the colours round-trip through 8-bit hex, so
/// exact float equality would never hold.
func sameColor(_ a: CGColor, _ b: CGColor) -> Bool {
    guard let x = a.components, let y = b.components, x.count >= 3, y.count >= 3 else {
        return false
    }
    return (0..<3).allSatisfy { abs(x[$0] - y[$0]) < 0.004 }
}

func setIconAppearance(theme themeName: String, tint tintName: String) {
    guard let theme = iconThemes[themeName] else {
        die("moodtool: unknown icon theme '\(themeName)'; one of: \(iconThemes.keys.sorted().joined(separator: " "))")
    }
    guard let cfg = currentIconConfiguration() else {
        die("moodtool: this macOS has no icon appearance setting")
    }

    // Saving forces every icon on the system to re-render, so don't save a
    // configuration that is already in effect. Worth doing properly for the
    // custom-colour case too: with the tint coming from the wallpaper the name
    // is always "Other", so comparing names alone would never match and every
    // run would re-render the whole icon set.
    let haveTheme = cfg.value(forKey: "iconAppearanceTheme") as? Int
    let haveTint = cfg.value(forKey: "iconTintColorName") as? Int
    if haveTheme == theme {
        if tintName.hasPrefix("#") {
            if let want = parseHexColor(tintName), haveTint == iconTints["other"],
                let have = currentOtherTintColor(cfg), sameColor(have, want)
            {
                print("\(iconThemeName(theme))\t\(iconTintName(haveTint!))")
                exit(0)
            }
        } else if let wantTint = iconTints[tintName], haveTint == wantTint {
            print("\(iconThemeName(theme))\t\(iconTintName(wantTint))")
            exit(0)
        }
    }

    cfg.setValue(theme, forKey: "iconAppearanceTheme")
    // A tint only shows through in the tinted themes; setting it under Clear or
    // Default is harmless and means the color is already right if the user
    // switches over later.
    if tintName.hasPrefix("#") {
        // An exact color, rather than one of the eight named ones. macOS calls
        // this "Other": the name enum goes to 10 and the real color rides along
        // as a CGColor. Snapping a wallpaper to eight buckets loses most of the
        // point, so this is the path the wallpaper-derived tint takes.
        guard let color = parseHexColor(tintName) else {
            die("moodtool: bad tint color '\(tintName)', expected #rrggbb")
        }
        cfg.setValue(iconTints["other"]!, forKey: "iconTintColorName")
        let sel = NSSelectorFromString("setOtherIconTintColor:")
        guard let method = class_getInstanceMethod(type(of: cfg), sel) else {
            die("moodtool: this macOS cannot take a custom icon tint color")
        }
        // Called through the IMP: the argument is a CGColorRef, and -perform:
        // only passes objects.
        typealias SetColor = @convention(c) (AnyObject, Selector, CGColor) -> Void
        let imp = unsafeBitCast(method_getImplementation(method), to: SetColor.self)
        imp(cfg, sel, color)
    } else if let tint = iconTints[tintName] {
        cfg.setValue(tint, forKey: "iconTintColorName")
    }

    let save = NSSelectorFromString("save")
    guard cfg.responds(to: save) else { die("moodtool: icon appearance is not settable here") }
    _ = cfg.perform(save)

    // Same rule as everywhere else in this tool: read it back, never assume.
    // The write is asynchronous, so give it a moment before checking.
    usleep(300_000)
    guard let after = currentIconConfiguration(),
        let got = after.value(forKey: "iconAppearanceTheme") as? Int
    else {
        die("moodtool: could not read the icon appearance back")
    }
    if got != theme {
        die("moodtool: icon theme did not stick (asked \(themeName), got \(iconThemeName(got)))")
    }
    let gotTint = after.value(forKey: "iconTintColorName") as? Int ?? -1
    print("\(iconThemeName(got))\t\(iconTintName(gotTint))")
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
          icon-theme <theme> [tint]          icon-theme-current
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
case "icon-theme":
    guard args.count >= 2 else {
        die("usage: moodtool icon-theme <default|dark|clear|tinted|…> [tint-color]")
    }
    setIconAppearance(theme: args[1], tint: args.count >= 3 ? args[2] : "")
case "icon-theme-current":
    reportIconAppearance()
case "image-tint":
    guard args.count >= 2 else { die("usage: moodtool image-tint <image-path>") }
    reportImageTint(args[1])
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
