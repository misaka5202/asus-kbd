//
//  CoreBrightnessProbe.swift
//
//  Ask macOS's own keyboard backlight system what it knows.
//
//  macOS has no public keyboard backlight API. The private framework
//  CoreBrightness owns it, and a keyboard is addressed by a numeric keyboardID:
//
//      KeyboardBrightnessClient.copyKeyboardBacklightIDs()
//      BrightnessSystemClient.copyProperty(forKey:"KeyboardBacklightBrightness",
//                                          keyboardID:)
//
//  The System Settings brightness control is driven by that same system, so the
//  question that decides whether the control can ever work on this machine is
//  simply whether a keyboardID exists for the keyboard. This prints the answer
//  instead of assuming one.
//
//  A companion tool, "Dim Keys", documents the same interface and notes that
//  writing KeyboardBacklightBrightness disengages macOS's own auto-brightness,
//  so writing is opt-in here.
//

import Foundation

@objc private protocol BrightnessSystemClientShim {
    @objc(isAlsSupported)
    func isAlsSupported() -> Bool
    @objc(copyPropertyForKey:keyboardID:)
    func copyProperty(forKey key: String, keyboardID: UInt64) -> Any?
    @objc(setProperty:withKey:keyboardID:)
    func setProperty(_ value: Any, withKey key: String, keyboardID: UInt64) -> Bool
}

@objc private protocol KeyboardBrightnessClientShim {
    func copyKeyboardBacklightIDs() -> [NSNumber]?
    @objc(isKeyboardBuiltIn:)
    func isKeyboardBuiltIn(_ kid: UInt64) -> Bool
    @objc(isAmbientFeatureAvailableOnKeyboard:)
    func isAmbientFeatureAvailable(onKeyboard kid: UInt64) -> Bool
    @objc(isAutoBrightnessEnabledForKeyboard:)
    func isAutoBrightnessEnabled(forKeyboard kid: UInt64) -> Bool
    @objc(backlightLevelForKeyboard:)
    func backlightLevel(forKeyboard kid: UInt64) -> Float
}

enum CoreBrightnessProbe {

    static let brightnessKey = "KeyboardBacklightBrightness"

    /// Returns a process exit status.
    static func run(setValue: Float?) -> Int32 {
        let path = "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
        guard dlopen(path, RTLD_NOW) != nil else {
            print("CoreBrightness: framework could not be loaded")
            return 1
        }

        guard let bscClass = NSClassFromString("BrightnessSystemClient") as? NSObject.Type,
              let kbcClass = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else {
            print("CoreBrightness loaded, but BrightnessSystemClient / KeyboardBrightnessClient are absent")
            return 1
        }

        let bscObject = bscClass.init()
        let kbcObject = kbcClass.init()
        let bsc = unsafeBitCast(bscObject, to: BrightnessSystemClientShim.self)
        let kbc = unsafeBitCast(kbcObject, to: KeyboardBrightnessClientShim.self)

        print("CoreBrightness loaded; both classes present")
        print("run on: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("")
        print("isAlsSupported: \(bsc.isAlsSupported())")
        print("")

        guard let ids = kbc.copyKeyboardBacklightIDs() else {
            print("copyKeyboardBacklightIDs() -> nil")
            return reportNoKeyboard(reason: "the call returned nil")
        }
        guard !ids.isEmpty else {
            return reportNoKeyboard(reason: "the list is empty")
        }

        print("copyKeyboardBacklightIDs() -> \(ids)")
        print("")

        for number in ids {
            let kid = number.uint64Value
            print("keyboardID \(kid)")
            print("  isKeyboardBuiltIn          : \(kbc.isKeyboardBuiltIn(kid))")
            print("  isAmbientFeatureAvailable  : \(kbc.isAmbientFeatureAvailable(onKeyboard: kid))")
            print("  isAutoBrightnessEnabled    : \(kbc.isAutoBrightnessEnabled(forKeyboard: kid))")
            print("  backlightLevelForKeyboard  : \(kbc.backlightLevel(forKeyboard: kid))")

            if let value = bsc.copyProperty(forKey: brightnessKey, keyboardID: kid) {
                print("  copyProperty(\(brightnessKey)) : \(value)")
            } else {
                print("  copyProperty(\(brightnessKey)) : nil")
                print("    ^ the property does not exist for this keyboard ID, so")
                print("      macOS has nothing to read or write for it")
            }

            if let wanted = setValue {
                let ok = bsc.setProperty(NSNumber(value: wanted), withKey: brightnessKey, keyboardID: kid)
                print("  setProperty(\(wanted)) -> \(ok)")
                print("    ^ if the keyboard light changed, this is a working control path;")
                print("      if not, the write is accepted and dropped")
            }
            print("")
        }

        return 0
    }

    private static func reportNoKeyboard(reason: String) -> Int32 {
        print("copyKeyboardBacklightIDs() -> no keyboard (\(reason))")
        print("")
        print("This is the answer to the slider question: macOS's keyboard backlight")
        print("system has no keyboard to drive, so the System Settings brightness")
        print("control cannot work no matter what the HID report contains. The")
        print("control is shown because the virtual keyboard advertises the")
        print("capability, but nothing is registered to act on it.")
        print("")
        print("Next step would be to find what CoreBrightness enumerates, and make")
        print("the virtual keyboard match it.")
        return 0
    }
}
