// The huddle recorder's button and its state, in three places at once.
//
//   Dock icon   — a white ring when idle, a red dot when recording. Click it to
//                 toggle. This is the control: the thing you press is the thing
//                 that shows what is happening.
//   On-screen   — a red "REC 1:23" badge floats near the top of the screen the
//     badge       whole time it records. Visible over full-screen apps.
//   Menu bar    — the same dot, for when the badge is in the way. On a Mac with
//                 a notch this one can be hidden behind it, so it is the spare.
//
// It asks OBS every couple of seconds what is true, rather than trusting its own
// memory, and writes every state change to <recordings>/.indicator.log.
//
// Build (installs into ~/Applications/Huddle Rec.app):
//     app/build.sh
//
// BIN and RECORDINGS come from Paths.swift, which build.sh writes for this Mac.
import Cocoa

let TOGGLE = "\(BIN)/record-huddle.sh"
let STATUS = "\(BIN)/obs-huddle.mjs"
// A GUI app inherits no shell profile; node and ffmpeg live off the default PATH.
let PATH = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

let RED = NSColor(srgbRed: 0.88, green: 0.23, blue: 0.18, alpha: 1)
let INK = NSColor(srgbRed: 0.04, green: 0.04, blue: 0.04, alpha: 1)

func run(_ command: String) -> String {
    let p = Process()
    let pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-c", "export PATH=\(PATH); \(command)"]
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

final class Indicator: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var badge: NSWindow?
    var badgeLabel: NSTextField?
    var recording = false
    var elapsed = ""
    var busy = false
    var busySince: Date?
    var lastDrawn: Bool?
    var tick = 0

    /// Appends to <recordings>/.indicator.log — state only, never content.
    func log(_ line: String) {
        let entry = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        let path = RECORDINGS + "/.indicator.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(entry.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? entry.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        item.button?.action = #selector(click)
        item.button?.target = self
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        buildBadge()
        render()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in self.poll() }
        poll()
    }

    /// Clicking the Dock icon of an already-running app lands here.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        toggle()
        return false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { menu() }

    // MARK: state

    func poll() {
        // A click that never came back must not freeze the state forever.
        if busy, let since = busySince, Date().timeIntervalSince(since) > 20 {
            log("busy stuck for \(Int(Date().timeIntervalSince(since)))s — clearing")
            busy = false
            busySince = nil
        }
        guard !busy else { return }
        tick += 1
        // While recording the clock has to tick; idle, every third beat is plenty.
        guard recording || tick % 3 == 0 else { return }
        DispatchQueue.global(qos: .utility).async {
            // pgrep first, in the same shell: no OBS, no node.
            let out = run("pgrep -xq OBS && node '\(STATUS)' status 2>/dev/null")
            guard
                let data = out.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                DispatchQueue.main.async { self.recording = false; self.render() }
                return
            }
            DispatchQueue.main.async {
                self.recording = json["recording"] as? Bool ?? false
                self.elapsed = Self.short(json["timecode"] as? String ?? "")
                self.render()
            }
        }
    }

    /// "00:12:04.320" -> "12:04", "01:02:03.000" -> "1:02:03"
    static func short(_ timecode: String) -> String {
        let parts = timecode.split(separator: ".").first?.split(separator: ":").map(String.init) ?? []
        guard parts.count == 3 else { return "" }
        let (h, m, s) = (parts[0], parts[1], parts[2])
        if h == "00" { return "\(Int(m) ?? 0):\(s)" }
        return "\(Int(h) ?? 0):\(m):\(s)"
    }

    // MARK: drawing

    func render() {
        if recording != lastDrawn {
            log("state: \(recording ? "RECORDING — dock icon red, badge shown" : "idle — dock icon ring, badge hidden")")
            lastDrawn = recording
        }
        NSApp.applicationIconImage = dockIcon()
        renderStatusItem()
        renderBadge()
    }

    /// Rounded black square with a white ring (idle) or a filled red dot (recording).
    func dockIcon() -> NSImage {
        let size: CGFloat = 512
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let body = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
                                    xRadius: size * 0.225, yRadius: size * 0.225)
            INK.setFill(); body.fill()
            let r = size * 0.21
            let dot = NSBezierPath(ovalIn: NSRect(x: size / 2 - r, y: size / 2 - r, width: r * 2, height: r * 2))
            if self.recording {
                RED.setFill(); dot.fill()
            } else {
                NSColor(white: 0.96, alpha: 1).setStroke()
                dot.lineWidth = size * 0.09
                dot.stroke()
            }
            return true
        }
    }

    func renderStatusItem() {
        guard let button = item.button else { return }
        let image = NSImage(systemSymbolName: recording ? "record.circle.fill" : "record.circle",
                            accessibilityDescription: recording ? "Recording" : "Not recording")
        if recording {
            button.image = image?.withSymbolConfiguration(.init(hierarchicalColor: .systemRed))
            button.image?.isTemplate = false
            button.attributedTitle = NSAttributedString(
                string: " " + elapsed,
                attributes: [.foregroundColor: NSColor.systemRed,
                             .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)])
            button.toolTip = "Recording — click to stop"
        } else {
            button.image = image
            button.image?.isTemplate = true
            button.attributedTitle = NSAttributedString(string: "")
            button.toolTip = "Click to record a call"
        }
    }

    // MARK: the floating badge

    func buildBadge() {
        let frame = NSRect(x: 0, y: 0, width: 132, height: 36)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = true          // never steals a click mid-meeting
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let pill = NSView(frame: frame)
        pill.wantsLayer = true
        pill.layer?.backgroundColor = INK.withAlphaComponent(0.92).cgColor
        pill.layer?.cornerRadius = 18
        pill.layer?.borderWidth = 1.5
        pill.layer?.borderColor = RED.cgColor

        let dot = NSView(frame: NSRect(x: 14, y: 14, width: 9, height: 9))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = RED.cgColor
        dot.layer?.cornerRadius = 4.5
        pill.addSubview(dot)

        let label = NSTextField(labelWithString: "REC")
        label.frame = NSRect(x: 31, y: 9, width: 92, height: 18)
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        pill.addSubview(label)

        window.contentView = pill
        badge = window
        badgeLabel = label
    }

    func renderBadge() {
        guard let badge else { return }
        guard recording else { badge.orderOut(nil); return }
        badgeLabel?.stringValue = elapsed.isEmpty ? "REC" : "REC  \(elapsed)"
        if let screen = NSScreen.main {
            let v = screen.visibleFrame
            badge.setFrameOrigin(NSPoint(x: v.maxX - badge.frame.width - 18, y: v.maxY - badge.frame.height - 12))
        }
        badge.orderFrontRegardless()
    }

    // MARK: actions

    @objc func click() {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu() } else { toggle() }
    }

    @objc func toggle() {
        guard !busy else { log("click ignored: a previous one is still running"); return }
        busy = true
        busySince = Date()
        log("click: was \(recording ? "recording" : "idle")")
        recording.toggle()          // react on the click, not two seconds later
        elapsed = ""
        render()
        DispatchQueue.global(qos: .userInitiated).async {
            let out = run("'\(TOGGLE)' toggle")
            DispatchQueue.main.async {
                self.busy = false
                self.busySince = nil
                self.log("toggle returned: \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
                for delay in [0.3, 1.0, 2.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.poll() }
                }
            }
        }
    }

    @objc func openRecordings() { NSWorkspace.shared.open(URL(fileURLWithPath: RECORDINGS)) }

    @objc func openTranscripts() { NSWorkspace.shared.open(URL(fileURLWithPath: RECORDINGS + "/transcripts")) }

    @objc func quit() { NSApp.terminate(nil) }

    func menu() -> NSMenu {
        let m = NSMenu()
        let t = NSMenuItem(title: recording ? "Stop recording\(elapsed.isEmpty ? "" : " (\(elapsed))")" : "Start recording",
                           action: #selector(toggle), keyEquivalent: "")
        t.target = self
        m.addItem(t)
        m.addItem(.separator())
        for (title, sel) in [("Open transcripts", #selector(openTranscripts)),
                             ("Open recordings", #selector(openRecordings))] {
            let e = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            e.target = self
            m.addItem(e)
        }
        m.addItem(.separator())
        let q = NSMenuItem(title: "Quit Huddle Rec", action: #selector(quit), keyEquivalent: "q")
        q.target = self
        m.addItem(q)
        return m
    }

    func showMenu() {
        item.menu = menu()
        item.button?.performClick(nil)
        item.menu = nil
    }
}

let app = NSApplication.shared
let indicator = Indicator()
app.delegate = indicator
app.setActivationPolicy(.regular)   // live in the Dock, where the state is visible
app.run()
