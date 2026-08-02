// moodbar — a one-emoji menu bar indicator for mood-wallpaper.
//
// Shows the current mood as a single emoji and nothing else, so it costs about
// as much menu bar width as the battery icon. Clicking it opens a small menu
// with the detail and the actions you'd otherwise run in a terminal.
//
// This is the only part of mood-wallpaper that stays resident. It is an
// accessory-policy app (no Dock icon, no window), it does no polling in the
// common case — it watches state/ with a kqueue vnode source and only wakes
// when a run rewrites it — and it shells out to mood-wallpaper.sh for every
// action rather than reimplementing any of the logic.

import AppKit
import Foundation

// MARK: - Where the project lives
//
// The binary sits at <root>/bin/moodbar, so the root is two levels up from the
// executable. Derived rather than hardcoded so the project can be moved.
let root = URL(fileURLWithPath: CommandLine.arguments[0])
    .resolvingSymlinksInPath()
    .deletingLastPathComponent()  // bin/
    .deletingLastPathComponent()  // <root>
let stateDir = root.appendingPathComponent("state")
let script = root.appendingPathComponent("mood-wallpaper.sh").path

let allMoods = [
    "happy", "calm", "energetic", "focused", "sad",
    "tired", "romantic", "horny", "night", "stressed",
]

func emoji(for mood: String) -> String {
    switch mood {
    case "happy": return "😊"
    case "calm": return "🌊"
    case "energetic": return "⚡"
    case "focused": return "🎯"
    case "sad": return "🌧"
    case "tired": return "😴"
    case "romantic": return "💗"
    case "horny": return "🔥"
    case "night": return "🌙"
    case "stressed": return "🫧"
    default: return "🎨"
    }
}

func readState(_ name: String) -> String? {
    let url = stateDir.appendingPathComponent(name)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

/// Fire and forget: every action is just the shell script, run off the main
/// thread so a 5-second wallpaper fetch never freezes the menu bar.
func runScript(_ args: [String]) {
    DispatchQueue.global(qos: .utility).async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script] + args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}

// MARK: - Status item

final class MoodBar: NSObject, NSMenuDelegate {
    // .variableLength keeps the item exactly as wide as its one-character
    // title; a square/fixed length would reserve space we never use.
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedDescriptor: CInt = -1

    override init() {
        super.init()
        // .variableLength with a one-character title is the narrowest a status
        // item gets; a fixed length would reserve space we don't need.
        item.button?.font = NSFont.systemFont(ofSize: 14)
        item.menu = NSMenu()
        item.menu?.delegate = self
        refresh()
        startWatching()
    }

    // MARK: state

    private var currentMood: String { readState("last-mood") ?? "unknown" }
    private var isPaused: Bool { FileManager.default.fileExists(atPath: stateDir.appendingPathComponent("paused").path) }

    /// "<mood>\t<expiry-epoch>", if a mood is pinned and hasn't expired yet.
    private var pinned: (mood: String, until: Date)? {
        guard let line = readState("override") else { return nil }
        let parts = line.components(separatedBy: "\t")
        guard parts.count >= 2, let epoch = Double(parts[1]) else { return nil }
        let until = Date(timeIntervalSince1970: epoch)
        return until > Date() ? (parts[0], until) : nil
    }

    private var lastRunDescription: String {
        guard let epoch = readState("last-run").flatMap(Double.init) else { return "never run" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: Date(timeIntervalSince1970: epoch), relativeTo: Date())
    }

    // MARK: rendering

    func refresh() {
        DispatchQueue.main.async {
            let mood = self.currentMood
            self.item.button?.title = emoji(for: mood)
            // Dimmed rather than a second glyph: it reads as "not currently
            // doing anything" without taking any more width.
            self.item.button?.appearsDisabled = self.isPaused
            var tip = "Mood: \(mood)"
            if let pin = self.pinned { tip += " (pinned until \(pin.until.formatted(date: .omitted, time: .shortened)))" }
            if self.isPaused { tip += " — paused" }
            self.item.button?.toolTip = tip
        }
    }

    /// Rebuilt on open so it always reflects the state on disk, and so nothing
    /// has to be kept in sync while the menu is closed.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let mood = currentMood

        let header = NSMenuItem(title: "\(emoji(for: mood))  \(mood)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if let pin = pinned {
            let until = pin.until.formatted(date: .omitted, time: .shortened)
            menu.addItem(disabled("pinned until \(until)"))
        } else if isPaused {
            menu.addItem(disabled("auto-switching paused"))
        } else {
            menu.addItem(disabled("last changed \(lastRunDescription)"))
        }

        menu.addItem(.separator())
        menu.addItem(action("Change now", #selector(changeNow)))
        menu.addItem(action("Why this mood?", #selector(explain)))

        menu.addItem(.separator())
        let pinMenu = NSMenu()
        for m in allMoods {
            let entry = NSMenuItem(
                title: "\(emoji(for: m))  \(m)", action: #selector(pin(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = m
            entry.state = (pinned?.mood == m) ? .on : .off
            pinMenu.addItem(entry)
        }
        let pinItem = NSMenuItem(title: "Pin a mood", action: nil, keyEquivalent: "")
        pinItem.submenu = pinMenu
        menu.addItem(pinItem)
        if pinned != nil {
            menu.addItem(action("Unpin", #selector(unpin)))
        }

        menu.addItem(action(isPaused ? "Resume" : "Pause", #selector(togglePause)))

        menu.addItem(.separator())
        menu.addItem(action("Quit", #selector(quit)))
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: actions

    @objc private func changeNow() { runScript(["--force"]) }
    @objc private func unpin() { runScript(["--clear-mood"]) }
    @objc private func togglePause() { runScript([isPaused ? "--resume" : "--pause"]) }

    @objc private func pin(_ sender: NSMenuItem) {
        guard let mood = sender.representedObject as? String else { return }
        runScript(["--set-mood", mood])
    }

    /// The explanation is a page of text, so it goes to a scrollable alert
    /// rather than a notification. Generated fresh — it is never stale.
    @objc private func explain() {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script, "--explain"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            let text: String
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                text = String(data: data, encoding: .utf8) ?? "(no output)"
            } catch {
                text = "Could not run mood-wallpaper.sh --explain:\n\(error.localizedDescription)"
            }
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Why this mood?"
                alert.informativeText = ""
                let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 340))
                field.string = text
                field.isEditable = false
                field.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
                let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 340))
                scroll.documentView = field
                scroll.hasVerticalScroller = true
                alert.accessoryView = scroll
                alert.addButton(withTitle: "OK")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: watching
    //
    // Watch the directory, not the files: every state write goes through a
    // temp file and a rename, so a watch on last-mood itself would follow the
    // replaced inode and go deaf after the first update.

    private func startWatching() {
        let fd = open(stateDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        watchedDescriptor = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in self?.refresh() }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source

        // Backstop for anything the vnode source misses (a state dir replaced
        // wholesale, a network volume). Cheap: one file read a minute.
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }
}

// MARK: - main

let app = NSApplication.shared
// .accessory = menu bar presence only. No Dock icon, no app switcher entry.
app.setActivationPolicy(.accessory)
let bar = MoodBar()
app.run()
