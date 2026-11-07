//
//  main.swift  (asus-kbd)
//
//  Command line front end for native ASUS keyboard backlight control.
//
//    asus-kbd list            enumerate every ASUS HID interface
//    asus-kbd info [n]        device, capabilities, raw reply bytes
//    asus-kbd set <0-3> [n]   set the backlight level
//    asus-kbd up | down       step one level
//    asus-kbd daemon [n]      listen for the Fn illumination keys
//    asus-kbd cbprobe [level] ask macOS's CoreBrightness system what it knows
//
//  The optional [n] selects an interface index from `list`. Without it the
//  ASUS vendor collection (usage page 0xFF31) is preferred.
//

import Foundation

func usage() {
    print("""
    usage: asus-kbd <command> [index]

      list            enumerate ASUS HID interfaces (start here)
      info [n]        show the chosen interface, capabilities and raw reply
      set <0-3> [n]   set the backlight level
      up | down       step one level
      daemon [n]      listen for the Fn illumination keys
      cbprobe [0-1]   ask macOS's own backlight system what it knows
    """)
}

func hex(_ bytes: [UInt8], _ n: Int) -> String {
    bytes.prefix(n).map { String(format: "%02X", $0) }.joined(separator: " ")
}

let args = CommandLine.arguments
guard args.count >= 2 else { usage(); exit(2) }

// ---- commands that do not need an open device -------------------------

if args[1] == "cbprobe" {
    var wanted: Float? = nil
    if args.count >= 3 {
        guard let v = Float(args[2]), v >= 0, v <= 1 else {
            FileHandle.standardError.write("error: cbprobe level must be 0.0-1.0\n".data(using: .utf8)!)
            exit(2)
        }
        wanted = v
    }
    exit(CoreBrightnessProbe.run(setValue: wanted))
}

if args[1] == "list" {
    let list = AsusKbdHID.candidates()
    if list.isEmpty {
        print("no ASUS HID devices found (vendor 0x0B05)")
        exit(1)
    }
    print("ASUS HID interfaces (\(list.count)):")
    for c in list.sorted(by: { $0.index < $1.index }) {
        print("  " + c.summary)
    }
    print("")
    print("pick one with: asus-kbd info <index>")
    exit(0)
}

// ---- resolve the optional interface index ----------------------------

let command = args[1]
var deviceIndex: Int? = nil
switch command {
case "info", "daemon", "up", "down":
    if args.count >= 3, let n = Int(args[2]) { deviceIndex = n }
case "set":
    if args.count >= 4, let n = Int(args[3]) { deviceIndex = n }
default:
    break
}

let hid = AsusKbdHID()

do {
    try hid.open(index: deviceIndex)
} catch {
    FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
defer { hid.close() }

if let c = hid.chosen {
    print("using " + c.summary)
    print("feature report buffer size: \(hid.featureSize) bytes")
}

switch command {
case "info":
    do {
        try hid.initialize()
        print("init report sent")
        let funcs = try hid.functions()
        let reply = try hid.getFeature()
        print("raw reply (\(reply.length) bytes): \(hex(reply.bytes, min(reply.length, 32)))")
        let supported = funcs.contains(.keyboardBacklight)
        print("capability byte: 0x\(String(funcs.rawValue, radix: 16))")
        print("backlight supported: \(supported ? "yes" : "no")")
        if !supported {
            print("note: try another index from `asus-kbd list`")
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
        let used = try hid.setBacklight(level: level)
        print("backlight -> \(level) (feature report sent as \(used) bytes)")
    } catch {
        FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
        exit(1)
    }

case "up", "down":
    let delta = (command == "up") ? 1 : -1
    let level = max(0, min(2 + delta, AsusKbdHID.maxLevel))
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
