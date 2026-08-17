import AppKit
import NvmeLensCore
import SwiftUI
import UserNotifications

/// The resident menu-bar application.
///
/// A status item that opens a panel, plus a separate settings window. The panel
/// is an `NSPopover` rather than an `NSMenu`: a menu is a list of commands, and a
/// graph, a value hierarchy and a health verdict all had to be forced into that
/// shape — each fix made the seams more obvious rather than less.
@MainActor
final class MenuBarApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var outsideClickMonitor: Any?
    private let model: AppModel
    /// Held for the process lifetime. Without an activity assertion macOS puts a
    /// background-only (LSUIElement) app to sleep, the timer stops firing, and
    /// collection silently stops — the stale display is the visible half of the
    /// problem; the missing history is the worse half.
    private var activityToken: NSObjectProtocol?

    private static var notificationsAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    init(store: HealthStore) {
        model = AppModel(store: store)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // ...AllowingIdleSystemSleep, not .userInitiated: this must survive App
        // Nap, but a drive-health monitor has no business keeping the Mac awake.
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "sampling NVMe SMART data on a timer")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)

        popover.behavior = .transient
        popover.animates = false
        let hosting = NSHostingController(
            rootView: PanelView(
                model: model,
                onOpenHistory: { [weak self] in self?.openHistory() },
                onOpenSettings: { [weak self] in self?.openSettings() },
                onQuit: { NSApplication.shared.terminate(nil) }))
        // Without this the controller never reports SwiftUI's ideal size, so the
        // popover is placed against a stale height and then grows — upwards, off
        // the top of the screen, once the content is taller than the guess.
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting

        if Self.notificationsAvailable {
            UNUserNotificationCenter.current().delegate = self
            // Rescues the state where the preference is on but authorization was
            // never actually requested.
            model.refreshNotificationAuthorization(requestIfUndetermined: true)
        }
        model.onAlerts = { [weak self] alerts in self?.deliver(alerts) }

        model.refresh()
        updateStatusItem()

        model.onSamplingIntervalChanged = { [weak self] seconds in
            self?.startTimer(intervalSeconds: seconds)
        }
        startTimer(intervalSeconds: model.samplingIntervalSeconds)
    }

    private func startTimer(intervalSeconds: Int) {
        timer?.invalidate()
        let timer = Timer(timeInterval: TimeInterval(max(10, intervalSeconds)), repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated {
                self?.model.refresh()
                self?.updateStatusItem()
            }
        }
        // .common keeps sampling running while the panel is open; the default
        // mode would stall the timer for as long as it stays up.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let activityToken { ProcessInfo.processInfo.endActivity(activityToken) }
    }

    private func updateStatusItem() {
        if let button = statusItem.button {
            StatusBarRenderer.apply(to: button, presentation: model.presentation)
        }
        statusItem.button?.toolTip =
            ([model.presentation.verdict]
            + model.presentation.drives.filter(\.isShownInMenuBar).map {
                "\($0.name): \($0.temperatureCelsius)°C"
            }).joined(separator: "\n")
    }

    // MARK: - Panel

    @objc private func togglePanel() {
        if popover.isShown {
            closePanel()
            return
        }
        guard let button = statusItem.button else { return }
        model.refresh()
        updateStatusItem()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Without this the panel is drawn in its inactive state, which recent
        // macOS renders as a dark, dimmed sheet that reads as a bug.
        popover.contentViewController?.view.window?.makeKey()

        // A transient popover from an accessory app does not reliably dismiss on
        // an outside click once the app has been activated, so close it here.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel() }
        }
    }

    private func closePanel() {
        popover.performClose(nil)
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    // MARK: - Settings

    private func openHistory() {
        closePanel()
        if historyWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(
                    x: 0, y: 0, width: HistoryView.preferredWidth, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
                defer: false)
            window.title = "nvme-lens History"
            window.contentViewController = NSHostingController(rootView: HistoryView(model: model))
            window.isReleasedWhenClosed = false
            window.center()
            historyWindow = window
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        historyWindow?.makeKeyAndOrderFront(nil)
    }

    private func openSettings() {
        closePanel()
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
                defer: false)
            window.title = "nvme-lens Settings"
            window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        // An accessory app has to activate explicitly, or the window opens behind
        // whatever the user was looking at.
        NSApplication.shared.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Notifications

    private func deliver(_ alerts: [NvmeLensCore.Alert]) {
        // Authorization was asked for when the user expressed intent, not here:
        // waiting for the first alert means the request is never made while
        // everything is healthy, and the app never appears in the system's
        // notification list at all.
        guard model.notificationsWillBeDelivered else { return }
        post(alerts)
    }

    private func post(_ alerts: [NvmeLensCore.Alert]) {
        let center = UNUserNotificationCenter.current()
        for alert in alerts {
            let content = UNMutableNotificationContent()
            content.title = "\(alert.model) — \(alert.kind)"
            content.body = alert.message
            content.sound = alert.severity == .critical ? .defaultCritical : .default
            // A trigger-bearing request survives the app exiting; a nil trigger
            // is dropped if the process goes away first.
            let request = UNNotificationRequest(
                identifier: "\(alert.serialNumber)-\(alert.kind)", content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
            center.add(request)
        }
    }

    @MainActor
    static func run(store: HealthStore) -> Never {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = MenuBarApp(store: store)
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
