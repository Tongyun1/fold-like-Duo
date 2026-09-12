import Foundation
import IOKit.hid

final class LidAngleSensor {
    enum Availability: Equatable {
        case available
        case unsupportedInterface
        case notFound
    }

    private static let options = IOOptionBits(kIOHIDOptionsTypeNone)
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?

    private(set) var availability: Availability = .notFound

    static func decode(_ bytes: [UInt8]) -> Double? {
        guard bytes.count >= 3 else { return nil }
        let value = Double(UInt16(bytes[1]) | UInt16(bytes[2]) << 8)
        guard (0...180).contains(value) else { return nil }
        return value
    }

    func connect() -> Bool {
        disconnect()
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, Self.options)
        self.manager = manager
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey as String: 0x05AC,
            kIOHIDProductIDKey as String: 0x8104,
        ] as CFDictionary)
        guard IOHIDManagerOpen(manager, Self.options) == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>
        else {
            availability = .notFound
            return false
        }

        availability = devices.isEmpty ? .notFound : .unsupportedInterface
        for candidate in devices {
            guard IOHIDDeviceOpen(candidate, Self.options) == kIOReturnSuccess else { continue }
            device = candidate
            if read() != nil {
                availability = .available
                return true
            }
            IOHIDDeviceClose(candidate, Self.options)
            device = nil
        }
        return false
    }

    func read() -> Double? {
        guard let device else { return nil }
        var report = [UInt8](repeating: 0, count: 8)
        var length = report.count
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &report, &length)
        guard result == kIOReturnSuccess else { return nil }
        return Self.decode(Array(report.prefix(length)))
    }

    func disconnect() {
        if let device { IOHIDDeviceClose(device, Self.options) }
        if let manager { IOHIDManagerClose(manager, Self.options) }
        device = nil
        manager = nil
    }

    deinit { disconnect() }
}
