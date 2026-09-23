import AppKit
import Foundation
import Security

struct LimitWindow {
    let percent: Double
    let resetAt: Date?
}

struct ServiceUsage {
    let name: String
    let accent: NSColor
    let short: LimitWindow?
    let weekly: LimitWindow?
    let error: String?

    static func loading(_ name: String, accent: NSColor) -> ServiceUsage {
        ServiceUsage(name: name, accent: accent, short: nil, weekly: nil, error: nil)
    }
}

final class UsageProvider {
    private var lastClaudeRefreshAttempt = Date.distantPast

    func fetch(completion: @escaping (ServiceUsage, ServiceUsage) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let codex = self.fetchCodex()
            let claude = self.fetchClaude()
            DispatchQueue.main.async { completion(codex, claude) }
        }
    }

    private func run(_ executable: String, _ arguments: [String], input: Data? = nil, closeDelay: TimeInterval = 0) -> (Data, Data, Int32)? {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        if let input {
            let stdin = Pipe()
            process.standardInput = stdin
            do {
                try process.run()
                stdin.fileHandleForWriting.write(input)
                if closeDelay > 0 { Thread.sleep(forTimeInterval: closeDelay) }
                try? stdin.fileHandleForWriting.close()
            } catch { return nil }
        } else {
            do { try process.run() } catch { return nil }
        }
        process.waitUntilExit()
        return (stdout.fileHandleForReading.readDataToEndOfFile(), stderr.fileHandleForReading.readDataToEndOfFile(), process.terminationStatus)
    }

    private func codexPath() -> String? {
        let fm = FileManager.default
        let fixed = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        if let match = fixed.first(where: { fm.isExecutableFile(atPath: $0) }) { return match }

        let extensions = fm.homeDirectoryForCurrentUser.appendingPathComponent(".vscode/extensions")
        guard let names = try? fm.contentsOfDirectory(atPath: extensions.path) else { return nil }
        let candidates = names
            .filter { $0.hasPrefix("openai.chatgpt-") }
            .sorted(by: >)
            .map { extensions.appendingPathComponent($0).appendingPathComponent("bin/macos-aarch64/codex").path }
        return candidates.first(where: { fm.isExecutableFile(atPath: $0) })
    }

    private func fetchCodex() -> ServiceUsage {
        let accent = NSColor(calibratedRed: 0.20, green: 0.85, blue: 0.70, alpha: 1)
        guard let path = codexPath() else {
            return ServiceUsage(name: "Codex", accent: accent, short: nil, weekly: nil, error: "Codex не найден")
        }
        let messages = [
            #"{"method":"initialize","id":1,"params":{"clientInfo":{"name":"limit-lens","version":"1.0"},"capabilities":{}}}"#,
            #"{"method":"initialized","params":{}}"#,
            #"{"method":"account/rateLimits/read","id":2,"params":{"excludeResetCreditDetails":true}}"#
        ].joined(separator: "\n") + "\n"
        // A cold app-server start can take several seconds. Retry once instead
        // of turning a slow response into a misleading sign-in error.
        for _ in 0..<2 {
            guard let result = run(path, ["app-server", "--stdio"], input: Data(messages.utf8), closeDelay: 5.0),
                  result.2 == 0,
                  let text = String(data: result.0, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (root["id"] as? Int) == 2,
                      let response = root["result"] as? [String: Any],
                      let limits = response["rateLimits"] as? [String: Any] else { continue }
                return ServiceUsage(
                    name: "Codex",
                    accent: accent,
                    short: parseCodexWindow(limits["primary"]),
                    weekly: parseCodexWindow(limits["secondary"]),
                    error: nil
                )
            }
        }
        return ServiceUsage(name: "Codex", accent: accent, short: nil, weekly: nil, error: "Codex временно недоступен")
    }

    private func parseCodexWindow(_ value: Any?) -> LimitWindow? {
        guard let object = value as? [String: Any], let percent = object["usedPercent"] as? Double ?? (object["usedPercent"] as? Int).map(Double.init) else { return nil }
        let reset = (object["resetsAt"] as? Double ?? (object["resetsAt"] as? Int).map(Double.init)).map(Date.init(timeIntervalSince1970:))
        return LimitWindow(percent: percent, resetAt: reset)
    }

    private func fetchClaude(allowTokenRefresh: Bool = true) -> ServiceUsage {
        let accent = NSColor(calibratedRed: 0.93, green: 0.51, blue: 0.32, alpha: 1)
        guard let credentials = run("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"]), credentials.2 == 0,
              let json = try? JSONSerialization.jsonObject(with: credentials.0) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            return ServiceUsage(name: "Claude", accent: accent, short: nil, weekly: nil, error: "Войдите в Claude Code")
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1", forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            responseData = data
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 18)

        guard let responseData,
              let root = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            return ServiceUsage(name: "Claude", accent: accent, short: nil, weekly: nil, error: "Нет связи")
        }
        if let apiError = root["error"] as? [String: Any] {
            let type = apiError["type"] as? String
            if allowTokenRefresh,
               type == "authentication_error",
               Date().timeIntervalSince(lastClaudeRefreshAttempt) > 1800 {
                lastClaudeRefreshAttempt = Date()
                if refreshClaudeLogin() {
                    return fetchClaude(allowTokenRefresh: false)
                }
            }
            return ServiceUsage(name: "Claude", accent: accent, short: nil, weekly: nil, error: "Обновите вход в Claude")
        }
        return ServiceUsage(
            name: "Claude",
            accent: accent,
            short: parseClaudeWindow(root["five_hour"]),
            weekly: parseClaudeWindow(root["seven_day"]),
            error: nil
        )
    }

    private func refreshClaudeLogin() -> Bool {
        let paths = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return false }
        // Claude Code refreshes its expired OAuth token before the request.
        // This runs only after an authentication error, never on normal polling.
        guard let result = run(path, [
            "-p",
            "--model", "claude-haiku-4-5-20251001",
            "--max-turns", "1",
            "Reply with OK only."
        ]) else { return false }
        return result.2 == 0
    }

    private func parseClaudeWindow(_ value: Any?) -> LimitWindow? {
        guard let object = value as? [String: Any], let percent = object["utilization"] as? Double ?? (object["utilization"] as? Int).map(Double.init) else { return nil }
        var reset: Date?
        if let timestamp = object["resets_at"] as? String {
            reset = ISO8601DateFormatter().date(from: timestamp)
            if reset == nil {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX"
                reset = formatter.date(from: timestamp)
            }
        }
        return LimitWindow(percent: percent, resetAt: reset)
    }
}

final class WidgetView: NSView {
    var codex = ServiceUsage.loading("Codex", accent: NSColor(calibratedRed: 0.20, green: 0.85, blue: 0.70, alpha: 1)) { didSet { needsDisplay = true } }
    var claude = ServiceUsage.loading("Claude", accent: NSColor(calibratedRed: 0.93, green: 0.51, blue: 0.32, alpha: 1)) { didSet { needsDisplay = true } }
    var updatedAt: Date? { didSet { needsDisplay = true } }
    private var dragMouseOrigin: NSPoint?
    private var dragWindowOrigin: NSPoint?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragMouseOrigin = NSEvent.mouseLocation
        dragWindowOrigin = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let mouseOrigin = dragMouseOrigin, let windowOrigin = dragWindowOrigin else { return }
        let current = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(
            x: windowOrigin.x + current.x - mouseOrigin.x,
            y: windowOrigin.y + current.y - mouseOrigin.y
        ))
    }

    override func mouseUp(with event: NSEvent) {
        dragMouseOrigin = nil
        dragWindowOrigin = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.clear.setFill()
        dirtyRect.fill()

        let panel = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 24, yRadius: 24)
        let panelGradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.075, green: 0.085, blue: 0.105, alpha: 0.96),
            NSColor(calibratedRed: 0.045, green: 0.050, blue: 0.064, alpha: 0.94)
        ])!
        panelGradient.draw(in: panel, angle: -68)
        NSColor(calibratedWhite: 1, alpha: 0.14).setStroke()
        panel.lineWidth = 1
        panel.stroke()

        drawText("AI · ЛИМИТЫ", at: NSPoint(x: 22, y: 18), size: 11, color: NSColor.white.withAlphaComponent(0.72), weight: .semibold, tracking: 1.25)
        let status: String
        if let updatedAt {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            status = "обновлено в \(formatter.string(from: updatedAt))"
        } else {
            status = "обновление…"
        }
        let statusAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.white.withAlphaComponent(0.42)]
        let statusWidth = status.size(withAttributes: statusAttrs).width
        status.draw(at: NSPoint(x: bounds.maxX - statusWidth - 22, y: 18), withAttributes: statusAttrs)

        drawCard(codex, rect: NSRect(x: 14, y: 44, width: bounds.width - 28, height: 119))
        drawCard(claude, rect: NSRect(x: 14, y: 171, width: bounds.width - 28, height: 119))

        drawText("↕  перетащите  ·  обновление каждые 2 минуты", at: NSPoint(x: 22, y: 303), size: 9.5, color: NSColor.white.withAlphaComponent(0.34), weight: .regular)
    }

    private func drawCard(_ usage: ServiceUsage, rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18)
        NSColor(calibratedWhite: 1, alpha: 0.06).setFill()
        path.fill()
        NSColor(calibratedWhite: 1, alpha: 0.055).setStroke()
        path.lineWidth = 0.8
        path.stroke()

        let iconRect = NSRect(x: rect.minX + 14, y: rect.minY + 12, width: 29, height: 29)
        let icon = NSBezierPath(roundedRect: iconRect, xRadius: 9, yRadius: 9)
        usage.accent.withAlphaComponent(0.18).setFill()
        icon.fill()
        drawCentered(String(usage.name.prefix(1)), center: NSPoint(x: iconRect.midX, y: iconRect.minY + 5), size: 14, color: usage.accent, weight: .bold)
        drawText(usage.name, at: NSPoint(x: rect.minX + 51, y: rect.minY + 16), size: 14, color: .white, weight: .semibold)

        if let error = usage.error {
            let errorRect = NSRect(x: rect.minX + 14, y: rect.minY + 54, width: rect.width - 28, height: 39)
            let errorPath = NSBezierPath(roundedRect: errorRect, xRadius: 11, yRadius: 11)
            usage.accent.withAlphaComponent(0.09).setFill()
            errorPath.fill()
            drawText(error, at: NSPoint(x: errorRect.minX + 12, y: errorRect.minY + 11), size: 11.5, color: NSColor.white.withAlphaComponent(0.65), weight: .medium)
            return
        }

        drawUsageRow(usage.short, title: "5 часов", y: rect.minY + 51, rect: rect, accent: usage.accent)
        drawUsageRow(usage.weekly, title: "Неделя", y: rect.minY + 84, rect: rect, accent: usage.accent)
    }

    private func drawUsageRow(_ value: LimitWindow?, title: String, y: CGFloat, rect: NSRect, accent: NSColor) {
        let labelX = rect.minX + 15
        let barX = rect.minX + 72
        let barWidth: CGFloat = 132
        drawText(title, at: NSPoint(x: labelX, y: y - 2), size: 10.5, color: NSColor.white.withAlphaComponent(0.58), weight: .medium)

        let trackRect = NSRect(x: barX, y: y + 2, width: barWidth, height: 7)
        let track = NSBezierPath(roundedRect: trackRect, xRadius: 3.5, yRadius: 3.5)
        NSColor.white.withAlphaComponent(0.09).setFill()
        track.fill()

        guard let value else {
            drawText("—", at: NSPoint(x: barX + barWidth + 12, y: y - 4), size: 13, color: NSColor.white.withAlphaComponent(0.35), weight: .bold)
            return
        }

        let clamped = CGFloat(max(0, min(100, value.percent))) / 100
        if clamped > 0 {
            let fillRect = NSRect(x: barX, y: y + 2, width: max(7, barWidth * clamped), height: 7)
            let fill = NSBezierPath(roundedRect: fillRect, xRadius: 3.5, yRadius: 3.5)
            accent.setFill()
            fill.fill()
        }
        drawRightAlignedMonospaced(
            String(format: "%.0f%%", value.percent),
            rightX: rect.maxX - 14,
            y: y - 5,
            size: 13,
            color: .white,
            weight: .bold
        )
        if let resetAt = value.resetAt {
            // Keep the two time values in stable columns. Their content changes,
            // but the visual anchors never jump left or right.
            drawRightAlignedMonospaced(
                resetClockText(resetAt),
                rightX: rect.minX + 226,
                y: y + 12,
                size: 9,
                color: NSColor.white.withAlphaComponent(0.43),
                weight: .regular
            )
            drawText("·", at: NSPoint(x: rect.minX + 232, y: y + 12), size: 9, color: NSColor.white.withAlphaComponent(0.25), weight: .regular)
            drawRightAlignedMonospaced(
                remainingText(resetAt),
                rightX: rect.maxX - 13,
                y: y + 12,
                size: 9,
                color: NSColor.white.withAlphaComponent(0.43),
                weight: .regular
            )
        }
    }

    private func resetClockText(_ date: Date) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.timeZone = .current
        formatter.dateFormat = calendar.isDateInToday(date) ? "сегодня HH:mm" : "d MMM, HH:mm"
        return formatter.string(from: date)
    }

    private func remainingText(_ date: Date) -> String {
        let interval = date.timeIntervalSinceNow
        if interval <= 0 { return "скоро сброс" }
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        if hours >= 24 { return "через \(hours / 24)д \(hours % 24)ч" }
        if hours > 0 { return "через \(hours)ч \(minutes)м" }
        return "через \(max(1, minutes))м"
    }

    private func drawCentered(_ text: String, center: NSPoint, size: CGFloat, color: NSColor, weight: NSFont.Weight) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
        let measured = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: center.x - measured.width / 2, y: center.y), withAttributes: attrs)
    }

    private func drawText(_ text: String, at point: NSPoint, size: CGFloat, color: NSColor, weight: NSFont.Weight, tracking: CGFloat = 0) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .kern: tracking
        ]
        text.draw(at: point, withAttributes: attrs)
    }

    private func drawRightAlignedMonospaced(_ text: String, rightX: CGFloat, y: CGFloat, size: CGFloat, color: NSColor, weight: NSFont.Weight) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight),
            .foregroundColor: color
        ]
        let width = text.size(withAttributes: attrs).width
        text.draw(at: NSPoint(x: rightX - width, y: y), withAttributes: attrs)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var widgetView: WidgetView!
    private var timer: Timer?
    private let provider = UsageProvider()
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        createWindow()
        createStatusItem()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in self?.refresh() }
    }

    private func createWindow() {
        let size = NSSize(width: 350, height: 326)
        let savedX = UserDefaults.standard.object(forKey: "windowX") as? CGFloat
        let savedY = UserDefaults.standard.object(forKey: "windowY") as? CGFloat
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: savedX ?? screen.maxX - size.width - 28, y: savedY ?? screen.maxY - size.height - 34)
        window = NSWindow(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        // Above Finder's desktop icons so the panel receives drag events,
        // but still far below ordinary application windows.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.delegate = self
        widgetView = WidgetView(frame: NSRect(origin: .zero, size: size))
        window.contentView = widgetView
        window.orderFrontRegardless()
    }

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: "AI Limits")
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Обновить сейчас", action: #selector(refreshFromMenu), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Показать виджет", action: #selector(showWidget), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Завершить", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    @objc private func refreshFromMenu() { refresh() }
    @objc private func showWidget() { window.orderFrontRegardless() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func refresh() {
        provider.fetch { [weak self] codex, claude in
            self?.widgetView.codex = codex
            self?.widgetView.claude = claude
            self?.widgetView.updatedAt = Date()
        }
    }

    func windowDidMove(_ notification: Notification) {
        UserDefaults.standard.set(window.frame.origin.x, forKey: "windowX")
        UserDefaults.standard.set(window.frame.origin.y, forKey: "windowY")
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
