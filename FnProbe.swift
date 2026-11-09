//
//  FnProbe.swift
//
//  Print only the ASUS Fn-key codes, one per line.
//
//  Why this exists
//  ---------------
//  hkscan showed the Fn keys are HID keys, not ACPI keys. Pressing them
//  produces input reports on the ASUS vendor collection:
//
//      id=0x5A  usage page 0xFF31  usage 0x76  len=6  5A XX 00 00 00 00
//
//  where byte 1 (XX) is the key code. That byte matches the codes the DSDT
//  uses for the same keys - 0x6B is the touchpad toggle in _Q12, for example -
//  so the EC raises both an ACPI event and a HID report for the same press.
//  macOS can use neither without help, but the HID path needs nothing more
//  than a listener in userspace.
//
//  hkscan was too noisy to read: the keyboard also emits a 0x5D heartbeat
//  every few hundred milliseconds and a stream of 0x01 keyboard reports, which
//  buried the codes. This tool prints nothing except report 0x5A, so pressing
//  the keys one at a time gives an unambiguous list.
//
//  Usage
//  -----
//      ./fnprobe            print codes as they arrive
//      ./fnprobe --table    also print a running count so the Nth code can be
//                           matched to the Nth key pressed
//
//  Press the Fn keys in a known order, one every two seconds, and the output
//  maps directly onto that order.
//

import Foundation
import IOKit.hid

let asusVendorID = 0x0B05

// Report 0x5A carries the key code in byte 1. The first byte is the report ID
// repeated, so the buffer looks like: 5A <code> 00 00 00 00.
let fnReportID: UInt32 = 0x5A

var counter = 0
let startTime = Date()

let callback: IOHIDReportCallback = { _, _, sender, _, reportID, report, reportLength in
    guard let sender = sender else { return }
    guard reportID == fnReportID, reportLength >= 2 else { return }

    // report[0] is the report ID, report[1] is the key code.
    let code = report[1]
    counter += 1

    let elapsed = String(format: "%7.2f", Date().timeIntervalSince(startTime))
    print("[\(elapsed)s]  code = 0x" + String(format: "%02X", code)
          + "   (#\(counter))   raw " + (0..<reportLength)
            .map { String(format: "%02X", report[$0]) }
            .joined(separator: " "))
}

// Swift rejects @main in a module that also has top-level code, and the
// callback needs file-scope state, so the entry point is a plain function
// invoked from a small top-level statement at the end of the file.
func runProbe() {
    print("=== ASUS Fn key code probe ===")
    print("")
    print("Prints only report 0x5A, which carries the Fn key codes.")
    print("Press the Fn keys in a known order, one every two seconds.")
    print("Ctrl-C to stop.")
    print("")

    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey as String: asusVendorID] as CFDictionary)

    let kr = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    guard kr == kIOReturnSuccess else {
        print("IOHIDManagerOpen failed: 0x" + String(format: "%X", kr))
        exit(1)
    }

    IOHIDManagerRegisterInputReportCallback(manager, callback, nil)
    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

    if let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !set.isEmpty {
        print("listening on \(set.count) ASUS device(s); waiting for report 0x5A")
        print("")
    } else {
        print("no ASUS HID devices matched vendor 0x0B05")
        exit(1)
    }

    CFRunLoopRun()
}

runProbe()
