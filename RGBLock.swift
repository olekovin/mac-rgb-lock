// RGB Lock: macOS picks YCbCr for some HDMI monitors and renegotiates back to it after every display
// sleep or monitor power cycle, firing no CG/NSWorkspace event (verified). So poll every 5s and
// re-assert RGB Full through IOMobileFramebufferSetDigitalOutMode, the same private DCP call
// BetterDisplay makes (identical "set_digital_out_mode: Modeset requested" in the kernel log).
import AppKit
import IOKit
import ServiceManagement
import SwiftUI

let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/rgb-lock.log")

// MARK: - Private IOMobileFramebuffer API (Apple silicon)

typealias FBRef = UnsafeMutableRawPointer
typealias FBOpen = @convention(c) (io_service_t, mach_port_t, UInt32, UnsafeMutablePointer<FBRef?>) -> kern_return_t
typealias FBGet = @convention(c) (FBRef, UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<UInt32>) -> kern_return_t
typealias FBSet = @convention(c) (FBRef, UInt32, UInt32) -> kern_return_t

struct FBAPI {
    let open: FBOpen, get: FBGet, set: FBSet
    static let shared: FBAPI? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer", RTLD_NOW),
              let o = dlsym(h, "IOMobileFramebufferOpen"),
              let g = dlsym(h, "IOMobileFramebufferGetDigitalOutMode"),
              let s = dlsym(h, "IOMobileFramebufferSetDigitalOutMode") else { return nil }
        return FBAPI(open: unsafeBitCast(o, to: FBOpen.self), get: unsafeBitCast(g, to: FBGet.self),
                     set: unsafeBitCast(s, to: FBSet.self))
    }()
}

typealias Element = [String: Any]

func int(_ e: Element, _ k: String) -> Int { e[k] as? Int ?? -1 }

/// "8-bit RGB Full" / "8-bit YCbCr 4:4:4 Limited"
func describe(_ e: Element) -> String {
    let enc: String
    switch int(e, "PixelEncoding") {
    case 0: enc = "RGB"
    case 3: enc = "YCbCr 4:4:4"
    case let n: enc = "YCbCr (\(n))"
    }
    return "\(int(e, "Depth"))-bit \(enc) \(int(e, "DynamicRange") == 0 ? "Full" : "Limited")"
}

/// One external display's link: its framebuffer and current color/timing elements.
struct Link {
    let name: String
    let fb: FBRef
    let timingID: UInt32
    let color: Element
    let allowed: [Element]  // color elements valid for the current timing

    var isRGB: Bool { int(color, "PixelEncoding") == 0 }

    /// Best real RGB Full SDR element the current timing allows, preferring the current bit depth.
    var rgbTarget: Element? {
        allowed.filter {
            int($0, "PixelEncoding") == 0 && int($0, "DynamicRange") == 0 && int($0, "EOTF") == 0
                && ($0["IsVirtual"] as? Bool) == false
        }.max { a, b in
            let da = int(a, "Depth") == int(color, "Depth"), db = int(b, "Depth") == int(color, "Depth")
            return da != db ? !da : int(a, "Score") < int(b, "Score")
        }
    }
}

var openFBs: [UInt64: FBRef] = [:]  // registry entry ID -> handle; opened once, reused every tick

func search(_ s: io_service_t, _ key: String) -> Any? {
    IORegistryEntrySearchCFProperty(s, kIOServicePlane, key as NSString as CFString, nil,
                                    IOOptionBits(kIORegistryIterateRecursively))
}

func externalLinks(_ api: FBAPI) -> [Link] {
    var it: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebuffer"), &it) == KERN_SUCCESS
    else { return [] }
    defer { IOObjectRelease(it) }
    var links: [Link] = []
    while case let s = IOIteratorNext(it), s != 0 {
        defer { IOObjectRelease(s) }
        guard IORegistryEntryCreateCFProperty(s, "external" as NSString as CFString, nil, 0) != nil else { continue }
        var entry: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(s, &entry)
        if openFBs[entry] == nil {
            var fb: FBRef?
            if api.open(s, mach_task_self_, 0, &fb) == KERN_SUCCESS, let fb { openFBs[entry] = fb }
        }
        var colorID: UInt32 = 0, timingID: UInt32 = 0
        guard let fb = openFBs[entry], api.get(fb, &colorID, &timingID) == KERN_SUCCESS, colorID != 0,
              let colors = search(s, "ColorElements") as? [Element],
              let timings = search(s, "TimingElements") as? [Element],
              let color = colors.first(where: { int($0, "ID") == Int(colorID) }),
              let timing = timings.first(where: { int($0, "ID") == Int(timingID) })
        else { continue }
        let attrs = search(s, "DisplayAttributes") as? Element
        let name = (attrs?["ProductAttributes"] as? Element)?["ProductName"] as? String ?? "External display"
        links.append(Link(name: name, fb: fb, timingID: timingID, color: color,
                          allowed: timing["ColorModes"] as? [Element] ?? []))
    }
    return links
}

// While displays sleep the link reports YCbCr and a modeset is pointless, so don't touch it then.
func externalAwake() -> Bool {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var n: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &n)
    return ids.prefix(Int(n)).contains { CGDisplayIsBuiltin($0) == 0 && CGDisplayIsAsleep($0) == 0 }
}

// MARK: - App

enum LinkState {
    case locked, fixing, asleep, absent, unsupported, paused

    var symbol: String {
        switch self {
        case .locked: "lock.display"
        case .fixing: "display.trianglebadge.exclamationmark"
        case .asleep: "moon.zzz"
        case .absent: "display"
        case .unsupported: "exclamationmark.triangle.fill"
        case .paused: "pause.circle"
        }
    }
    var title: String {
        switch self {
        case .locked: "Locked to RGB"
        case .fixing: "Switching to RGB…"
        case .asleep: "Display asleep"
        case .absent: "No external display"
        case .unsupported: "Can't switch this display"
        case .paused: "Paused"
        }
    }
    var color: Color {
        switch self {
        case .locked: .green
        case .fixing: .orange
        case .unsupported: .red
        case .asleep, .absent, .paused: .secondary
        }
    }
}

func log(_ s: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile()
        h.write(Data(line.utf8))
        try? h.close()
    } else {
        try? line.write(to: logURL, atomically: true, encoding: .utf8)
    }
}

final class Enforcer: ObservableObject {
    @Published var state = LinkState.absent
    @Published var name = "—"
    @Published var mode = ""
    @Published var lastFix: Date?
    @Published var fixes = 0
    @Published var enabled = !UserDefaults.standard.bool(forKey: "paused") {
        didSet {
            UserDefaults.standard.set(!enabled, forKey: "paused")
            let on = enabled
            queue.async { self.active = on; self.tick() }
        }
    }

    private let queue = DispatchQueue(label: "rgb-lock")
    private var active: Bool  // queue-owned copy of `enabled`
    private var timer: DispatchSourceTimer?

    init() {
        active = !UserDefaults.standard.bool(forKey: "paused")
        log("RGB Lock started")
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 5)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func fixNow() { queue.async { self.tick() } }

    private func publish(_ s: LinkState, _ link: Link? = nil, fixed: Bool = false) {
        DispatchQueue.main.async {
            self.state = s
            if let link { self.name = link.name; self.mode = describe(link.color) }
            if s == .absent { self.name = "—"; self.mode = "" }
            if fixed { self.lastFix = Date(); self.fixes += 1 }
        }
    }

    private func tick() {
        guard let api = FBAPI.shared else { return publish(.unsupported) }
        guard externalAwake() else { return publish(active ? .asleep : .paused) }
        let links = externalLinks(api)
        guard !links.isEmpty else { return publish(.absent) }
        var shown: (LinkState, Link, Bool)?
        for link in links {
            let result = enforce(api, link)
            // The panel shows one display: the first one that isn't fine, else the first.
            if shown == nil || (shown!.0 == .locked && result.0 != .locked) { shown = result }
        }
        publish(shown!.0, shown!.1, fixed: shown!.2)
    }

    /// Switch only when actually on YCbCr: a modeset blanks the display, never fire blindly.
    private func enforce(_ api: FBAPI, _ link: Link) -> (LinkState, Link, Bool) {
        if link.isRGB { return (.locked, link, false) }
        guard active else { return (.paused, link, false) }
        guard let target = link.rgbTarget, let targetID = target["ID"] as? Int else {
            log("\(link.name): \(describe(link.color)), no RGB Full mode allowed for this timing")
            return (.unsupported, link, false)
        }
        log("\(link.name): \(describe(link.color)) -> \(describe(target)) (color \(targetID), timing \(link.timingID))")
        let kr = api.set(link.fb, UInt32(targetID), link.timingID)
        if kr != KERN_SUCCESS { log("set failed: 0x\(String(kr, radix: 16))") }
        sleep(2)  // the link retrains before the new mode reads back
        let after = externalLinks(api).first { $0.name == link.name } ?? link
        return after.isRGB ? (.locked, after, true) : (.fixing, after, false)
    }
}

struct Panel: View {
    @ObservedObject var e: Enforcer
    @State private var atLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: e.state.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(e.state.color)
                    .frame(width: 40, height: 40)
                    .background(e.state.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("RGB Lock").font(.headline)
                    Text(e.state.title).font(.subheadline).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                row("Display", e.name)
                row("Mode", e.mode.isEmpty ? "—" : e.mode)
                row("Last fix", e.lastFix.map { $0.formatted(date: .omitted, time: .shortened) } ?? "—")
                row("Fixes", "\(e.fixes)")
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            Toggle("Keep display on RGB", isOn: $e.enabled)
            Toggle("Launch at login", isOn: $atLogin)
                .onChange(of: atLogin) { on in
                    do { try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() } catch {
                        log("login item: \(error.localizedDescription)")
                    }
                    atLogin = SMAppService.mainApp.status == .enabled
                }

            HStack {
                Button("Fix now") { e.fixNow() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .toggleStyle(.switch)
        .padding(16)
        .frame(width: 320)
    }

    func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Text(v).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
        .font(.caption)
    }
}

@main
struct RGBLockApp: App {
    @StateObject private var e = Enforcer()

    init() {
        // Default on, only from /Applications: a login item registered from a build or DMG path breaks on move.
        if Bundle.main.bundlePath.hasPrefix("/Applications/"),
           !UserDefaults.standard.bool(forKey: "loginItemOffered") {
            UserDefaults.standard.set(true, forKey: "loginItemOffered")
            try? SMAppService.mainApp.register()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            Panel(e: e)
        } label: {
            Image(systemName: e.state.symbol)
        }
        .menuBarExtraStyle(.window)
    }
}
