//
//  main.swift  (asus-kbd)
//
//  Command line front end for the native keyboard backlight control.
//
//    asus-kbd info            show device, capabilities and current level
//    asus-kbd set <0-3>       set the backlight level
//    asus-kbd up | down       step the level
//    asus-kbd daemon          listen for Fn keys and drive the backlight
//

import Foundation

func usage() {
    print("""
    usage: asus-kbd <command>

      info            show device and capabilities
      set <0-3>       set backlight level
      up | down       step one level
      daemon          listen for Fn illumination keys
    """)
}

let args = CommandLine.arguments
guard args.count >= 2 else { usage(); exit(2) }

let hid = AsusKbdHID()

do {
    try hid.open()
} catch {
    FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
defer { hid.close() }

switch args[1] {
case "info":
    print("device: ASUS HID (VID 0x\(String(AsusKbdHID.vendorID, radix: 16)))")
    do {
        try hid.initialize()
        let funcs = try hid.functions()
        let supported = funcs.contains(.keyboardBacklight)
        print("backlight supported: \(supported ? "yes" : "no")")
        if !supported {
            print("note: firmware did not report backlight support; writes will be ignored")
        }
    } catch {
        FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
        exit(1)
    }

case "set":
    guard args.count >= 3, let level = Int(args[2]) else {
        FileHandle.standardError.write("error: set needs a level 0..3\n".data(using: .utf8)!)
        exit(2)
    }
    guard level >= 0, level <= AsusKbdHID.maxLevel else {
        FileHandle.standardError.write("error: level must be 0..\(AsusKbdHID.maxLevel)\n".data(using: .utf8)!)
        exit(2)
    }
    do {
        try hid.initialize()
        try hid.setBacklight(level: level)
        print("backlight -> \(level)")
    } catch {
        FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
        exit(1)
    }

case "up", "down":
    // Stepping from the CLI needs a known starting point; the firmware can be
    // read back through the feature report, but its value is model specific,
    // so treat a bare up/down as "one step from the middle".
    let delta = (args[1] == "up") ? 1 : -1
    let start = 2
    let level = max(0, min(start + delta, AsusKbdHID.maxLevel))
    do {
        try hid.initialize()
        try hid.setBacklight(level: level)
        print("backlight -> \(level)")
    } catch {
        FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
        exit(1)
    }

case "daemon":
    do {
        try hid.initialize()
        let funcs = try hid.functions()
        guard funcs.contains(.keyboardBacklight) else {
            FileHandle.standardError.write("error: \(AsusKbdError.backlightUnsupported)\n".data(using: .utf8)!)
            exit(1)
        }
    } catch {
        FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
        exit(1)
    }

    let monitor = FnKeyMonitor(hid: hid)
    if !monitor.start() {
        FileHandle.standardError.write("error: could not start HID monitoring\n".data(using: .utf8)!)
        exit(1)
    }
    print("listening for Fn illumination keys (Ctrl+C to stop)")
    CFRunLoopRun()

default:
    usage()
    exit(2)
}
