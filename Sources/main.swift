import AppKit
import SwiftUI

// MARK: - Model

enum Posture: String, CaseIterable {
    case sitting, standing, moving

    var title: String { switch self { case .sitting: "Sitzen"; case .standing: "Stehen"; case .moving: "Bewegen" } }
    var verb: String { switch self { case .sitting: "Ich sitze jetzt"; case .standing: "Ich stehe jetzt"; case .moving: "Ich bewege mich" } }
    var state: String { switch self { case .sitting: "sitzt"; case .standing: "stehst"; case .moving: "bewegst dich" } }
    var symbol: String { switch self { case .sitting: "figure.seated.side"; case .standing: "figure.stand"; case .moving: "figure.walk" } }
    var color: Color {
        switch self {
        case .sitting: Color(red: 0.95, green: 0.55, blue: 0.20)
        case .standing: Color(red: 0.20, green: 0.75, blue: 0.45)
        case .moving: Color(red: 0.25, green: 0.55, blue: 0.95)
        }
    }
}

struct Entry {
    let date: Date
    let event: String // start | change | skip | manual | quit
    let response: Int
}

let skipReasons = ["Kann gerade nicht", "Meeting / Call", "Ergibt gerade keinen Sinn", "Schmerzen"]

// MARK: - State

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    private let defaults = UserDefaults.standard
    @Published var posture: Posture { didSet { defaults.set(posture.rawValue, forKey: "posture") } }
    @Published var intervalMinutes: Int { didSet { defaults.set(intervalMinutes, forKey: "interval") } }
    @Published var cycleStart: Date { didSet { defaults.set(cycleStart, forKey: "cycleStart") } }
    @Published var now = Date()
    @Published var promptShownAt: Date?
    @Published private(set) var entries: [Entry] = []

    /// Test hook: overrides the interval in seconds.
    private let testSeconds = ProcessInfo.processInfo.environment["STANDUP_INTERVAL_SECONDS"].flatMap(Double.init)
    let logURL: URL
    private let overlay = OverlayController()
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        return f
    }()

    var interval: TimeInterval { testSeconds ?? Double(intervalMinutes) * 60 }
    var remaining: TimeInterval { max(0, cycleStart.addingTimeInterval(interval).timeIntervalSince(now)) }
    var elapsed: TimeInterval { now.timeIntervalSince(cycleStart) }

    private init() {
        posture = Posture(rawValue: defaults.string(forKey: "posture") ?? "") ?? .sitting
        let saved = defaults.integer(forKey: "interval")
        intervalMinutes = saved > 0 ? saved : 40
        cycleStart = defaults.object(forKey: "cycleStart") as? Date ?? Date()
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StandUpSitDown")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        logURL = dir.appendingPathComponent("log.csv")
        loadLog()
    }

    func start() {
        log("start", from: posture, to: posture, reason: "")
        let t = Timer(timeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { AppState.shared.tick() } }
        RunLoop.main.add(t, forMode: .common)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppState.shared.screensChanged() }
        }
        tick()
    }

    private func tick() {
        now = Date()
        if promptShownAt != nil {
            overlay.reassert()
        } else if remaining <= 0 {
            showPrompt()
        }
    }

    private func screensChanged() {
        if promptShownAt != nil { overlay.show(state: self) }
    }

    func showPrompt() {
        guard promptShownAt == nil else { return }
        promptShownAt = Date()
        overlay.show(state: self)
    }

    func choose(_ p: Posture) {
        log("change", from: posture, to: p, reason: "")
        posture = p
        finishPrompt()
    }

    func skip(_ reason: String) {
        log("skip", from: posture, to: posture, reason: reason)
        finishPrompt()
    }

    func setManually(_ p: Posture) {
        guard p != posture else { return }
        log("manual", from: posture, to: p, reason: "")
        posture = p
        cycleStart = Date()
    }

    func quitLogged() { log("quit", from: posture, to: posture, reason: "") }

    private func finishPrompt() {
        promptShownAt = nil
        cycleStart = Date()
        now = cycleStart
        overlay.hide()
    }

    // MARK: Log (CSV: timestamp,event,from,to,reason,interval_min,response_sec)

    private func log(_ event: String, from: Posture, to: Posture, reason: String) {
        let date = Date()
        let response = promptShownAt.map { Int(date.timeIntervalSince($0)) } ?? 0
        let line = [iso.string(from: date), event, from.rawValue, to.rawValue, reason, String(intervalMinutes), String(response)]
            .joined(separator: ",") + "\n"
        if !FileManager.default.fileExists(atPath: logURL.path) {
            try? "timestamp,event,from,to,reason,interval_min,response_sec\n".write(to: logURL, atomically: true, encoding: .utf8)
        }
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        }
        entries.append(Entry(date: date, event: event, response: response))
    }

    private func loadLog() {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return }
        entries = text.split(separator: "\n").dropFirst().compactMap { row in
            let f = row.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 7, let d = iso.date(from: f[0]) else { return nil }
            return Entry(date: d, event: f[1], response: Int(f[6]) ?? 0)
        }
    }

    func stats(since: Date) -> (changes: Int, skips: Int, avgResponse: Int) {
        let prompts = entries.filter { $0.date >= since && ($0.event == "change" || $0.event == "skip") }
        let changes = prompts.filter { $0.event == "change" }
        let avg = changes.isEmpty ? 0 : changes.map(\.response).reduce(0, +) / changes.count
        return (changes.count, prompts.count - changes.count, avg)
    }
}

// MARK: - Overlay windows

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class OverlayController {
    private var windows: [NSWindow] = []

    func show(state: AppState) {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        NSApp.setActivationPolicy(.regular)
        let primaryScreen = NSScreen.screens.first
        for screen in NSScreen.screens {
            let w = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: OverlayView(primary: screen == primaryScreen).environmentObject(state))
            w.setFrame(screen.frame, display: true)
            w.orderFrontRegardless()
            windows.append(w)
        }
        windows.first?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching, .disableHideApplication, .disableAppleMenu]
    }

    func reassert() {
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        windows.forEach { $0.orderFrontRegardless() }
        if let first = windows.first, !first.isKeyWindow { first.makeKey() }
    }

    func hide() {
        NSApp.presentationOptions = []
        windows.forEach { $0.orderOut(nil) }
        windows = []
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Views

func clock(_ t: TimeInterval) -> String {
    let s = Int(t.rounded(.up))
    return String(format: "%d:%02d", s / 60, s % 60)
}

struct Blur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .fullScreenUI
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct OverlayView: View {
    @EnvironmentObject var s: AppState
    let primary: Bool
    @State private var showReasons = false

    var body: some View {
        ZStack {
            Blur()
            LinearGradient(colors: [.black.opacity(0.75), s.posture.color.opacity(0.45)], startPoint: .top, endPoint: .bottom)
            if primary { prompt } else { secondary }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    private var prompt: some View {
        VStack(spacing: 40) {
            VStack(spacing: 16) {
                Image(systemName: "figure.stand.line.dotted.figure.stand")
                    .font(.system(size: 80, weight: .semibold))
                    .symbolEffect(.pulse, options: .repeating)
                Text("Positionswechsel")
                    .font(.system(size: 72, weight: .heavy, design: .rounded))
                Text("Du \(s.posture.state) seit \(Int(s.elapsed / 60)) Minuten. Zeit für etwas anderes.")
                    .font(.system(size: 24, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
            }
            HStack(spacing: 28) {
                ForEach(Array(Posture.allCases.enumerated()), id: \.element) { i, p in
                    PostureCard(p: p, key: i + 1, current: p == s.posture) { s.choose(p) }
                }
            }
            skipArea.frame(height: 60)
            if let shown = s.promptShownAt {
                Text("Wartet seit \(clock(s.now.timeIntervalSince(shown)))")
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder private var skipArea: some View {
        if showReasons {
            HStack(spacing: 12) {
                ForEach(skipReasons, id: \.self) { r in
                    Button(r) { s.skip(r) }.buttonStyle(ChipStyle())
                }
                Button("Zurück") { showReasons = false }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6)).padding(.leading, 8)
            }
        } else {
            Button("Geht gerade nicht …") { showReasons = true }
                .buttonStyle(.plain)
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    private var secondary: some View {
        VStack(spacing: 20) {
            Image(systemName: "figure.stand.line.dotted.figure.stand").font(.system(size: 90, weight: .semibold))
            Text("Positionswechsel").font(.system(size: 56, weight: .heavy, design: .rounded))
            Text("Bitte auf dem Hauptbildschirm bestätigen.").font(.title2).foregroundStyle(.white.opacity(0.7))
        }
        .foregroundStyle(.white)
    }
}

struct PostureCard: View {
    let p: Posture
    let key: Int
    let current: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 18) {
                Image(systemName: p.symbol).font(.system(size: 76, weight: .semibold)).frame(height: 96)
                Text(p.verb).font(.system(size: 24, weight: .bold, design: .rounded))
                Text(current ? "Aktueller Zustand" : "Taste \(key)")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .opacity(0.7)
            }
            .foregroundStyle(.white.opacity(current ? 0.4 : 1))
            .frame(width: 250, height: 270)
            .background(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(p.color.gradient)
                    .opacity(current ? 0.15 : (hover ? 1 : 0.8))
            )
            .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(.white.opacity(hover ? 0.6 : 0.2), lineWidth: 2))
            .shadow(color: p.color.opacity(current ? 0 : 0.5), radius: hover ? 30 : 15)
            .scaleEffect(hover && !current ? 1.05 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(current)
        .keyboardShortcut(KeyEquivalent(Character(String(key))), modifiers: [])
        .onHover { hover = $0 }
        .animation(.spring(duration: 0.25), value: hover)
    }
}

struct ChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.35 : 0.15)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.3)))
            .foregroundStyle(.white)
    }
}

struct MenuLabel: View {
    @ObservedObject var s: AppState
    var body: some View {
        let r = s.remaining
        HStack(spacing: 4) {
            Image(systemName: s.posture.symbol)
            Text(r < 60 ? clock(r) : "\(Int((r / 60).rounded(.up))) min").monospacedDigit()
        }
    }
}

struct MenuView: View {
    @EnvironmentObject var s: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: s.posture.symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(s.posture.color.gradient))
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Du \(s.posture.state)").font(.headline)
                    Text("Nächster Wechsel in \(clock(s.remaining))").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            ProgressView(value: min(s.elapsed, s.interval), total: s.interval).tint(s.posture.color)

            VStack(alignment: .leading, spacing: 6) {
                Text("Zustand korrigieren").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { s.posture }, set: { s.setManually($0) })) {
                    ForEach(Posture.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            Stepper("Intervall: \(s.intervalMinutes) min", value: $s.intervalMinutes, in: 5...120, step: 5)

            Divider()
            statsRow("Heute", s.stats(since: Calendar.current.startOfDay(for: s.now)))
            statsRow("7 Tage", s.stats(since: Calendar.current.date(byAdding: .day, value: -7, to: s.now)!))
            Divider()

            HStack {
                Button("Jetzt wechseln") { s.showPrompt() }
                Spacer()
                Button("Log") { NSWorkspace.shared.activateFileViewerSelecting([s.logURL]) }
                Button("Beenden") { NSApp.terminate(nil) }
            }
        }
        .padding(18)
        .frame(width: 320)
    }

    private func statsRow(_ title: String, _ st: (changes: Int, skips: Int, avgResponse: Int)) -> some View {
        let total = st.changes + st.skips
        return HStack {
            Text(title).font(.subheadline.weight(.semibold)).frame(width: 56, alignment: .leading)
            Label("\(st.changes)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            Label("\(st.skips)", systemImage: "forward.fill").foregroundStyle(.orange)
            Spacer()
            Text(total == 0 ? "–" : "\(st.changes * 100 / total) %").font(.subheadline.weight(.bold)).monospacedDigit()
            Text("Ø \(st.avgResponse)s").font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.subheadline)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        MainActor.assumeIsolated { AppState.shared.start() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { AppState.shared.promptShownAt == nil ? .terminateNow : .terminateCancel }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppState.shared.quitLogged() }
    }
}

@main
struct StandUpSitDownApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(state)
        } label: {
            MenuLabel(s: state)
        }
        .menuBarExtraStyle(.window)
    }
}
