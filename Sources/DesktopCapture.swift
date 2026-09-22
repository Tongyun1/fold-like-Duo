import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

private struct SendablePixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer
}

@MainActor
final class DesktopCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let outputQueue = DispatchQueue(label: "app.fold-like-duo.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var configuration: SCStreamConfiguration?
    private var starting = false
    private var generation = 0
    private var frameRate = LidActivity.movingFrameRate
    private var desiredFrameRate = LidActivity.movingFrameRate
    private var frameRateTask: Task<Void, Never>?

    private(set) var isRunning = false
    private(set) var lastFrameAt: Date?
    var onFrame: ((CVPixelBuffer) -> Void)?
    var onFailure: ((String) -> Void)?

    nonisolated static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    nonisolated static func requestPermission() {
        _ = CGRequestScreenCaptureAccess()
    }

    func start(displayID: CGDirectDisplayID,
               framesPerSecond: Int = LidActivity.movingFrameRate) async throws {
        try Task.checkCancellation()
        guard !isRunning, !starting else { return }
        starting = true
        defer { starting = false }
        let generation = self.generation
        guard Self.hasPermission else {
            throw CaptureError.permissionDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        try Task.checkCancellation()
        guard generation == self.generation else { throw CancellationError() }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.noBuiltInDisplay
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == ownPID }
        guard !ownApps.isEmpty else { throw CaptureError.cannotExcludeSelf }

        let filter = SCContentFilter(display: display,
                                     excludingApplications: ownApps,
                                     exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        let scale = min(1.0, 2880.0 / Double(display.width))
        configuration.width = max(Int(Double(display.width) * scale), 1)
        configuration.height = max(Int(Double(display.height) * scale), 1)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
        configuration.queueDepth = 2
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        if #available(macOS 14.0, *) {
            configuration.captureResolution = .best
            configuration.shouldBeOpaque = true
        }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        do {
            try await stream.startCapture()
            try Task.checkCancellation()
            guard generation == self.generation else { throw CancellationError() }
        } catch {
            try? await stream.stopCapture()
            throw error
        }
        self.configuration = configuration
        self.stream = stream
        frameRate = framesPerSecond
        desiredFrameRate = framesPerSecond
        isRunning = true
    }

    func setFrameRate(_ framesPerSecond: Int) {
        desiredFrameRate = max(framesPerSecond, 1)
        guard frameRateTask == nil, frameRate != desiredFrameRate,
              let stream, let configuration else { return }
        let generation = self.generation
        // Serialize/coalesce updates; never restart capture just to change rate.
        frameRateTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == self.generation { frameRateTask = nil }
            }
            while generation == self.generation, !Task.isCancelled,
                  frameRate != desiredFrameRate {
                let rate = desiredFrameRate
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(rate))
                do {
                    try await stream.updateConfiguration(configuration)
                    guard generation == self.generation else { return }
                    frameRate = rate
                } catch {
                    guard generation == self.generation, !Task.isCancelled else { return }
                    onFailure?(error.localizedDescription)
                    return
                }
            }
        }
    }

    private func invalidateSession() -> SCStream? {
        generation += 1
        frameRateTask?.cancel()
        frameRateTask = nil
        let old = stream
        stream = nil
        configuration = nil
        isRunning = false
        lastFrameAt = nil
        return old
    }

    func stop() async {
        let old = invalidateSession()
        try? await old?.stopCapture()
    }

    nonisolated func stream(_ stream: SCStream,
                            didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }

        let frame = SendablePixelBuffer(value: pixelBuffer)
        let streamID = ObjectIdentifier(stream)
        Task { @MainActor [weak self] in
            guard let self, self.stream.map(ObjectIdentifier.init) == streamID, isRunning else { return }
            lastFrameAt = Date()
            onFrame?(frame.value)
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let streamID = ObjectIdentifier(stream)
        Task { @MainActor [weak self] in
            guard let self, self.stream.map(ObjectIdentifier.init) == streamID else { return }
            _ = invalidateSession()
            onFailure?(error.localizedDescription)
        }
    }
}

enum CaptureError: LocalizedError {
    case permissionDenied
    case noBuiltInDisplay
    case cannotExcludeSelf

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            L10n.text("Screen Recording permission is required.")
        case .noBuiltInDisplay:
            L10n.text("The built-in display is unavailable.")
        case .cannotExcludeSelf:
            L10n.text("fold-like-Duo could not exclude its overlay from capture, so capture was stopped safely.")
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            ?? CGMainDisplayID()
    }

    static var builtIn: NSScreen? {
        screens.first { CGDisplayIsBuiltin($0.displayID) != 0 }
    }
}
