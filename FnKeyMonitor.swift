//
//  FnKeyMonitor.swift
//
//  Listens for the ASUS vendor HID usages that macOS ignores and turns them
//  into backlight changes.
//
//  The Fn brightness keys arrive on usage page 0xFF31 (ASUS vendor) with
//  usages 0xC4 (up) and 0xC5 (down). macOS maps nothing to those, which is
//  why the keys look dead. Linux does the same job in hid-asus.c by mapping
//  0xC4/0xC5 to KEY_KBDILLUMUP/KEY_KBDILLUMDOWN.
//
//  This monitor does not synthesise regular HID keyboard input; it only
//  drives the backlight. Synthesising keys would require an event tap and
//  accessibility permission, which is more than this needs.
//

import Foundation
import IOKit.hid

final class FnKeyMonitor {

    /// Usage page / usages, per HIDUsageTables.h (0xFF31 vendor page).
    static let asusVendorPage: UInt32 = 0xFF31
    static let usageIlluminationUp: UInt32 = 0xC4
    static let usageIlluminationDown: UInt32 = 0xC5

    private var manager: IOHIDManager?
    private let hid: AsusKbdHID
    private var level: Int
    private let maxLevel: Int

    /// Called whenever the level changes, so the UI can follow along.
    var onLevelChange: ((Int) -> Void)?

    init(hid: AsusKbdHID, startLevel: Int = 2, maxLevel: Int = AsusKbdHID.maxLevel) {
        self.hid = hid
        self.level = max(0, min(startLevel, maxLevel))
        self.maxLevel = maxLevel
    }

    func currentLevel() -> Int { level }

    /// Start listening. Reports whether monitoring could be set up at all.
    @discardableResult
    func start() -> Bool {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        let match: [String: Any] = [
            kIOHIDVendorIDKey as String: AsusKbdHID.vendorID,
            kIOHIDPrimaryUsagePageKey as String: Int(Self.asusVendorPage)
        ]
        IOHIDManagerSetDeviceMatching(mgr, match as CFDictionary)

        // Input values arrive through this callback. We only consume the two
        // illumination usages and leave everything else alone.
        let callback: IOHIDValueCallback = { context, _, _, value in
            guard let context = context else { return }
            let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.handle(value: value)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(mgr, callback, selfPtr)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(),
                                        CFRunLoopMode.defaultMode.rawValue)

        let kr = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        if kr != kIOReturnSuccess {
            NSLog("FnKeyMonitor: IOHIDManagerOpen failed (%d)", kr)
            return false
        }

        manager = mgr
        return true
    }

    func stop() {
        guard let mgr = manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(),
                                          CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = nil
    }

    private func handle(value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)

        guard usagePage == Self.asusVendorPage else { return }

        // Vendor usages are reported as either a key press (1) or a relative
        // delta; only react to a non-zero value so a release does not trigger
        // a second step.
        let intValue = IOHIDValueGetIntegerValue(value)
        guard intValue != 0 else { return }

        switch usage {
        case Self.usageIlluminationUp:
            step(+1)
        case Self.usageIlluminationDown:
            step(-1)
        default:
            break
        }
    }

    private func step(_ delta: Int) {
        // Clamp without wrapping: pressing up at max does nothing rather than
        // jumping back to 0.
        let next = level + delta
        guard next >= 0, next <= maxLevel, next != level else { return }
        level = next

        do {
            try hid.setBacklight(level: level)
            NSLog("FnKeyMonitor: backlight -> %d", level)
            onLevelChange?(level)
        } catch {
            NSLog("FnKeyMonitor: setBacklight failed: %@", "\(error)")
        }
    }
}
