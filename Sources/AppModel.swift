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
    private var retryTicks = 0
    private var lastRawAngle: Double?
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
        startSensorPolling()
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
        guard permissionNeeded else { return }
        requestScreenAccess()
    }

    func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    func setAutomatic(_ value: Bool) {
        automatic = value
        if value {
            gate.reset(at: sensorAngle)
            updateMessage()
        } else {
            failClear(L10n.text("Paused. Your desktop is back to normal."))
        }
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

    private func startSensorPolling() {
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                if !self.connected {
                    self.retryTicks += 1
                    guard self.retryTicks == 1 || self.retryTicks % 300 == 0 else { return }
                    self.connected = self.sensor.connect()
                }
                let reading = self.connected ? self.sensor.read() : nil
                if reading == nil { self.connected = false }
                self.receiveSensor(reading, availability: self.sensor.availability)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        sensorTimer = timer
    }

    private func receiveSensor(_ reading: Double?, availability: LidAngleSensor.Availability) {
        guard !shutdownRequested else { return }
        sensorAvailability = availability
        guard let reading else {
            sensorAngle = nil
            gate.reset()
            failClear(L10n.text(availability == .notFound
                      ? "No compatible MacBook lid sensor was found. The sample preview still works."
                      : "The lid sensor exists but its angle interface is unavailable on this Mac."))
            return
        }

        let previous = lastRawAngle
        lastRawAngle = reading
        let filtered = smoothedAngle.map { $0 + (reading - $0) * 0.32 } ?? reading
        smoothedAngle = filtered
        sensorAngle = filtered

        guard automatic, !suspended, !permissionNeeded, emergencyShortcutAvailable else {
            gate.reset(at: filtered)
            if effectActive { failClear(L10n.text("Paused. Your desktop is back to normal.")) }
            return
        }

        let closing = previous.map { reading < $0 - 0.15 } ?? false
        if closing, reading < min(triggerAngle + 28, 125) {
            ensureCaptureStarted()
        }

        let now = CACurrentMediaTime()
        let permitted = gate.permits(angle: filtered, triggerAngle: triggerAngle, now: now)
        let progress = permitted ? parameters.progress(for: filtered) : 0
        if permitted, progress > 0 {
            ensureCaptureStarted()
            effectActive = true
            overlay.update(parameters: parameters, progress: progress)
            message = L10n.format("Following the lid · %d°", Int(filtered.rounded()))
            captureStopTask?.cancel()
            captureStopTask = nil
        } else {
            if effectActive { overlay.hide() }
            effectActive = false
            if reading >= triggerAngle || !closing {
                scheduleCaptureStop()
            }
            updateMessage()
        }
    }

    private func ensureCaptureStarted() {
        guard !capture.isRunning, captureStartTask == nil,
              let displayID = NSScreen.builtIn?.displayID else { return }
        captureStopTask?.cancel()
        captureStopTask = nil
        do {
            try overlay.prepare(parameters: parameters)
        } catch {
            failClear(error.localizedDescription)
            return
        }
        captureStartTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await capture.start(displayID: displayID, framesPerSecond: 60)
                captureActive = capture.isRunning
            } catch {
                permissionNeeded = !DesktopCapture.hasPermission
                failClear(error.localizedDescription)
            }
            captureStartTask = nil
        }
    }

    private func scheduleCaptureStop() {
        guard capture.isRunning, captureStopTask == nil else { return }
        captureStopTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard let self, !Task.isCancelled, !effectActive else { return }
            await capture.stop()
            captureActive = false
            captureStopTask = nil
        }
    }

    private func failClear(_ reason: String) {
        gate.reset(at: sensorAngle)
        overlay.hide()
        effectActive = false
        message = reason
        if capture.isRunning { scheduleCaptureStop() }
    }

    private func updateMessage() {
        if permissionNeeded {
            message = L10n.text("Screen access is required for the live effect.")
        } else if sensorAvailability != .available {
            message = L10n.text("Waiting for a compatible lid-angle sensor.")
        } else if !automatic {
            message = L10n.text("Paused. The sample preview remains available.")
        } else {
            message = L10n.format("Ready. Close the lid below %d° to begin.", Int(triggerAngle))
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
        failClear(L10n.text("Suspended safely while the display is unavailable."))
        Task {
            await capture.stop()
            captureActive = false
        }
        overlay.destroy()
    }

    private func resumeAfterSystem() {
        suspended = false
        connected = false
        retryTicks = 0
        lastRawAngle = nil
        smoothedAngle = nil
        gate.reset()
        updateMessage()
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
