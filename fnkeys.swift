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
//  it - repeated measurements showed notify = 0 while keys were pressed. So
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
//  Ownership of the HID device
//  ---------------------------
//  An earlier version of this file opened one IOHIDManager for input and a
//  second one for the backlight write. That fails on this machine:
//
//      IOHIDManagerOpen  -> 0xE00002E2  kIOReturnExclusiveAccess
//      IOHIDDeviceSetReport -> 0xE00002CD  kIOReturnNotOpen
//
//  A manager matching the vendor usage page takes exclusive ownership of the
//  collection, so a second manager - or the queued report write behind it -
//  cannot get in. There is exactly one manager here, and the device used for
//  writing comes out of that same manager:
//
//      IOHIDManagerCreate / SetDeviceMatching(vendorID) / Open
//      IOHIDManagerCopyDevices  ->  pick the vendor-page device
//      IOHIDDeviceOpen          ->  takes the write path for that device
//
//  which is how asus-kbd opens it, and that already works here.
//
//  Scope
//  -----
//      keyboard backlight   HID feature report 5A BA C5 C4 <level>
//      sleep                IOPMSleepSystem
//
//  Everything else is reported and not acted on, because a key that does
//  nothing is a usable system and a key that does the wrong thing is not:
//
//      touchpad toggle      needs AsusSMC's kern event
//      microphone mute      needs an event tap and accessibility consent
//      wireless             macOS owns the WiFi state
//
//  Build:
//    swiftc -O -target x86_64-apple-macos11.0 \
//      -framework IOKit -framework CoreFoundation \
//      -o fnkeys fnkeys.swift
//

import Foundation
import IOKit
import IOKit.hid
import IOKit.pwr_mgt

// MARK: - Constants

private let asusVendorID = 0x0B05
private let asusVendorUsagePage = 0xFF31
private let fnReportID: UInt32 = 0x5A

/// The EC accepts 0...3 on this board; asus-kbd writes the same range.
private let maxBacklightLevel = 3

/// Backlight report layout: report id, then BA C5 C4, then the level.
/// The length is 5 bytes, which is what asus-kbd sends for this report.
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

    var handled: Bool {
        switch self {
        case .illuminationUp, .illuminationDown, .sleep: return true
        default: return false
        }
    }
}

// MARK: - Shared state

private var verbose = false
private var backlightLevel = 2
private var lastHeartbeat: TimeInterval = 0

/// The one device used for feature-report writes, taken from the manager that
/// is also listening for input. Kept at file scope because the report callback
/// is a C function and cannot capture.
private var writeDevice: IOHIDDevice?

// MARK: - Backlight

/// Sends the backlight feature report on the already-open device.
///
/// Retries a few times: the first write after start can come back
/// kIOReturnNotReady while the keyboard is still enumerating, and a single
/// lost press is worse than a short retry.
@discardableResult
func setBacklight(_ level: Int) -> Bool {
    guard let dev = writeDevice else {
        NSLog("fnkeys: no write device")
        return false
    }

    let clamped = max(0, min(level, maxBacklightLevel))
    var report = [UInt8](repeating: 0, count: 5)
    report[0] = UInt8(fnReportID)
    report[1] = backlightMagic[0]
    report[2] = backlightMagic[1]
    report[3] = backlightMagic[2]
    report[4] = UInt8(clamped)

    for attempt in 0..<3 {
        let kr = report.withUnsafeBufferPointer { buf in
            IOHIDDeviceSetReport(dev, kIOHIDReportTypeFeature,
                                 CFIndex(fnReportID),
                                 buf.baseAddress!, buf.count)
        }
        if kr == kIOReturnSuccess {
            backlightLevel = clamped
            return true
        }
        if attempt == 2 {
            NSLog("fnkeys: SetReport failed 0x%X", kr)
            return false
        }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return false
}

// MARK: - Actions

func handle(_ code: UInt8) {
    guard let fn = FnCode(rawValue: code) else {
        print(String(format: "  code 0x%02X - unmapped, ignored", code))
        return
    }

    if fn == .heartbeat {
        // Emitted every few seconds whether or not a key was pressed. Printing
        // at most every 30 s keeps it visibly separate from real keys.
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
            print("    needs an event tap and accessibility consent")
        case .wireless:
            print("    macOS owns the WiFi state; not synthesised")
        default:
            break
        }
        return
    }

    switch fn {
    case .illuminationUp:
        if setBacklight(backlightLevel + 1) {
            print("    backlight \(backlightLevel)")
        } else {
            print("    backlight write failed")
        }

    case .illuminationDown:
        if setBacklight(backlightLevel - 1) {
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

    // 0x00 is the release report that follows every press; acting on it would
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

// MARK: - Entry point

final class FnKeys {
    static func run() {
        if CommandLine.arguments.contains("--verbose") { verbose = true }

        print("=== ASUS Fn keys ===")
        print("")
        print("report 0x5A on the ASUS vendor collection - no signing, no kext.")
        print("Ctrl-C to stop.")
        print("")

        // One manager for everything. Matching only on the vendor id keeps the
        // standard keyboard interface out of it, which is what lets
        // IOHIDManagerOpen succeed while the system's own driver keeps working.
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager,
                                      [kIOHIDVendorIDKey as String: asusVendorID] as CFDictionary)

        let openKr = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openKr == kIOReturnSuccess else {
            print(String(format: "IOHIDManagerOpen failed: 0x%X", openKr))
            if openKr == kIOReturnExclusiveAccess {
                print("  another process holds this collection.")
                print("  stop any earlier fnkeys:  launchctl bootout gui/$(id -u)/local.fnkeys")
            }
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

        // Pick the vendor-page collection for writes; that is the one that
        // carries the 0x5A feature report.
        var pick: IOHIDDevice?
        for dev in set {
            let page = (IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsagePageKey as CFString)
                        as? NSNumber)?.intValue ?? 0
            if page == asusVendorUsagePage {
                pick = dev
                break
            }
        }
        if pick == nil {
            pick = set.first
        }

        if let dev = pick {
            let kr = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
            if kr == kIOReturnSuccess {
                writeDevice = dev
                print("backlight control available")
                // Reflect the starting level so the first press moves from
                // where the keyboard actually is rather than from a guess.
                setBacklight(backlightLevel)
            } else {
                print(String(format: "backlight unavailable: IOHIDDeviceOpen 0x%X", kr))
                if kr == kIOReturnExclusiveAccess {
                    print("  the writable interface is held by another process")
                }
            }
        }
        print("")

        CFRunLoopRun()
    }
}

FnKeys.run()
