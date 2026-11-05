//
//  AsusKbdHID.swift
//
//  Native keyboard-backlight + Fn-key support for ASUS ROG keyboards, using
//  only public IOHID APIs in userspace. No kext, no SIP changes, no third
//  party driver.
//
//  Protocol (identical in Linux drivers/hid/hid-asus.c and ROG-HID):
//    Feature report id 0x5A, 16 bytes
//      init        : 5A 41 53 55 53 20 54 65 63 2E 49 6E 63 2E 00
//      get funcs   : 5A 05 20 31 00 08 00 ...
//                    -> reply byte 6 has the capability bits,
//                       bit0 = keyboard backlight supported
//      set backlight: 5A BA C5 C4 <level> 00 ...
//                    level is 0..ASUS_KBD_MAX_LEVEL
//
//  The Fn keys arrive as vendor usage page 0xFF31 with usage 0xC4 / 0xC5
//  (illumination up / down). macOS does not map those to anything by
//  default, which is why they appear dead.
//
//  Why not ACPI: the GA503QM DSDT's EC0.SLKB computes a level into a local
//  and never writes it anywhere, so the ACPI path is a no-op on this board.
//  The firmware only reacts to the HID feature report.
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
    case setReportFailed(IOReturn)
    case getReportFailed(IOReturn)
    case backlightUnsupported

    var description: String {
        switch self {
        case .deviceNotFound:
            return "ASUS keyboard HID device (VID 0x0B05) not found"
        case .openFailed(let kr):
            return "IOHIDDeviceOpen failed (\(kr)); this usually means the "
                 + "keyboard is a restricted device and needs input monitoring "
                 + "permission, or the process must be root"
        case .setReportFailed(let kr):
            return "IOHIDDeviceSetReport failed (\(kr))"
        case .getReportFailed(let kr):
            return "IOHIDDeviceGetReport failed (\(kr))"
        case .backlightUnsupported:
            return "keyboard reports no backlight support"
        }
    }
}

final class AsusKbdHID {

    static let vendorID: Int = 0x0B05
    static let featureReportID: CFIndex = 0x5A
    static let reportSize = 16

    // Firmware has ASUS_EV_MAX_BRIGHTNESS = 3, i.e. four levels.
    static let maxLevel = 3

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?

    /// Open the ASUS keyboard's vendor HID interface.
    ///
    /// We deliberately match on vendor id only: several keyboards expose the
    /// vendor collection on different usage pages and the product id varies
    /// per model (this machine is 0b05:19b6, ROG-HID also lists 1869, 1866,
    /// 1854, 1837, 1822).
    func open() throws {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        // Primary usage page 0xFF31 is the ASUS vendor page. Fall back to a
        // plain vendor-id match if the keyboard does not advertise it.
        let vendorPageMatch: [String: Any] = [
            kIOHIDVendorIDKey as String: Self.vendorID,
            kIOHIDPrimaryUsagePageKey as String: 0xFF31
        ]
        let vendorOnlyMatch: [String: Any] = [
            kIOHIDVendorIDKey as String: Self.vendorID
        ]

        IOHIDManagerSetDeviceMatching(mgr, vendorPageMatch as CFDictionary)
        IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))

        var found = Self.firstDevice(mgr)

        if found == nil {
            IOHIDManagerSetDeviceMatching(mgr, vendorOnlyMatch as CFDictionary)
            // Re-open so the new matching dictionary takes effect.
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            found = Self.firstDevice(mgr)
        }

        guard let dev = found else {
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            throw AsusKbdError.deviceNotFound
        }

        // Opening with seize would steal the keyboard; we only want the
        // vendor collection, so open without it.
        let kr = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        if kr != kIOReturnSuccess {
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            throw AsusKbdError.openFailed(kr)
        }

        self.manager = mgr
        self.device = dev
    }

    private static func firstDevice(_ mgr: IOHIDManager) -> IOHIDDevice? {
        guard let set = IOHIDManagerCopyDevices(mgr) else { return nil }

        // Bridge the untyped CFSet through NSArray, which is well defined for
        // IOHIDDevice elements and avoids hand-rolled CFSet pointer juggling.
        let array = set as NSArray
        for case let obj as IOHIDDevice in array {
            return obj
        }
        return nil
    }

    func close() {
        if let d = device {
            IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if let m = manager {
            IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        device = nil
        manager = nil
    }

    // MARK: - low level

    private func setFeature(_ bytes: [UInt8]) throws {
        guard let dev = device else { throw AsusKbdError.deviceNotFound }
        precondition(bytes.count == Self.reportSize)

        var buffer = bytes
        let kr: IOReturn = buffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> IOReturn in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            return IOHIDDeviceSetReport(dev,
                                        kIOHIDReportTypeFeature,
                                        Self.featureReportID,
                                        base,
                                        CFIndex(raw.count))
        }
        if kr != kIOReturnSuccess {
            throw AsusKbdError.setReportFailed(kr)
        }
    }

    private func getFeature() throws -> [UInt8] {
        guard let dev = device else { throw AsusKbdError.deviceNotFound }

        var buffer = [UInt8](repeating: 0, count: Self.reportSize)
        var length = CFIndex(buffer.count)
        let kr: IOReturn = buffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> IOReturn in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            return IOHIDDeviceGetReport(dev,
                                        kIOHIDReportTypeFeature,
                                        Self.featureReportID,
                                        base,
                                        &length)
        }
        if kr != kIOReturnSuccess {
            throw AsusKbdError.getReportFailed(kr)
        }
        return buffer
    }

    // MARK: - protocol

    /// The keyboard needs this handshake before it answers feature reports.
    func initialize() throws {
        var buf = [UInt8](repeating: 0, count: Self.reportSize)
        let ascii: [UInt8] = [0x41, 0x53, 0x55, 0x53, 0x20, 0x54, 0x65, 0x63,
                              0x2E, 0x49, 0x6E, 0x63, 0x2E]
        buf[0] = UInt8(Self.featureReportID)
        for (i, b) in ascii.enumerated() { buf[i + 1] = b }
        try setFeature(buf)
    }

    /// Ask which features the keyboard implements.
    ///
    /// Mirrors hid-asus.c: write the query, read the feature report back and
    /// take byte 6 as the capability bitmap.
    func functions() throws -> AsusKbdFunctions {
        var buf = [UInt8](repeating: 0, count: Self.reportSize)
        buf[0] = UInt8(Self.featureReportID)
        buf[1] = 0x05
        buf[2] = 0x20
        buf[3] = 0x31
        buf[5] = 0x08

        try setFeature(buf)
        let reply = try getFeature()
        return AsusKbdFunctions(rawValue: reply[6])
    }

    /// Set the keyboard backlight, 0..maxLevel.
    func setBacklight(level: Int) throws {
        let clamped = max(0, min(level, Self.maxLevel))

        var buf = [UInt8](repeating: 0, count: Self.reportSize)
        buf[0] = UInt8(Self.featureReportID)
        buf[1] = 0xBA      // command
        buf[2] = 0xC5      // illumination down
        buf[3] = 0xC4      // illumination up
        buf[4] = UInt8(clamped)
        try setFeature(buf)
    }
}
