// openwispr-hud — a tiny floating voice-reactive badge for open-wispr.
//
// Trigger is the DICTATION HOTKEY ONLY (not mic activity), via a keyboard event
// tap. We read open-wispr's configured hotkey from its config so we stay in sync
// (default: Globe/fn, keyCode 63).
//
//   hotkey down -> show pill, start our mic tap, render live waveform (5 bars)
//   hotkey up   -> stop the tap, run a back-and-forth "processing" wave, fade out
//
// Permissions: Input Monitoring (to see the hotkey) + Microphone (level metering).

import Cocoa
import AVFoundation
import Accelerate
import IOKit.hid

func hlog(_ s: String) {
    FileHandle.standardError.write(Data(("[hud] " + s + "\n").utf8))
}

// MARK: - 5-bar waveform view (live levels OR processing wave)

final class WaveformView: NSView {
    static let barCount = 5
    private var levels: [CGFloat] = Array(repeating: 0, count: WaveformView.barCount)
    private var processing = false
    private var phase: CGFloat = 0
    private var animTimer: Timer?

    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }

    // Live mode: each bar is a frequency band (bass→treble), set directly.
    func setLevels(_ vals: [CGFloat]) {
        guard !processing else { return }
        for i in 0..<min(levels.count, vals.count) { levels[i] = max(0, min(1, vals[i])) }
        needsDisplay = true
    }

    func reset() {
        stopProcessing()
        levels = Array(repeating: 0, count: WaveformView.barCount)
        needsDisplay = true
    }

    // Processing mode: a bump bounces left↔right across the 5 bars.
    func startProcessing() {
        processing = true
        phase = 0
        animTimer?.invalidate()
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.phase += 0.26
            let n = WaveformView.barCount
            let pos = CGFloat(n - 1) / 2 * (1 + sin(self.phase))   // 0 … n-1, oscillating
            let sigma: CGFloat = 0.85
            for i in 0..<n {
                let d = CGFloat(i) - pos
                self.levels[i] = 0.12 + 0.88 * exp(-(d * d) / (2 * sigma * sigma))
            }
            self.needsDisplay = true
        }
    }
    func stopProcessing() { processing = false; animTimer?.invalidate(); animTimer = nil }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width, h = bounds.height
        let n = WaveformView.barCount
        let barW: CGFloat = 3
        let gap = (w - CGFloat(n) * barW) / CGFloat(n + 1)
        let midY = h / 2
        let minH: CGFloat = 2
        let maxH = h - 1
        // Monochrome: bright white while listening, dimmer while processing.
        let color = processing ? NSColor(white: 1.0, alpha: 0.45)
                               : NSColor(white: 1.0, alpha: 0.92)
        color.setFill()
        var x = gap
        for lv in levels {
            let bh = minH + lv * (maxH - minH)
            NSBezierPath(roundedRect: NSRect(x: x, y: midY - bh/2, width: barW, height: bh),
                         xRadius: barW/2, yRadius: barW/2).fill()
            x += barW + gap
        }
    }
}

// MARK: - Floating pill

final class Pill {
    private let window: NSWindow
    let wave: WaveformView
    private var hideWork: DispatchWorkItem?

    init() {
        let size = NSSize(width: 64, height: 24)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.alphaValue = 0

        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        bg.material = .hudWindow
        bg.state = .active
        bg.blendingMode = .behindWindow
        bg.wantsLayer = true
        bg.layer?.cornerRadius = size.height / 2
        bg.layer?.masksToBounds = true
        bg.layer?.borderWidth = 1
        bg.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        wave = WaveformView(frame: NSRect(x: 9, y: 4, width: size.width - 18, height: size.height - 8))
        bg.addSubview(wave)
        window.contentView = bg
        reposition()
        NotificationCenter.default.addObserver(self, selector: #selector(reposition),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func reposition() {
        // Follow the screen the mouse is on — NSScreen.main resolves to the primary
        // display for a background app, which is the wrong monitor half the time.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let vf = screen?.visibleFrame else { return }
        window.setFrameOrigin(NSPoint(x: vf.midX - window.frame.width/2, y: vf.minY + 90))
    }

    func showListening() {
        hideWork?.cancel(); hideWork = nil
        reposition()
        wave.reset()
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; window.animator().alphaValue = 1 }
    }

    func startProcessing() { wave.startProcessing() }

    func fadeOut(after seconds: TimeInterval) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; self.window.animator().alphaValue = 0 },
                completionHandler: { self.window.orderOut(nil); self.wave.stopProcessing() })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

// MARK: - Mic capture (live levels only; bounded by the hotkey hold)

final class CaptureSession {
    private let engine = AVAudioEngine()
    private let onLevels: ([CGFloat]) -> Void
    private var timer: Timer?

    // Per-band state (bars = frequency bands, bass→treble).
    private let bandCount = 5
    private var envelope: [CGFloat]   // smoothed target per band (updated per audio buffer)
    private var display:  [CGFloat]   // eased value shown per band
    private var bandBins: [(Int, Int)] = []

    // FFT.
    private let fftSize = 1024
    private let log2n: vDSP_Length
    private var fftSetup: FFTSetup?
    private var window: [Float]

    // Adaptive gain (auto-calibrates to mic level so bars use the full range).
    private var peakDB: Float = -45
    private let peakFloor: Float = -45   // don't let noise fill the bars during silence
    private let peakDecay: Float = 0.04  // per audio buffer
    private let dynRange:  Float = 38    // dB span mapped to 0…1

    // Damping (smaller = smoother, larger = snappier). Dynamic look comes from
    // bands moving independently; damping just removes the raw jitter.
    private let envelopeAlpha: CGFloat = 0.55
    private let displayEase:   CGFloat = 0.5
    private let gamma:         CGFloat = 0.7

    init(onLevels: @escaping ([CGFloat]) -> Void) {
        self.onLevels = onLevels
        envelope = Array(repeating: 0, count: bandCount)
        display  = Array(repeating: 0, count: bandCount)
        log2n = vDSP_Length(log2(Double(fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    }
    deinit { if let s = fftSetup { vDSP_destroy_fftsetup(s) } }

    private func computeBands(sampleRate: Double) {
        let edges: [Double] = [120, 350, 800, 1800, 3800, 7500]   // 5 log-spaced speech bands
        let freqPerBin = sampleRate / Double(fftSize)
        bandBins = (0..<bandCount).map { i in
            let lo = max(1, Int(edges[i] / freqPerBin))
            let hi = min(fftSize/2 - 1, Int(edges[i+1] / freqPerBin))
            return (lo, max(lo, hi))
        }
    }

    func start() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        hlog("capture start: mic auth = \(status.rawValue) (0=notDetermined,1=restricted,2=denied,3=authorized)")
        if status != .authorized {
            AVCaptureDevice.requestAccess(for: .audio) { granted in hlog("mic requestAccess -> \(granted)") }
        }
        let input = engine.inputNode
        let fmt = input.inputFormat(forBus: 0)
        hlog("input format channels=\(fmt.channelCount) sampleRate=\(fmt.sampleRate)")
        guard fmt.channelCount > 0 else { hlog("no input channels — aborting capture"); return }
        computeBands(sampleRate: fmt.sampleRate)
        input.installTap(onBus: 0, bufferSize: UInt32(fftSize), format: fmt) { [weak self] buf, _ in
            self?.process(buf)
        }
        do { try engine.start(); hlog("engine started") } catch { hlog("engine start FAILED: \(error)"); return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            for i in 0..<self.bandCount {
                self.display[i] += (self.envelope[i] - self.display[i]) * self.displayEase
            }
            self.onLevels(self.display)
        }
    }

    private func process(_ buf: AVAudioPCMBuffer) {
        guard let ch = buf.floatChannelData?[0], let setup = fftSetup, !bandBins.isEmpty else { return }
        let count = min(Int(buf.frameLength), fftSize)

        var samples = [Float](repeating: 0, count: fftSize)
        for i in 0..<count { samples[i] = ch[i] }
        vDSP_vmul(samples, 1, window, 1, &samples, 1, vDSP_Length(fftSize))

        var real = [Float](repeating: 0, count: fftSize/2)
        var imag = [Float](repeating: 0, count: fftSize/2)
        var mags = [Float](repeating: 0, count: fftSize/2)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                samples.withUnsafeBufferPointer { sp in
                    sp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize/2) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(fftSize/2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(fftSize/2))
            }
        }

        // Per-band average power → dB.
        var dbs = [Float](repeating: -120, count: bandCount)
        for b in 0..<bandCount {
            let (lo, hi) = bandBins[b]
            var sum: Float = 0
            for k in lo...hi { sum += mags[k] }
            let avg = sum / Float(hi - lo + 1)
            dbs[b] = avg > 0 ? 10 * log10(avg) : -120
        }

        // Adaptive gain: track a slowly-decaying peak, map [peak-dynRange … peak] → 0…1.
        let frameMax = dbs.max() ?? -120
        peakDB = frameMax > peakDB ? frameMax : max(peakFloor, peakDB - peakDecay)
        let floorDB = peakDB - dynRange

        var raw = [CGFloat](repeating: 0, count: bandCount)
        for b in 0..<bandCount {
            let norm = max(0, min(1, (dbs[b] - floorDB) / dynRange))
            raw[b] = pow(CGFloat(norm), gamma)
        }
        DispatchQueue.main.async {
            for b in 0..<self.bandCount {
                self.envelope[b] = self.envelope[b] * (1 - self.envelopeAlpha) + raw[b] * self.envelopeAlpha
            }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if engine.isRunning { engine.inputNode.removeTap(onBus: 0); engine.stop() }
        for i in 0..<bandCount { envelope[i] = 0; display[i] = 0 }
        peakDB = peakFloor
    }
}

// MARK: - Hotkey watcher (keyboard event tap; hotkey-only trigger)

private func tapCallback(proxy: CGEventTapProxy, type: CGEventType,
                         event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let rc = refcon {
        Unmanaged<HotkeyWatcher>.fromOpaque(rc).takeUnretainedValue().handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}

final class HotkeyWatcher {
    private let onDown: () -> Void
    private let onUp: () -> Void
    private var tap: CFMachPort?
    private var held = false

    private let useFn: Bool
    private let targetKeyCode: Int64

    init(onDown: @escaping () -> Void, onUp: @escaping () -> Void) {
        self.onDown = onDown; self.onUp = onUp
        let kc = HotkeyWatcher.readConfiguredKeyCode()
        self.targetKeyCode = kc
        self.useFn = (kc == 63)     // 63 = Globe/fn
        requestInputMonitoring()
        if !install() {
            // Permission not granted yet — retry until the user grants it.
            Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] t in
                if self?.install() == true { t.invalidate() }
            }
        }
    }

    // Read open-wispr's configured hotkey keyCode so we track whatever it uses.
    private static func readConfiguredKeyCode() -> Int64 {
        let path = ("~/.config/open-wispr/config.json" as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hk = obj["hotkey"] as? [String: Any],
              let kc = hk["keyCode"] as? Int else { return 63 }
        return Int64(kc)
    }

    private func requestInputMonitoring() {
        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        hlog("input-monitoring access = \(access.rawValue) (0=granted,1=denied,2=unknown)")
        if access != kIOHIDAccessTypeGranted {
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
    }

    private func install() -> Bool {
        let mask = (1 << CGEventType.flagsChanged.rawValue) |
                   (1 << CGEventType.keyDown.rawValue) |
                   (1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                options: .listenOnly, eventsOfInterest: CGEventMask(mask),
                callback: tapCallback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            hlog("event tap create FAILED (Input Monitoring not effective yet) — will retry")
            return false
        }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        hlog("event tap installed (useFn=\(useFn), keyCode=\(targetKeyCode))")
        return true
    }

    func handle(type: CGEventType, event: CGEvent) {
        // macOS disables a tap that's slow or after certain events — re-enable it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        var down = held
        if useFn {
            guard type == .flagsChanged else { return }
            down = event.flags.contains(.maskSecondaryFn)
        } else {
            guard event.getIntegerValueField(.keyboardEventKeycode) == targetKeyCode else { return }
            if type == .keyDown { down = true }
            else if type == .keyUp { down = false }
            else { return }
        }
        guard down != held else { return }
        held = down
        DispatchQueue.main.async { down ? self.onDown() : self.onUp() }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let pill = Pill()
    var watcher: HotkeyWatcher!
    var capture: CaptureSession?
    private let processingDuration: TimeInterval = 1.6

    func applicationDidFinishLaunching(_ note: Notification) {
        if CommandLine.arguments.contains("--demo") { runDemo(); return }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        watcher = HotkeyWatcher(
            onDown: { [weak self] in self?.begin() },
            onUp:   { [weak self] in self?.end() })
    }

    private func begin() {
        guard capture == nil else { return }
        pill.showListening()
        let cap = CaptureSession { [weak self] levels in self?.pill.wave.setLevels(levels) }
        capture = cap
        cap.start()
    }

    private func end() {
        capture?.stop(); capture = nil
        pill.startProcessing()
        pill.fadeOut(after: processingDuration)
    }

    private func runDemo() {
        pill.showListening()
        var t = 0.0
        Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] tm in
            t += 0.2
            var vals = [CGFloat]()
            for i in 0..<5 {
                let a = abs(sin(t + Double(i) * 0.8))
                let b = 0.35 + 0.65 * abs(sin(t * 0.4 + Double(i) * 0.5))
                vals.append(CGFloat(a * b))
            }
            self?.pill.wave.setLevels(vals)
            if t > 20 { tm.invalidate() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { self.pill.startProcessing() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self.pill.fadeOut(after: 0); }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.5) { NSApp.terminate(nil) }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
