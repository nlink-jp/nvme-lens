import AppKit
import NvmeLensCore
import ServiceManagement
import UserNotifications
import SwiftUI

/// Observable state shared by the panel and the settings window.
///
/// The views read this and call back into it; nothing in the views talks to the
/// store or to IOKit directly.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var presentation = MenuBarPresentation(
        title: "––", verdict: "starting…", drives: [], unmonitorable: [])
    /// Temperature history for the drives shown in the menu bar, keyed by serial.
    @Published private(set) var series: [String: TemperatureSeries.Summary] = [:]
    @Published private(set) var storeError: String?
    @Published private(set) var loginItemMessage: String?
    @Published private(set) var lastSampledAt: Date?
    /// The system's answer, read back rather than assumed. A toggle that says
    /// "on" while the OS says denied promises something that will not happen.
    @Published private(set) var notificationAuthorization: UNAuthorizationStatus = .notDetermined

    let store: HealthStore
    var configuration: Configuration { preferences.configuration }

    static let graphWindow: TimeInterval = 6 * 3600
    static let graphBucketSeconds = 600
    static let graphWindowLabel = "6h"

    let preferences: Preferences

    /// Called when the sampling interval changes, so the timer can be rebuilt.
    /// A setting that only takes effect after a restart is barely a setting.
    var onSamplingIntervalChanged: ((Int) -> Void)?

    init(store: HealthStore, preferences: Preferences = Preferences()) {
        self.store = store
        self.preferences = preferences
    }

    // MARK: - Selection

    var selectedSerials: Set<String> { preferences.menuBarDrives }

    func toggleWatched(_ serial: String) {
        var selection = selectedSerials
        if selection.contains(serial) { selection.remove(serial) } else { selection.insert(serial) }
        preferences.menuBarDrives = selection
        refresh()
    }

    // MARK: - Sampling interval

    var samplingIntervalSeconds: Int {
        get { preferences.samplingIntervalSeconds }
        set {
            guard newValue != preferences.samplingIntervalSeconds else { return }
            preferences.samplingIntervalSeconds = newValue
            onSamplingIntervalChanged?(newValue)
            objectWillChange.send()
        }
    }

    // MARK: - Sampling

    func refresh() {
        let records = IOKitDeviceReader.readAll()
        var alerts: [NvmeLensCore.Alert] = []
        do {
            alerts = try Sampler(store: store, configuration: configuration).run(records: records)
                .alerts
            storeError = nil
            lastSampledAt = Date()
        } catch {
            // The readings are still valid; only the history is not being
            // written. Blanking the panel would overstate the problem.
            storeError = "history not being recorded: \(error)"
        }

        presentation = MenuBarPresentation.make(
            records: records, alerts: alerts, selectedSerials: selectedSerials,
            configuration: configuration)
        reloadSeries()
        if !alerts.isEmpty { onAlerts?(alerts) }
    }

    /// Called with any alerts a refresh produced. Set by the app delegate so the
    /// model stays free of UserNotifications.
    var onAlerts: (([NvmeLensCore.Alert]) -> Void)?

    private func reloadSeries() {
        let now = Date()
        let start = now.addingTimeInterval(-Self.graphWindow)
        var loaded: [String: TemperatureSeries.Summary] = [:]
        for drive in presentation.drives where drive.isShownInMenuBar {
            guard let points = try? store.temperatureHistory(serial: drive.serialNumber, since: start)
            else { continue }
            loaded[drive.serialNumber] = TemperatureSeries.summarize(
                points: points, from: start, to: now, bucketSeconds: Self.graphBucketSeconds)
        }
        series = loaded
    }

    // MARK: - Login item

    /// Read from the system every time. A cached copy would disagree with System
    /// Settings the moment the user changes it there.
    var loginItemStatus: LoginItemStatus {
        guard Bundle.main.bundleIdentifier != nil else { return .notFound }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .unknown(-1)
        }
    }

    var loginItem: LoginItemPresentation { .make(status: loginItemStatus) }

    /// The application is the collector, so not opening at login means a hole in
    /// the history after every restart.
    func setLoginItem(enabled wanted: Bool) {
        let before = loginItemStatus
        var errorText: String?
        do {
            if wanted {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorText = error.localizedDescription
        }
        // Verify the status actually moved instead of trusting the call: "no
        // error but the switch snaps back" is the worst outcome.
        switch LoginItemOutcome.evaluate(
            wanted: wanted, before: before, after: loginItemStatus, error: errorText)
        {
        case .succeeded: loginItemMessage = nil
        case .failed(let message), .didNotChange(let message): loginItemMessage = message
        }
        objectWillChange.send()
    }

    var isBundled: Bool { Bundle.main.bundleIdentifier != nil }

    // MARK: - Notifications

    var notificationsEnabled: Bool { preferences.notificationsEnabled }

    /// Asked for at the moment the user expresses intent, not when an alert
    /// finally happens.
    ///
    /// Deferring it until the first alert means the request is never made while
    /// everything is healthy — so the application never appears in the system's
    /// notification list, cannot be configured there, cannot be tested, and
    /// stays silent forever if the condition never arrives. That exact bug
    /// shipped in a sibling tool.
    func setNotifications(enabled: Bool) {
        preferences.notificationsEnabled = enabled
        objectWillChange.send()
        guard enabled, isBundled else { return }
        requestNotificationAuthorization()
    }

    /// Also called at launch, to rescue the state where the preference is on but
    /// authorization was never actually requested.
    func refreshNotificationAuthorization(requestIfUndetermined: Bool) {
        guard isBundled else { return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            // Only the status crosses the boundary: UNNotificationSettings is
            // not Sendable, and hopping the whole object trips Swift 6.
            let status = settings.authorizationStatus
            Task { @MainActor in
                guard let self else { return }
                self.notificationAuthorization = status
                if requestIfUndetermined, status == .notDetermined,
                    self.preferences.notificationsEnabled
                {
                    self.requestNotificationAuthorization()
                }
            }
        }
    }

    private func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
            [weak self] _, _ in
            Task { @MainActor in self?.refreshNotificationAuthorization(requestIfUndetermined: false) }
        }
    }

    /// Whether an alert will actually reach the user right now.
    var notificationsWillBeDelivered: Bool {
        isBundled && notificationsEnabled && notificationAuthorization == .authorized
    }

    var notificationProblem: String? {
        guard isBundled else { return "Running unbundled: notifications are unavailable." }
        guard notificationsEnabled else { return nil }
        switch notificationAuthorization {
        case .denied:
            return "Denied in System Settings — alerts will not be delivered."
        case .notDetermined:
            return "Not yet allowed — macOS has not been asked."
        default:
            return nil
        }
    }

    func openNotificationSettings() {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// Any change to a threshold re-evaluates immediately: a setting whose
    /// effect you cannot see until the next tick invites doubt that it applied.
    func alertingChanged() {
        objectWillChange.send()
        refresh()
    }
}
