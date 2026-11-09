//
//  HKScan.swift
//
//  Which path do the Fn keys actually take?
//
//  This exists because one question has been blocking every attempt at the
//  ACPI side:
//
//      when a key is pressed, does the firmware send a HID report, or does it
//      raise an ACPI event that reaches EC0._Qxx?
//
//  On this machine F7 and F8 already change the screen brightness without any
//  driver involvement, so at least those two are HID. macOS never exposes an
//  "Fn" modifier to userspace either - the modifier is consumed by the
//  keyboard firmware, and what the OS sees is whichever event the firmware
//  chose to send. So the ACPI route being silent does not prove the keys are
//  broken; it may only prove they are not ACPI keys at all.
//
//  The previous rounds all measured the ACPI side:
//
//      - EC0._CRS now reports the 53-byte set with the GpioInt (SSDT-ECIRQ)
//      - ATKD.INIT succeeds, so ATKP is One
//      - calling EC0._Q78 by hand produces 0x7C end to end
//      - pressing keys produces no notification at all
//
//  That last point is consistent with both "the EC interrupt never fires" and
//  "these keys never raise an ACPI event in the first place". This tool
//  separates them by listening to raw HID input instead.
//
//  What it prints
//  --------------
//  Every input report arriving from the ASUS vendor collection, as
//  usage-page:usage plus the raw bytes. Press the Fn keys one at a time and
//  the ones that appear here are HID keys; the ones that never appear are
//  candidates for ACPI.
//
//  This only reads. It does not open the device for writing, does not
//  synthesise anything and needs no special permissions.
//
//  Build:
//    swiftc -O -o hkscan HKScan.swift AsusKbdHID.swift
//

import Foundation
import IOKit.hid

let asusVendorID = 0x0B05

// Pages seen in the wild on ASUS keyboards. 0xFF31 is the vendor page the
// backlight usages live on; the 0x0C / 0x0B pages are consumer and telephony,
// which is where media and mic-mute keys usually land.
func pageName(_ page: UInt32) -> String {
    switch page {
    case 0x01: return "Generic Desktop"
    case 0x0B: return "Telephony"
    case 0x0C: return "Consumer"
    case 0xFF31: return "ASUS vendor"
    case 0xFF00: return "Vendor 0xFF00"
    default: return String(format: "page 0x%04X", page)
    }
}

func hex(_ bytes: UnsafePointer<UInt8>, _ length: Int) -> String {
    guard length > 0 else { return "" }
    return (0..<length).map { String(format: "%02X", bytes[$0]) }.joined(separator: " ")
}

var seenKeys = Set<String>()
let startTime = Date()

// Run-loop callback: the report descriptor is read once per device and cached,
// because asking IOHIDDevice for a property on every input report is wasted
// work and the descriptor cannot change while the device is open.
var deviceInfo: [UInt: (page: UInt32, usage: UInt32, product: String)] = [:]

let inputCallback: IOHIDReportCallback = { context, result, sender, type, reportID, report, reportLength in
    guard let sender = sender else { return }
    let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
    let key = UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque().hashValue)

    let info: (page: UInt32, usage: UInt32, product: String)
    if let cached = deviceInfo[key] {
        info = cached
    } else {
        let pageObj = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString)
        let usageObj = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString)
        let productObj = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString)
        info = (
            (pageObj as? NSNumber)?.uint32Value ?? 0,
            (usageObj as? NSNumber)?.uint32Value ?? 0,
            (productObj as? String) ?? "?"
        )
        deviceInfo[key] = info
    }

    let bytes = report.bindMemory(to: UInt8.self, capacity: reportLength)
    let payload = hex(bytes, reportLength)

    let elapsed = String(format: "%6.2f", Date().timeIntervalSince(startTime))
    let shape = String(format: "0x%02X %@", reportID, payload)
    let first = !seenKeys.contains(shape)
    seenKeys.insert(shape)

    // A leading "*" marks a report shape not seen before, so a key that only
    // ever repeats an old shape is still visible in the log.
    var line = "\(first ? "*" : " ") [\(elapsed)s]"
    line += String(format: " id=0x%02X", reportID)
    line += "  \(pageName(info.page))"
    line += String(format: "  usage=0x%02X", info.usage)
    line += "  len=\(reportLength)  \(payload)"
    print(line)
}

func main() {
    print("=== ASUS HID input scanner ===")
    print("")
    print("Press each Fn key once, slowly, and note which line appears.")
    print("Keys that never produce a line are not HID keys.")
    print("Ctrl-C to stop.")
    print("")

    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    let match: [String: Any] = [kIOHIDVendorIDKey as String: asusVendorID]
    IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)

    let kr = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    guard kr == kIOReturnSuccess else {
        print("IOHIDManagerOpen failed: 0x" + String(format: "%X", kr))
        print("(try running with sudo if this is a permission problem)")
        exit(1)
    }

    // The context argument is unused: the callback gets the sending device from
    // its own `sender` parameter, which is the reliable way in IOKit.hid.
    IOHIDManagerRegisterInputReportCallback(manager, inputCallback, nil)
    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

    // Report what was found, so an empty log can be told apart from a device
    // that never matched.
    if let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !set.isEmpty {
        print("matched \(set.count) ASUS HID device(s):")
        for dev in set {
            let pid = (IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? NSNumber)?.uint32Value ?? 0
            let page = (IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsagePageKey as CFString) as? NSNumber)?.uint32Value ?? 0
            let usage = (IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsageKey as CFString) as? NSNumber)?.uint32Value ?? 0
            let product = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? "?"
            print(String(format: "  PID 0x%04X  %@  primary=%04X:%02X", pid, product, page, usage))
        }
        print("")
    } else {
        print("no ASUS HID devices matched vendor 0x0B05")
        print("")
    }

    CFRunLoopRun()
}

main()
