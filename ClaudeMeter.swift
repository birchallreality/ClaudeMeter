import AppKit
import ServiceManagement
import os

let log = Logger(subsystem: "com.isaac.claudemeter", category: "fetch")

// MARK: - Data

let sessionLength: TimeInterval = 5 * 3600
let weekLength: TimeInterval = 7 * 86400

struct Window: Decodable {
    let utilization: Double
    let resets_at: String?

    var used: Double { utilization / 100 }

    var resetDate: Date? {
        // API sends microseconds ("…00.368902+00:00"); strip them for ISO8601DateFormatter.
        guard let s = resets_at?.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        else { return nil }
        return ISO8601DateFormatter().date(from: s)
    }

    /// Fraction of the window already elapsed; nil when no window is active.
    func elapsed(of length: TimeInterval) -> Double? {
        guard let reset = resetDate else { return nil }
        return min(max(1 - reset.timeIntervalSinceNow / length, 0), 1)
    }
}

struct Usage: Decodable {
    let five_hour: Window?
    let seven_day: Window?
}

enum FetchError: Error, Equatable {
    case signedOut, offline
    case rateLimited(retryAfter: TimeInterval?)
}

/// Reads Claude Code's OAuth token via the `security` CLI (same tool Claude Code uses,
/// so no Keychain prompt and nothing breaks on rebuild).
func readToken() -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = json["claudeAiOauth"] as? [String: Any]
    else { return nil }
    return oauth["accessToken"] as? String
}

func fetchUsage() async -> Result<Usage, FetchError> {
    guard let token = readToken() else { return .failure(.signedOut) }
    var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.timeoutInterval = 15
    guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return .failure(.offline) }
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    if code == 401 || code == 403 { return .failure(.signedOut) }
    if code == 429 {
        let retryAfter = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        return .failure(.rateLimited(retryAfter: retryAfter))
    }
    guard code == 200, let usage = try? JSONDecoder().decode(Usage.self, from: data) else { return .failure(.offline) }
    return .success(usage)
}

// MARK: - Levels & colours

enum Level: Int, Comparable {
    case ok, warn, critical
    static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

    var color: NSColor {
        let (light, dark) = switch self {
        case .ok: (0x4E9A5F, 0x73C184)
        case .warn: (0xC98A1E, 0xE3AE4A)
        case .critical: (0xCC4B3F, 0xEC6D60)
        }
        return dynamic(light: hex(light), dark: hex(dark))
    }
}

/// Using quota faster than the clock (ignored while usage is small).
func isAhead(_ used: Double, _ elapsed: Double?) -> Bool {
    guard let e = elapsed else { return false }
    return used >= 0.25 && used > e + 0.10
}

/// Absolute usage sets the level; running ahead of pace can raise ok → warn, never to critical.
func level(_ used: Double, _ elapsed: Double?) -> Level {
    let absolute: Level = used >= 0.85 ? .critical : used >= 0.60 ? .warn : .ok
    return max(absolute, isAhead(used, elapsed) ? .warn : .ok)
}

func hex(_ v: Int) -> NSColor {
    NSColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255,
            blue: CGFloat(v & 255) / 255, alpha: 1)
}

func dynamic(light: NSColor, dark: NSColor) -> NSColor {
    NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
}

let ink = dynamic(light: .black, dark: .white)
let track = dynamic(light: .black.withAlphaComponent(0.18), dark: .white.withAlphaComponent(0.24))
let faintTrack = dynamic(light: .black.withAlphaComponent(0.12), dark: .white.withAlphaComponent(0.12))
let meterTrack = dynamic(light: .black.withAlphaComponent(0.12), dark: .white.withAlphaComponent(0.18))

// MARK: - Formatting

func countdown(to date: Date) -> String {
    let mins = max(0, Int(date.timeIntervalSinceNow / 60))
    let (d, h, m) = (mins / 1440, mins / 60 % 24, mins % 60)
    if d > 0 { return "\(d)d\(h)h" }
    if h > 0 { return "\(h)h\(String(format: "%02d", m))m" }
    return m > 0 ? "\(m)m" : "<1m"
}

func resetText(_ date: Date) -> String {
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate(Calendar.current.isDateInToday(date) ? "jmm" : "EEEjmm")
    return "Resets \(f.string(from: date)) · in \(countdown(to: date))"
}

/// Right-hand caption in the dropdown, and whether it's a warning.
func paceMessage(_ w: Window, length: TimeInterval) -> (String, Bool) {
    guard let reset = w.resetDate, let e = w.elapsed(of: length) else { return ("", false) }
    if w.used >= 1 { return ("Limit reached", true) }
    if isAhead(w.used, e) {
        let secondsToLimit = (1 - w.used) / (w.used / max(e * length, 60))
        return secondsToLimit < reset.timeIntervalSinceNow
            ? ("Limit in ~" + countdown(to: Date() + secondsToLimit), true)
            : ("Ahead of pace", true)
    }
    return level(w.used, e) > .ok ? ("High usage", true) : ("On pace", false)
}

// MARK: - Drawing

/// Clip that removes a horizontal/vertical band from `rect` (the knockout around a pace mark).
func clip(_ rect: NSRect, excluding band: NSRect?) {
    guard let band else { return }
    let path = NSBezierPath(rect: rect)
    path.append(NSBezierPath(rect: band))
    path.windingRule = .evenOdd
    path.addClip()
}

/// Twin Bars: 14×22pt. Left (6pt) = 5h session with a pace line at time elapsed,
/// right (4pt) = week. Bars fill from the bottom in their level colour.
func glyph(session: Window?, week: Window?, signedOut: Bool) -> NSImage {
    NSImage(size: NSSize(width: 14, height: 22), flipped: false) { _ in
        let bars: [(x: CGFloat, w: CGFloat, win: Window?, length: TimeInterval, paceLine: Bool)] = [
            (1, 6, session, sessionLength, true),
            (10, 4, week, weekLength, false),
        ]
        for bar in bars {
            let rect = NSRect(x: bar.x, y: 3, width: bar.w, height: 16)
            let win = signedOut ? nil : bar.win
            let elapsed = win?.elapsed(of: bar.length)
            let lineY = elapsed.map { min(max((rect.minY + 16 * CGFloat($0)).rounded(.down), 4), 17) }

            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: bar.w / 2, yRadius: bar.w / 2).addClip()
            if bar.paceLine, let y = lineY {
                clip(rect, excluding: NSRect(x: rect.minX, y: y - 1, width: bar.w, height: 3))
            }
            (signedOut ? faintTrack : track).setFill()
            rect.fill()
            if let win, win.used > 0 {
                level(win.used, elapsed).color.setFill()
                NSRect(x: rect.minX, y: rect.minY, width: bar.w,
                       height: max(1, (16 * CGFloat(min(win.used, 1))).rounded())).fill()
            }
            NSGraphicsContext.restoreGraphicsState()

            if bar.paceLine, let y = lineY {
                ink.setFill()
                NSRect(x: rect.minX - 1, y: y, width: bar.w + 2, height: 1).fill()
            }
        }
        return true
    }
}

/// One dropdown section: title + %, a horizontal meter with a pace tick, reset + pace captions.
final class SectionView: NSView {
    let title: String
    let length: TimeInterval
    var data: Window? { didSet { needsDisplay = true } }

    init(title: String, length: TimeInterval) {
        self.title = title
        self.length = length
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 66))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let w = data else { return }
        let pad: CGFloat = 14
        let elapsed = w.elapsed(of: length)
        let lvl = level(w.used, elapsed)

        func text(_ s: String, top: CGFloat, font: NSFont, color: NSColor, right: Bool = false) {
            let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
            let size = a.size()
            a.draw(at: NSPoint(x: right ? bounds.width - pad - size.width : pad, y: bounds.height - top - size.height))
        }

        text(title, top: 6, font: .systemFont(ofSize: 13, weight: .semibold), color: .labelColor)
        text("\(Int(w.utilization.rounded()))%", top: 6,
             font: .monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
             color: lvl == .ok ? .labelColor : lvl.color, right: true)

        // Meter
        let rect = NSRect(x: pad, y: bounds.height - 30, width: bounds.width - 2 * pad, height: 6)
        let tickX = elapsed.map { (rect.minX + rect.width * CGFloat($0)).rounded(.down) }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).addClip()
        clip(rect, excluding: tickX.map { NSRect(x: $0 - 1, y: rect.minY, width: 3, height: rect.height) })
        meterTrack.setFill()
        rect.fill()
        if w.used > 0 {
            lvl.color.setFill()
            NSRect(x: rect.minX, y: rect.minY, width: max(2, (rect.width * CGFloat(min(w.used, 1))).rounded()),
                   height: rect.height).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        if let x = tickX {
            ink.withAlphaComponent(0.85).setFill()
            NSRect(x: x, y: rect.minY - 2, width: 1, height: rect.height + 4).fill()
        }

        // Captions
        let caption = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        text(w.resetDate.map(resetText) ?? "Starts with your next message", top: 38, font: caption,
             color: .secondaryLabelColor)
        let (msg, alert) = paceMessage(w, length: length)
        text(msg, top: 38, font: caption, color: alert ? lvl.color : .secondaryLabelColor, right: true)
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let sessionView = SectionView(title: "Session", length: sessionLength)
    let weekView = SectionView(title: "Week", length: weekLength)
    lazy var sessionItem = viewItem(sessionView)
    lazy var weekItem = viewItem(weekView)
    var usage: Usage?
    var error: FetchError?
    var nextFetch = Date.distantPast
    var failures = 0
    var fetching = false
    var appearanceObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ note: Notification) {
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.button?.imagePosition = .imageLeading
        // Colours are appearance-dependent, so redraw when the menu bar flips light/dark.
        appearanceObservation = item.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.render() }
        }
        render()
        refresh()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in self.tick() }
        }
    }

    /// Every minute: fetch if due (backoff may push that out), otherwise just redraw the pace line.
    func tick() {
        if Date() >= nextFetch { refresh() } else { render() }
    }

    func refresh() {
        guard !fetching else { return }
        fetching = true
        Task {
            switch await fetchUsage() {
            case .success(let u):
                usage = u
                error = nil
                failures = 0
            case .failure(let e):
                error = e
                // A 401 means the network is fine, so only back off on offline / rate-limited.
                failures = e == .signedOut ? 0 : failures + 1
            }
            // 1m normally; after failures 2m, 4m, 8m… capped at 15m, never sooner than Retry-After.
            var delay = min(60 * pow(2, Double(failures)), 900)
            if case .rateLimited(let after?) = error { delay = max(delay, after) }
            nextFetch = Date() + delay
            if let error {
                log.notice("fetch failed: \(String(describing: error), privacy: .public), retry in \(Int(delay))s")
            }
            fetching = false
            render()
        }
    }

    func render() {
        guard let button = item.button else { return }
        let signedOut = error == .signedOut || usage == nil
        let session = usage?.five_hour
        button.image = glyph(session: session, week: usage?.seven_day, signedOut: signedOut)
        let title = signedOut ? "—" : "\(Int((session?.utilization ?? 0).rounded()))%"
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular),
        ])
        button.appearsDisabled = error != nil
        sessionView.data = session
        weekView.data = usage?.seven_day
    }

    // Rebuilt every time the menu opens; section views update live after a refresh.
    func menuNeedsUpdate(_ menu: NSMenu) {
        tick()
        menu.removeAllItems()

        if error == .signedOut {
            menu.addItem(info("Open Claude Code to sign in"))
        } else if let u = usage {
            if u.five_hour != nil { menu.addItem(sessionItem) }
            if u.seven_day != nil { menu.addItem(weekItem) }
            if let note = retryNote { menu.addItem(info(note)) }
        } else {
            menu.addItem(info(retryNote ?? "Loading…"))
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Refresh", action: #selector(refreshAction), keyEquivalent: "r").target = self
        let login = menu.addItem(withTitle: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(withTitle: "Quit ClaudeMeter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private var retryNote: String? {
        switch error {
        case .offline: "Can't reach Anthropic · retrying in \(countdown(to: nextFetch))"
        case .rateLimited: "Rate limited · retrying in \(countdown(to: nextFetch))"
        default: nil
        }
    }

    private func viewItem(_ view: NSView) -> NSMenuItem {
        let mi = NSMenuItem()
        mi.view = view
        return mi
    }

    private func info(_ text: String) -> NSMenuItem {
        let mi = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        mi.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        return mi
    }

    @objc func refreshAction() { refresh() }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

@main
enum Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
