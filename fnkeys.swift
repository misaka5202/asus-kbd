//
//  fnkeys.swift
//
//  Turn the ASUS Fn keys into actual system actions.
//
//  Background
//  ----------
//  On this machine the Fn keys are HID keys, not ACPI keys. Pressing one
//  produces an input report on the ASUS vendor collection:
//
//      id=0x5A   page 0xFF31   len=6   5A XX 00 00 00 00
//
//  where byte 1 is the key code. fnprobe established that by listening with
//  IOHIDManager, which needs no code signing, no kext and no SIP change.
//
//  The ACPI path exists too (_Qxx -> IANE -> Notify) but macOS never drives
//  it: repeated measurements showed notify = 0 while keys were pressed. So
//  this listens on HID and ignores ACPI entirely.
//
//  Codes observed on this machine (GA503QM, PID 0x19B6):
//
//      0xC4  keyboard backlight up      0x6B  touchpad toggle
//      0xC5  keyboard backlight down    0x6C  sleep
//      0x88  wireless / airplane        0x7C  microphone mute
//      0xEC  heartbeat, every ~3 s - ignored
//      0xB3  unconfirmed                0xAE  unconfirmed
//
//  Scope
//  -----
//  This tool does the two things a userspace process can do without extra
//  permissions:
//
//      keyboard backlight   written straight to the keyboard as the HID
//                           feature report 5A BA C5 C4 <level>, the same
//                           protocol asus-kbd already proves works
//      sleep                IOPMSleepSystem, the normal sleep path
//
//  Everything else is reported and not acted on, on purpose:
//
//      touchpad toggle      needs the AsusSMC kext's kern event; there is no
//                           userspace equivalent that macOS honours
//      microphone mute      would need a synthetic Consumer event, which
//                           requires an event tap and accessibility consent
//      wireless             macOS owns the WiFi state; a synthetic toggle
//                           would race the menu bar
//
//  A key that does nothing is a usable system. A key that does the wrong thing
//  is not, so unmapped or unsupported codes are printed and left alone.
//
//  Build:
//    swiftc -O -target x86_64-apple-macos11.0 \
//      -framework IOKit -framework CoreFoundation \
//      -o fnkeys fnkeys.swift
//
//  Run:
//    ./fnkeys              foreground, Ctrl-C to stop
//    ./fnkeys --verbose    print raw bytes of every report
//

import Foundation
import IOKit
import IOKit.hid
import IOKit.pwr_mgt

// MARK: - Constants

private let asusVendorID = 0x0B05
private let fnReportID: UInt32 = 0x5A

/// The EC accepts 0...3 on this board; asus-kbd writes the same range through
/// the same feature report.
private let maxBacklightLevel = 3

/// Backlight report: report id 0x5A, magic BA C5 C4, then the level.
private let backlightMagic: [UInt8] = [0xBA, 0xC5, 0xC4]

// MARK: - Codes

enum FnCode: UInt8 {
    case illuminationUp = 0xC4
    case illuminationDown = 0xC5
    case touchpadToggle = 0x6B
    case sleep = 0x6C
    case micMute = 0x7C
    case wireless = 0x88
    case heartbeat = 0xEC

    var name: String {
        switch self {
        case .illuminationUp:   return "keyboard backlight up"
        case .illuminationDown: return "keyboard backlight down"
        case .touchpadToggle:   return "touchpad toggle"
        case .sleep:            return "sleep"
        case .micMute:          return "microphone mute"
        case .wireless:         return "wireless toggle"
        case .heartbeat:        return "heartbeat"
        }
    }

    /// Whether this tool acts on the code, as opposed to only reporting it.
    var handled: Bool {
        switch self {
        case .illuminationUp, .illuminationDown, .sleep: return true
        default: return false
        }
    }
}

// MARK: - State

private var verbose = false
private var backlightLevel = 2
private var lastHeartbeat: TimeInterval = 0

// MARK: - Keyboard backlight

/// Sets the keyboard backlight over the HID feature report.
///
/// Kept separate from the report listener because opening a device for writing
/// is a different operation from receiving reports, and doing it lazily means
/// a machine without the vendor collection still runs the rest of the tool.
final class Backlight {
    private var device: IOHIDDevice?

    func open() -> Bool {
        if device != nil { return true }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDVendorIDKey as String: asusVendorID,
            kIOHIDPrimaryUsagePageKey as String: 0xFF31,
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let first = set.first else {
            return false
        }

        let kr = IOHIDDeviceOpen(first, IOOptionBits(kIOHIDOptionsTypeNone))
        guard kr == kIOReturnSuccess else {
            NSLog("fnkeys: IOHIDDeviceOpen failed 0x%X", kr)
            return false
        }
        device = first
        return true
    }

    @discardableResult
    func set(level: Int) -> Bool {
        guard open(), let dev = device else { return false }
        let clamped = max(0, min(level, maxBacklightLevel))

        var report = [UInt8](repeating: 0, count: 5)
        report[0] = UInt8(fnReportID)
        report[1] = backlightMagic[0]
        report[2] = backlightMagic[1]
        report[3] = backlightMagic[2]
        report[4] = UInt8(clamped)

        let kr = report.withUnsafeBufferPointer { buf in
            IOHIDDeviceSetReport(dev, kIOHIDReportTypeFeature,
                                 CFIndex(fnReportID),
                                 buf.baseAddress!, buf.count)
        }
        guard kr == kIOReturnSuccess else {
            NSLog("fnkeys: SetReport failed 0x%X", kr)
            return false
        }
        backlightLevel = clamped
        return true
    }
}

private let backlight = Backlight()

// MARK: - Actions

private func handle(_ code: UInt8) {
    guard let fn = FnCode(rawValue: code) else {
        print(String(format: "  code 0x%02X - unmapped, ignored", code))
        return
    }

    if fn == .heartbeat {
        // The keyboard emits this every few seconds whether or not a key was
        // pressed. Printing it at most every 30 s keeps it visibly separate
        // from real keys without flooding the log.
        let now = Date().timeIntervalSince1970
        if verbose || now - lastHeartbeat > 30 {
            print("  heartbeat (ignored)")
            lastHeartbeat = now
        }
        return
    }

    print("  \(fn.name)")

    guard fn.handled else {
        switch fn {
        case .touchpadToggle:
            print("    needs AsusSMC's kern event; no userspace equivalent")
        case .micMute:
            print("    needs an event tap and accessibility consent; not synthesised")
        case .wireless:
            print("    macOS owns the WiFi state; not synthesised")
        default:
            break
        }
        return
    }

    switch fn {
    case .illuminationUp:
        let target = backlightLevel + 1
        if backlight.set(level: target) {
            print("    backlight \(backlightLevel)")
        } else {
            print("    backlight write failed")
        }

    case .illuminationDown:
        let target = backlightLevel - 1
        if backlight.set(level: target) {
            print("    backlight \(backlightLevel)")
        } else {
            print("    backlight write failed")
        }

    case .sleep:
        let port = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
        guard port != 0 else {
            print("    could not reach power management")
            return
        }
        let kr = IOPMSleepSystem(port)
        IOObjectRelease(port)
        if kr != kIOReturnSuccess {
            NSLog("fnkeys: IOPMSleepSystem failed 0x%X", kr)
            print(String(format: "    sleep failed 0x%X", kr))
        }

    default:
        break
    }
}

// MARK: - HID listener

private let reportCallback: IOHIDReportCallback = { _, _, sender, _, reportID, report, length in
    guard reportID == fnReportID, length >= 2 else { return }
    let code = report[1]

    // 0x00 is the release report that follows every press. Acting on it would
    // double every action.
    guard code != 0x00 else { return }

    let stamp = DateFormatter.localizedString(from: Date(),
                                              dateStyle: .none,
                                              timeStyle: .medium)
    if verbose {
        var raw = ""
        for i in 0..<length { raw += String(format: "%02X ", report[i]) }
        print("[\(stamp)] 0x\(String(format: "%02X", code))  \(raw)")
    } else {
        print("[\(stamp)]")
    }

    handle(code)
}

final class FnKeys {
    static func run() {
        if CommandLine.arguments.contains("--verbose") { verbose = true }

        print("=== ASUS Fn keys ===")
        print("")
        print("report 0x5A on the ASUS vendor collection - no signing, no kext.")
        print("Ctrl-C to stop.")
        print("")

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager,
                                      [kIOHIDVendorIDKey as String: asusVendorID] as CFDictionary)

        let openKr = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openKr == kIOReturnSuccess else {
            print(String(format: "IOHIDManagerOpen failed: 0x%X", openKr))
            exit(1)
        }

        IOHIDManagerRegisterInputReportCallback(manager, reportCallback, nil)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(),
                                        CFRunLoopMode.defaultMode.rawValue)

        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !set.isEmpty else {
            print("no ASUS HID devices found (vendor 0x0B05)")
            exit(1)
        }

        print("listening on \(set.count) ASUS device(s)")
        if backlight.open() {
            print("backlight control available, level \(backlightLevel)")
        } else {
            print("backlight control unavailable - Fn+F2/F3 will do nothing")
        }
        print("")

        CFRunLoopRun()
    }
}

FnKeys.run()
