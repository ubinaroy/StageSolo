// StageSolo — with Stage Manager on several screens, clicking a thumbnail in one screen's strip
// switches only that screen, even when the app also has windows on the other screens.
//
// Stage Manager brings an app forward on every screen where it has windows. StageSolo catches presses
// on strip thumbnails of such apps (or of groups containing one) and instead focuses a single window,
// the front one of the pressed group (front that window, make it key, raise it — the technique yabai
// uses); Stage Manager then switches that screen only and brings the rest of the group along.
// Like Stage Manager it acts on the press. Needs the Accessibility permission.
import Cocoa
import ServiceManagement
import os

let repoURL = URL(string: "https://github.com/ubinaroy/StageSolo")!
let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "StageSolo", category: "focus")
let chinese = Locale.preferredLanguages.first?.hasPrefix("zh") == true
func L(_ en: String, _ zh: String) -> String { chinese ? zh : en }

// MARK: - Private window-server calls (the same ones yabai uses)

typealias SetFront = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> Int32
typealias PostEvent = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32
typealias GetPSN = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> Int32  // GetProcessForPID is unavailable to Swift
typealias AXGetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

func load<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, as _: T.Type) -> T? {
    dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
}
let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
let setFront = load(sky, "_SLPSSetFrontProcessWithOptions", as: SetFront.self)
let postEvent = load(sky, "SLPSPostEventRecordTo", as: PostEvent.self)
let getPSN = load(rtldDefault, "GetProcessForPID", as: GetPSN.self)
let axGetWindow = load(rtldDefault, "_AXUIElementGetWindow", as: AXGetWindow.self)
let supported = setFront != nil && postEvent != nil && getPSN != nil && axGetWindow != nil

// MARK: - Windows

// Stage Manager draws each strip thumbnail as the app's real window scaled down, and the window list
// reports it at that size. Over each thumbnail Stage Manager puts its own windows (process
// "WindowManager"): a hit area of the same size and an app-icon badge on the bottom-left corner.
// Windows grouped into one stage show up as overlapping thumbnails.
let thumbnailMaxSize: CGFloat = 300  // thumbnails are ~70–170 pt
let stripEdgeMargin: CGFloat = 150   // thumbnails sit ~15 pt from the screen edge; a group fans out further
let clickZone: CGFloat = 250         // only clicks this close to a screen edge are looked at
let groupOverlap: CGFloat = 0.25     // grouped thumbnails overlap by ~50% of the smaller one

struct Win { let id: CGWindowID; let pid: pid_t; let owner: String; let frame: CGRect; let display: CGDirectDisplayID }

func stageManagerOn() -> Bool {
    CFPreferencesAppSynchronize("com.apple.WindowManager" as CFString)
    return CFPreferencesCopyAppValue("GloballyEnabled" as CFString, "com.apple.WindowManager" as CFString) as? Bool ?? false
}

func display(at p: CGPoint) -> CGDirectDisplayID? {
    var d: CGDirectDisplayID = 0, count: UInt32 = 0
    return CGGetDisplaysWithPoint(p, 1, &d, &count) == .success && count > 0 ? d : nil
}

// On-screen normal windows, front to back.
func windows() -> [Win] {
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return info.compactMap { w in
        guard w[kCGWindowLayer as String] as? Int == 0, (w[kCGWindowAlpha as String] as? Double ?? 0) > 0,
              let f = CGRect(dictionaryRepresentation: w[kCGWindowBounds as String] as! CFDictionary),
              f.width > 50, f.height > 50, let d = display(at: CGPoint(x: f.midX, y: f.midY)) else { return nil }
        return Win(id: w[kCGWindowNumber as String] as! CGWindowID, pid: w[kCGWindowOwnerPID as String] as! pid_t,
                   owner: w[kCGWindowOwnerName as String] as? String ?? "", frame: f, display: d)
    }
}

// A strip thumbnail: an app window shown small against the left or right edge of its screen.
func isThumbnail(_ w: Win) -> Bool {
    let b = CGDisplayBounds(w.display)
    return w.owner != "WindowManager" && w.frame.width < thumbnailMaxSize && w.frame.height < thumbnailMaxSize
        && (w.frame.minX - b.minX < stripEdgeMargin || b.maxX - w.frame.maxX < stripEdgeMargin)
}

// The thumbnail a click at p lands on: the topmost window there, or, when that is one of Stage Manager's
// own windows (a hit area or a badge), the thumbnail it overlaps most. nil when p is not on a strip.
func thumbnail(at p: CGPoint, in ws: [Win]) -> Win? {
    guard let top = ws.first(where: { $0.frame.contains(p) }) else { return nil }
    if isThumbnail(top) { return top }
    guard top.owner == "WindowManager", top.frame.width < thumbnailMaxSize, top.frame.height < thumbnailMaxSize else { return nil }
    let overlap = { (w: Win) -> CGFloat in let r = w.frame.intersection(top.frame); return r.isNull ? 0 : r.width * r.height }
    return ws.filter { isThumbnail($0) && $0.display == top.display && overlap($0) > 0 }.max { overlap($0) < overlap($1) }
}

// The thumbnail plus every thumbnail stacked with it, directly or through others: one stage in the strip.
// Grouped windows overlap by about half; separate thumbnails only touch by a few points while one is hovered.
func group(of t: Win, in ws: [Win]) -> [Win] {
    let thumbs = ws.filter { isThumbnail($0) && $0.display == t.display }
    func stacked(_ a: Win, _ b: Win) -> Bool {
        let r = a.frame.intersection(b.frame)
        return !r.isNull && r.width * r.height >= groupOverlap * min(a.frame.width * a.frame.height, b.frame.width * b.frame.height)
    }
    var members = [t]
    while let next = thumbs.first(where: { c in !members.contains { $0.id == c.id } && members.contains { stacked($0, c) } }) {
        members.append(next)
    }
    return members
}

func alsoOnAnotherScreen(_ w: Win, in ws: [Win]) -> Bool {
    ws.contains { $0.pid == w.pid && $0.display != w.display && $0.owner != "WindowManager" }
}

// Bring just this window forward: front its app with only this window, make it key, raise it.
func focus(_ t: Win) {
    guard let setFront, let postEvent, let getPSN, let axGetWindow else { return }
    var psn = ProcessSerialNumber()
    _ = getPSN(t.pid, &psn)
    let front = setFront(&psn, t.id, 0x200)  // kCPSUserGenerated, without 0x100 (all windows)
    for kind: UInt8 in [1, 2] {              // make key: synthesized events, as in yabai
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8; bytes[0x08] = kind; bytes[0x3a] = 0x10
        for i in 0..<16 { bytes[0x20 + i] = 0xff }
        withUnsafeBytes(of: t.id) { for i in 0..<4 { bytes[0x3c + i] = $0[i] } }
        _ = postEvent(&psn, &bytes)
    }
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(AXUIElementCreateApplication(t.pid), kAXWindowsAttribute as CFString, &value)
    let ax = (value as? [AXUIElement] ?? []).first { var id: CGWindowID = 0; return axGetWindow($0, &id) == .success && id == t.id }
    let raise = ax.map { AXUIElementPerformAction($0, kAXRaiseAction as CFString).rawValue } ?? -1
    logger.notice("\(t.owner, privacy: .public) window \(t.id) on display \(t.display): front=\(front) raise=\(raise)")
}

// MARK: - Mouse event tap

var tap: CFMachPort?
var paused = false
var swallowing = false  // the rest of a press StageSolo took over: its drags and release
let modifiers: CGEventFlags = [.maskShift, .maskAlternate, .maskCommand, .maskControl]
let focusQueue = DispatchQueue(label: "StageSolo.focus")

// Decide about a press. Returns true when StageSolo takes it over.
func takeOver(_ event: CGEvent) -> Bool {
    let p = event.location
    guard let d = display(at: p) else { return false }
    let b = CGDisplayBounds(d)
    guard p.x - b.minX < clickZone || b.maxX - p.x < clickZone, stageManagerOn() else { return false }
    let ws = windows()
    guard let t = thumbnail(at: p, in: ws) else { return false }
    guard event.flags.intersection(modifiers).isEmpty else {
        logger.info("press on \(t.owner, privacy: .public) \(t.id) with a modifier key: left to Stage Manager")
        return false
    }
    let members = group(of: t, in: ws)
    let spread = members.filter { alsoOnAnotherScreen($0, in: ws) }
    let front = ws.first { w in members.contains { $0.id == w.id } } ?? t  // bring a group back in its own order
    logger.info("press on \(t.owner, privacy: .public) \(t.id); stage \(members.map(\.owner), privacy: .public); also on other screens: \(spread.map(\.owner), privacy: .public)")
    guard !spread.isEmpty else { return false }
    focusQueue.async { focus(front) }
    return true
}

let callback: CGEventTapCallBack = { _, type, event, _ in
    if type == .leftMouseDown && swallowing {  // the release of the last press we took over never came
        logger.info("missed a release; no longer swallowing")
        swallowing = false
    }
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        logger.info("event tap disabled by \(type == .tapDisabledByTimeout ? "timeout" : "user input", privacy: .public); enabling it again")
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    case .leftMouseDown where !paused:
        if takeOver(event) {
            swallowing = true
            return nil  // Stage Manager never sees this press
        }
    case .leftMouseDragged where swallowing:
        return nil
    case .leftMouseUp where swallowing:
        swallowing = false
        logger.info("release swallowed")
        return nil
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}

func startTap() -> Bool {
    let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue | 1 << CGEventType.leftMouseUp.rawValue
                           | 1 << CGEventType.leftMouseDragged.rawValue)
    guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                    eventsOfInterest: mask, callback: callback, userInfo: nil) else { return false }
    tap = t
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
    CGEvent.tapEnable(tap: t, enable: true)
    return true
}

// MARK: - Menu bar item

final class MenuBar: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let status = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let pause = NSMenuItem(title: "", action: #selector(togglePause), keyEquivalent: "")
    let settings = NSMenuItem(title: L("Open Accessibility Settings…", "打开辅助功能设置…"), action: #selector(openSettings), keyEquivalent: "")
    let login = NSMenuItem(title: L("Launch at Login", "登录时启动"), action: #selector(toggleLogin), keyEquivalent: "")

    override init() {
        super.init()
        item.button?.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "StageSolo")
        let about = NSMenuItem(title: L("About StageSolo", "关于 StageSolo"), action: #selector(openAbout), keyEquivalent: "")
        let quit = NSMenuItem(title: L("Quit StageSolo", "退出 StageSolo"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for i in [pause, settings, login, about] { i.target = self }
        quit.target = NSApp
        let menu = NSMenu()
        let items: [NSMenuItem] = [status, .separator(), pause, settings, login, .separator(), about, quit]
        items.forEach(menu.addItem)
        menu.delegate = self
        item.menu = menu
        refresh()
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    func refresh() {
        status.title = !supported ? L("Not supported on this macOS version", "不支持此 macOS 版本")
            : tap == nil ? L("Needs the Accessibility permission", "需要辅助功能权限")
            : paused ? L("Paused", "已暂停")
            : !stageManagerOn() ? L("Stage Manager is off", "台前调度未开启")
            : L("On: a click switches only that screen", "运行中：点缩略图只切这块屏")
        pause.title = paused ? L("Resume", "继续") : L("Pause", "暂停")
        pause.isHidden = tap == nil
        settings.isHidden = tap != nil || !supported
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        item.button?.appearsDisabled = tap == nil || paused
    }

    @objc func togglePause() { paused.toggle(); refresh() }
    @objc func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            logger.error("launch at login: \(error.localizedDescription, privacy: .public)")
        }
        if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        refresh()
    }
    @objc func openAbout() { NSWorkspace.shared.open(repoURL) }
}

// MARK: - Main

let app = NSApplication.shared
if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").count > 1 { exit(0) }
app.setActivationPolicy(.accessory)
var started = false
if supported {
    _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    started = startTap()
} else {
    logger.error("private window-server functions not found; StageSolo stays off")
}
let menuBar = MenuBar()
if supported && !started {
    Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { timer in  // wait for the Accessibility permission
        guard startTap() else { return }
        timer.invalidate()
        menuBar.refresh()
        logger.notice("event tap on")
    }
}
logger.notice("launched; event tap \(started ? "on" : "waiting", privacy: .public)")
app.run()
