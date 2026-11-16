import Foundation
import Darwin
import CoreGraphics
import CoreMedia
import CoreVideo
import ApplicationServices
import Carbon.HIToolbox
import MirageCore
import MirageHelper

let arguments = CommandLine.arguments

func argumentValue(_ flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

if arguments.contains("--list-displays") {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    for id in ids {
        if let size = captureSize(for: id) {
            print("id=\(id) pixel=\(size.width)x\(size.height)")
        } else {
            print("id=\(id) pixel=unknown")
        }
    }
} else if arguments.contains("--encode-selftest") {
    let counter = FrameCounter()
    do {
        let encoder = try VideoEncoder(width: 1280, height: 800, fps: 60, bitrate: 20_000_000)
        encoder.onFrame = { counter.record($0) }
        guard let pixelBuffer = makeTestPixelBuffer(width: 1280, height: 800) else {
            print("pixel_buffer=failed")
            exit(2)
        }
        for index in 0..<30 {
            let pts = CMTime(value: Int64(monotonicMicros()), timescale: 1_000_000)
            try encoder.encode(pixelBuffer, pts: pts, forceKeyframe: index == 0)
        }
        encoder.finish()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))
        let (frames, keyframes) = counter.snapshot()
        print("create_status=0 frames=\(frames) keyframes=\(keyframes)")
        exit(frames == 30 && keyframes == 1 ? 0 : 1)
    } catch {
        print("encoder_error=\(error)")
        exit(1)
    }
} else if arguments.contains("--input-selftest") {
    let trusted = AXIsProcessTrusted()
    let secure = IsSecureEventInputEnabled()
    print("input_accessibility=\(trusted ? 1 : 0)")
    print("secure_input=\(secure ? 1 : 0)")
    exit(0)
} else if arguments.contains("--tls-selftest") {
    guard let tls = try? TLSIdentity.loadOrCreate() else {
        print("tls_load=failed")
        exit(1)
    }
    print("fingerprint=\(PairingPayload(host: "x", port: 1, fingerprint: tls.fingerprint, name: "x", deviceID: UUID()).fingerprintHex)")
    fflush(stdout)
    var key: SecKey?
    let status = SecIdentityCopyPrivateKey(tls.identity, &key)
    print("copy_key_status=\(status)")
    fflush(stdout)
    guard status == errSecSuccess, let key else { exit(2) }
    var error: Unmanaged<CFError>?
    let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, Data("test".utf8) as CFData, &error)
    print("sign=\(signature != nil) error=\(String(describing: error))")
    fflush(stdout)
    exit(signature != nil ? 0 : 3)
} else if arguments.contains("--serve-selftest") {
    let config = SessionConfig(width: 1280, height: 800, fps: 60, codec: 1, bitrate: 20_000_000, rotation: 0)
    let tls = arguments.contains("--tls") ? try? TLSIdentity.loadOrCreate() : nil
    let server = MirageServer(
        port: 7777,
        config: config,
        bindAddress: tls == nil ? .ipv4(.loopback) : nil,
        serviceName: tls == nil ? nil : "Mirage",
        tlsIdentity: tls?.identity
    )
    server.onLog = { message in
        print(message)
        fflush(stdout)
    }
    server.inputCaps = 0b111111
    server.inputAllowed = { _ in true }
    server.inputPaused = { InputControl.isPaused }
    server.onInput = { event in
        switch event {
        case .pointer(let samples):
            let kinds = samples.map { $0.kind.rawValue }.map(String.init).joined(separator: ",")
            let points = samples.map { String(format: "%.3f,%.3f b=%u", $0.x, $0.y, $0.buttons) }.joined(separator: " ")
            print("input_pointer count=\(samples.count) kinds=\(kinds) \(points)")
        case .key(let key):
            print("input_key action=\(key.action.rawValue) keycode=\(key.keycode) unicode=\(key.unicode) modifiers=\(key.modifiers)")
        case .text(let text):
            print("input_text text=\(text.text)")
        case .scroll(let scroll):
            print("input_scroll phase=\(scroll.phase.rawValue) dx=\(scroll.dx) dy=\(scroll.dy) flags=\(scroll.flags)")
        case .releaseAll:
            print("input_release_all")
        }
        fflush(stdout)
    }
    do {
        try server.start()
        print(tls == nil ? "listening=127.0.0.1:7777" : "listening=0.0.0.0:7778 tls=1")
        fflush(stdout)
    } catch {
        print("server_error=\(error)")
        exit(1)
    }
    let seconds = argumentValue("--seconds").flatMap { Double($0) } ?? 30
    Thread.sleep(forTimeInterval: seconds)
    server.stop()
} else {
    let displayID = argumentValue("--display").flatMap { UInt32($0) } ?? CGMainDisplayID()
    let port = argumentValue("--port").flatMap { UInt16($0) } ?? 7777
    let fps = argumentValue("--fps").flatMap { Int($0) } ?? 60
    let bitrate = argumentValue("--bitrate").flatMap { Int($0) } ?? 20_000_000
    let maxWidth = argumentValue("--max-width").flatMap { Int($0) } ?? 3840
    let maxHeight = argumentValue("--max-height").flatMap { Int($0) } ?? 2160
    let mode = DisplayMode(rawValue: argumentValue("--mode") ?? "mirror") ?? .mirror
    let pointWidth = argumentValue("--width").flatMap { Int($0) } ?? 1280
    let pointHeight = argumentValue("--height").flatMap { Int($0) } ?? 800
    let autoSize = arguments.contains("--auto-size")
    let wifi = arguments.contains("--wifi")
    let position = DisplayPosition(rawValue: argumentValue("--position") ?? "right") ?? .right
    let dumpFramePath = argumentValue("--dump-frame")
    let recordPath = argumentValue("--record")

    let app = HelperApp(
        displayID: displayID,
        port: port,
        fps: fps,
        bitrate: bitrate,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
        mode: mode,
        pointWidth: pointWidth,
        pointHeight: pointHeight,
        autoSize: autoSize,
        position: position,
        wifi: wifi,
        dumpFramePath: dumpFramePath,
        recordPath: recordPath
    )
    let box = ErrorBox()
    let startSemaphore = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            try await app.run()
        } catch {
            box.set(error)
        }
        startSemaphore.signal()
    }
    startSemaphore.wait()
    if let error = box.get() {
        print("helper_error=\(error)")
        exit(1)
    }
    let shutdown = ShutdownSignal()
    shutdown.install {
        Task {
            await app.stop()
            print("helper_stopped=signal")
            fflush(stdout)
            exit(0)
        }
    }
    RunLoop.current.run()
}

final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    func set(_ error: Error) {
        lock.lock()
        self.error = error
        lock.unlock()
    }

    func get() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return error
    }
}

final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var keyframes = 0

    func record(_ frame: EncodedFrame) {
        lock.lock()
        frames += 1
        if frame.header.flags & 1 == 1 { keyframes += 1 }
        lock.unlock()
    }

    func snapshot() -> (Int, Int) {
        lock.lock()
        defer { lock.unlock() }
        return (frames, keyframes)
    }
}

func makeTestPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
    var pixelBuffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        attributes as CFDictionary,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else { return nil }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    if let luma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
        memset(luma, 0x10, CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) * CVPixelBufferGetHeightOfPlane(pixelBuffer, 0))
    }
    if let chroma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) {
        memset(chroma, 0x80, CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1) * CVPixelBufferGetHeightOfPlane(pixelBuffer, 1))
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    return pixelBuffer
}