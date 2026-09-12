import AppKit
import CoreImage

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OverlayController {
    private var window: OverlayPanel?
    private var metalView: EffectMetalView?
    private var boundDisplayID: CGDirectDisplayID?
    private var desiredProgress: Double = 0
    private var awaitingFirstFrame = false

    private(set) var isVisible = false

    func prepare(parameters: EffectParameters) throws {
        guard let screen = NSScreen.builtIn else { throw CaptureError.noBuiltInDisplay }
        if boundDisplayID != screen.displayID { destroy() }
        if let metalView {
            metalView.parameters = parameters
            return
        }

        let view = EffectMetalView()
        if let error = view.initializationError {
            throw NSError(domain: "HingeFlow.Renderer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: error])
        }
        view.parameters = parameters
        view.targetProgress = 0
        view.onPresented = { [weak self] in self?.revealAfterFirstFrame() }

        let panel = OverlayPanel(contentRect: screen.frame,
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered,
                                 defer: false,
                                 screen: screen)
        panel.contentView = view
        panel.backgroundColor = .black
        panel.isOpaque = true
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.worksWhenModal = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        panel.sharingType = .none
        panel.alphaValue = 0

        window = panel
        metalView = view
        boundDisplayID = screen.displayID
    }

    func update(parameters: EffectParameters, progress: Double) {
        desiredProgress = min(max(progress, 0), 1)
        guard desiredProgress > 0 else {
            hide()
            return
        }
        do { try prepare(parameters: parameters) } catch { return }
        metalView?.parameters = parameters
        metalView?.targetProgress = desiredProgress
        if window?.isVisible != true {
            awaitingFirstFrame = true
        }
    }

    func setSource(_ image: CIImage) {
        metalView?.source = image
        guard desiredProgress > 0, let window else { return }
        if !window.isVisible {
            awaitingFirstFrame = true
            window.alphaValue = 0
            window.orderFrontRegardless()
            isVisible = true
        }
    }

    func hide() {
        desiredProgress = 0
        awaitingFirstFrame = false
        metalView?.targetProgress = 0
        metalView?.resetMotion()
        window?.alphaValue = 0
        window?.orderOut(nil)
        isVisible = false
    }

    func destroy() {
        hide()
        window?.contentView = nil
        window?.close()
        window = nil
        metalView = nil
        boundDisplayID = nil
    }

    private func revealAfterFirstFrame() {
        guard awaitingFirstFrame, desiredProgress > 0, window?.isVisible == true else { return }
        awaitingFirstFrame = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window?.animator().alphaValue = 1
        }
    }
}

@MainActor
final class PresenceWindow {
    private var window: NSWindow?

    func ensureVisible() {
        guard window == nil else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                              styleMask: .borderless,
                              backing: .buffered,
                              defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 0.004
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.sharingType = .readOnly
        window.orderFrontRegardless()
        self.window = window
    }
}
