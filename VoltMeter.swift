import SwiftUI
import AppKit
import AVFoundation
import CoreAudio
import IOKit.hid

// MARK: - Panel state over the Volt 2's vendor HID interface
//
// Report ID 1, byte 1 is a bitmask (mapped by hand, 15.11.2026):
//   0x80 Vintage 2   0x40 Vintage 1   0x20 INST 2   0x10 INST 1
//   0x08 Direct stereo   0x04 Direct mono   0x02 48V
// Knobs (gain, monitor) are analog and never reported.
// The device does not answer GetReport, so state is only known after a change;
// the last seen byte is persisted and shown as "last known" until then.
//
// Control: output report 0x10 takes the same bitmask and sets the whole panel
// (verified with Vintage 1, 15.11.2026). The device echoes the new state on
// report 1, so the UI only ever shows what the hardware confirmed. Commands are
// blocked until the state is confirmed, so a stale byte can never be written back.

enum DirectMode: String { case off = "Off", stereo = "Stereo", mono = "Mono" }

final class VoltPanel: ObservableObject {
    @Published var bits: UInt8
    @Published var confirmed = false
    @Published var connected = false

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private static let key = "lastPanelBits"

    var vintage1: Bool { bits & 0x40 != 0 }
    var vintage2: Bool { bits & 0x80 != 0 }
    var inst1: Bool { bits & 0x10 != 0 }
    var inst2: Bool { bits & 0x20 != 0 }
    var phantom: Bool { bits & 0x02 != 0 }
    var direct: DirectMode { bits & 0x08 != 0 ? .stereo : (bits & 0x04 != 0 ? .mono : .off) }

    init() {
        bits = UInt8(UserDefaults.standard.integer(forKey: Self.key))
        start()
    }

    private func start() {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: 0x2b5a, kIOHIDProductIDKey: 0x21] as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, device in
            let me = Unmanaged<VoltPanel>.fromOpaque(ctx!).takeUnretainedValue()
            IOHIDDeviceRegisterInputReportCallback(device, me.buffer, 64, { ctx, _, _, _, id, report, len in
                guard id == 1, len >= 2 else { return }
                let me = Unmanaged<VoltPanel>.fromOpaque(ctx!).takeUnretainedValue()
                let b = report[1]
                DispatchQueue.main.async {
                    me.bits = b
                    me.confirmed = true
                    UserDefaults.standard.set(Int(b), forKey: VoltPanel.key)
                }
            }, ctx)
            DispatchQueue.main.async { me.device = device; me.connected = true }
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, _ in
            let me = Unmanaged<VoltPanel>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { me.device = nil; me.connected = false; me.confirmed = false }
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m
    }

    var canControl: Bool { connected && confirmed && device != nil }

    private func write(_ newBits: UInt8) {
        guard canControl, let device else { return }
        var out: [UInt8] = [0x10, newBits, 0, 0, 0]
        IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x10, &out, out.count)
    }

    func toggle(_ mask: UInt8) { write(bits ^ mask) }

    func setDirect(_ mode: DirectMode) {
        let base = bits & ~UInt8(0x0C)
        write(base | (mode == .stereo ? 0x08 : mode == .mono ? 0x04 : 0))
    }
}

// MARK: - Input metering on the Volt 2

struct ChannelLevel {
    var peakDB: Float = -120
    var holdDB: Float = -120
    var holdUntil = Date.distantPast
    var clipped = false

    /// What the meter actually shows; used to skip redraws that would change nothing.
    var displayKey: [Int] { [Int((max(peakDB, -61) * 2).rounded()), Int((max(holdDB, -61) * 10).rounded()), clipped ? 1 : 0] }
}

/// Live levels live in their own object so 30 Hz meter updates redraw only the meter rows,
/// not the whole app (the menu bar scene observes `Meter`).
final class Levels: ObservableObject {
    @Published var ch = [ChannelLevel(), ChannelLevel()]
}

final class Meter: ObservableObject {
    let levels = Levels()
    @Published var anyClip = false
    private var ch = [ChannelLevel(), ChannelLevel()]
    // the IOProc folds its peaks in here; a 30 Hz timer on the main thread drains them
    private let peakLock = NSLock()
    private var pending: [Float] = [0, 0]
    private var ticker: Timer?
    @Published var status = "Waiting for microphone access"
    @Published var live = false

    // Reads the Volt 2 straight from the HAL with an IOProc. AVAudioEngine stalled
    // after one buffer when its input was switched to the Volt, so it is not used.
    private var device: AudioDeviceID = 0
    private var procID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "voltmeter.io", qos: .userInteractive)
    private var watchdog: Timer?
    private let clipLevel: Float = 0.989 // about -0.1 dBFS

    init() {
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            DispatchQueue.main.async {
                guard ok else { self.status = "Allow microphone access for VoltMeter in System Settings"; return }
                self.startEngine()
                let t = Timer(timeInterval: 1.0 / 30, repeats: true) { _ in self.tick() }
                t.tolerance = 0.005
                RunLoop.main.add(t, forMode: .common)
                self.ticker = t
                // re-attach if the Volt is unplugged and plugged back in
                self.watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                    if self.voltDeviceID() != self.device || self.device == 0 { self.startEngine() }
                }
            }
        }
    }

    func resetClips() {
        for i in ch.indices { ch[i].clipped = false }
        levels.ch = ch
        anyClip = false
    }

    private func tick() {
        guard live else { return }
        peakLock.lock(); let peaks = pending; pending = [0, 0]; peakLock.unlock()
        update(peaks: peaks)
    }

    private func voltDeviceID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return nil }
        for id in ids {
            var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                      mScope: kAudioObjectPropertyScopeGlobal,
                                                      mElement: kAudioObjectPropertyElementMain)
            var name: Unmanaged<CFString>?
            var nsize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nsize, &name) == noErr,
                  let n = name?.takeRetainedValue() as String?, n.contains("Volt") else { continue }
            var inAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                    mScope: kAudioDevicePropertyScopeInput,
                                                    mElement: kAudioObjectPropertyElementMain)
            var ssize: UInt32 = 0
            if AudioObjectGetPropertyDataSize(id, &inAddr, 0, nil, &ssize) == noErr, ssize > 0 { return id }
        }
        return nil
    }

    private func startEngine() {
        if let procID, device != 0 {
            AudioDeviceStop(device, procID)
            AudioDeviceDestroyIOProcID(device, procID)
        }
        procID = nil
        device = 0
        guard let dev = voltDeviceID() else { status = "Plug in the Volt 2"; live = false; return }

        var proc: AudioDeviceIOProcID?
        let err = AudioDeviceCreateIOProcIDWithBlock(&proc, dev, ioQueue) { [weak self] _, inData, _, _, _ in
            guard let self else { return }
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            var peaks: [Float] = [0, 0]
            var chanBase = 0
            // works for both interleaved (1 buffer x N ch) and planar (N buffers x 1 ch) layouts
            for b in abl {
                guard let raw = b.mData else { continue }
                let nch = Int(b.mNumberChannels)
                let s = raw.assumingMemoryBound(to: Float.self)
                let total = Int(b.mDataByteSize) / MemoryLayout<Float>.size
                for i in 0..<total {
                    let c = chanBase + i % max(nch, 1)
                    if c < 2 { peaks[c] = max(peaks[c], abs(s[i])) }
                }
                chanBase += nch
            }
            if ProcessInfo.processInfo.environment["VM_DEBUG"] != nil {
                FileHandle.standardError.write("bufs=\(abl.count) ch=\(abl.first?.mNumberChannels ?? 0) bytes=\(abl.first?.mDataByteSize ?? 0) peaks=\(peaks)\n".data(using: .utf8)!)
            }
            self.peakLock.lock()
            self.pending[0] = max(self.pending[0], peaks[0]); self.pending[1] = max(self.pending[1], peaks[1])
            self.peakLock.unlock()
        }
        guard err == noErr, let proc else { status = "Audio error \(err)"; return }
        let startErr = AudioDeviceStart(dev, proc)
        guard startErr == noErr else {
            AudioDeviceDestroyIOProcID(dev, proc)
            status = "Audio start error \(startErr)"
            return
        }
        procID = proc
        device = dev

        live = true
        readRates()
    }

    // MARK: Sample rate

    @Published var rate: Double = 0
    @Published var rates: [Double] = []

    static func label(_ r: Double) -> String {
        let k = r / 1000
        return k == k.rounded() ? "\(Int(k)) kHz" : String(format: "%.1f kHz", k)
    }

    private func readRates() {
        guard device != 0 else { return }
        var r = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &r)
        rate = r
        status = r > 0 ? Self.label(r) : ""

        var listAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var lsize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &listAddr, 0, nil, &lsize) == noErr, lsize > 0 else { return }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(lsize) / MemoryLayout<AudioValueRange>.size)
        AudioObjectGetPropertyData(device, &listAddr, 0, nil, &lsize, &ranges)
        rates = Array(Set(ranges.map { $0.mMinimum })).sorted()
    }

    /// Sets the Volt's sample rate for the whole system (what Audio MIDI Setup does).
    func setRate(_ r: Double) {
        guard device != 0, r != rate else { return }
        var value = Float64(r)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let err = AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float64>.size), &value)
        if err != noErr { NSLog("VoltMeter: sample rate change failed \(err)") }
        // the device takes a moment to switch; read back what it actually runs at
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.readRates() }
    }

    private var lastUpdate = Date()

    private func update(peaks: [Float]) {
        let now = Date()
        let dt = Float(min(now.timeIntervalSince(lastUpdate), 0.1))
        lastUpdate = now
        for c in 0..<2 {
            let db = peaks[c] > 0 ? 20 * log10(peaks[c]) : -120
            var l = ch[c]
            // needle ballistics: quick but not instant rise, 20 dB/s fall
            l.peakDB = db > l.peakDB ? l.peakDB + (db - l.peakDB) * min(1, dt * 25) : max(db, l.peakDB - 20 * dt)
            if db >= l.holdDB || now > l.holdUntil { l.holdDB = db; l.holdUntil = now.addingTimeInterval(1.5) }
            if peaks[c] >= clipLevel { l.clipped = true }
            ch[c] = l
        }
        let clip = ch.contains { $0.clipped }
        if clip != anyClip { anyClip = clip }
        // nothing to draw when the panel is hidden or covered, or when nothing visibly moved
        guard FloatingPanel.shared.isOnScreen else { return }
        if ch.map(\.displayKey) != levels.ch.map(\.displayKey) { levels.ch = ch }
    }
}

// MARK: - UI
//
// Look: Or's mockup (15.11.2026). A near-black body with three raised cards:
// one row per input (name, level in dB, a long segmented LED meter with a scale,
// Vintage and Inst keys), and a bottom row for phantom power and direct monitor.
// Warm off-white type, lime as the one live colour.

enum Palette {
    static let body = Color(red: 0.082, green: 0.082, blue: 0.086)
    static let card = Color(red: 0.118, green: 0.118, blue: 0.125)
    static let cardEdge = Color.white.opacity(0.07)
    static let key = Color(red: 0.165, green: 0.165, blue: 0.172)
    static let keyEdge = Color.white.opacity(0.09)
    static let ink = Color(red: 0.94, green: 0.91, blue: 0.85)        // warm off-white
    static let inkDim = Color(red: 0.94, green: 0.91, blue: 0.85).opacity(0.55)
    static let rule = Color.white.opacity(0.12)
    static let lime = Color(red: 0.71, green: 0.95, blue: 0.23)
    static let limeOff = Color(red: 0.71, green: 0.95, blue: 0.23).opacity(0.14)
    static let amber = Color(red: 1.00, green: 0.70, blue: 0.22)
    static let red = Color(red: 0.98, green: 0.33, blue: 0.30)
    static let well = Color(red: 0.06, green: 0.06, blue: 0.065)
}

/// Panel zoom (100/150/200%). Everything is laid out at its real size rather than
/// scaled as a bitmap, so text and lines stay sharp. The panel is rebuilt on change.
enum UIScale { static var s: CGFloat = 1 }
func u(_ x: CGFloat) -> CGFloat { x * UIScale.s }

extension Font {
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font { .system(size: u(size), weight: weight) }
}

// MARK: Pieces

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(.horizontal, u(18))
            .frame(height: u(76))
            .background(RoundedRectangle(cornerRadius: u(14), style: .continuous).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: u(14), style: .continuous).strokeBorder(Palette.cardEdge, lineWidth: u(1)))
    }
}

struct VRule: View {
    var height: CGFloat = 40
    var body: some View { Rectangle().fill(Palette.rule).frame(width: u(1), height: u(height)) }
}

/// Raised key. Off: dark. On: fills with its colour.
struct Key: View {
    let title: String
    let on: Bool
    var color: Color = Palette.lime
    var enabled = true
    var width: CGFloat = 84
    var action: () -> Void = {}
    @State private var hover = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            Text(title).font(.ui(15, .semibold))
                .foregroundStyle(on ? Color.black.opacity(0.85) : Palette.ink.opacity(enabled ? 1 : 0.45))
                .frame(width: u(width), height: u(40))
                .background(
                    RoundedRectangle(cornerRadius: u(9), style: .continuous)
                        .fill(on ? color : (hover && enabled ? Palette.key.opacity(1.25) : Palette.key))
                )
                .overlay(RoundedRectangle(cornerRadius: u(9), style: .continuous)
                    .strokeBorder(on ? Color.white.opacity(0.25) : Palette.keyEdge.opacity(hover && enabled ? 2 : 1), lineWidth: u(1)))
                .shadow(color: on ? color.opacity(0.35) : .black.opacity(0.45), radius: on ? u(7) : u(2), y: on ? 0 : u(1.5))
                .scaleEffect(pressed ? 0.96 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hover = $0 }
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in pressed = true }.onEnded { _ in pressed = false })
        .animation(.easeOut(duration: 0.15), value: on)
        .animation(.easeOut(duration: 0.08), value: pressed)
        .help(enabled ? "Turn \(title) \(on ? "off" : "on")" : "Press any button on the Volt first")
    }
}

/// Segmented LED meter, -60 to 0 dBFS, linear in dB to match the scale under it.
struct LEDMeter: View {
    let level: ChannelLevel
    let live: Bool
    let reset: () -> Void

    static let segments = 38
    static let marks: [Int] = [-60, -48, -36, -24, -12, 0]

    private func db(of i: Int) -> Float { -60 + 60 * Float(i + 1) / Float(Self.segments) }

    var body: some View {
        let width = u(340)
        Button(action: reset) {
            VStack(spacing: u(4)) {
                HStack(spacing: u(2)) {
                    ForEach(0..<Self.segments, id: \.self) { i in
                        let t = db(of: i)
                        let color = t > -1.6 ? Palette.red : t > -7 ? Palette.amber : Palette.lime
                        let isHold = live && level.holdDB > -60 && abs(level.holdDB - t) < 60 / Float(Self.segments) / 2 + 0.01
                        let lit = live && (level.peakDB >= t - 0.01 || isHold || (i == Self.segments - 1 && level.clipped))
                        RoundedRectangle(cornerRadius: u(1.5))
                            .fill(lit ? color : color.opacity(0.14))
                            .shadow(color: lit ? color.opacity(0.55) : .clear, radius: u(3))
                    }
                }
                .frame(width: width, height: u(20))
                .padding(u(3))
                .background(RoundedRectangle(cornerRadius: u(4)).fill(Palette.well))
                .transaction { $0.animation = nil }
                // scale
                ZStack(alignment: .topLeading) {
                    ForEach(Self.marks, id: \.self) { m in
                        let x = width * CGFloat(m + 60) / 60
                        VStack(spacing: u(2)) {
                            Rectangle().fill(Palette.inkDim).frame(width: u(1), height: u(5))
                            Text(m == 0 ? "0" : "\u{2212}\(-m)").font(.ui(10.5, .medium).monospacedDigit()).foregroundStyle(Palette.inkDim)
                                .fixedSize()
                        }
                        .frame(width: u(30))
                        .offset(x: u(3) + x - u(15))
                    }
                }
                .frame(width: width + u(6), height: u(20), alignment: .topLeading)
            }
        }
        .buttonStyle(.plain)
        .help(level.clipped ? "Clipped. Click to clear." : "Input level")
    }
}

struct ChannelRow: View {
    let index: Int
    let level: ChannelLevel
    let live: Bool
    let vintage: Bool
    let inst: Bool
    let enabled: Bool
    let reset: () -> Void
    let toggleVintage: () -> Void
    let toggleInst: () -> Void

    var body: some View {
        Card {
            HStack(spacing: u(18)) {
                Text("Input \(index)").font(.ui(22, .semibold)).foregroundStyle(Palette.ink)
                    .frame(width: u(88), alignment: .leading)
                VRule()
                HStack(alignment: .firstTextBaseline, spacing: u(4)) {
                    Text(level.clipped ? "Clip"
                         : live && level.holdDB > -60 ? String(format: "%.1f", level.holdDB).replacingOccurrences(of: "-", with: "\u{2212}")
                         : "\u{2212}\u{221E}")
                        .font(.ui(30, .bold).monospacedDigit())
                        .foregroundStyle(level.clipped ? Palette.red : Palette.ink.opacity(live && level.holdDB > -60 ? 1 : 0.5))
                    Text("dB").font(.ui(16, .medium)).foregroundStyle(Palette.inkDim)
                }
                .frame(width: u(128), alignment: .leading)
                .transaction { $0.animation = nil }
                VRule()
                LEDMeter(level: level, live: live, reset: reset)
                    .padding(.top, u(14))
                Spacer(minLength: u(6))
                Key(title: "Vintage", on: vintage, color: Palette.amber, enabled: enabled, width: 92, action: toggleVintage)
                Key(title: "Inst", on: inst, color: Palette.lime, enabled: enabled, width: 76, action: toggleInst)
            }
        }
    }
}

/// Off / Mono / Stereo as one joined control.
struct DirectSwitch: View {
    let mode: DirectMode
    var enabled = true
    var select: (DirectMode) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 0) {
            ForEach([DirectMode.off, .mono, .stereo], id: \.self) { m in
                let on = mode == m && m != .off
                Button { select(m) } label: {
                    Text(m.rawValue).font(.ui(15, .semibold))
                        .foregroundStyle(on ? Color.black.opacity(0.85) : Palette.ink.opacity(mode == m ? 1 : 0.75))
                        .frame(width: u(80), height: u(40))
                        .background(
                            RoundedRectangle(cornerRadius: u(8), style: .continuous)
                                .fill(on ? Palette.lime : (mode == m ? Color.white.opacity(0.08) : .clear))
                                .shadow(color: on ? Palette.lime.opacity(0.35) : .clear, radius: u(7))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(RoundedRectangle(cornerRadius: u(9), style: .continuous).fill(Palette.key))
        .overlay(RoundedRectangle(cornerRadius: u(9), style: .continuous).strokeBorder(Palette.keyEdge, lineWidth: u(1)))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .animation(.easeOut(duration: 0.15), value: mode)
    }
}

/// Signal-bars mark in the header. Doubles as quit: it turns into a red x on hover.
struct HeaderMark: View {
    let live: Bool
    @State private var hover = false
    var body: some View {
        Button { NSApp.terminate(nil) } label: {
            ZStack {
                if hover {
                    Circle().fill(Palette.red).frame(width: u(18), height: u(18))
                    Image(systemName: "xmark").font(.system(size: u(8), weight: .heavy)).foregroundStyle(.black.opacity(0.75))
                } else {
                    HStack(alignment: .bottom, spacing: u(2.5)) {
                        ForEach(0..<4, id: \.self) { i in
                            RoundedRectangle(cornerRadius: u(1))
                                .fill(live ? Palette.lime : Palette.inkDim)
                                .frame(width: u(3.5), height: u(5 + CGFloat(i) * 4))
                        }
                    }
                }
            }
            .frame(width: u(24), height: u(22))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Quit VoltMeter")
    }
}

/// The sample rate in the header. Click it to pick another rate for the Volt.
struct RatePicker: View {
    @EnvironmentObject var meter: Meter
    @State private var hover = false
    var body: some View {
        Menu {
            ForEach(meter.rates, id: \.self) { r in
                Button { meter.setRate(r) } label: {
                    if r == meter.rate { Label(Meter.label(r), systemImage: "checkmark") } else { Text(Meter.label(r)) }
                }
            }
        } label: {
            Text(meter.status).font(.ui(17, .semibold).monospacedDigit()).foregroundStyle(Palette.ink)
            .padding(.horizontal, u(8)).padding(.vertical, u(4))
            .background(RoundedRectangle(cornerRadius: u(7)).fill(Color.white.opacity(hover ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hover = $0 }
        .help("Sample rate")
    }
}

// MARK: Panel

struct Faceplate: View {
    @EnvironmentObject var meter: Meter
    @EnvironmentObject var panel: VoltPanel

    private var footnote: String? {
        if !meter.live { return meter.status }
        if !panel.connected { return "Volt controls not connected" }
        if !panel.confirmed { return "Press any button on the Volt once to unlock the controls" }
        return nil
    }

    var body: some View {
        let ok = panel.canControl
        VStack(spacing: 0) {
            // header
            HStack(spacing: u(14)) {
                HeaderMark(live: meter.live)
                Text("VoltMeter").font(.ui(25, .semibold)).kerning(u(-0.3)).foregroundStyle(Palette.ink)
                Spacer()
                if let footnote {
                    Text(footnote).font(.ui(12, .medium)).foregroundStyle(Palette.inkDim)
                        .padding(.trailing, u(10))
                }
                Circle().fill(meter.live ? Palette.lime : Palette.inkDim).frame(width: u(9), height: u(9))
                    .shadow(color: meter.live ? Palette.lime.opacity(0.6) : .clear, radius: u(3))
                Text(meter.live ? "Volt 2" : "Not connected").font(.ui(17, .semibold)).foregroundStyle(Palette.ink)
                if meter.live {
                    VRule(height: 22)
                    RatePicker()
                }
            }
            .padding(.horizontal, u(22))
            .frame(height: u(52))
            Rectangle().fill(Palette.rule).frame(height: u(1))

            VStack(spacing: u(10)) {
                InputRows(levels: meter.levels, live: meter.live, enabled: ok, reset: meter.resetClips)
                Card {
                    HStack(spacing: u(18)) {
                        Text("Phantom Power").font(.ui(20, .semibold)).foregroundStyle(Palette.ink)
                        VRule()
                        Key(title: "48V", on: panel.phantom, color: Palette.red, enabled: ok, width: 76) { panel.toggle(0x02) }
                        Spacer()
                        Text("Direct Monitor").font(.ui(20, .semibold)).foregroundStyle(Palette.ink)
                        VRule()
                        DirectSwitch(mode: panel.direct, enabled: ok) { panel.setDirect($0) }
                    }
                }
            }
            .padding(u(10))
        }
        .background(RoundedRectangle(cornerRadius: u(18), style: .continuous).fill(Palette.body))
        .overlay(RoundedRectangle(cornerRadius: u(18), style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: u(1)))
        .fixedSize()
    }
}

/// The two input rows. Only this view observes the live levels.
struct InputRows: View {
    @ObservedObject var levels: Levels
    @EnvironmentObject var panel: VoltPanel
    let live: Bool
    let enabled: Bool
    let reset: () -> Void

    var body: some View {
        ChannelRow(index: 1, level: levels.ch[0], live: live, vintage: panel.vintage1, inst: panel.inst1,
                   enabled: enabled, reset: reset,
                   toggleVintage: { panel.toggle(0x40) }, toggleInst: { panel.toggle(0x10) })
        ChannelRow(index: 2, level: levels.ch[1], live: live, vintage: panel.vintage2, inst: panel.inst2,
                   enabled: enabled, reset: reset,
                   toggleVintage: { panel.toggle(0x80) }, toggleInst: { panel.toggle(0x20) })
    }
}

final class FloatingPanel {
    static let shared = FloatingPanel()
    private var window: NSPanel?
    var isVisible: Bool { window?.isVisible ?? false }
    var isOnScreen: Bool { guard let w = window else { return false }; return w.isVisible && w.occlusionState.contains(.visible) }

    static let sizes: [CGFloat] = [1, 1.5, 2]
    static var scale: CGFloat {
        let v = UserDefaults.standard.double(forKey: "panelScale")
        return v > 0 ? CGFloat(v) : 1
    }

    func show(meter: Meter, panel: VoltPanel) {
        if let w = window { w.orderFrontRegardless(); return }
        let host = makeHost(meter: meter, panel: panel)
        let w = NSPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.level = .floating
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.hidesOnDeactivate = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.contentView = host
        if let saved = UserDefaults.standard.string(forKey: "panelTopLeft") {
            w.setFrameTopLeftPoint(NSPointFromString(saved))
        } else {
            w.center()
        }
        w.orderFrontRegardless()
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: w, queue: .main) { _ in
            let f = w.frame
            UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: f.minX, y: f.maxY)), forKey: "panelTopLeft")
        }
        window = w
    }

    /// Resizes the panel, keeping its top-left corner where it is.
    func setScale(_ scale: CGFloat, meter: Meter, panel: VoltPanel) {
        UserDefaults.standard.set(Double(scale), forKey: "panelScale")
        guard let w = window else { return }
        let topLeft = NSPoint(x: w.frame.minX, y: w.frame.maxY)
        let host = makeHost(meter: meter, panel: panel)
        w.contentView = host
        w.setContentSize(host.fittingSize)
        w.setFrameTopLeftPoint(topLeft)
    }

    private func makeHost(meter: Meter, panel: VoltPanel) -> NSView {
        let s = Self.scale
        UIScale.s = s
        let host = NSHostingView(rootView:
            Faceplate()
                .contextMenu {
                    ForEach(Self.sizes, id: \.self) { size in
                        Button("\(Int(size * 100))%" + (size == s ? "  ✓" : "")) {
                            FloatingPanel.shared.setScale(size, meter: meter, panel: panel)
                        }
                    }
                    Divider()
                    Button("Hide meter") { FloatingPanel.shared.hide() }
                    Button("Quit VoltMeter") { NSApp.terminate(nil) }
                }
                .environmentObject(meter).environmentObject(panel))
        host.layoutSubtreeIfNeeded()
        return host
    }

    func hide() { window?.orderOut(nil) }
    func toggle(meter: Meter, panel: VoltPanel) { isVisible ? hide() : show(meter: meter, panel: panel) }
}

struct MenuIcon: View {
    @ObservedObject var meter: Meter
    var body: some View {
        Image(systemName: meter.anyClip ? "exclamationmark.triangle.fill" : "gauge.with.needle")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onReopen: (() -> Void)?
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        onReopen?(); return false
    }
}

@main
struct VoltMeterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var meter = Meter()
    @StateObject private var panel = VoltPanel()
    @AppStorage("panelScale") private var panelScale: Double = 1

    var body: some Scene {
        MenuBarExtra {
            Button("Show or hide meter") { FloatingPanel.shared.toggle(meter: meter, panel: panel) }
                .keyboardShortcut("m")
            Menu("Size") {
                ForEach(FloatingPanel.sizes, id: \.self) { size in
                    Button("\(Int(size * 100))%" + (size == CGFloat(panelScale > 0 ? panelScale : 1) ? "  ✓" : "")) {
                        FloatingPanel.shared.show(meter: meter, panel: panel)
                        FloatingPanel.shared.setScale(size, meter: meter, panel: panel)
                    }
                }
            }
            Button("Clear peak lamps") { meter.resetClips() }
            Divider()
            Button("Quit VoltMeter") { NSApp.terminate(nil) }.keyboardShortcut("q")
        } label: {
            MenuIcon(meter: meter)
                .onAppear {
                    // the meter opens with the app, and again when the app is launched while running
                    DispatchQueue.main.async {
                        FloatingPanel.shared.show(meter: meter, panel: panel)
                        delegate.onReopen = { FloatingPanel.shared.show(meter: meter, panel: panel) }
                    }
                }
        }
    }
}
