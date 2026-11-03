// XDR Agent Screen: menu bar app that dims or blacks out displays (gamma, so screenshots still work),
// with a brightness slider, configurable global hotkey, idle auto-blackout and an optional virtual
// "Agent Display" (mirrored by default) that takes over when the physical display is powered off.
import AppKit
import Carbon
import CoreGraphics
import IOKit
import ServiceManagement

let appName = "XDR Agent Screen"

let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/xdr-agent-screen.log")

let logDateFormatter: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

func log(_ s: String) {
    let line = "\(logDateFormatter.string(from: Date())) \(s)\n"
    print(line, terminator: ""); fflush(stdout)
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.write(to: logURL, atomically: false, encoding: .utf8)
    }
}

// MARK: - Settings

let defaults = UserDefaults.standard

// One-time import of settings from the earlier "screenkeeper" build.
func migrateLegacySettings() {
    guard !defaults.bool(forKey: "migrated"), let old = UserDefaults(suiteName: "local.screenkeeper") else { return }
    for key in ["hotkeyCode", "hotkeyMods", "hotkeyDisplay", "level", "virtualResolution"] {
        if let v = old.object(forKey: key) { defaults.set(v, forKey: key) }
    }
    defaults.set(true, forKey: "migrated")
}

struct Hotkey {
    var keyCode: UInt32
    var modifiers: UInt32  // Carbon modifier mask

    // Built from the key code rather than stored, so it ignores Shift (⇧⌘1, not ⇧⌘!) and follows
    // the current keyboard layout.
    var display: String { modifierSymbols(cocoaModifiers(modifiers)) + keyName(Int(keyCode)) }

    static let fallback = Hotkey(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(cmdKey | optionKey | controlKey))

    static func load() -> Hotkey {
        guard defaults.object(forKey: "hotkeyCode") != nil else { return fallback }
        return Hotkey(keyCode: UInt32(defaults.integer(forKey: "hotkeyCode")),
                      modifiers: UInt32(defaults.integer(forKey: "hotkeyMods")))
    }

    func save() {
        defaults.set(Int(keyCode), forKey: "hotkeyCode")
        defaults.set(Int(modifiers), forKey: "hotkeyMods")
        defaults.set(display, forKey: "hotkeyDisplay")
    }
}

// Slider stops for idle auto-blackout; 0 = off (rightmost).
let idleStops = [1, 2, 3, 5, 10, 15, 30, 60, 0]

var idleMinutes: Int {
    get { defaults.object(forKey: "idleMinutes") as? Int ?? 5 }
    set { defaults.set(newValue, forKey: "idleMinutes") }
}

// Last non-black brightness, restored by the hotkey after a blackout.
var savedLevel: Double {
    get { defaults.object(forKey: "level") as? Double ?? 1 }
    set { defaults.set(newValue, forKey: "level") }
}

let virtualResolutions: [(UInt32, UInt32)] = [(1280, 720), (1920, 1080), (2560, 1440), (3840, 2160)]

var virtualResolution: (UInt32, UInt32)? {
    get {
        let p = (defaults.string(forKey: "virtualResolution") ?? "").split(separator: "x").compactMap { UInt32($0) }
        return p.count == 2 ? (p[0], p[1]) : nil
    }
    set { defaults.set(newValue.map { "\($0.0)x\($0.1)" } ?? "", forKey: "virtualResolution") }
}

var mirrorEnabled: Bool {
    get { defaults.object(forKey: "mirror") as? Bool ?? true }
    set { defaults.set(newValue, forKey: "mirror") }
}

// MARK: - Brightness (gamma)

// Each display's ColorSync gamma, captured so dimming scales the calibrated curve instead of replacing it.
var baseTables: [CGDirectDisplayID: ([CGGammaValue], [CGGammaValue], [CGGammaValue])] = [:]
// The displays that were online when baseTables was captured.
var capturedDisplays: Set<CGDirectDisplayID> = []

func onlineDisplays() -> [CGDirectDisplayID] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &n)
    return Array(ids.prefix(Int(n)))
}

func captureBaseTables() {
    CGDisplayRestoreColorSyncSettings()
    baseTables = [:]
    let ids = onlineDisplays()
    capturedDisplays = Set(ids)
    for id in ids {
        var r = [CGGammaValue](repeating: 0, count: 1024), g = r, b = r; var n: UInt32 = 0
        guard CGGetDisplayTransferByTable(id, 1024, &r, &g, &b, &n) == .success, n > 0 else { continue }
        baseTables[id] = (Array(r.prefix(Int(n))), Array(g.prefix(Int(n))), Array(b.prefix(Int(n))))
    }
}

func applyGamma(_ level: Double) {
    if level >= 0.999 { CGDisplayRestoreColorSyncSettings(); return }
    let k = CGGammaValue(max(0, level))
    for id in onlineDisplays() {
        if let (r, g, b) = baseTables[id] {
            var rr = r.map { $0 * k }, gg = g.map { $0 * k }, bb = b.map { $0 * k }
            CGSetDisplayTransferByTable(id, UInt32(rr.count), &rr, &gg, &bb)
        } else {
            var lo: [CGGammaValue] = [0, k]
            CGSetDisplayTransferByTable(id, 2, &lo, &lo, &lo)
        }
    }
}

// Hardware (backlight) brightness through the private DisplayServices framework, the same call the
// system brightness slider uses. Displays without a controllable backlight (virtual ones) just fail.
let displayServices = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
typealias DSGetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
typealias DSSetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
let dsGet = dlsym(displayServices, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: DSGetBrightness.self) }
let dsSet = dlsym(displayServices, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: DSSetBrightness.self) }

func hardwareBrightness() -> Double? {
    guard let dsGet else { return nil }
    for id in onlineDisplays() where id != virtualDisplay?.displayID {
        var b: Float = 0
        if dsGet(id, &b) == 0 { return Double(b) }
    }
    return nil
}

func setHardwareBrightness(_ v: Double) {
    guard let dsSet else { return }
    for id in onlineDisplays() where id != virtualDisplay?.displayID { _ = dsSet(id, Float(v)) }
}

// Combined brightness: the upper half of the slider drives the backlight, the lower half keeps the
// backlight at minimum and dims further in software down to black.
func hardwarePart(_ level: Double) -> Double { max(0, min(1, (level - 0.5) * 2)) }

// Fraction of the minimum-backlight luminance the lower half leaves on screen, linear in the slider.
func softwareDimPart(_ level: Double) -> Double { max(0, min(1, level * 2)) }

// Gamma output scale for that luminance. Luminance goes roughly with the encoded value to the power
// 2.2, so scaling the encoded value linearly would make most of the lower half near-black, and the
// XDR's local dimming switches zones fully off well before black.
func gammaPart(_ level: Double) -> Double { pow(softwareDimPart(level), 1 / 2.2) }

func applyLevel(_ level: Double) {
    setHardwareBrightness(hardwarePart(level))
    applyGamma(gammaPart(level))
}

// Seconds since the last HID event. Synthetic input from automation also resets this,
// so it only ever triggers blacking out, never restoring.
func hidIdleSeconds() -> Double {
    let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
    defer { IOObjectRelease(svc) }
    guard let v = IORegistryEntryCreateCFProperty(svc, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? NSNumber else { return 0 }
    return v.doubleValue / 1e9
}

// MARK: - Agent display (virtual)

var virtualDisplay: CGVirtualDisplay?

func setVirtualDisplay(_ size: (UInt32, UInt32)?) {
    if virtualDisplay != nil { log("agent display removed") }
    virtualDisplay = nil
    guard let (w, h) = size else { return }
    let desc = CGVirtualDisplayDescriptor()
    desc.queue = .main
    desc.name = "Agent Display"
    desc.maxPixelsWide = w * 2
    desc.maxPixelsHigh = h * 2
    desc.sizeInMillimeters = CGSize(width: 600, height: 340)
    desc.productID = 0x5348; desc.vendorID = 0x3456; desc.serialNum = 1
    desc.terminationHandler = { _, _ in log("agent display terminated") }
    guard let d = CGVirtualDisplay(descriptor: desc) else { log("agent display create failed"); return }
    let settings = CGVirtualDisplaySettings()
    settings.hiDPI = 0
    settings.modes = [CGVirtualDisplayMode(width: w, height: h, refreshRate: 60)]
    guard d.apply(settings) else { log("agent display applySettings failed"); return }
    virtualDisplay = d
    log("agent display id=\(d.displayID) \(w)x\(h)")
}

// Mirror the agent display onto the physical main display, or undo it. When the physical display
// goes away the mirror set dissolves on its own and the agent display becomes main.
func syncMirror() {
    guard let v = virtualDisplay?.displayID else { return }
    let current = CGDisplayMirrorsDisplay(v)
    let master = mirrorEnabled ? onlineDisplays().first { $0 != v && CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay } : nil
    let target = master ?? kCGNullDirectDisplay
    guard current != target else { return }
    var cfg: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&cfg) == .success else { return }
    CGConfigureDisplayMirrorOfDisplay(cfg, v, target)
    let err = CGCompleteDisplayConfiguration(cfg, .forSession)
    log(target == kCGNullDirectDisplay ? "mirror off (\(err.rawValue))" : "mirror agent→\(target) (\(err.rawValue))")
}

var mirrorWork: DispatchWorkItem?

// Display changes arrive in bursts; settle before touching the mirror configuration.
func scheduleMirrorSync() {
    mirrorWork?.cancel()
    let w = DispatchWorkItem { syncMirror() }
    mirrorWork = w
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
}

// MARK: - Launch at login

func loginItemStatus() -> String {
    switch SMAppService.mainApp.status {
    case .enabled: return "enabled"
    case .requiresApproval: return "requiresApproval"
    case .notRegistered: return "notRegistered"
    case .notFound: return "notFound"
    @unknown default: return "unknown"
    }
}

func setLoginItem(_ on: Bool) throws {
    if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    log("login item \(on ? "on" : "off") → \(loginItemStatus())")
}

// MARK: - Hotkey formatting

func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
    var m: UInt32 = 0
    if flags.contains(.control) { m |= UInt32(controlKey) }
    if flags.contains(.option) { m |= UInt32(optionKey) }
    if flags.contains(.shift) { m |= UInt32(shiftKey) }
    if flags.contains(.command) { m |= UInt32(cmdKey) }
    return m
}

func cocoaModifiers(_ m: UInt32) -> NSEvent.ModifierFlags {
    var flags: NSEvent.ModifierFlags = []
    if m & UInt32(controlKey) != 0 { flags.insert(.control) }
    if m & UInt32(optionKey) != 0 { flags.insert(.option) }
    if m & UInt32(shiftKey) != 0 { flags.insert(.shift) }
    if m & UInt32(cmdKey) != 0 { flags.insert(.command) }
    return flags
}

func modifierSymbols(_ flags: NSEvent.ModifierFlags) -> String {
    (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
        + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
}

let specialKeys: [Int: String] = [
    kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
    kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
    kVK_F19: "F19", kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
    kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑",
    kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
]
// Numeric keypad keys, named apart from the main-row keys that type the same character.
let keypadKeys: [Int: String] = [
    kVK_ANSI_Keypad0: "0", kVK_ANSI_Keypad1: "1", kVK_ANSI_Keypad2: "2", kVK_ANSI_Keypad3: "3",
    kVK_ANSI_Keypad4: "4", kVK_ANSI_Keypad5: "5", kVK_ANSI_Keypad6: "6", kVK_ANSI_Keypad7: "7",
    kVK_ANSI_Keypad8: "8", kVK_ANSI_Keypad9: "9", kVK_ANSI_KeypadDecimal: ".", kVK_ANSI_KeypadMultiply: "*",
    kVK_ANSI_KeypadPlus: "+", kVK_ANSI_KeypadMinus: "-", kVK_ANSI_KeypadDivide: "/",
    kVK_ANSI_KeypadEquals: "=", kVK_ANSI_KeypadClear: "⌧", kVK_ANSI_KeypadEnter: "⌤",
]

// The unshifted character a key types in the current keyboard layout (falling back to an ASCII
// layout when the current input source, e.g. an input method, has no layout data).
func layoutCharacter(_ code: Int) -> String? {
    let sources: [() -> Unmanaged<TISInputSource>?] = [TISCopyCurrentKeyboardLayoutInputSource,
                                                       TISCopyCurrentASCIICapableKeyboardLayoutInputSource]
    for copy in sources {
        guard let src = copy()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { continue }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var n = 0
        let status = data.withUnsafeBytes { buf -> OSStatus in
            guard let layout = buf.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, 4, &n, &chars)
        }
        let s = String(utf16CodeUnits: chars, count: n).trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        if status == noErr, !s.isEmpty { return s }
    }
    return nil
}

func keyName(_ code: Int) -> String {
    if let s = specialKeys[code] { return s }
    if let s = keypadKeys[code] { return "Keypad " + s }
    return layoutCharacter(code)?.uppercased() ?? "Key \(code)"
}

let functionKeys: Set<Int> = Set([kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
                                  kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
                                  kVK_F16, kVK_F17, kVK_F18, kVK_F19])

// MARK: - App

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    var hotkey = Hotkey.load()
    var hotkeyRef: EventHotKeyRef?
    var level = 1.0  // current software brightness, 0 = black
    var lastManualChange = Date()
    var sessionLocked = false
    var recorder: NSPanel?
    var recorderMonitor: Any?
    var recorderObservers: [NSObjectProtocol] = []
    var displayRefreshWork: DispatchWorkItem?
    weak var levelSlider: NSSlider?
    weak var toggleItem: NSMenuItem?
    weak var idleLabelItem: NSMenuItem?
    weak var brightnessLabelItem: NSMenuItem?

    var isBlack: Bool { level <= 0 }

    // Software dim and black are temporary states: restoring always returns to a native backlight
    // position (the right half of the slider), never to a software-dimmed one.
    static let minRestoreLevel = 0.5
    // Slider positions this close to the left edge snap to black.
    static let blackSnap = 0.02

    func applicationDidFinishLaunching(_ note: Notification) {
        migrateLegacySettings()
        hotkey = Hotkey.load()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            app.toggle(reason: "hotkey"); return noErr
        }, 1, &spec, nil, nil)
        if !registerHotkey(hotkey) { hotkey = .fallback; _ = registerHotkey(hotkey) }

        setVirtualDisplay(virtualResolution)
        scheduleMirrorSync()
        captureBaseTables()
        // Respect the backlight the system already has, unless we had pushed it to minimum ourselves
        // (software dim / black out) and didn't get to put it back, e.g. after a crash.
        if savedLevel < 0.5 || defaults.bool(forKey: "overridingBacklight") { setLevel(restoreLevel, reason: "startup") }
        else { syncFromHardware(); setLevel(level, reason: "startup") }

        // Display hot-plug (e.g. XDR powered back on) resets gamma and mirroring; reapply both.
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            if !flags.contains(.beginConfigurationFlag) { DispatchQueue.main.async { app.displaysChanged() } }
        }, nil)

        // The hotkey doesn't reach us on the lock screen, so never leave it dark: bring the
        // brightness back when the session locks.
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"),
                                                            object: nil, queue: .main) { [unowned self] _ in
            sessionLocked = true
            if level < App.minRestoreLevel { setLevel(restoreLevel, reason: "lock") }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsUnlocked"),
                                                            object: nil, queue: .main) { [unowned self] _ in
            sessionLocked = false
            lastManualChange = Date()
        }

        // Common modes, so this keeps running while the menu is open or an alert is up.
        let timer = Timer(timeInterval: 2, repeats: true) { [unowned self] _ in
            // ColorSync / Night Shift can rewrite gamma behind our back
            if gammaPart(level) < 0.999 { applyGamma(gammaPart(level)) }
            // A restore by signal or menu doesn't reset the HID idle clock, so also require a full idle
            // period since the last manual change; otherwise we'd black out again right away.
            let threshold = Double(idleMinutes * 60)
            if !isBlack && !sessionLocked && idleMinutes > 0 && hidIdleSeconds() >= threshold
                && Date().timeIntervalSince(lastManualChange) >= threshold {
                setLevel(0, reason: "idle")
                closeMenu()  // an open menu would swallow the hotkey on the now black screen
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        log("\(appName) started, hotkey=\(hotkey.display) idle=\(idleMinutes)min level=\(level) "
            + "agentDisplay=\(virtualResolution.map { "\($0.0)x\($0.1)" } ?? "off") mirror=\(mirrorEnabled)")
    }

    func applicationWillTerminate(_ note: Notification) {
        if level < 0.5 {
            setHardwareBrightness(hardwarePart(restoreLevel))
            defaults.set(false, forKey: "overridingBacklight")
        }
        CGDisplayRestoreColorSyncSettings()
        log("exit")
    }

    // The reconfiguration callback fires once per display per change, in bursts. Reapply the dimming
    // right away with the tables we have (no restore, so no flash), and only recapture the ColorSync
    // tables, which briefly restores the normal picture, once the burst settles and only if the set of
    // displays actually changed.
    func displaysChanged() {
        if level < 0.5 { applyLevel(level) }
        scheduleMirrorSync()
        displayRefreshWork?.cancel()
        let w = DispatchWorkItem { [unowned self] in
            guard Set(onlineDisplays()) != capturedDisplays else { return }
            captureBaseTables()
            if level < 0.5 { applyLevel(level) }
        }
        displayRefreshWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    // MARK: Brightness

    func setLevel(_ new: Double, reason: String) {
        let wasBlack = isBlack
        if reason != "idle" { lastManualChange = Date() }
        // The restore target is only committed when the menu closes (see menuDidClose), so values
        // passed through while dragging toward black never become it.
        level = new < App.blackSnap ? 0 : min(1, new)
        defaults.set(level < 0.5, forKey: "overridingBacklight")
        applyLevel(level)
        updateIcon()
        levelSlider?.doubleValue = level
        toggleItem?.attributedTitle = toggleTitle()
        brightnessLabelItem?.title = brightnessLabel()
        if isBlack != wasBlack || reason != "slider" { log("level \(String(format: "%.2f", level)) (\(reason))") }
    }

    func toggle(reason: String) {
        if !isBlack { syncFromHardware() }  // remember the backlight as the user last left it
        setLevel(isBlack ? restoreLevel : 0, reason: reason)
    }

    var restoreLevel: Double { max(savedLevel, App.minRestoreLevel) }

    // The backlight can be changed from the keyboard or System Settings; follow it while we're
    // not dimming in software.
    func syncFromHardware() {
        guard level >= 0.5, let hw = hardwareBrightness() else { return }
        level = App.level(fromHardware: hw)
        savedLevel = level
    }

    static func level(fromHardware hw: Double) -> Double { 0.5 + hw / 2 }

    // A display, with a small moon on its screen when blacked out or a sun when dimmed in software.
    func updateIcon() {
        let display = NSImage(systemSymbolName: "display", accessibilityDescription: appName)!
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))!
        let badgeName = isBlack ? "moon.fill" : (level < App.minRestoreLevel ? "sun.min.fill" : nil)
        let badge = badgeName.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
            .withSymbolConfiguration(.init(pointSize: 7, weight: .bold))
        let size = display.size
        let img = NSImage(size: size, flipped: false) { rect in
            display.draw(in: rect)
            if let badge {
                // Centered on the screen area, which sits in the upper part of the glyph.
                let b = badge.size
                badge.draw(in: NSRect(x: (size.width - b.width) / 2, y: size.height * 0.6 - b.height / 2,
                                      width: b.width, height: b.height))
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = appName
        statusItem.button?.image = img
    }

    @objc func levelSliderChanged(_ s: NSSlider) {
        setLevel(s.doubleValue, reason: "slider")
        // An open menu swallows every key, including the hotkey and ⌃⌘Q, and can't be seen once the
        // screen is black, so close it the moment the slider reaches black.
        if isBlack { closeMenu() } else { closeMenuOnRelease() }
    }

    // Like a regular menu item, finishing a slider adjustment (mouse up) closes the menu.
    func closeMenuOnRelease() {
        if NSApp.currentEvent?.type == .leftMouseUp { closeMenu() }
    }

    func closeMenu() { DispatchQueue.main.async { self.statusItem.menu?.cancelTracking() } }

    func brightnessLabel() -> String {
        if isBlack { return "Brightness: Off (black)" }
        if level < 0.5 { return "Brightness: Software Dim \(Int((softwareDimPart(level) * 100).rounded()))%" }
        return "Brightness: Native Backlight \(Int((hardwarePart(level) * 100).rounded()))%"
    }

    // Slider with a caption row explaining its two halves.
    func brightnessSliderItem(_ slider: NSSlider) -> NSMenuItem {
        let item = sliderItem(slider, height: 52)
        guard let view = item.view else { return item }
        let half = App.sliderWidth / 2
        for (i, text) in ["Software Dim", "Native Backlight"].enumerated() {
            let l = NSTextField(labelWithString: text)
            l.font = .systemFont(ofSize: 10)
            l.textColor = .tertiaryLabelColor
            l.alignment = .center
            l.frame = NSRect(x: App.sliderX + CGFloat(i) * half, y: 8, width: half, height: 13)
            view.addSubview(l)
        }
        slider.numberOfTickMarks = 3  // marks the software / backlight boundary in the middle
        slider.toolTip = """
            Left half: backlight stays at minimum and the picture is dimmed in software (gamma), \
            down to fully black at the far left.
            Right half: the display's native backlight, same as the system brightness control.
            Screenshots are unaffected by software dimming.
            """
        return item
    }

    @objc func idleSliderChanged(_ s: NSSlider) {
        closeMenuOnRelease()
        let m = idleStops[min(idleStops.count - 1, max(0, Int(s.doubleValue.rounded())))]
        guard m != idleMinutes else { return }
        idleMinutes = m
        idleLabelItem?.title = idleLabel()
        log("idle set to \(m)min")
    }

    func idleLabel() -> String {
        idleMinutes == 0 ? "Idle Black-out: Off" : "Black Out After \(idleMinutes) min Idle"
    }

    // Layout shared by both sliders: the track spans from the menu's text edge to its
    // key-equivalent column, and the view is wide enough to set the menu's width.
    static let menuWidth: CGFloat = 300
    static let sliderX: CGFloat = 15
    static let sliderWidth: CGFloat = menuWidth - sliderX - 18

    func sliderItem(_ slider: NSSlider, height: CGFloat = 30) -> NSMenuItem {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: App.menuWidth, height: height))
        let top = height - 30  // room below the slider for captions
        slider.frame = NSRect(x: App.sliderX, y: top + 4, width: App.sliderWidth, height: 22)
        view.addSubview(slider)
        let item = NSMenuItem()
        item.view = view
        return item
    }

    // MARK: Hotkey

    @discardableResult
    func registerHotkey(_ hk: Hotkey) -> Bool {
        if let ref = hotkeyRef { UnregisterEventHotKey(ref); hotkeyRef = nil }
        let id = EventHotKeyID(signature: OSType(0x58445241), id: 1)  // 'XDRA'
        let status = RegisterEventHotKey(hk.keyCode, hk.modifiers, id, GetApplicationEventTarget(), 0, &hotkeyRef)
        log(status == noErr ? "hotkey \(hk.display) registered" : "hotkey \(hk.display) failed: \(status)")
        return status == noErr
    }

    @objc func recordHotkey() {
        if let recorder {  // already recording: bring that panel back instead of opening a second one
            NSApp.activate(ignoringOtherApps: true)
            recorder.makeKeyAndOrderFront(nil)
            return
        }
        if let ref = hotkeyRef { UnregisterEventHotKey(ref); hotkeyRef = nil }  // let the current combo be re-recorded

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 110),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Set Shortcut"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        let label = NSTextField(wrappingLabelWithString: "Press the new shortcut\n(must include ⌘ ⌥ ⌃, or use F1–F19)\nEsc to cancel")
        label.alignment = .center
        label.frame = NSRect(x: 20, y: 20, width: 280, height: 70)
        panel.contentView?.addSubview(label)
        panel.center()
        recorder = panel

        recorderMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [unowned self] e in
            let code = Int(e.keyCode)
            if code == kVK_Escape { finishRecording(nil); return nil }
            let flags = e.modifierFlags.intersection([.control, .option, .shift, .command])
            guard !flags.intersection([.control, .option, .command]).isEmpty || functionKeys.contains(code) else {
                label.stringValue = "Must include ⌘ ⌥ ⌃\n(or use F1–F19), try again\nEsc to cancel"
                return nil
            }
            finishRecording(Hotkey(keyCode: UInt32(code), modifiers: carbonModifiers(flags)))
            return nil
        }
        // Closing the panel or switching away from it cancels, so the old hotkey never stays unregistered.
        recorderObservers = [NSWindow.willCloseNotification, NSWindow.didResignKeyNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) {
                [unowned self] _ in if recorderMonitor != nil { finishRecording(nil) }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func finishRecording(_ new: Hotkey?) {
        if let m = recorderMonitor { NSEvent.removeMonitor(m); recorderMonitor = nil }
        recorderObservers.forEach { NotificationCenter.default.removeObserver($0) }
        recorderObservers = []
        recorder?.close(); recorder = nil
        if let new, registerHotkey(new) {
            hotkey = new
            hotkey.save()
        } else {
            if let new {
                let alert = NSAlert()
                alert.messageText = "Shortcut \(new.display) could not be registered"
                alert.informativeText = "It may be taken by the system or another app. Keeping \(hotkey.display)."
                alert.runModal()
            }
            registerHotkey(hotkey)
        }
    }

    // MARK: Menu

    // "🌙 Black Out Now" / "☀ Restore Brightness", with the symbol drawn inline (this macOS
    // doesn't render NSMenuItem.image in status menus).
    func toggleTitle() -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        let symbol = NSImage(systemSymbolName: isBlack ? "sun.max.fill" : "moon.fill", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: font.pointSize, weight: .regular)
                .applying(.init(paletteColors: [.labelColor])))!
        let attachment = NSTextAttachment()
        attachment.image = symbol
        attachment.bounds = NSRect(x: 0, y: font.descender + 1, width: symbol.size.width, height: symbol.size.height)
        let s = NSMutableAttributedString(attachment: attachment)
        s.append(NSAttributedString(string: "  " + (isBlack ? "Restore Brightness" : "Black Out Now"),
                                    attributes: [.font: font]))
        return s
    }

    // Menu key equivalent that displays the same combo as the global hotkey.
    func keyEquivalent(for hk: Hotkey) -> (String, NSEvent.ModifierFlags)? {
        let mods = cocoaModifiers(hk.modifiers)
        let code = Int(hk.keyCode)
        // A menu key equivalent can't tell keypad keys from main-row ones; show none rather than a wrong one.
        if keypadKeys[code] != nil { return nil }
        let special: [Int: Int] = [
            kVK_Space: 0x20, kVK_Return: 0x0D, kVK_Tab: 0x09, kVK_Delete: 0x08,
            kVK_ForwardDelete: NSDeleteFunctionKey, kVK_LeftArrow: NSLeftArrowFunctionKey,
            kVK_RightArrow: NSRightArrowFunctionKey, kVK_UpArrow: NSUpArrowFunctionKey,
            kVK_DownArrow: NSDownArrowFunctionKey, kVK_Home: NSHomeFunctionKey, kVK_End: NSEndFunctionKey,
            kVK_PageUp: NSPageUpFunctionKey, kVK_PageDown: NSPageDownFunctionKey,
        ]
        let fKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                     kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19]
        if let i = fKeys.firstIndex(of: code) { return (String(UnicodeScalar(NSF1FunctionKey + i)!), mods) }
        if let u = special[code] { return (String(UnicodeScalar(u)!), mods) }
        // Printable key: its unshifted character, so ⇧ shows as a modifier rather than a shifted symbol.
        guard let key = layoutCharacter(code)?.lowercased(), key.count == 1 else { return nil }
        return (key, mods)
    }

    // The hotkey shown on "Black Out Now" is informational; the global hotkey does the work.
    func menuHasKeyEquivalent(_ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
                              action: UnsafeMutablePointer<Selector?>) -> Bool { false }

    func menuItem(_ title: String, _ action: Selector?, tag: Int = 0, on: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.tag = tag
        item.state = on ? .on : .off
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        syncFromHardware()
        updateIcon()

        // Black out
        let toggle = menuItem(isBlack ? "Restore Brightness" : "Black Out Now", #selector(menuToggle))
        toggle.attributedTitle = toggleTitle()
        // The global hotkey, shown in the native key-equivalent column; menuHasKeyEquivalent keeps it
        // display-only (the hotkey itself is handled globally).
        if let (key, mods) = keyEquivalent(for: hotkey) {
            toggle.keyEquivalent = key
            toggle.keyEquivalentModifierMask = mods
        }
        toggleItem = toggle
        menu.addItem(toggle)
        menu.addItem(menuItem("Set Shortcut…", #selector(recordHotkey)))
        menu.addItem(.separator())

        // Brightness
        let bl = NSMenuItem(title: brightnessLabel(), action: nil, keyEquivalent: "")
        bl.isEnabled = false
        brightnessLabelItem = bl
        menu.addItem(bl)
        let ls = NSSlider(value: level, minValue: 0, maxValue: 1, target: self, action: #selector(levelSliderChanged(_:)))
        ls.isContinuous = true
        levelSlider = ls
        menu.addItem(brightnessSliderItem(ls))
        menu.addItem(.separator())

        // Idle auto-blackout
        let idleLabel = NSMenuItem(title: idleLabel(), action: nil, keyEquivalent: "")
        idleLabel.isEnabled = false
        idleLabelItem = idleLabel
        menu.addItem(idleLabel)
        let idx = idleStops.firstIndex(of: idleMinutes) ?? idleStops.firstIndex(of: 5)!
        let isl = NSSlider(value: Double(idx), minValue: 0, maxValue: Double(idleStops.count - 1),
                           target: self, action: #selector(idleSliderChanged(_:)))
        isl.numberOfTickMarks = idleStops.count
        isl.allowsTickMarkValuesOnly = true
        isl.isContinuous = true
        menu.addItem(sliderItem(isl))
        menu.addItem(.separator())

        // Agent display
        let current = virtualResolution
        let virtMenu = NSMenu()
        virtMenu.addItem(menuItem("Off", #selector(setVirtual(_:)), tag: -1, on: current == nil))
        virtMenu.addItem(.separator())
        for (i, (w, h)) in virtualResolutions.enumerated() {
            let on = current.map { $0 == (w, h) } ?? false
            virtMenu.addItem(menuItem("\(w) × \(h)", #selector(setVirtual(_:)), tag: i, on: on))
        }
        virtMenu.addItem(.separator())
        virtMenu.addItem(menuItem("Mirror Main Display", #selector(toggleMirror), on: mirrorEnabled))
        let virtItem = NSMenuItem(title: "Agent Display: " + (current.map { "\($0.0) × \($0.1)" } ?? "Off"),
                                  action: nil, keyEquivalent: "")
        virtItem.submenu = virtMenu
        menu.addItem(virtItem)
        menu.addItem(.separator())

        // State in the title rather than a checkmark: a checked item makes the menu reserve a state
        // column, which shifts every title off the sliders' edge.
        let loginOn = SMAppService.mainApp.status == .enabled
        menu.addItem(menuItem("Launch at Login: " + (loginOn ? "On" : "Off"), #selector(toggleLoginItem)))
        menu.addItem(NSMenuItem(title: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    func menuDidClose(_ menu: NSMenu) {
        if level >= App.minRestoreLevel { savedLevel = level }
    }

    @objc func menuToggle() { toggle(reason: "menu") }

    @objc func setVirtual(_ sender: NSMenuItem) {
        let size = sender.tag < 0 ? nil : virtualResolutions[sender.tag]
        // Re-picking the current choice would tear the display down and rebuild it for nothing.
        let unchanged = size.map { s in virtualDisplay != nil && virtualResolution.map { $0 == s } == true }
            ?? (virtualDisplay == nil)
        guard !unchanged else { return }
        virtualResolution = size
        setVirtualDisplay(size)
        scheduleMirrorSync()
    }

    @objc func toggleLoginItem() {
        do {
            try setLoginItem(SMAppService.mainApp.status != .enabled)
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc func toggleMirror() {
        mirrorEnabled.toggle()
        scheduleMirrorSync()
    }
}

// MARK: - Main

// `XDRAgentScreen --login-item status|on|off` manages Launch at Login without the UI.
if let i = CommandLine.arguments.firstIndex(of: "--login-item") {
    let arg = CommandLine.arguments.dropFirst(i + 1).first ?? "status"
    do {
        if arg == "on" || arg == "off" { try setLoginItem(arg == "on") }
        print(loginItemStatus())
        exit(0)
    } catch {
        print("error: \(error.localizedDescription)")
        exit(1)
    }
}

let nsApp = NSApplication.shared

// Only one copy, however it was launched (login item, Finder, `open`).
if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
    .contains(where: { $0.processIdentifier != getpid() }) {
    log("another instance is running; exiting")
    exit(0)
}

let app = App()
nsApp.delegate = app
nsApp.setActivationPolicy(.accessory)

let signalSources = [SIGTERM, SIGINT].map { sig -> DispatchSourceSignal in
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { NSApp.terminate(nil) }
    src.resume()
    return src
}

// `kill -USR1 <pid>` pops the menu open for 5 seconds, for taking screenshots of it.
signal(SIGUSR1, SIG_IGN)
let menuPeek = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
menuPeek.setEventHandler {
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { app.statusItem.menu?.cancelTracking() }
    app.statusItem.button?.performClick(nil)
}
menuPeek.resume()

// `kill -USR2 <pid>` toggles black out, same as the hotkey (for scripts and remote sessions).
signal(SIGUSR2, SIG_IGN)
let remoteToggle = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
remoteToggle.setEventHandler { app.toggle(reason: "signal") }
remoteToggle.resume()

nsApp.run()
