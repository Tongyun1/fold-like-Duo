import AppKit
import Carbon
import Combine
import CoreImage
import Foundation

@MainActor
final class AppModel: ObservableObject, @unchecked Sendable {
    @Published var automatic: Bool {
        didSet { UserDefaults.standard.set(automatic, forKey: "automatic") }
    }
    @Published var launchAtLogin = LoginService.isEnabled
    @Published var permissionNeeded = !DesktopCapture.hasPermission
    @Published var sensorAngle: Double?
    @Published var sensorAvailability: LidAngleSensor.Availability = .notFound
    @Published var message = L10n.text("Move the lid to begin.")
    @Published var effectActive = false
    @Published var captureActive = false
    @Published var emergencyShortcutAvailable = false
    @Published var reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    @Published var triggerAngle: Double {
        didSet { UserDefaults.standard.set(triggerAngle, forKey: "triggerAngle") }
    }
    @Published var topNarrowing: Double {
        didSet { UserDefaults.standard.set(topNarrowing, forKey: "topNarrowing") }
    }
    @Published var blurRadius: Double {
        didSet { UserDefaults.standard.set(blurRadius, forKey: "blurRadius") }
    }
    @Published var darkening: Double {
        didSet { UserDefaults.standard.set(darkening, forKey: "darkening") }
    }
    @Published var frost: Double {
        didSet { UserDefaults.standard.set(frost, forKey: "frost") }
    }

    private let sensor = LidAngleSensor()
    private let capture = DesktopCapture()
    private let overlay = OverlayController()
    private let presence = PresenceWindow()
    private var gate = MotionGate()
    private var sensorTimer: Timer?
    private var connected = false
    private var nextSensorRetry: CFTimeInterval = 0
    private var activity = LidActivity()
    private var smoothedAngle: Double?
    private var captureStartTask: Task<Void, Never>?
    private var captureStopTask: Task<Void, Never>?
    private var shutdownRequested = false
    private var suspended = false
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var observers: [NSObjectProtocol] = []

    var parameters: EffectParameters {
        EffectParameters(triggerAngle: triggerAngle,
                         fullAngle: 8,
                         topNarrowing: topNarrowing,
                         blurRadius: blurRadius,
                         blurFalloff: 1.35,
                         darkening: darkening,
                         frost: frost,
                         reducedMotion: reducedMotion)
    }

    var statusTitle: String {
        if permissionNeeded { return L10n.text("Screen access needed") }
        if sensorAvailability != .available { return L10n.text("Lid sensor unavailable") }
        if !emergencyShortcutAvailable { return L10n.text("Stop shortcut unavailable") }
        if !automatic { return L10n.text("Paused") }
        return L10n.text(effectActive ? "Following the lid" : "Ready")
    }

    init() {
        automatic = UserDefaults.standard.object(forKey: "automatic") as? Bool ?? true
        triggerAngle = Self.stored("triggerAngle", fallback: 92, range: 75...115)
        topNarrowing = Self.stored("topNarrowing", fallback: 0.30, range: 0.08...0.65)
        blurRadius = Self.stored("blurRadius", fallback: 88, range: 20...160)
        darkening = Self.stored("darkening", fallback: 0.12, range: 0...0.45)
        frost = Self.stored("frost", fallback: 0.10, range: 0...0.35)
    }

    func start() {
        presence.ensureVisible()
        capture.onFrame = { [weak self] buffer in
            guard let self else { return }
            let image = CIImage(cvPixelBuffer: buffer)
            overlay.setSource(image)
        }
        capture.onFailure = { [weak self] reason in
            self?.failClear(L10n.format("Screen capture stopped: %@", reason))
        }
        installHotKey()
        installObservers()
        scheduleSensorPoll()
        updateMessage()
    }

    func requestScreenAccess() {
        DesktopCapture.requestPermission()
        permissionNeeded = !DesktopCapture.hasPermission
        if permissionNeeded {
            message = L10n.text("Allow fold-like-Duo under Privacy & Security → Screen Recording, then return here.")
        }
    }

    func requestScreenAccessIfNeeded() {
        // Read TCC directly here instead of relying on the value captured while
        // AppModel was being initialized during application startup.
        guard !DesktopCapture.hasPermission else {
            permissionNeeded = false
            return
        }
        requestScreenAccess()
    }

    func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    func setAutomatic(_ value: Bool) {
        automatic = value
        if value {
            gate.reset(at: smoothedAngle)
            updateMessage()
        } else {
            failClear(L10n.text("Paused. Your desktop is back to normal."))
        }
        scheduleSensorPoll()
    }

    func setLaunchAtLogin(_ value: Bool) {
        do {
            try LoginService.setEnabled(value)
            launchAtLogin = LoginService.isEnabled
            message = L10n.text(LoginService.needsApproval
                ? "Approve fold-like-Duo in System Settings → General → Login Items."
                : "Launch at login updated.")
        } catch {
            launchAtLogin = LoginService.isEnabled
            message = error.localizedDescription
        }
    }

    func resetAppearance() {
        triggerAngle = 92
        topNarrowing = 0.30
        blurRadius = 88
        darkening = 0.12
        frost = 0.10
    }

    func shutdown() {
        shutdownRequested = true
        sensorTimer?.invalidate()
        sensorTimer = nil
        sensor.disconnect()
        captureStartTask?.cancel()
        captureStopTask?.cancel()
        overlay.destroy()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        observers.forEach {
            NotificationCenter.default.removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        Task { await capture.stop() }
    }

    private func scheduleSensorPoll(after interval: TimeInterval = 1.0 / 60.0) {
        sensorTimer?.invalidate()
        guard !shutdownRequested, !suspended else { return }
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.pollSensor() }
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        sensorTimer = timer
    }

    private func pollSensor() {
        guard !shutdownRequested, !suspended else { return }
        let now = CACurrentMediaTime()
        if !connected, now >= nextSensorRetry {
            connected = sensor.connect()
            nextSensorRetry = now + 5
        }
        let reading = connected ? sensor.read() : nil
        if let reading {
            activity.observe(reading, now: now)
        } else {
            connected = false
        }
        receiveSensor(reading, availability: sensor.availability)
        let interval: TimeInterval
        if !connected {
            interval = max(nextSensorRetry - now, 0.1)
        } else if !automatic || permissionNeeded || !emergencyShortcutAvailable {
            interval = 1
        } else {
            interval = activity.isMoving(at: now) ? 1.0 / 60.0 : 0.1
        }
        scheduleSensorPoll(after: interval)
    }

    private func receiveSensor(_ reading: Double?, availability: LidAngleSensor.Availability) {
        guard !shutdownRequested else { return }
        if sensorAvailability != availability { sensorAvailability = availability }
        guard let reading else {
            if sensorAngle != nil { sensorAngle = nil }
            smoothedAngle = nil
            activity = LidActivity()
            gate.reset()
            failClear(L10n.text(availability == .notFound
                      ? "No compatible MacBook lid sensor was found. The sample preview still works."
                      : "The lid sensor exists but its angle interface is unavailable on this Mac."))
            return
        }

        var filtered = smoothedAngle.map { $0 + (reading - $0) * 0.32 } ?? reading
        if abs(filtered - reading) < 0.01 { filtered = reading }
        smoothedAngle = filtered
        // The UI displays whole degrees; do not rebuild SwiftUI at sensor rate.
        if sensorAngle != filtered.rounded() { sensorAngle = filtered.rounded() }

        guard automatic, !suspended, !permissionNeeded, emergencyShortcutAvailable else {
            gate.reset(at: filtered)
            if effectActive { failClear(L10n.text("Paused. Your desktop is back to normal.")) }
            return
        }

        let now = CACurrentMediaTime()
        let permitted = gate.permits(angle: filtered, triggerAngle: triggerAngle, now: now)
        let progress = permitted ? parameters.progress(for: filtered) : 0
        if permitted, progress > 0 {
            guard ensureCaptureStarted() else { return }
            if !effectActive { effectActive = true }
            capture.setFrameRate(activity.captureFrameRate(at: now))
            overlay.update(parameters: parameters, progress: progress)
            setMessage(L10n.format("Following the lid · %d°", Int(filtered.rounded())))
        } else {
            if effectActive { overlay.hide() }
            if effectActive { effectActive = false }
            stopCaptureImmediately()
            updateMessage()
        }
    }

    private func ensureCaptureStarted() -> Bool {
        guard !capture.isRunning, captureStartTask == nil,
              captureStopTask == nil else { return true }
        guard let displayID = NSScreen.builtIn?.displayID else {
            failClear(CaptureError.noBuiltInDisplay.localizedDescription)
            return false
        }
        do {
            try overlay.prepare(parameters: parameters)
        } catch {
            failClear(error.localizedDescription)
            return false
        }
        captureStartTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await capture.start(displayID: displayID,
                                        framesPerSecond: activity.captureFrameRate(at: CACurrentMediaTime()))
                captureActive = capture.isRunning
            } catch is CancellationError {
                captureActive = false
            } catch {
                permissionNeeded = !DesktopCapture.hasPermission
                failClear(error.localizedDescription)
            }
            captureStartTask = nil
        }
        return true
    }

    private func stopCaptureImmediately() {
        guard captureStopTask == nil,
              capture.isRunning || captureStartTask != nil else { return }
        captureStartTask?.cancel()
        captureStopTask = Task { [weak self] in
            guard let self else { return }
            await capture.stop()
            captureActive = false
            captureStopTask = nil
        }
    }

    private func failClear(_ reason: String) {
        gate.reset(at: smoothedAngle)
        overlay.hide()
        if effectActive { effectActive = false }
        setMessage(reason)
        stopCaptureImmediately()
    }

    private func setMessage(_ value: String) {
        if message != value { message = value }
    }

    private func updateMessage() {
        if permissionNeeded {
            setMessage(L10n.text("Screen access is required for the live effect."))
        } else if sensorAvailability != .available {
            setMessage(L10n.text("Waiting for a compatible lid-angle sensor."))
        } else if !automatic {
            setMessage(L10n.text("Paused. The sample preview remains available."))
        } else {
            setMessage(L10n.format("Ready. Close the lid below %d° to begin.", Int(triggerAngle)))
        }
    }

    private func installObservers() {
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.permissionNeeded = !DesktopCapture.hasPermission
                self.updateMessage()
            }
        })

        let workspace = NSWorkspace.shared.notificationCenter
        let suspendNames: [Notification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ]
        for name in suspendNames {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.suspendForSystem() }
            })
        }
        let resumeNames: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ]
        for name in resumeNames {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.resumeAfterSystem() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.suspendForSystem()
                self.resumeAfterSystem()
            }
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            }
        })
    }

    private func suspendForSystem() {
        suspended = true
        sensorTimer?.invalidate()
        sensorTimer = nil
        sensor.disconnect()
        connected = false
        failClear(L10n.text("Suspended safely while the display is unavailable."))
        overlay.destroy()
    }

    private func resumeAfterSystem() {
        guard !shutdownRequested else { return }
        suspended = false
        connected = false
        nextSensorRetry = 0
        activity = LidActivity()
        smoothedAngle = nil
        gate.reset()
        updateMessage()
        scheduleSensorPoll()
    }

    private func installHotKey() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                  eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let handlerResult = InstallEventHandler(GetApplicationEventTarget(), { _, _, pointer in
            guard let pointer else { return noErr }
            let model = Unmanaged<AppModel>.fromOpaque(pointer).takeUnretainedValue()
            Task { @MainActor in model.setAutomatic(false) }
            return noErr
        }, 1, &event, pointer, &hotKeyHandler)
        let keyResult = RegisterEventHotKey(UInt32(kVK_Escape),
                                            UInt32(cmdKey | shiftKey),
                                            EventHotKeyID(signature: 0x48464C57, id: 1),
                                            GetApplicationEventTarget(),
                                            0,
                                            &hotKey)
        emergencyShortcutAvailable = handlerResult == noErr && keyResult == noErr
    }

    private static func stored(_ key: String,
                               fallback: Double,
                               range: ClosedRange<Double>) -> Double {
        let value = UserDefaults.standard.object(forKey: key) as? Double ?? fallback
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
