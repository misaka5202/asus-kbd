//
//  AsusKbdHID.swift
//
//  Native keyboard-backlight control for ASUS ROG keyboards, using only
//  public userspace IOHID APIs. No kext, no SIP change, no third party driver.
//
//  Protocol (identical in Linux drivers/hid/hid-asus.c and ROG-HID):
//    Feature report id 0x5A
//      init         : 5A 41 53 55 53 20 54 65 63 2E 49 6E 63 2E 00
//      get funcs    : 5A 05 20 31 00 08 ...  -> reply byte 6 holds caps,
//                                              bit0 = keyboard backlight
//      set backlight: 5A BA C5 C4 <level> 00 ...
//
//  Buffer sizing note: the report layout differs between the ASUS vendor
//  collections exposed by one keyboard, and IOHIDDeviceGetReport answers
//  kIOReturnOverrun (0xE00002E8) when the caller's buffer is too small.
//  Instead of hard-coding 16 bytes we size from the device's
//  MaxFeatureReportSize and retry with progressively larger buffers,
//  reporting the byte count we actually received.
//

import Foundation
import IOKit.hid

/// Capability bits returned by the "get keyboard functions" report.
struct AsusKbdFunctions: OptionSet {
    let rawValue: UInt8
    static let keyboardBacklight = AsusKbdFunctions(rawValue: 1 << 0)
}

enum AsusKbdError: Error, CustomStringConvertible {
    case deviceNotFound
    case openFailed(IOReturn)
    case setReportFailed(IOReturn, Int)
    case getReportFailed(IOReturn, Int)
    case backlightUnsupported

    /// Human readable IOReturn, because the raw number alone tells you nothing.
    static func describe(_ kr: IOReturn) -> String {
        switch kr {
        case kIOReturnSuccess:         return "success"
        case kIOReturnNoDevice:        return "kIOReturnNoDevice"
        case kIOReturnNotPrivileged:   return "kIOReturnNotPrivileged"
        case kIOReturnBadArgument:     return "kIOReturnBadArgument"
        case kIOReturnExclusiveAccess: return "kIOReturnExclusiveAccess"
        case kIOReturnUnsupported:     return "kIOReturnUnsupported"
        case kIOReturnNotOpen:         return "kIOReturnNotOpen"
        case kIOReturnNotReadable:     return "kIOReturnNotReadable"
        case kIOReturnNotWritable:     return "kIOReturnNotWritable"
        case kIOReturnTimeout:         return "kIOReturnTimeout"
        case kIOReturnOverrun:         return "kIOReturnOverrun"
        case kIOReturnNotPermitted:    return "kIOReturnNotPermitted"
        default:
            return String(format: "IOReturn 0x%08X", UInt32(bitPattern: kr))
        }
    }

    var description: String {
        switch self {
        case .deviceNotFound:
            return "no ASUS HID device found (vendor 0x0B05)"
        case .openFailed(let kr):
            return "IOHIDDeviceOpen failed: \(Self.describe(kr)). This usually "
                 + "means the keyboard is protected; grant the terminal Input "
                 + "Monitoring permission, or run as root"
        case .setReportFailed(let kr, let size):
            return "IOHIDDeviceSetReport failed at \(size) bytes: \(Self.describe(kr))"
        case .getReportFailed(let kr, let size):
            return "IOHIDDeviceGetReport failed at \(size) bytes: \(Self.describe(kr))"
        case .backlightUnsupported:
            return "the keyboard reports no backlight support"
        }
    }
}

/// One ASUS HID interface we could talk to.
struct AsusHidCandidate {
    let index: Int
    let device: IOHIDDevice
    let product: String
    let vendorID: Int
    let productID: Int
    let primaryUsagePage: Int
    let primaryUsage: Int
    let transport: String
    let maxFeatureReportSize: Int
    let maxInputReportSize: Int

    var summary: String {
        String(format: "[%d] %@ vid=0x%04X pid=0x%04X usagePage=0x%04X usage=0x%02X "
                     + "transport=%@ featureSize=%d inputSize=%d",
               index, product, vendorID, productID,
               primaryUsagePage, primaryUsage, transport,
               maxFeatureReportSize, maxInputReportSize)
    }
}

final class AsusKbdHID {

    static let vendorID: Int = 0x0B05
    static let asusVendorUsagePage: Int = 0xFF31

    /// Report id used by every command in this protocol.
    static let featureReportID: CFIndex = 0x5A

    /// The protocol itself is 16 bytes; anything beyond that is padding.
    static let protocolReportSize = 16

    /// Firmware has ASUS_EV_MAX_BRIGHTNESS = 3, i.e. four levels.
    static let maxLevel = 3

    private var manager: IOHIDManager?
    private(set) var device: IOHIDDevice?
    private(set) var chosen: AsusHidCandidate?

    /// Buffer size used for feature reports; follows the device, never below
    /// the protocol size.
    private(set) var featureSize = protocolReportSize

    // MARK: - discovery

    /// Read an integer property by name. Literal strings are used on purpose:
    /// the named constants move between SDK versions and a missing define
    /// would be a build failure rather than a missing value.
    private static func intProperty(_ dev: IOHIDDevice, _ key: String) -> Int? {
        guard let v = IOHIDDeviceGetProperty(dev, key as CFString) else { return nil }
        if let n = v as? NSNumber { return n.intValue }
        return nil
    }

    private static func stringProperty(_ dev: IOHIDDevice, _ key: String) -> String {
        guard let v = IOHIDDeviceGetProperty(dev, key as CFString) else { return "?" }
        if let s = v as? String { return s }
        return "\(v)"
    }

    /// Enumerate every HID interface exposed by ASUS hardware.
    static func candidates() -> [AsusHidCandidate] {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [ kIOHIDVendorIDKey as String: vendorID ]
        IOHIDManagerSetDeviceMatching(mgr, match as CFDictionary)
        IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        defer { IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone)) }

        guard let set = IOHIDManagerCopyDevices(mgr) else { return [] }
        let nsSet = set as NSSet

        var out: [AsusHidCandidate] = []
        var index = 0
        for case let dev as IOHIDDevice in nsSet {
            out.append(AsusHidCandidate(
                index: index,
                device: dev,
                product: Self.stringProperty(dev, "Product"),
                vendorID: Self.intProperty(dev, "VendorID") ?? -1,
                productID: Self.intProperty(dev, "ProductID") ?? -1,
                primaryUsagePage: Self.intProperty(dev, "PrimaryUsagePage") ?? -1,
                primaryUsage: Self.intProperty(dev, "PrimaryUsage") ?? -1,
                transport: Self.stringProperty(dev, "Transport"),
                maxFeatureReportSize: Self.intProperty(dev, "MaxFeatureReportSize") ?? -1,
                maxInputReportSize: Self.intProperty(dev, "MaxInputReportSize") ?? -1
            ))
            index += 1
        }

        // IOHIDManagerCopyDevices hands back an unordered set, so the same
        // machine can enumerate differently every run. Sort deterministically
        // (vendor page first, then usage, then size) so the indices printed by
        // `list` stay stable and safe to pass back in.
        out.sort { a, b in
            let aVendor = a.primaryUsagePage == asusVendorUsagePage
            let bVendor = b.primaryUsagePage == asusVendorUsagePage
            if aVendor != bVendor { return aVendor }
            if a.primaryUsagePage != b.primaryUsagePage {
                return a.primaryUsagePage < b.primaryUsagePage
            }
            if a.primaryUsage != b.primaryUsage { return a.primaryUsage < b.primaryUsage }
            if a.maxFeatureReportSize != b.maxFeatureReportSize {
                return a.maxFeatureReportSize < b.maxFeatureReportSize
            }
            return a.productID < b.productID
        }

        // Renumber after sorting so the printed index matches the array slot.
        return out.enumerated().map { offset, c in
            AsusHidCandidate(index: offset,
                             device: c.device,
                             product: c.product,
                             vendorID: c.vendorID,
                             productID: c.productID,
                             primaryUsagePage: c.primaryUsagePage,
                             primaryUsage: c.primaryUsage,
                             transport: c.transport,
                             maxFeatureReportSize: c.maxFeatureReportSize,
                             maxInputReportSize: c.maxInputReportSize)
        }
    }

    // MARK: - connection

    /// Open a device. Without an index we prefer the ASUS vendor collection
    /// (usage page 0xFF31); otherwise the index from `candidates()` is used.
    func open(index: Int? = nil) throws {
        let list = Self.candidates()
        guard !list.isEmpty else { throw AsusKbdError.deviceNotFound }

        let pick: AsusHidCandidate
        if let idx = index {
            guard let c = list.first(where: { $0.index == idx }) else {
                throw AsusKbdError.deviceNotFound
            }
            pick = c
        } else {
            pick = list.first(where: { $0.primaryUsagePage == Self.asusVendorUsagePage })
                ?? list.first(where: { $0.maxFeatureReportSize >= Self.protocolReportSize })
                ?? list[0]
        }

        let kr = IOHIDDeviceOpen(pick.device, IOOptionBits(kIOHIDOptionsTypeNone))
        if kr != kIOReturnSuccess {
            throw AsusKbdError.openFailed(kr)
        }

        chosen = pick
        device = pick.device
        featureSize = max(Self.protocolReportSize, pick.maxFeatureReportSize)
    }

    func close() {
        if let d = device {
            IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        device = nil
        chosen = nil
        manager = nil
    }

    // MARK: - low level

    /// Send a feature report.
    ///
    /// `exactLength` mirrors what Linux sends (see asus_kbd_set_brightness:
    /// `const u8 buf[FEATURE_KBD_REPORT_SIZE] = {...}` i.e. 16 bytes). The
    /// device advertises MaxFeatureReportSize 64 for the whole interface, but
    /// the report we care about is smaller, so padding the payload up to 64
    /// changes the request and the firmware may ignore it. We therefore try
    /// the exact protocol length first and only fall back to the declared
    /// feature size if the device rejects it.
    @discardableResult
    private func setFeature(_ bytes: [UInt8], exactLength: Int? = nil) throws -> Int {
        guard let dev = device else { throw AsusKbdError.deviceNotFound }

        var buffer = bytes
        let target = exactLength ?? buffer.count
        if buffer.count < target {
            buffer.append(contentsOf: [UInt8](repeating: 0, count: target - buffer.count))
        } else if buffer.count > target {
            buffer = Array(buffer.prefix(target))
        }

        func send(_ buf: [UInt8]) -> IOReturn {
            let length = buf.count
            return buf.withUnsafeBytes { raw -> IOReturn in
                let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                return IOHIDDeviceSetReport(dev,
                                            kIOHIDReportTypeFeature,
                                            Self.featureReportID,
                                            base,
                                            CFIndex(length))
            }
        }

        var kr = send(buffer)
        var used = buffer.count

        if kr != kIOReturnSuccess, featureSize > buffer.count {
            // Retry with the device's declared size before giving up.
            var padded = buffer
            padded.append(contentsOf: [UInt8](repeating: 0,
                                              count: featureSize - buffer.count))
            kr = send(padded)
            used = padded.count
        }

        if kr != kIOReturnSuccess {
            throw AsusKbdError.setReportFailed(kr, used)
        }
        return used

    }

    /// Read the feature report, trying the declared size and then progressively
    /// larger buffers, so a wrong MaxFeatureReportSize cannot hide the data.
    func getFeature() throws -> (bytes: [UInt8], length: Int) {
        guard let dev = device else { throw AsusKbdError.deviceNotFound }

        var lastError: IOReturn = kIOReturnError
        var lastSize = 0

        for size in [featureSize, 32, 64, 128, 256] where size >= featureSize {
            var buffer = [UInt8](repeating: 0, count: size)
            var length = CFIndex(size)

            let kr: IOReturn = buffer.withUnsafeMutableBytes { raw -> IOReturn in
                let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                return IOHIDDeviceGetReport(dev,
                                            kIOHIDReportTypeFeature,
                                            Self.featureReportID,
                                            base,
                                            &length)
            }

            if kr == kIOReturnSuccess {
                return (buffer, Int(length))
            }
            lastError = kr
            lastSize = size
        }

        throw AsusKbdError.getReportFailed(lastError, lastSize)
    }

    // MARK: - protocol

    /// The keyboard needs this handshake before it answers feature reports.
    func initialize() throws {
        var buf = [UInt8](repeating: 0, count: Self.protocolReportSize)
        let ascii: [UInt8] = [0x41, 0x53, 0x55, 0x53, 0x20, 0x54, 0x65, 0x63,
                              0x2E, 0x49, 0x6E, 0x63, 0x2E]
        buf[0] = UInt8(Self.featureReportID)
        for (i, b) in ascii.enumerated() { buf[i + 1] = b }
        // Linux: asus_kbd_init sends sizeof(buf) == 16.
        try setFeature(buf, exactLength: Self.protocolReportSize)
    }

    /// Ask which features the keyboard implements.
    func functions() throws -> AsusKbdFunctions {
        var buf = [UInt8](repeating: 0, count: Self.protocolReportSize)
        buf[0] = UInt8(Self.featureReportID)
        buf[1] = 0x05
        buf[2] = 0x20
        buf[3] = 0x31
        buf[5] = 0x08

        // Linux: asus_kbd_get_functions sends sizeof(buf) == 6, not 16.
        try setFeature(buf, exactLength: 6)
        let reply = try getFeature()
        guard reply.length > 6 else {
            // Too short to hold the capability byte; report unsupported rather
            // than reading out of range.
            return AsusKbdFunctions(rawValue: 0)
        }
        return AsusKbdFunctions(rawValue: reply.bytes[6])
    }

    /// Set the keyboard backlight, 0..maxLevel.
    @discardableResult
    func setBacklight(level: Int) throws -> Int {
        let clamped = max(0, min(level, Self.maxLevel))

        var buf = [UInt8](repeating: 0, count: Self.protocolReportSize)
        buf[0] = UInt8(Self.featureReportID)
        buf[1] = 0xBA      // command
        buf[2] = 0xC5      // illumination down
        buf[3] = 0xC4      // illumination up
        buf[4] = UInt8(clamped)
        // Linux: asus_kbd_set_brightness sends sizeof(buf) == 16.
        return try setFeature(buf, exactLength: Self.protocolReportSize)
    }
}
