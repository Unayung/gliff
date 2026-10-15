import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import ApplicationServices
import VideoToolbox
import Metal

// stdout belongs exclusively to the bridge. Diagnostics go to stderr.
let outputLock = NSLock()
func packet(_ kind: UInt8, _ data: Data) {
    outputLock.lock()
    defer { outputLock.unlock() }
    var header = Data([kind])
    var count = UInt32(data.count).littleEndian
    withUnsafeBytes(of: &count) { header.append(contentsOf: $0) }
    do {
        try FileHandle.standardOutput.write(contentsOf: header)
        try FileHandle.standardOutput.write(contentsOf: data)
    } catch { exit(0) }
}
func event(_ value: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: value) { packet(2, data) }
}
func diagnostic(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}
func fail(_ text: String) -> Never {
    event(["type": "error", "message": text]); diagnostic(text); exit(1)
}
func exact(_ count: Int) -> Data? {
    // Pipe reads can return only a few KiB even for a Retina-size frame.
    // Requesting the entire remainder churns large allocations that malloc
    // caches after each short read; reserve once and keep read buffers small.
    var data = Data(capacity: count)
    while data.count < count {
        // Drain Foundation's temporary NSData after each short read instead of
        // keeping a frame's worth of chunk buffers until the packet completes.
        let received = autoreleasepool { () -> Bool in
            guard let part = try? FileHandle.standardInput.read(upToCount: min(count - data.count, 64 * 1024)), !part.isEmpty else { return false }
            data.append(part); return true
        }
        if !received { return nil }
    }
    return data
}
func number(_ data: Data, _ at: Int) -> UInt32 {
    data[at..<at+4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
}
func append(_ number: UInt32, _ to: inout Data) {
    var n = number.littleEndian
    withUnsafeBytes(of: &n) { to.append(contentsOf: $0) }
}
func readCommands(onClose: @escaping () -> Void = {}, _ callback: @escaping (UInt8, Data) -> Void) {
    DispatchQueue.global(qos: .userInteractive).async {
        // This dispatch work item lives for the entire connection. Foundation
        // pipe reads autorelease NSData, so drain each packet, not just on exit.
        while autoreleasepool(invoking: { () -> Bool in
            guard let header = exact(5) else { return false }
            let count = Int(number(header, 1))
            guard count <= 64 * 1024 * 1024, let data = exact(count) else { return false }
            callback(header[0], data)
            return true
        }) {}
        DispatchQueue.main.async { onClose(); NSApplication.shared.terminate(nil); exit(0) }
    }
}
func json(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

// NSPasteboard requests data only when an application pastes. The pipe reader
// resolves the wait directly, so a paste callback on the main thread can wait.
final class PasteProvider: NSObject, NSPasteboardItemDataProvider {
    let serial: UInt32
    let condition = NSCondition()
    var text: String?
    var finished = false
    var requested = false
    init(_ serial: UInt32) { self.serial = serial }
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        condition.lock()
        if !requested { requested = true; event(["type": "paste", "serial": serial]) }
        let deadline = Date(timeIntervalSinceNow: 30)
        while !finished { if !condition.wait(until: deadline) { break } }
        let value = text
        condition.unlock()
        if let value = value { item.setString(value, forType: type) }
    }
    func receive(_ cmd: [String: Any]) {
        condition.lock(); text = cmd["text"] as? String; finished = true
        condition.broadcast(); condition.unlock()
    }
}
final class Clipboard {
    var provider: PasteProvider?
    var observed = Int.min
    var timer: Timer?
    let lock = NSLock()
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
    }
    func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != observed else { return }
        observed = pb.changeCount
        lock.lock(); provider = nil; lock.unlock()
        let text = pb.string(forType: .string)
        event(["type": "clipboard", "text": (text.map { $0.utf8.count <= 1024*1024 ? $0 : "" } as Any?) ?? NSNull()])
    }
    // Called on the pipe reader, including while the main thread is pasting.
    func receive(_ cmd: [String: Any]) -> Bool {
        guard cmd["type"] as? String == "clipboard_data" else { return false }
        lock.lock(); let p = provider; lock.unlock()
        if cmd["serial"] as? UInt32 == p?.serial { p?.receive(cmd) }
        return true
    }
    func command(_ cmd: [String: Any]) {
        guard cmd["type"] as? String == "clipboard_offer" else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        lock.lock()
        if cmd["text"] as? Bool == true, let serial = cmd["serial"] as? UInt32 {
            let p = PasteProvider(serial); let item = NSPasteboardItem()
            item.setDataProvider(p, forTypes: [.string]); provider = p
            pb.writeObjects([item])
        } else { provider = nil }
        lock.unlock()
        observed = pb.changeCount
    }
}
let clipboard = Clipboard()

final class Input {
    var display: CGDirectDisplayID = CGMainDisplayID()
    var keys: Set<CGKeyCode> = []
    var buttons: Set<Int> = []
    var position: CGPoint = .zero
    var capsLock = CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
    let source = CGEventSource(stateID: .privateState)
    func flags() -> CGEventFlags {
        var f: CGEventFlags = []
        if capsLock { f.insert(.maskAlphaShift) }
        if keys.contains(55) || keys.contains(54) { f.insert(.maskCommand) }
        if keys.contains(56) || keys.contains(60) { f.insert(.maskShift) }
        if keys.contains(58) || keys.contains(61) { f.insert(.maskAlternate) }
        if keys.contains(59) || keys.contains(62) { f.insert(.maskControl) }
        return f
    }
    func handle(_ cmd: [String: Any]) {
        switch cmd["type"] as? String {
        case "key":
            guard let code = cmd["keycode"] as? UInt16, let down = cmd["pressed"] as? Bool else { return }
            if code == 57 && down && !keys.contains(code) { capsLock.toggle() }
            if down { keys.insert(code) } else { keys.remove(code) }
            let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            e?.flags = flags(); e?.post(tap: .cghidEventTap)
        case "motion":
            let bounds = CGDisplayBounds(display)
            let x = min(max(cmd["x"] as? Double ?? 0, 0), max(0, bounds.width - 1))
            let y = min(max(cmd["y"] as? Double ?? 0, 0), max(0, bounds.height - 1))
            position = CGPoint(x: bounds.minX + x, y: bounds.minY + y)
            let type: CGEventType = buttons.contains(0) ? .leftMouseDragged : buttons.contains(1) ? .rightMouseDragged : buttons.isEmpty ? .mouseMoved : .otherMouseDragged
            let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: position, mouseButton: buttons.contains(1) ? .right : .left)
            e?.flags = flags(); e?.post(tap: .cghidEventTap)
        case "button":
            guard let button = cmd["button"] as? Int, let down = cmd["pressed"] as? Bool, let b = CGMouseButton(rawValue: UInt32(button)) else { return }
            if down { buttons.insert(button) } else { buttons.remove(button) }
            let type: CGEventType = button == 0 ? (down ? .leftMouseDown : .leftMouseUp) : button == 1 ? (down ? .rightMouseDown : .rightMouseUp) : (down ? .otherMouseDown : .otherMouseUp)
            let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: position, mouseButton: b)
            e?.flags = flags(); e?.post(tap: .cghidEventTap)
        case "axis":
            let value = Int32(max(-32768, min(32767, cmd["value"] as? Double ?? 0)))
            let horizontal = cmd["horizontal"] as? Bool ?? false
            let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: horizontal ? 0 : -value, wheel2: horizontal ? -value : 0, wheel3: 0)
            e?.flags = flags(); e?.post(tap: .cghidEventTap)
        case "release":
            for key in Array(keys) { handle(["type": "key", "keycode": key, "pressed": false]) }
            for button in Array(buttons) { handle(["type": "button", "button": button, "pressed": false]) }
        default: break
        }
    }
}

// Each request completes before accepting another frame. This bounds retained
// VideoToolbox surfaces even if the SSH client stops acknowledging video.
final class HardwareEncoder {
    var session: VTCompressionSession?
    let width: Int, height: Int, fps: Int
    var sequence: Int64 = 0
    var produced = false
    init(_ width: Int, _ height: Int, _ bitrate: Int, _ fps: Int) throws {
        self.width = width; self.height = height; self.fps = fps
        guard width >= 2, width <= 1920, height >= 2, height <= 1200, width % 2 == 0, height % 2 == 0, fps > 0 else { throw NSError(domain: "Gliff.Encoder", code: 1) }
        let specification = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        let attributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                          kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                          kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        let callback: VTCompressionOutputCallback = { refcon, _, status, flags, sample in
            guard let refcon = refcon else { return }
            let encoder = Unmanaged<HardwareEncoder>.fromOpaque(refcon).takeUnretainedValue()
            autoreleasepool { encoder.output(status, flags, sample) }
        }
        do {
            try check(VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
                encoderSpecification: specification, imageBufferAttributes: attributes, compressedDataAllocator: nil,
                outputCallback: callback, refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &session), "create hardware encoder")
            guard let session = session else { throw NSError(domain: "Gliff.Encoder", code: 2) }
            for (key, value) in [(kVTCompressionPropertyKey_RealTime, true as CFBoolean),
                                 (kVTCompressionPropertyKey_AllowFrameReordering, false as CFBoolean)] {
                try check(VTSessionSetProperty(session, key: key, value: value), "set \(key)")
            }
            try check(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel), "set H.264 profile")
            try check(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber), "set bitrate")
            try check(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber), "set frame rate")
            try check(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: (fps * 2) as CFNumber), "set keyframe interval")
            try check(VTCompressionSessionPrepareToEncodeFrames(session), "prepare hardware encoder")
            var hardware: CFTypeRef?
            let hardwareStatus = withUnsafeMutablePointer(to: &hardware) { pointer in
                VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, allocator: nil, valueOut: UnsafeMutableRawPointer(pointer))
            }
            try check(hardwareStatus, "check hardware encoder")
            guard (hardware as? Bool) == true else { throw NSError(domain: "Gliff.Encoder", code: 3, userInfo: [NSLocalizedDescriptionKey: "VideoToolbox selected a software encoder"]) }
        } catch { close(); throw error }
    }
    func check(_ status: OSStatus, _ operation: String) throws {
        if status != noErr { throw NSError(domain: "Gliff.Encoder", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "\(operation) failed (\(status))"]) }
    }
    func close() {
        if let session = session { VTCompressionSessionInvalidate(session); self.session = nil }
    }
    deinit { close() }
    func encode(_ data: Data) {
        guard data.count == 16 + width * height * 4, number(data, 0) == width, number(data, 4) == height, number(data, 12) <= 1,
              let session = session, let pool = VTCompressionSessionGetPixelBufferPool(session) else { fail("Invalid hardware encoder frame") }
        do {
            var pixel: CVPixelBuffer?
            let limits = [kCVPixelBufferPoolAllocationThresholdKey: 3] as CFDictionary
            try check(CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, limits, &pixel), "allocate bounded encoder surface")
            guard let pixel = pixel else { fail("Could not allocate encoder surface") }
            try check(CVPixelBufferLockBaseAddress(pixel, []), "lock encoder surface")
            let base = CVPixelBufferGetBaseAddress(pixel)!
            let stride = CVPixelBufferGetBytesPerRow(pixel)
            data.withUnsafeBytes { raw in
                for row in 0..<height { base.advanced(by: row * stride).copyMemory(from: raw.baseAddress!.advanced(by: 16 + row * width * 4), byteCount: width * 4) }
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            let properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: number(data, 12) == 1] as CFDictionary
            produced = false
            try check(VTCompressionSessionEncodeFrame(session, imageBuffer: pixel, presentationTimeStamp: CMTime(value: sequence, timescale: Int32(fps)),
                duration: CMTime(value: 1, timescale: Int32(fps)), frameProperties: properties, sourceFrameRefcon: nil, infoFlagsOut: nil), "encode hardware frame")
            sequence += 1
            try check(VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid), "complete hardware frame")
            if !produced { fail("Hardware encoder did not produce a frame") }
        } catch { fail(error.localizedDescription) }
    }
    func output(_ status: OSStatus, _ flags: VTEncodeInfoFlags, _ sample: CMSampleBuffer?) {
        guard status == noErr, !flags.contains(.frameDropped), let sample = sample, sample.isValid,
              let format = sample.formatDescription, let buffer = sample.dataBuffer else { fail("Hardware encoder output failed (\(status))") }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) != true
        var encoded = Data()
        append(keyframe ? 1 : 0, &encoded)
        var pointer: UnsafePointer<UInt8>?, size = 0, count = 0, headerLength: Int32 = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength) == noErr,
              headerLength >= 1, headerLength <= 4 else { fail("Invalid H.264 parameter sets") }
        if keyframe {
            for i in 0..<count {
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                      let pointer = pointer, size > 0 else { fail("Invalid H.264 parameter set") }
                encoded.append(contentsOf: [0, 0, 0, 1]); encoded.append(pointer, count: size)
            }
        }
        let length = CMBlockBufferGetDataLength(buffer)
        var avcc = Data(count: length)
        let copied = avcc.withUnsafeMutableBytes { raw in CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: length, destination: raw.baseAddress!) }
        guard copied == noErr else { fail("Could not read H.264 output") }
        var offset = 0
        while offset < avcc.count {
            guard offset + Int(headerLength) <= avcc.count else { fail("Truncated H.264 length") }
            var size = 0
            for byte in avcc[offset..<offset + Int(headerLength)] { size = (size << 8) | Int(byte) }
            offset += Int(headerLength)
            guard size > 0, size <= avcc.count - offset else { fail("Truncated H.264 NAL") }
            encoded.append(contentsOf: [0, 0, 0, 1]); encoded.append(avcc[offset..<offset + size]); offset += size
        }
        produced = true
        packet(3, encoded)
    }
}

final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
    var stream: SCStream?
    let input = Input()
    var scale: UInt32 = 1000
    var config: SCStreamConfiguration?
    func resize(_ width: Int, _ height: Int) {
        guard let stream = stream, let config = config else { return }
        let pw = CGDisplayPixelsWide(input.display), ph = CGDisplayPixelsHigh(input.display)
        let ratio = min(1, min(Double(max(2, min(width, 1920))) / Double(pw), Double(max(2, min(height, 1200))) / Double(ph)))
        let w = max(2, Int(Double(pw) * ratio) / 2 * 2), h = max(2, Int(Double(ph) * ratio) / 2 * 2)
        if config.width == w && config.height == h { return }
        config.width = w; config.height = h
        Task { do { try await stream.updateConfiguration(config) } catch { fail("Could not resize capture: \(error.localizedDescription)") } }
    }
    func start(_ requested: String, _ maxWidth: Int, _ maxHeight: Int, _ fps: Int) async {
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            fail("Screen Recording permission is required. Open Gliff on this Mac and enable it in System Settings > Privacy & Security > Screen & System Audio Recording, then reconnect.")
        }
        guard AXIsProcessTrusted() else {
            fail("Accessibility permission is required to control this Mac. Enable Gliff in System Settings > Privacy & Security > Accessibility, then reconnect.")
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { requested == "auto" ? $0.displayID == CGMainDisplayID() : String($0.displayID) == requested || "display-\($0.displayID)" == requested }) else {
                fail("Display \(requested) was not found. Use gliff-server --outputs to list displays.")
            }
            input.display = display.displayID
            let physicalWidth = CGDisplayPixelsWide(display.displayID)
            let physicalHeight = CGDisplayPixelsHigh(display.displayID)
            let ratio = min(1, min(Double(maxWidth) / Double(physicalWidth), Double(maxHeight) / Double(physicalHeight)))
            let width = max(2, Int(Double(physicalWidth) * ratio) / 2 * 2)
            let height = max(2, Int(Double(physicalHeight) * ratio) / 2 * 2)
            scale = UInt32(max(1, Double(width) / CGDisplayBounds(display.displayID).width * 1000))
            let config = SCStreamConfiguration()
            config.width = width; config.height = height
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.colorSpaceName = CGColorSpace.sRGB
            config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(fps))
            config.queueDepth = 3; config.showsCursor = true
            self.config = config
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "gliff.capture", qos: .userInteractive))
            self.stream = stream
            event(["type": "ready", "width": width, "height": height, "scale_milli": scale, "output": "display-\(display.displayID)"])
            try await stream.startCapture()
            DispatchQueue.main.async { clipboard.start() }
        } catch { fail("Screen capture failed: \(error.localizedDescription)") }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { fail("Screen capture stopped: \(error.localizedDescription)") }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        autoreleasepool { sendFrame(sample, type) }
    }
    func sendFrame(_ sample: CMSampleBuffer, _ type: SCStreamOutputType) {
        guard type == .screen, sample.isValid, let buffer = sample.imageBuffer else { return }
        // Skip idle/blank samples; ScreenCaptureKit can reuse their previous image.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]], let raw = attachments.first?[.status] as? Int, raw != SCFrameStatus.complete.rawValue { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var data = Data(capacity: 12 + width * height * 4)
        let frameScale = UInt32(max(1, Double(width) / CGDisplayBounds(input.display).width * 1000))
        append(UInt32(width), &data); append(UInt32(height), &data); append(frameScale, &data)
        for row in 0..<height { data.append(base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self), count: width * 4) }
        packet(1, data)
    }
}

// The hardware stream: ScreenCaptureKit hands IOSurface frames at the stream
// size, a Metal kernel splits each into AVC444's main and auxiliary NV12
// (the twin of gliff-vk's split.comp, BT.709 limited range), and one
// VideoToolbox session per plane set encodes them. No frame is copied
// through the CPU. The bridge grants one encode at a time ("frame"), so the
// link, not the screen, sets the pace and the frame sent is always the
// newest one.
let splitSource = """
#include <metal_stdlib>
using namespace metal;
static float luma(float3 c) { return (16.0 + 0.1826 * c.r + 0.6142 * c.g + 0.0620 * c.b) / 255.0; }
static float chroma_u(float3 c) { return (128.0 - 0.1006 * c.r - 0.3386 * c.g + 0.4392 * c.b) / 255.0; }
static float chroma_v(float3 c) { return (128.0 + 0.4392 * c.r - 0.3989 * c.g - 0.0403 * c.b) / 255.0; }
static float3 px(texture2d<float, access::read> src, int x, int y) {
    uint2 p = uint2(clamp(x, 0, int(src.get_width()) - 1), clamp(y, 0, int(src.get_height()) - 1));
    return src.read(p).rgb * 255.0;
}
kernel void split(texture2d<float, access::read> src [[texture(0)]],
                  texture2d<float, access::write> main_y [[texture(1)]],
                  texture2d<float, access::write> main_uv [[texture(2)]],
                  texture2d<float, access::write> aux_y [[texture(3)]],
                  texture2d<float, access::write> aux_uv [[texture(4)]],
                  constant int &has_aux [[buffer(0)]],
                  uint2 gid [[thread_position_in_grid]]) {
    int width = int(main_y.get_width()), height = int(main_y.get_height());
    int bx = int(gid.x), by = int(gid.y), x = 2 * bx, y = 2 * by;
    if (x >= width || y >= height) return;
    float3 c00 = px(src, x, y), c10 = px(src, x + 1, y), c01 = px(src, x, y + 1), c11 = px(src, x + 1, y + 1);
    main_y.write(float4(luma(c00)), uint2(x, y));
    main_y.write(float4(luma(c10)), uint2(x + 1, y));
    main_y.write(float4(luma(c01)), uint2(x, y + 1));
    main_y.write(float4(luma(c11)), uint2(x + 1, y + 1));
    main_uv.write(float4(chroma_u(c00), chroma_v(c00), 0.0, 0.0), uint2(bx, by));
    if (has_aux == 0) return;
    aux_uv.write(float4(chroma_u(c10), chroma_v(c10), 0.0, 0.0), uint2(bx, by));
    int half_h = height / 2;
    aux_y.write(float4(chroma_u(c01)), uint2(x, by));
    aux_y.write(float4(chroma_u(c11)), uint2(x + 1, by));
    aux_y.write(float4(chroma_v(c01)), uint2(x, half_h + by));
    aux_y.write(float4(chroma_v(c11)), uint2(x + 1, half_h + by));
}
"""

func annexB(_ sample: CMSampleBuffer) -> (Data, Bool)? {
    guard sample.isValid, let format = sample.formatDescription, let buffer = sample.dataBuffer else { return nil }
    let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
    let keyframe = (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    var encoded = Data()
    var pointer: UnsafePointer<UInt8>?, size = 0, count = 0, headerLength: Int32 = 0
    guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength) == noErr,
          headerLength >= 1, headerLength <= 4 else { return nil }
    if keyframe {
        for i in 0..<count {
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                  let pointer = pointer, size > 0 else { return nil }
            encoded.append(contentsOf: [0, 0, 0, 1]); encoded.append(pointer, count: size)
        }
    }
    let length = CMBlockBufferGetDataLength(buffer)
    var avcc = Data(count: length)
    let copied = avcc.withUnsafeMutableBytes { raw in CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: length, destination: raw.baseAddress!) }
    guard copied == noErr else { return nil }
    var offset = 0
    while offset < avcc.count {
        guard offset + Int(headerLength) <= avcc.count else { return nil }
        var size = 0
        for byte in avcc[offset..<offset + Int(headerLength)] { size = (size << 8) | Int(byte) }
        offset += Int(headerLength)
        guard size > 0, size <= avcc.count - offset else { return nil }
        encoded.append(contentsOf: [0, 0, 0, 1]); encoded.append(avcc[offset..<offset + size]); offset += size
    }
    return (encoded, keyframe)
}

// One VideoToolbox H.264 session: High profile, no reordering, keyframes
// only on request, rate changed in place.
final class VTStream {
    var session: VTCompressionSession?
    let width: Int, height: Int
    var output: Data?
    var keyframe = false
    init(_ width: Int, _ height: Int, _ bitrate: Int, _ fps: Int, _ vbvMs: Int) throws {
        self.width = width; self.height = height
        let attributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                          kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                          kCVPixelBufferMetalCompatibilityKey: true,
                          kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        let callback: VTCompressionOutputCallback = { refcon, _, status, flags, sample in
            guard let refcon = refcon else { return }
            let stream = Unmanaged<VTStream>.fromOpaque(refcon).takeUnretainedValue()
            autoreleasepool {
                if status == noErr, !flags.contains(.frameDropped), let sample = sample, let (data, key) = annexB(sample) {
                    stream.output = data; stream.keyframe = key
                }
            }
        }
        // Low-latency rate control keeps each frame near its budget instead
        // of averaging over a window; fall back where it is not offered.
        var created = noErr
        for lowLatency in [true, false] {
            var spec: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
            if lowLatency { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
            created = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
                encoderSpecification: spec as CFDictionary, imageBufferAttributes: attributes, compressedDataAllocator: nil,
                outputCallback: callback, refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &session)
            if created == noErr { break }
        }
        guard created == noErr, let session = session else { throw NSError(domain: "Gliff.Encoder", code: Int(created), userInfo: [NSLocalizedDescriptionKey: "create hardware encoder failed (\(created))"]) }
        let required: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel),
        ]
        for (key, value) in required {
            let status = VTSessionSetProperty(session, key: key, value: value)
            if status != noErr { close(); throw NSError(domain: "Gliff.Encoder", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "set \(key) failed (\(status))"]) }
        }
        let optional: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, Int32.max as CFNumber),
            (kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 86400 as CFNumber),
            (kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2),
            (kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2),
            (kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
            (kVTCompressionPropertyKey_MaximizePowerEfficiency, kCFBooleanFalse),
            // One short-term reference, as the Linux encoder codes it: the
            // clients' VA-API parser takes no long-term reference marking.
            (kVTCompressionPropertyKey_EnableLTR, kCFBooleanFalse),
            (kVTCompressionPropertyKey_ReferenceBufferCount, 1 as CFNumber),
        ]
        for (key, value) in optional { _ = VTSessionSetProperty(session, key: key, value: value) }
        setRate(bitrate, fps, vbvMs)
        let prepared = VTCompressionSessionPrepareToEncodeFrames(session)
        if prepared != noErr { close(); throw NSError(domain: "Gliff.Encoder", code: Int(prepared), userInfo: [NSLocalizedDescriptionKey: "prepare hardware encoder failed (\(prepared))"]) }
        // The specification requires hardware, so creation fails without it.
        // (Low-latency sessions do not report UsingHardwareAcceleratedVideoEncoder.)
    }
    func setRate(_ bitrate: Int, _ fps: Int, _ vbvMs: Int) {
        guard let session = session else { return }
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: max(bitrate, 10_000) as CFNumber)
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: max(fps, 1) as CFNumber)
        let window = Double(max(vbvMs, 50)) / 1000
        let limits = [Double(bitrate) / 8 * window, window] as CFArray
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
    }
    var pool: CVPixelBufferPool? { session.flatMap { VTCompressionSessionGetPixelBufferPool($0) } }
    func submit(_ pixel: CVPixelBuffer, _ pts: CMTime, _ keyframe: Bool) -> OSStatus {
        guard let session = session else { return -1 }
        output = nil
        let properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: keyframe] as CFDictionary
        return VTCompressionSessionEncodeFrame(session, imageBuffer: pixel, presentationTimeStamp: pts, duration: .invalid, frameProperties: properties, sourceFrameRefcon: nil, infoFlagsOut: nil)
    }
    func complete() { if let session = session { VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid) } }
    func close() { if let session = session { VTCompressionSessionInvalidate(session); self.session = nil } }
    deinit { close() }
}

final class Streamer: NSObject, SCStreamOutput, SCStreamDelegate {
    var stream: SCStream?
    var config: SCStreamConfiguration?
    let input = Input()
    let queue = DispatchQueue(label: "gliff.stream", qos: .userInteractive)
    let device: MTLDevice
    let commands: MTLCommandQueue
    let pipeline: MTLComputePipelineState
    var cache: CVMetalTextureCache?
    var pointsWidth = 1.0
    // Owned by `queue`.
    var latest: CVPixelBuffer?
    var dirty = false
    var granted = false
    var wantKeyframe = true
    var dual: Bool
    var bitrate: Int, fps: Int, vbvMs: Int
    var main: VTStream?, aux: VTStream?
    init(dual: Bool, bitrate: Int, fps: Int, vbvMs: Int) throws {
        self.dual = dual; self.bitrate = bitrate; self.fps = fps; self.vbvMs = vbvMs
        guard let device = MTLCreateSystemDefaultDevice(), let commands = device.makeCommandQueue() else { throw NSError(domain: "Gliff.Stream", code: 1, userInfo: [NSLocalizedDescriptionKey: "Metal is unavailable"]) }
        self.device = device; self.commands = commands
        let library = try device.makeLibrary(source: splitSource, options: nil)
        guard let function = library.makeFunction(name: "split") else { throw NSError(domain: "Gliff.Stream", code: 2) }
        pipeline = try device.makeComputePipelineState(function: function)
        super.init()
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        // Fail before the session starts if this Mac cannot encode in hardware.
        _ = try VTStream(64, 64, 1_000_000, 30, 250)
    }
    func start(_ requested: String, _ width: Int, _ height: Int, _ captureFps: Int) async {
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            fail("Screen Recording permission is required. Open Gliff on this Mac and enable it in System Settings > Privacy & Security > Screen & System Audio Recording, then reconnect.")
        }
        guard AXIsProcessTrusted() else {
            fail("Accessibility permission is required to control this Mac. Enable Gliff in System Settings > Privacy & Security > Accessibility, then reconnect.")
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { requested == "auto" ? $0.displayID == CGMainDisplayID() : String($0.displayID) == requested || "display-\($0.displayID)" == requested }) else {
                fail("Display \(requested) was not found. Use gliff-server --outputs to list displays.")
            }
            input.display = display.displayID
            let mode = CGDisplayCopyDisplayMode(display.displayID)
            let bounds = CGDisplayBounds(display.displayID)
            pointsWidth = bounds.width
            let nativeWidth = mode?.pixelWidth ?? Int(bounds.width), nativeHeight = mode?.pixelHeight ?? Int(bounds.height)
            let config = SCStreamConfiguration()
            // Start at the display scaled into the requested box (never up).
            let fit = min(1, min(Double(width) / Double(nativeWidth), Double(height) / Double(nativeHeight)))
            config.width = max(2, Int(Double(nativeWidth) * fit) & ~1); config.height = max(2, Int(Double(nativeHeight) * fit) & ~1)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.colorSpaceName = CGColorSpace.sRGB
            config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(max(captureFps, 1)))
            config.queueDepth = 5; config.showsCursor = true
            self.config = config
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            self.stream = stream
            event(["type": "ready", "output": "display-\(display.displayID)", "native_width": nativeWidth, "native_height": nativeHeight,
                   "points_width": Int(bounds.width), "points_height": Int(bounds.height), "refresh": mode?.refreshRate ?? 0])
            try await stream.startCapture()
            DispatchQueue.main.async { clipboard.start() }
        } catch { fail("Screen capture failed: \(error.localizedDescription)") }
    }
    func resize(_ width: Int, _ height: Int) {
        guard let stream = stream, let config = config else { return }
        let w = max(2, width & ~1), h = max(2, height & ~1)
        if config.width == w && config.height == h { return }
        config.width = w; config.height = h
        Task { do { try await stream.updateConfiguration(config) } catch { fail("Could not resize capture: \(error.localizedDescription)") } }
    }
    // Commands from the bridge, already on `queue`.
    func command(_ cmd: [String: Any]) {
        switch cmd["type"] as? String {
        case "frame":
            granted = true
            if cmd["keyframe"] as? Bool == true { wantKeyframe = true }
            pump(refresh: false)
        case "refresh":
            pump(refresh: true)
        case "rate":
            bitrate = cmd["bitrate"] as? Int ?? bitrate; fps = cmd["fps"] as? Int ?? fps; vbvMs = cmd["vbv_ms"] as? Int ?? vbvMs
            main?.setRate(bitrate, fps, vbvMs); aux?.setRate(bitrate, fps, vbvMs)
        case "chroma":
            let want = cmd["dual"] as? Bool ?? dual
            if want != dual { dual = want; aux = nil; wantKeyframe = true }
        default: break
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { fail("Screen capture stopped: \(error.localizedDescription)") }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid, let buffer = sample.imageBuffer else { return }
        // Idle samples repeat the previous image.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]], let raw = attachments.first?[.status] as? Int, raw != SCFrameStatus.complete.rawValue { return }
        latest = buffer; dirty = true
        pump(refresh: false)
    }
    // Encode the newest frame when the bridge has granted one; a refresh
    // re-encodes the kept frame so a still screen sharpens.
    func pump(refresh: Bool) {
        guard granted, let frame = latest, dirty || refresh else { return }
        let still = !dirty
        granted = false; dirty = false
        autoreleasepool { encode(frame, refresh: still) }
    }
    func texture(_ pixel: CVPixelBuffer, _ plane: Int, _ format: MTLPixelFormat) -> (CVMetalTexture, MTLTexture)? {
        guard let cache = cache else { return nil }
        let w = plane == 0 ? CVPixelBufferGetWidth(pixel) : CVPixelBufferGetWidthOfPlane(pixel, plane)
        let h = plane == 0 ? CVPixelBufferGetHeight(pixel) : CVPixelBufferGetHeightOfPlane(pixel, plane)
        var out: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixel, nil, format, w, h, plane, &out) == kCVReturnSuccess,
              let out = out, let texture = CVMetalTextureGetTexture(out) else { return nil }
        return (out, texture)
    }
    func surface(_ stream: VTStream) -> CVPixelBuffer? {
        guard let pool = stream.pool else { return nil }
        var pixel: CVPixelBuffer?
        let limits = [kCVPixelBufferPoolAllocationThresholdKey: 4] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, limits, &pixel) == kCVReturnSuccess, let pixel = pixel else { return nil }
        CVBufferSetAttachment(pixel, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixel, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixel, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return pixel
    }
    func encode(_ frame: CVPixelBuffer, refresh: Bool) {
        let started = DispatchTime.now().uptimeNanoseconds
        let width = CVPixelBufferGetWidth(frame) & ~1, height = CVPixelBufferGetHeight(frame) & ~1
        do {
            if main?.width != width || main?.height != height { main = nil; aux = nil }
            if main == nil { main = try VTStream(width, height, bitrate, fps, vbvMs); wantKeyframe = true }
            if dual && aux == nil { aux = try VTStream(width, height, bitrate, fps, vbvMs); wantKeyframe = true }
        } catch { fail("Hardware encoder failed: \(error.localizedDescription)") }
        guard let main = main, let mainPixel = surface(main) else { return skip() }
        let auxPixel = aux.flatMap { surface($0) }
        if dual && auxPixel == nil { return skip() }
        guard let src = texture(frame, 0, .bgra8Unorm), let my = texture(mainPixel, 0, .r8Unorm), let muv = texture(mainPixel, 1, .rg8Unorm),
              let buffer = commands.makeCommandBuffer(), let encoder = buffer.makeComputeCommandEncoder() else { return skip() }
        let ay = auxPixel.flatMap { texture($0, 0, .r8Unorm) }, auv = auxPixel.flatMap { texture($0, 1, .rg8Unorm) }
        var hasAux: Int32 = auxPixel == nil ? 0 : 1
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(src.1, index: 0); encoder.setTexture(my.1, index: 1); encoder.setTexture(muv.1, index: 2)
        encoder.setTexture(ay?.1 ?? my.1, index: 3); encoder.setTexture(auv?.1 ?? muv.1, index: 4)
        encoder.setBytes(&hasAux, length: 4, index: 0)
        let group = MTLSize(width: 16, height: 16, depth: 1)
        let blocks = MTLSize(width: (width / 2 + 15) / 16, height: (height / 2 + 15) / 16, depth: 1)
        encoder.dispatchThreadgroups(blocks, threadsPerThreadgroup: group)
        encoder.endEncoding()
        buffer.commit(); buffer.waitUntilCompleted()
        withExtendedLifetime((src, my, muv, ay, auv)) {}
        let key = wantKeyframe
        let pts = CMClockGetTime(CMClockGetHostTimeClock())
        var status = main.submit(mainPixel, pts, key)
        if status == noErr, let aux = aux, let auxPixel = auxPixel { status = aux.submit(auxPixel, pts, key) }
        main.complete(); aux?.complete()
        guard status == noErr else { fail("Hardware encoding failed (\(status))") }
        // A dropped plane would desynchronise the pair; resend both as a keyframe.
        guard let mainData = main.output, auxPixel == nil || aux?.output != nil else { return skip() }
        wantKeyframe = false
        let auxData = auxPixel == nil ? Data() : aux?.output ?? Data()
        var packetData = Data(capacity: 28 + mainData.count + auxData.count)
        append((main.keyframe ? 1 : 0) | (refresh ? 2 : 0), &packetData)
        append(UInt32(width), &packetData); append(UInt32(height), &packetData)
        append(UInt32(max(1, Double(width) / pointsWidth * 1000)), &packetData)
        append(UInt32(mainData.count), &packetData); append(UInt32(auxData.count), &packetData)
        append(UInt32(min(UInt64(UInt32.max), (DispatchTime.now().uptimeNanoseconds - started) / 1000)), &packetData)
        packetData.append(mainData); packetData.append(auxData)
        packet(3, packetData)
    }
    // Nothing was coded: hand the grant back and start the next pair clean.
    func skip() {
        wantKeyframe = true
        var empty = Data()
        for _ in 0..<7 { append(0, &empty) }
        packet(3, empty)
    }
}

final class RemoteView: NSView {
    var image: CGImage? {
        didSet { window?.invalidateCursorRects(for: self) }
    }
    private let invisibleCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1), flipped: false, drawingHandler: { _ in true }), hotSpot: .zero)
    var cursorInVideo = false {
        didSet { window?.invalidateCursorRects(for: self) }
    }
    var scale: Double = 1
    var pressed: Set<UInt16> = []
    var buttons: Set<Int> = []
    var released = false
    var hovering = false
    var message = "Connecting…"
    var tracking: NSTrackingArea?
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override func updateTrackingAreas() {
        if let old = tracking { removeTrackingArea(old) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area); tracking = area
        super.updateTrackingAreas()
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        if image != nil && cursorInVideo { addCursorRect(pictureRect, cursor: invisibleCursor) }
    }
    var pictureRect: NSRect {
        guard let image = image else { return .zero }
        let ratio = min(bounds.width / Double(image.width), bounds.height / Double(image.height))
        let w = Double(image.width) * ratio, h = Double(image.height) * ratio
        return NSRect(x: (bounds.width - w)/2, y: (bounds.height - h)/2, width: w, height: h)
    }
    override func draw(_ dirty: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        if let image = image, let cg = NSGraphicsContext.current?.cgContext {
            cg.saveGState(); cg.interpolationQuality = .none
            let r = pictureRect
            cg.translateBy(x: r.minX, y: r.maxY); cg.scaleBy(x: 1, y: -1)
            cg.draw(image, in: CGRect(x: 0, y: 0, width: r.width, height: r.height)); cg.restoreGState()
        } else {
            let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 16)]
            let text = message as NSString
            let size = text.size(withAttributes: attrs)
            text.draw(in: NSRect(x: 24, y: bounds.height/2, width: max(bounds.width-48, size.width), height: 100), withAttributes: attrs)
        }
    }
    func release() {
        for key in pressed { event(["type": "key", "keycode": key, "pressed": false]) }
        for button in buttons { event(["type": "button", "button": button, "pressed": false]) }
        pressed.removeAll(); buttons.removeAll()
    }
    func key(_ e: NSEvent, _ down: Bool) {
        if down && e.keyCode == 53 && e.modifierFlags.contains(.shift) { release(); released = true; return }
        guard hovering, !released, !e.isARepeat else { return }
        if down { pressed.insert(e.keyCode) } else { pressed.remove(e.keyCode) }
        event(["type": "key", "keycode": e.keyCode, "pressed": down])
    }
    override func keyDown(with e: NSEvent) { key(e, true) }
    override func keyUp(with e: NSEvent) { key(e, false) }
    override func flagsChanged(with e: NSEvent) {
        guard hovering, !released else { return }
        // Caps Lock sends flagsChanged on both toggle directions, rather than
        // ordinary key-down/up events. Each transition must toggle the host.
        if e.keyCode == 57 {
            event(["type": "key", "keycode": 57, "pressed": true])
            event(["type": "key", "keycode": 57, "pressed": false])
            return
        }
        let mask: NSEvent.ModifierFlags
        switch e.keyCode {
        case 54, 55: mask = .command
        case 56, 60: mask = .shift
        case 58, 61: mask = .option
        case 59, 62: mask = .control
        default: return
        }
        let down = e.modifierFlags.contains(mask) && !pressed.contains(e.keyCode)
        if down { pressed.insert(e.keyCode) } else { pressed.remove(e.keyCode) }
        event(["type": "key", "keycode": e.keyCode, "pressed": down])
    }
    func motion(_ e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil), r = pictureRect
        guard let image = image, r.contains(p) else {
            if hovering { release() }
            hovering = false
            return
        }
        hovering = true
        event(["type": "motion", "x": (p.x-r.minX)/r.width*Double(image.width)/scale, "y": (p.y-r.minY)/r.height*Double(image.height)/scale])
    }
    override func mouseMoved(with e: NSEvent) { motion(e) }
    override func mouseDragged(with e: NSEvent) { motion(e) }
    override func rightMouseDragged(with e: NSEvent) { motion(e) }
    override func otherMouseDragged(with e: NSEvent) { motion(e) }
    override func mouseEntered(with e: NSEvent) { hovering = pictureRect.contains(convert(e.locationInWindow, from: nil)); released = false }
    override func mouseExited(with e: NSEvent) { hovering = false; release() }
    func button(_ e: NSEvent, _ down: Bool) {
        if down { hovering = true; released = false; window?.makeFirstResponder(self); buttons.insert(e.buttonNumber) } else { buttons.remove(e.buttonNumber) }
        motion(e); event(["type": "button", "button": e.buttonNumber, "pressed": down])
    }
    override func mouseDown(with e: NSEvent) { button(e, true) }
    override func mouseUp(with e: NSEvent) { button(e, false) }
    override func rightMouseDown(with e: NSEvent) { button(e, true) }
    override func rightMouseUp(with e: NSEvent) { button(e, false) }
    override func otherMouseDown(with e: NSEvent) { button(e, true) }
    override func otherMouseUp(with e: NSEvent) { button(e, false) }
    override func scrollWheel(with e: NSEvent) {
        guard pictureRect.contains(convert(e.locationInWindow, from: nil)) else { return }
        let factor = e.hasPreciseScrollingDeltas ? 1.0 : 10.0
        if e.scrollingDeltaY != 0 { event(["type": "axis", "horizontal": false, "value": -e.scrollingDeltaY * factor]) }
        if e.scrollingDeltaX != 0 { event(["type": "axis", "horizontal": true, "value": -e.scrollingDeltaX * factor]) }
    }
}

final class App: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let view = RemoteView()
    var window: NSWindow?
    var pending: Data?
    let pendingLock = NSLock()
    var drawing = false
    var painted = false
    func applicationDidFinishLaunching(_ note: Notification) {
        let menu = NSMenu(); let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        let hosting = appMenu.addItem(withTitle: "Enable Remote Control…", action: #selector(App.requestHostPermissions), keyEquivalent: "")
        hosting.target = self
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Gliff", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApplication.shared.mainMenu = menu
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = CommandLine.arguments.dropFirst(2).first ?? "Gliff"
        w.contentView = view; w.delegate = self; w.acceptsMouseMovedEvents = true
        w.center(); w.makeKeyAndOrderFront(nil); w.makeFirstResponder(view); window = w
        NSApplication.shared.activate(ignoringOtherApps: true)
        clipboard.start()
        resizeEvent()
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] e in
            guard let self = self, self.window?.isKeyWindow == true, !self.view.released, self.view.hovering, self.view.image != nil else { return e }
            self.view.key(e, e.type == .keyDown); return nil
        }
        readCommands { [weak self] kind, data in
            guard let self = self else { return }
            if kind == 1 {
                self.pendingLock.lock(); self.pending = data
                let schedule = !self.drawing; self.drawing = true; self.pendingLock.unlock()
                if schedule { DispatchQueue.main.async { autoreleasepool { self.drawPending() } } }
            } else {
                let cmd = json(data)
                if clipboard.receive(cmd) { return }
                DispatchQueue.main.async {
                    clipboard.command(cmd)
                    if cmd["type"] as? String == "cursor_mode" { self.view.cursorInVideo = cmd["embedded"] as? Bool == true }
                    if let message = cmd["message"] as? String { self.view.message = message; self.view.image = nil; self.view.needsDisplay = true }
                    if let text = cmd["clipboard"] as? String { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
                }
            }
        }
    }
    @objc func requestHostPermissions() {
        _ = CGRequestScreenCaptureAccess()
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }
    func drawPending() {
        pendingLock.lock(); let data = pending; pending = nil; drawing = false; pendingLock.unlock()
        guard let data = data, data.count >= 12 else { return }
        let w = Int(number(data, 0)), h = Int(number(data, 4)), s = number(data, 8)
        guard w > 0, h > 0, s > 0, w * h * 4 == data.count - 12, let provider = CGDataProvider(data: data.subdata(in: 12..<data.count) as CFData) else { return }
        view.image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue).union(.byteOrder32Little), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        view.scale = Double(s)/1000; view.needsDisplay = true
        if !painted { painted = true; diagnostic("Gliff displayed first frame: \(w)x\(h)") }
    }
    func resizeEvent() {
        let factor = window?.backingScaleFactor ?? 1
        event(["type": "resize", "width": Int(view.bounds.width * factor), "height": Int(view.bounds.height * factor), "scale": factor])
    }
    func windowDidResize(_ note: Notification) { resizeEvent() }
    func windowDidResignKey(_ note: Notification) { view.release() }
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ note: Notification) { view.release(); event(["type": "bye"]) }
}

struct NearbyComputer {
    let id: String
    let name: String
    let host: String
    let port: Int
    let user: String
    let platform: String
    var address: String { user.isEmpty ? host : "\(user)@\(host)" }
    var displayName: String {
        let hostname = host.hasSuffix(".local") ? String(host.dropLast(6)) : host
        return name == "Gliff on \(hostname) (\(user))" ? hostname : name
    }
    var value: [String: Any] { ["name": name, "host": host, "port": port, "user": user, "platform": platform] }
}

// Bonjour supplies additions/removals rather than repeated subnet scans.
// Keep at most 128 service objects and resolve names only, not SSH connections.
final class NearbyComputers: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    let browser = NetServiceBrowser()
    var services: [String: NetService] = [:]
    var records: [String: NearbyComputer] = [:]
    var onChange: (() -> Void)?
    var failure: String?
    var computers: [NearbyComputer] {
        records.values.sorted { ($0.name, $0.address) < ($1.name, $1.address) }
    }
    func key(_ service: NetService) -> String { "\(service.name)\n\(service.type)\n\(service.domain)" }
    func start() {
        stop(); failure = nil
        browser.delegate = self
        browser.searchForServices(ofType: "_gliff._tcp.", inDomain: "local.")
        onChange?()
    }
    func stop() {
        browser.stop()
        for service in services.values { service.stopMonitoring(); service.stop(); service.delegate = nil }
        services.removeAll(); records.removeAll()
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        let id = key(service)
        guard services[id] == nil, services.count < 128 else { return }
        services[id] = service; service.delegate = self
        service.resolve(withTimeout: 5)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let id = key(service)
        if let old = services.removeValue(forKey: id) {
            old.stopMonitoring(); old.stop(); old.delegate = nil
        }
        records.removeValue(forKey: id)
        onChange?()
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        failure = "Nearby computers unavailable. Allow Gliff in System Settings → Privacy & Security → Local Network, or enter an SSH address."
        onChange?()
    }
    func netServiceDidResolveAddress(_ service: NetService) {
        update(service); service.startMonitoring()
    }
    func netService(_ service: NetService, didUpdateTXTRecord data: Data) { update(service) }
    func netService(_ service: NetService, didNotResolve errorDict: [String: NSNumber]) {
        records.removeValue(forKey: key(service)); onChange?()
    }
    func update(_ service: NetService) {
        let id = key(service)
        guard services[id] === service else { return }
        let txt = NetService.dictionary(fromTXTRecord: service.txtRecordData() ?? Data())
        func text(_ key: String) -> String { txt[key].flatMap { String(data: $0, encoding: .utf8) } ?? "" }
        let host = (service.hostName ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard text("transport") == "ssh", text("protocol") == "1", (1...65535).contains(service.port),
              host.range(of: "^[A-Za-z0-9_][A-Za-z0-9_.-]{0,252}$", options: .regularExpression) != nil else {
            records.removeValue(forKey: id); onChange?(); return
        }
        let hint = text("user")
        let user = hint.range(of: "^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$", options: .regularExpression) != nil ? hint : ""
        records[id] = NearbyComputer(id: id, name: service.name, host: host, port: service.port, user: user, platform: text("platform"))
        onChange?()
    }
}

final class ComputerPickerRow: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let color = isEmphasized ? NSColor.selectedContentBackgroundColor : NSColor.unemphasizedSelectedContentBackgroundColor
        color.setFill()
        var rect = bounds.insetBy(dx: 4, dy: 3)
        if let scroll = enclosingScrollView { rect.size.width = min(bounds.width, scroll.contentSize.width) - 8 }
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
    }
}

final class ComputerPicker: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let nearby = NearbyComputers()
    let table = NSTableView()
    let address = NSTextField(string: "")
    let port = NSTextField(string: "22")
    let status = NSTextField(wrappingLabelWithString: "Searching the local network…")
    let progress = NSProgressIndicator()
    var window: NSWindow?
    var listHeight: NSLayoutConstraint?
    var rows: [NearbyComputer] = []
    var updating = false
    var finished = false
    var selectedID: String?
    func label(_ text: String, _ size: CGFloat = 13) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: size); return label
    }
    func stack(_ views: [NSView], _ orientation: NSUserInterfaceLayoutOrientation, _ spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = orientation; stack.spacing = spacing
        stack.alignment = orientation == .vertical ? .leading : .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }
    func applicationDidFinishLaunching(_ note: Notification) {
        let menu = NSMenu(); let item = NSMenuItem(); menu.addItem(item)
        let appMenu = NSMenu(); item.submenu = appMenu
        let permission = appMenu.addItem(withTitle: "Enable Remote Control…", action: #selector(hostPermissions), keyEquivalent: "")
        permission.target = self
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Gliff", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApplication.shared.mainMenu = menu
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 340), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "Gliff"; w.delegate = self
        let background = NSBox()
        background.boxType = .custom; background.titlePosition = .noTitle
        background.borderWidth = 0; background.fillColor = .underPageBackgroundColor
        w.contentView = background
        let view = w.contentView!
        let card = NSBox()
        card.boxType = .custom; card.titlePosition = .noTitle
        card.fillColor = .controlBackgroundColor; card.borderColor = .separatorColor
        card.borderWidth = 0.5; card.cornerRadius = 16
        card.contentViewMargins = .zero; card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true; card.layer?.cornerRadius = 16
        card.layer?.shadowColor = NSColor.black.cgColor; card.layer?.shadowOpacity = 0.12
        card.layer?.shadowRadius = 12; card.layer?.shadowOffset = NSSize(width: 0, height: -4)
        view.addSubview(card)
        let title = label("Connect to a Computer", 18)
        title.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        let subtitle = label("Choose a nearby computer or enter an SSH address.")
        subtitle.textColor = .secondaryLabelColor
        let heading = stack([title, subtitle], .vertical, 4)
        let list = NSBox()
        list.boxType = .custom; list.titlePosition = .noTitle
        list.fillColor = .controlBackgroundColor; list.borderColor = .separatorColor
        list.borderWidth = 0.5; list.cornerRadius = 8; list.contentViewMargins = .zero
        list.wantsLayer = true; list.layer?.cornerRadius = 8; list.layer?.masksToBounds = true
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true; scroll.borderType = .noBorder
        for (id, title, width) in [("name", "Computer", CGFloat(180)), ("address", "SSH Address", CGFloat(324))] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width
            table.addTableColumn(column)
        }
        table.delegate = self; table.dataSource = self; table.rowHeight = 30
        table.style = .inset; table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel("Nearby Computers")
        table.frame = NSRect(x: 0, y: 0, width: 536, height: 66); table.autoresizingMask = [.width]
        table.target = self; table.doubleAction = #selector(connect)
        scroll.documentView = table; list.contentView!.addSubview(scroll)
        progress.style = .spinning; progress.controlSize = .small
        progress.isIndeterminate = true; progress.isDisplayedWhenStopped = false
        progress.setAccessibilityLabel("Searching for nearby computers")
        status.font = NSFont.systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        status.preferredMaxLayoutWidth = 496
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let refresh = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh Nearby Computers")!, target: self, action: #selector(refresh))
        refresh.bezelStyle = .inline; refresh.controlSize = .small
        refresh.toolTip = "Refresh Nearby Computers"; refresh.setAccessibilityLabel("Refresh Nearby Computers")
        let statusRow = stack([progress, status, refresh], .horizontal, 8)
        address.placeholderString = "user@computer.local"
        address.bezelStyle = .roundedBezel; port.bezelStyle = .roundedBezel
        address.font = NSFont.systemFont(ofSize: 13); port.font = address.font
        address.setAccessibilityLabel("SSH Address"); port.setAccessibilityLabel("SSH Port")
        address.setContentHuggingPriority(.defaultLow, for: .horizontal)
        address.delegate = self; port.delegate = self
        let fields = stack([label("SSH Address:"), address, label("Port:"), port], .horizontal, 10)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded; cancel.controlSize = .large; cancel.keyEquivalent = "\u{1b}"
        let connect = NSButton(title: "Connect", target: self, action: #selector(connect))
        connect.bezelStyle = .rounded; connect.controlSize = .large; connect.keyEquivalent = "\r"
        let actions = stack([NSView(), cancel, connect], .horizontal, 8)
        let content = stack([heading, list, statusRow, fields, actions], .vertical, 12)
        card.contentView!.addSubview(content)
        for row in [heading, list, statusRow, fields, actions] { row.translatesAutoresizingMaskIntoConstraints = false }
        let listHeight = list.heightAnchor.constraint(equalToConstant: 66)
        self.listHeight = listHeight
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 600),
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            card.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            card.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            content.leadingAnchor.constraint(equalTo: card.contentView!.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: card.contentView!.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: card.contentView!.topAnchor, constant: 20),
            content.bottomAnchor.constraint(equalTo: card.contentView!.bottomAnchor, constant: -20),
            list.widthAnchor.constraint(equalTo: content.widthAnchor),
            listHeight,
            scroll.leadingAnchor.constraint(equalTo: list.contentView!.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: list.contentView!.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: list.contentView!.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: list.contentView!.bottomAnchor),
            statusRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            statusRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 20),
            progress.widthAnchor.constraint(equalToConstant: 16),
            progress.heightAnchor.constraint(equalToConstant: 16),
            fields.widthAnchor.constraint(equalTo: content.widthAnchor),
            port.widthAnchor.constraint(equalToConstant: 64),
            actions.widthAnchor.constraint(equalTo: content.widthAnchor),
            cancel.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            connect.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
        ])
        table.nextKeyView = address; address.nextKeyView = port
        port.nextKeyView = connect; connect.nextKeyView = cancel; cancel.nextKeyView = refresh
        refresh.nextKeyView = table
        w.defaultButtonCell = connect.cell as? NSButtonCell
        window = w; fitWindow()
        w.center(); w.makeKeyAndOrderFront(nil); w.makeFirstResponder(address)
        NSApplication.shared.activate(ignoringOtherApps: true)
        nearby.onChange = { [weak self] in self?.update() }
        nearby.start()
        // The parent can close/inspect this chooser without making a connection.
        readCommands(onClose: { [weak self] in self?.cancel(nil) }) { [weak self] _, data in
            let cmd = json(data)
            DispatchQueue.main.async {
                guard let self = self else { return }
                if cmd["type"] as? String == "cancel" { self.cancel(nil) }
                if cmd["type"] as? String == "select", let index = cmd["index"] as? Int, self.rows.indices.contains(index) {
                    self.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                    self.window?.makeFirstResponder(self.table)
                }
                if cmd["type"] as? String == "inspect" {
                    event(["type": "picker_state", "hosts": self.rows.map { $0.value }, "rows": self.table.numberOfRows, "host": self.address.stringValue, "port": self.port.stringValue])
                }
            }
        }
    }
    func update() {
        updating = true; rows = nearby.computers; table.reloadData()
        if let index = rows.firstIndex(where: { $0.id == selectedID }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        updating = false
        if rows.isEmpty && nearby.failure == nil { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        status.stringValue = nearby.failure ?? (rows.isEmpty ? "Searching for nearby computers… You can also enter an SSH address." : "\(rows.count) computer\(rows.count == 1 ? "" : "s") found. SSH access is required to connect.")
        listHeight?.constant = (table.headerView?.frame.height ?? 22) + CGFloat(max(1, min(rows.count, 4))) * (table.rowHeight + table.intercellSpacing.height) + 12
        fitWindow()
    }
    func fitWindow() {
        guard let window = window, let view = window.contentView else { return }
        // Follow the content until the user enlarges the window; preserve their size afterwards.
        let wasCompact = window.contentMinSize == .zero || window.contentLayoutRect.size == window.contentMinSize
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        window.contentMinSize = size
        if wasCompact { window.setContentSize(size) }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ComputerPickerRow() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let computer = rows[row]
        let identifier = tableColumn!.identifier
        if let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell.textField?.stringValue = identifier.rawValue == "name" ? computer.displayName : computer.address
            return cell
        }
        let cell = NSTableCellView(); cell.identifier = identifier
        let text = label(identifier.rawValue == "name" ? computer.displayName : computer.address)
        text.lineBreakMode = .byTruncatingTail; text.translatesAutoresizingMaskIntoConstraints = false
        cell.textField = text; cell.addSubview(text)
        var leading = cell.leadingAnchor
        if identifier.rawValue == "name" {
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil)
            icon.translatesAutoresizingMaskIntoConstraints = false
            cell.imageView = icon; cell.addSubview(icon)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 18), icon.heightAnchor.constraint(equalToConstant: 18),
            ])
            leading = icon.trailingAnchor
        }
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leading, constant: 8),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updating, rows.indices.contains(table.selectedRow) else { return }
        let computer = rows[table.selectedRow]; selectedID = computer.id
        address.stringValue = computer.address; port.stringValue = String(computer.port)
    }
    @objc func refresh(_ sender: Any?) { nearby.start() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { connect(nil); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { cancel(nil); return true }
        return false
    }
    @objc func connect(_ sender: Any?) {
        let host = address.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !host.hasPrefix("-"), host.utf8.count <= 320,
              host.range(of: "^[A-Za-z0-9_.:@\\[\\]%-]+$", options: .regularExpression) != nil,
              let number = Int(port.stringValue), (1...65535).contains(number) else {
            status.stringValue = "Enter an SSH address and a port between 1 and 65535."; fitWindow(); return
        }
        complete(["type": "connect", "host": host, "port": number])
    }
    @objc func cancel(_ sender: Any?) { complete(["type": "cancel"]) }
    func complete(_ value: [String: Any]) {
        guard !finished else { return }
        finished = true; nearby.stop(); event(value); NSApplication.shared.terminate(nil)
    }
    @objc func hostPermissions(_ sender: Any?) {
        _ = CGRequestScreenCaptureAccess()
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }
    func windowWillClose(_ note: Notification) { cancel(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ note: Notification) {
        if !finished { finished = true; nearby.stop(); event(["type": "cancel"]) }
    }
}

let mode = ProcessInfo.processInfo.environment["GLIFF_ASKPASS"] == "1" ? "askpass" : (CommandLine.arguments.dropFirst().first ?? "permissions")
let app = NSApplication.shared
if mode == "encode" {
    let args = Array(CommandLine.arguments.dropFirst(2))
    guard args.count == 4, let width = Int(args[0]), let height = Int(args[1]), let bitrate = Int(args[2]), let fps = Int(args[3]) else { fail("Invalid encoder configuration") }
    do {
        let encoder = try HardwareEncoder(width, height, bitrate, fps)
        event(["type": "encoder", "hardware": true, "name": "videotoolbox"])
        app.setActivationPolicy(.prohibited)
        readCommands(onClose: { encoder.close() }) { kind, data in
            guard kind == 4 else { fail("Unexpected encoder command") }
            encoder.encode(data)
        }
        withExtendedLifetime(encoder) { app.run() }
    } catch { fail(error.localizedDescription) }
} else if mode == "askpass" {
    app.setActivationPolicy(.accessory); app.activate(ignoringOtherApps: true)
    let prompt = CommandLine.arguments.dropFirst().joined(separator: " ")
    let alert = NSAlert(); alert.messageText = "SSH Authentication"; alert.informativeText = prompt
    if prompt.contains("yes/no") {
        alert.messageText = "Connect to this computer?"
        alert.addButton(withTitle: "Connect"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { exit(1) }
        print("yes")
    } else {
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 26))
        alert.accessoryView = field
        alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { exit(1) }
        print(field.stringValue)
    }
    exit(0)
} else if mode == "choose" {
    app.setActivationPolicy(.regular)
    let picker = ComputerPicker(); app.delegate = picker
    withExtendedLifetime(picker) { app.run() }
} else if mode == "discover" {
    app.setActivationPolicy(.accessory)
    let nearby = NearbyComputers(); nearby.start()
    Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { _ in
        if let failure = nearby.failure { event(["type": "error", "message": failure]) }
        else { event(["type": "hosts", "hosts": nearby.computers.map { $0.value }]) }
        nearby.stop(); app.terminate(nil)
    }
    withExtendedLifetime(nearby) { app.run() }
} else if mode == "app" {
    app.setActivationPolicy(.regular)
    let delegate = App(); app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
} else if mode == "stream" {
    // display width height fps dual bitrate vbv_ms
    app.setActivationPolicy(.accessory)
    let args = Array(CommandLine.arguments.dropFirst(2))
    guard args.count == 7, let width = Int(args[1]), let height = Int(args[2]), let fps = Int(args[3]), let bitrate = Int(args[5]), let vbv = Int(args[6]) else { fail("Invalid stream configuration") }
    let streamer: Streamer
    do { streamer = try Streamer(dual: args[4] == "1", bitrate: bitrate, fps: fps, vbvMs: vbv) }
    catch { event(["type": "unsupported", "message": error.localizedDescription]); exit(2) }
    readCommands(onClose: { streamer.input.handle(["type": "release"]) }) { _, data in
        let cmd = json(data)
        if clipboard.receive(cmd) { return }
        switch cmd["type"] as? String {
        case "frame", "refresh", "rate", "chroma": streamer.queue.async { streamer.command(cmd) }
        case "resize": DispatchQueue.main.async { streamer.resize(cmd["width"] as? Int ?? 2, cmd["height"] as? Int ?? 2) }
        default: DispatchQueue.main.async { streamer.input.handle(cmd); clipboard.command(cmd) }
        }
    }
    Task { await streamer.start(args[0], width, height, fps) }
    withExtendedLifetime(streamer) { app.run() }
} else if mode == "capture" {
    app.setActivationPolicy(.accessory)
    let args = Array(CommandLine.arguments.dropFirst(2))
    let capture = Capture()
    readCommands(onClose: { capture.input.handle(["type": "release"]) }) { _, data in
        let cmd = json(data)
        if clipboard.receive(cmd) { return }
        DispatchQueue.main.async {
            if cmd["type"] as? String == "resize" { capture.resize(cmd["width"] as? Int ?? 1920, cmd["height"] as? Int ?? 1200) }
            else { capture.input.handle(cmd); clipboard.command(cmd) }
        }
    }
    Task { await capture.start(args.first ?? "auto", Int(args.count > 1 ? args[1] : "1920") ?? 1920, Int(args.count > 2 ? args[2] : "1200") ?? 1200, Int(args.count > 3 ? args[3] : "30") ?? 30) }
    app.run()
    capture.input.handle(["type": "release"])
} else if mode == "outputs" {
    var displays = [CGDirectDisplayID](repeating: 0, count: 32), count: UInt32 = 0
    CGGetActiveDisplayList(32, &displays, &count)
    for id in displays.prefix(Int(count)) {
        let b = CGDisplayBounds(id)
        print("display-\(id)\t\(CGDisplayPixelsWide(id))x\(CGDisplayPixelsHigh(id))\t\(Int(b.width))x\(Int(b.height)) logical\(id == CGMainDisplayID() ? "\tmain" : "")")
    }
} else {
    if CommandLine.arguments.contains("--request") {
        _ = CGRequestScreenCaptureAccess()
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    print("Screen Recording: \(CGPreflightScreenCaptureAccess() ? "granted" : "required")")
    print("Accessibility: \(AXIsProcessTrusted() ? "granted" : "required")")
    if !CGPreflightScreenCaptureAccess() || !AXIsProcessTrusted() { exit(1) }
}
