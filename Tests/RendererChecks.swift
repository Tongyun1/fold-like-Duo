import AppKit
import CoreImage

/// Real Metal submissions using generated artwork; no screen recording or HID.
@main
enum RendererChecks {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                try await run()
                exit(0)
            } catch {
                fputs("Renderer checks failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        app.run()
    }

    @MainActor
    static func run() async throws {
        let view = EffectMetalView()
        if let error = view.initializationError { throw SelfCheck.Failure(error) }
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 640, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        var frames = 0
        view.onPresented = { frames += 1 }
        view.targetProgress = 0.5
        view.source = SampleArtwork.make()
        try await Task.sleep(for: .seconds(1))
        guard frames > 0, view.isPaused else {
            throw SelfCheck.Failure("initial artwork must render and settle")
        }

        let settledFrames = frames
        for _ in 0..<120 {
            view.parameters = EffectParameters()
            view.targetProgress = 0.5
            try await Task.sleep(for: .milliseconds(17))
        }
        let redundantFrames = frames - settledFrames
        print("GPU frames after 120 unchanged updates: \(redundantFrames)")
        guard redundantFrames == 0 else {
            throw SelfCheck.Failure("unchanged input must leave the renderer paused")
        }

        view.targetProgress = 0.7
        try await Task.sleep(for: .seconds(1))
        guard frames > settledFrames, view.isPaused else {
            throw SelfCheck.Failure("angle change must render and settle again")
        }
        let beforeAppearance = frames
        view.parameters.frost += 0.05
        try await Task.sleep(for: .milliseconds(250))
        guard frames > beforeAppearance, view.isPaused else {
            throw SelfCheck.Failure("appearance changes must redraw a stationary lid")
        }
        let beforeSource = frames
        view.source = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 400))
        try await Task.sleep(for: .milliseconds(250))
        guard frames > beforeSource, view.isPaused else {
            throw SelfCheck.Failure("new desktop content must redraw a stationary lid")
        }
        let beforeStop = frames
        view.targetProgress = 0.9
        view.resetMotion()
        view.stopRendering()
        try await Task.sleep(for: .milliseconds(250))
        guard frames == beforeStop, view.isPaused else {
            throw SelfCheck.Failure("stopping must cancel pending rendering")
        }
        let empty = EffectMetalView()
        empty.targetProgress = 0.5
        empty.draw(in: empty)
        guard empty.isPaused else { throw SelfCheck.Failure("waiting for a source must not run the display link") }
        print("Renderer checks passed: rest, motion, appearance, live content, and stop")
    }
}
