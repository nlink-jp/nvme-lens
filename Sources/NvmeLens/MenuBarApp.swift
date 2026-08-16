import AppKit
import NvmeLensCore
import UserNotifications

/// The resident menu-bar application.
///
/// It drives the same `Sampler` the `sample` subcommand uses, so what the GUI
/// records and what the CLI records cannot diverge.
@MainActor
final class MenuBarApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private let store: HealthStore
    private let configuration: Configuration
    private lazy var sampler = Sampler(store: store, configuration: configuration)
    private var notificationsRequested = false
    private var lastError: String?

    /// UserNotifications requires a real application bundle. Touching
    /// `UNUserNotificationCenter.current()` from a bare binary raises
    /// `bundleProxyForCurrentProcess is nil` and takes the process down, so a
    /// development run (`swift build` output, no `.app`) must skip the whole
    /// subsystem rather than crash on launch.
    private static var notificationsAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    init(store: HealthStore, configuration: Configuration) {
        self.store = store
        self.configuration = configuration
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "––"
        if Self.notificationsAvailable {
            UNUserNotificationCenter.current().delegate = self
        }

        refresh()
        let interval = TimeInterval(max(10, configuration.sampling.temperatureIntervalSeconds))
        // The timer fires on the main run loop, so the isolation assumption
        // holds; asserting it is cheaper than hopping through a Task each tick.
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // .common keeps sampling running while a menu is open; the default mode
        // would stall the timer for as long as the user holds the menu down.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }

    // MARK: - Sampling

    private func refresh() {
        let records = IOKitDeviceReader.readAll()
        var alerts: [Alert] = []
        do {
            alerts = try sampler.run(records: records).alerts
            lastError = nil
        } catch {
            // A failing store must not blank the display: the readings are still
            // valid, only the history is not being written. Say so instead.
            lastError = "history not being recorded: \(error)"
        }

        let presentation = MenuBarPresentation.make(
            records: records, alerts: alerts, configuration: configuration)
        statusItem.button?.title = presentation.title
        statusItem.button?.toolTip = presentation.summary
        statusItem.menu = buildMenu(presentation: presentation, alerts: alerts)

        if !alerts.isEmpty { deliver(alerts) }
    }

    // MARK: - Menu

    private func buildMenu(presentation: MenuBarPresentation, alerts: [Alert]) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(disabledItem(presentation.summary))
        if let lastError {
            menu.addItem(disabledItem("⚠︎ \(lastError)"))
        }
        if !Self.notificationsAvailable {
            // Silently not notifying would look identical to "nothing is wrong".
            menu.addItem(disabledItem("⚠︎ notifications off: running unbundled"))
        }
        menu.addItem(.separator())

        for row in presentation.rows {
            let prefix = row.severity == .critical ? "!! " : (row.severity == .warning ? "! " : "")
            let item = NSMenuItem(title: prefix + row.title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(disabledItem("    " + row.detail))
        }

        if !alerts.isEmpty {
            menu.addItem(.separator())
            for alert in alerts {
                menu.addItem(
                    disabledItem("\(alert.severity.rawValue): \(alert.model) — \(alert.message)"))
            }
        }

        menu.addItem(.separator())
        let refreshItem = NSMenuItem(
            title: "Sample now", action: #selector(sampleNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        // The version belongs on screen: a GUI that cannot tell you which build
        // it is makes every bug report ambiguous.
        menu.addItem(disabledItem("nvme-lens \(Version.current)"))
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func sampleNow() { refresh() }

    @objc private func quit() { NSApplication.shared.terminate(nil) }

    // MARK: - Notifications

    private func deliver(_ alerts: [Alert]) {
        guard Self.notificationsAvailable else { return }
        // Authorization is requested on the first real alert rather than at
        // launch. Killing the process while that prompt is unanswered pins the
        // permission to denied until the user fixes it in System Settings, and
        // launching-then-quitting is exactly what a smoke test does.
        let center = UNUserNotificationCenter.current()
        guard notificationsRequested else {
            notificationsRequested = true
            center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
                guard granted else { return }
                Task { @MainActor in self?.post(alerts) }
            }
            return
        }
        post(alerts)
    }

    private func post(_ alerts: [Alert]) {
        let center = UNUserNotificationCenter.current()
        for alert in alerts {
            let content = UNMutableNotificationContent()
            content.title = "\(alert.model) — \(alert.kind)"
            content.body = alert.message
            content.sound = alert.severity == .critical ? .defaultCritical : .default
            // A trigger-bearing request survives the app exiting; a nil trigger
            // is dropped if the process goes away first.
            let request = UNNotificationRequest(
                identifier: "\(alert.serialNumber)-\(alert.kind)",
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
            center.add(request)
        }
    }

    @MainActor
    static func run(store: HealthStore, configuration: Configuration) -> Never {
        let application = NSApplication.shared
        // Accessory: menu-bar resident, no Dock icon, no main window. Info.plist
        // sets LSUIElement for the bundled .app; this covers running the bare
        // binary too.
        application.setActivationPolicy(.accessory)
        let delegate = MenuBarApp(store: store, configuration: configuration)
        application.delegate = delegate
        application.run()
        exit(0)
    }
}

extension MenuBarApp: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
