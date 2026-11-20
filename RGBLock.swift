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
    let key: String  // stable across reconnects: "DEL-53501-DNJLKF3"
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
        let product = attrs?["ProductAttributes"] as? Element ?? [:]
        let name = product["ProductName"] as? String ?? "External display"
        // Serial keeps two identical monitors apart; fall back to the registry entry if there is none.
        let serial = product["AlphanumericSerialNumber"] ?? product["SerialNumber"] ?? entry
        let key = "\(product["ManufacturerID"] ?? "?")-\(product["ProductID"] ?? "?")-\(serial)"
        links.append(Link(key: key, name: name, fb: fb, timingID: timingID, color: color,
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
    case locked, fixing, asleep, absent, unsupported, unlocked

    var symbol: String {
        switch self {
        case .locked: "lock.display"
        case .fixing: "display.trianglebadge.exclamationmark"
        case .asleep: "moon.zzz"
        case .absent: "display"
        case .unsupported: "exclamationmark.triangle.fill"
        case .unlocked: "pause.circle"
        }
    }
    var title: String {
        switch self {
        case .locked: "Locked to RGB"
        case .fixing: "Switching to RGB…"
        case .asleep: "Display asleep"
        case .absent: "No external display"
        case .unsupported: "Can't switch to RGB"
        case .unlocked: "Not locking any display"
        }
    }
    var color: Color {
        switch self {
        case .locked: .green
        case .fixing: .orange
        case .unsupported: .red
        case .asleep, .absent, .unlocked: .secondary
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


struct DisplayStatus: Identifiable {
    let id: String  // Link.key
    let name: String
    let mode: String
    let state: LinkState
}

final class Enforcer: ObservableObject {
    @Published var state = LinkState.absent
    @Published var displays: [DisplayStatus] = []
    @Published var locked: Set<String>
    @Published var lastFix: Date?
    @Published var fixes = 0

    private let queue = DispatchQueue(label: "rgb-lock")
    private var lockedQ: Set<String>  // queue-owned copy of `locked`
    private var firstRun: Bool
    private var timer: DispatchSourceTimer?

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: "lockedDisplays")
        let initial = Set(saved ?? [])
        locked = initial
        lockedQ = initial
        firstRun = saved == nil
        log("RGB Lock started")
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 5)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func fixNow() { queue.async { self.tick() } }

    func setLocked(_ key: String, _ on: Bool) {
        if on { locked.insert(key) } else { locked.remove(key) }
        save(locked)
        let s = locked
        queue.async { self.lockedQ = s; self.tick() }
    }

    private func save(_ s: Set<String>) { UserDefaults.standard.set(s.sorted(), forKey: "lockedDisplays") }

    private func tick() {
        guard let api = FBAPI.shared else { return publish(.unsupported, nil) }
        guard externalAwake() else { return publish(.asleep, nil) }
        let links = externalLinks(api)
        if firstRun, !links.isEmpty {
            // First run locks whatever is plugged in now; displays connected later start unlocked.
            firstRun = false
            lockedQ = Set(links.map(\.key))
            let s = lockedQ
            DispatchQueue.main.async { self.locked = s; self.save(s) }
            log("first run: locking \(links.map(\.name).joined(separator: ", "))")
        }
        var fixed = 0
        let rows = links.map { link -> DisplayStatus in
            let (state, now, didFix) = enforce(api, link)
            if didFix { fixed += 1 }
            return DisplayStatus(id: link.key, name: link.name, mode: describe(now.color), state: state)
        }
        publish(overall(rows), rows, fixed: fixed)
    }

    /// Menu bar state: the worst state among locked displays.
    private func overall(_ rows: [DisplayStatus]) -> LinkState {
        if rows.isEmpty { return .absent }
        let states = rows.map(\.state)
        for s in [LinkState.fixing, .unsupported, .locked] where states.contains(s) { return s }
        return .unlocked
    }

    private func publish(_ s: LinkState, _ rows: [DisplayStatus]?, fixed: Int = 0) {
        DispatchQueue.main.async {
            self.state = s
            if let rows { self.displays = rows }
            if fixed > 0 { self.lastFix = Date(); self.fixes += fixed }
        }
    }

    /// Switch only locked displays that are actually on YCbCr: a modeset blanks the screen.
    private func enforce(_ api: FBAPI, _ link: Link) -> (LinkState, Link, Bool) {
        guard lockedQ.contains(link.key) else { return (.unlocked, link, false) }
        if link.isRGB { return (.locked, link, false) }
        guard let target = link.rgbTarget, let targetID = target["ID"] as? Int else {
            log("\(link.name): \(describe(link.color)), no RGB Full mode allowed for this timing")
            return (.unsupported, link, false)
        }
        log("\(link.name): \(describe(link.color)) -> \(describe(target)) (color \(targetID), timing \(link.timingID))")
        let kr = api.set(link.fb, UInt32(targetID), link.timingID)
        if kr != KERN_SUCCESS { log("set failed: 0x\(String(kr, radix: 16))") }
        sleep(2)  // the link retrains before the new mode reads back
        let after = externalLinks(api).first { $0.key == link.key } ?? link
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

            VStack(spacing: 0) {
                if e.displays.isEmpty {
                    Text("Connect an external display to lock it.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                ForEach(e.displays) { d in
                    HStack(spacing: 10) {
                        Circle().fill(d.state.color).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.name).font(.callout.weight(.medium))
                            Text(d.mode).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("Lock \(d.name)", isOn: Binding(
                            get: { e.locked.contains(d.id) },
                            set: { e.setLocked(d.id, $0) }))
                            .labelsHidden()
                            .controlSize(.small)
                            .help("Keep \(d.name) on RGB Full")
                    }
                    .padding(10)
                    if d.id != e.displays.last?.id { Divider() }
                }
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Text("Last fix \(e.lastFix.map { $0.formatted(date: .omitted, time: .shortened) } ?? "—")")
                Spacer()
                Text("Fixes \(e.fixes)")
            }
            .font(.caption).foregroundStyle(.secondary)

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
