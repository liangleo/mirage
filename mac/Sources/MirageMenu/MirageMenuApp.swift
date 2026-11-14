import SwiftUI
import AppKit
import Darwin
import MirageCore

private func centerWindowOnPrimaryScreen(title: String) {
    DispatchQueue.main.async {
        guard let window = NSApplication.shared.windows.first(where: { $0.title == title }),
              let screen = NSScreen.screens.first else { return }
        let size = window.frame.size
        let visible = screen.visibleFrame
        window.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        ))
    }
}

@main
struct MirageMenuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var controller = HelperController.shared

    var body: some Scene {
        Window("Mirage", id: "main") {
            MainView(controller: controller)
        }
        .defaultSize(width: 520, height: 780)

        MenuBarExtra("Mirage", systemImage: "display") {
            StatusMenu(controller: controller)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        HelperController.shared.stop()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard HelperController.shared.acquireInstanceLock() else {
            NSApplication.shared.terminate(nil)
            return
        }

        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--autostart"),
           index + 1 < arguments.count,
           let mode = HelperController.Mode(rawValue: arguments[index + 1]) {
            HelperController.shared.setMode(mode)
            HelperController.shared.start()
        } else if HelperController.shared.autoStartOnLaunch {
            HelperController.shared.start()
        }

        if arguments.contains("--usb") {
            HelperController.shared.setUsbBridge(true)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard !arguments.contains("--show") else { return }
            for window in NSApplication.shared.windows where window.title == "Mirage" {
                window.close()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

struct StatusMenu: View {
    @ObservedObject var controller: HelperController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(controller.status)
        Button(controller.isRunning ? "停止服务" : "启动服务") {
            controller.toggle()
        }
        Button(controller.usbBridgeRunning ? "停止 USB 连接" : "USB 连接（AOA）") {
            controller.setUsbBridge(!controller.usbBridgeRunning)
        }
        Divider()
        Button {
            controller.setMode(.extend)
            if !controller.isRunning { controller.start() }
        } label: {
            Text((controller.mode == .extend ? "✓ " : "") + "副屏（虚拟显示器）")
        }
        Button {
            controller.setMode(.mirror)
            if !controller.isRunning { controller.start() }
        } label: {
            Text((controller.mode == .mirror ? "✓ " : "") + "镜像主屏")
        }
        Divider()
        Menu("分辨率：\(controller.resolution.label)") {
            ForEach(HelperController.resolutions, id: \.self) { resolution in
                Button((controller.resolution == resolution ? "✓ " : "")
                    + resolution.menuLabel) {
                    controller.setResolution(resolution)
                }
            }
        }
        Menu("帧率：\(controller.fps) fps") {
            ForEach(HelperController.frameRates, id: \.self) { fps in
                Button((controller.fps == fps ? "✓ " : "") + "\(fps) fps") {
                    controller.setFPS(fps)
                }
            }
        }
        Divider()
        Button("打开主界面") {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("退出 Mirage") {
            NSApplication.shared.terminate(nil)
        }
    }
}

struct MainView: View {
    @ObservedObject var controller: HelperController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "display")
                    .font(.system(size: 30))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mirage")
                        .font(.title2.bold())
                    HStack(spacing: 8) {
                        Circle()
                            .fill(controller.isRunning ? Color.green : Color.gray)
                            .frame(width: 8, height: 8)
                        Text(controller.status)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Toggle("启动/停止服务", isOn: Binding(
                    get: { controller.isRunning },
                    set: { enabled in
                        if enabled {
                            controller.start()
                        } else {
                            controller.stop()
                        }
                    }
                ))
                .toggleStyle(.switch)

                Toggle("启动 App 后自动启动服务", isOn: Binding(
                    get: { controller.autoStartOnLaunch },
                    set: { controller.setAutoStartOnLaunch($0) }
                ))
                .toggleStyle(.switch)

                Toggle("USB 免调试连接（AOA）", isOn: Binding(
                    get: { controller.usbBridgeRunning },
                    set: { controller.setUsbBridge($0) }
                ))
                .toggleStyle(.switch)
            }

            GroupBox("连接设置") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("模式", selection: Binding(
                        get: { controller.mode },
                        set: { controller.setMode($0) }
                    )) {
                        Text("副屏（虚拟显示器）").tag(HelperController.Mode.extend)
                        Text("镜像主屏").tag(HelperController.Mode.mirror)
                    }
                    .pickerStyle(.segmented)

                    Picker("分辨率", selection: Binding(
                        get: { controller.resolution },
                        set: { controller.setResolution($0) }
                    )) {
                        ForEach(HelperController.resolutions, id: \.self) { resolution in
                            Text(resolution.label).tag(resolution)
                        }
                    }

                    Picker("帧率", selection: Binding(
                        get: { controller.fps },
                        set: { controller.setFPS($0) }
                    )) {
                        ForEach(HelperController.frameRates, id: \.self) { fps in
                            Text("\(fps) fps").tag(fps)
                        }
                    }
                }
                .padding(8)
            }

            HStack {
                Button("日志文件") {
                    NSWorkspace.shared.open(controller.logURL)
                }
                Button("屏幕录制设置") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("日志")
                        .font(.headline)
                    Spacer()
                    Text("自动滚动")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LogView(logURL: controller.logURL)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Button("退出 Mirage") {
                    NSApplication.shared.terminate(nil)
                }
                Spacer()
                Button("关闭窗口") {
                    NSApplication.shared.keyWindow?.close()
                }
            }
        }
        .padding(20)
        .frame(width: 520, height: 780)
        .onAppear {
            centerWindowOnPrimaryScreen(title: "Mirage")
        }
    }
}

// Timer fires on the main run loop; all state access stays on main.
final class LogTailer: ObservableObject, @unchecked Sendable {
    @Published private(set) var text = ""

    private let url: URL
    private var tail = LogTail()
    private var timer: Timer?
    private var buffer = ""
    private let maxCharacters = 200_000
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init(url: URL) {
        self.url = url
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        timer?.invalidate()
    }

    private func refresh() {
        let chunk = tail.readNew(from: url)
        guard !chunk.isEmpty else { return }

        buffer += chunk
        var lines = buffer.components(separatedBy: "\n")
        guard lines.count > 1 else { return }
        buffer = lines.removeLast()

        let stamp = timeFormatter.string(from: Date())
        let body = lines.map { line -> String in
            let clean = line.hasSuffix("\r") ? String(line.dropLast()) : line
            return clean.isEmpty ? "" : "[\(stamp)] \(clean)"
        }.joined(separator: "\n")

        text.append(body + "\n")
        if text.count > maxCharacters {
            text = String(text.suffix(maxCharacters))
        }
    }
}

struct LogView: View {
    @StateObject private var tailer: LogTailer

    init(logURL: URL) {
        _tailer = StateObject(wrappedValue: LogTailer(url: logURL))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(tailer.text.isEmpty ? "暂无日志" : tailer.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .id("bottom")
            }
            .background(Color.black)
            .onChange(of: tailer.text) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onAppear {
                DispatchQueue.main.async {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }
}

@MainActor
final class HelperController: ObservableObject {
    static let shared = HelperController()

    enum Mode: String {
        case mirror
        case extend

        var title: String {
            self == .mirror ? "镜像" : "副屏"
        }
    }

    struct Resolution: Hashable {
        let width: Int
        let height: Int

        var isAuto: Bool { width == 0 && height == 0 }
        var label: String { isAuto ? "自动（匹配设备）" : "\(width)×\(height)" }
        var menuLabel: String {
            isAuto ? label : "\(label)（编码 \(width * 2)×\(height * 2)）"
        }
    }

    static let resolutions: [Resolution] = [
        Resolution(width: 0, height: 0),
        Resolution(width: 960, height: 600),
        Resolution(width: 1280, height: 720),
        Resolution(width: 1280, height: 800),
        Resolution(width: 1600, height: 1000),
        Resolution(width: 1920, height: 1080),
        Resolution(width: 1920, height: 1200),
    ]

    static let frameRates = [30, 60, 90, 120]

    @Published private(set) var mode: Mode
    @Published private(set) var resolution: Resolution
    @Published private(set) var fps: Int
    @Published private(set) var autoStartOnLaunch: Bool
    @Published private(set) var isRunning = false
    @Published private(set) var usbBridgeRunning = false
    @Published private(set) var status = "未运行"

    let logURL: URL

    private var process: Process?
    private var externalHelperPID: pid_t?
    private var bridgeProcess: Process?
    private var monitorTimer: Timer?
    private var instanceLockFD: Int32 = -1

    private init() {
        let autoDefaultKey = "resolutionDefaultAutoV1"
        if !UserDefaults.standard.bool(forKey: autoDefaultKey) {
            UserDefaults.standard.set(0, forKey: "resolutionWidth")
            UserDefaults.standard.set(0, forKey: "resolutionHeight")
            UserDefaults.standard.set(true, forKey: autoDefaultKey)
        }

        let savedMode = UserDefaults.standard.string(forKey: "mode").flatMap(Mode.init(rawValue:)) ?? .extend
        mode = savedMode

        let savedWidth = UserDefaults.standard.integer(forKey: "resolutionWidth")
        let savedHeight = UserDefaults.standard.integer(forKey: "resolutionHeight")
        let savedResolution = Resolution(width: savedWidth, height: savedHeight)
        resolution = Self.resolutions.contains(savedResolution)
            ? savedResolution
            : Self.resolutions[0]

        let savedFPS = UserDefaults.standard.integer(forKey: "fps")
        fps = Self.frameRates.contains(savedFPS) ? savedFPS : 60
        autoStartOnLaunch = UserDefaults.standard.bool(forKey: "autoStartOnLaunch")

        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Mirage", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        logURL = logs.appendingPathComponent("helper.log")

        startMonitor()
    }

    private func startMonitor() {
        let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshExternalState()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        monitorTimer = timer
        refreshExternalState()
    }

    private func refreshExternalState() {
        guard process == nil else { return }

        if let pid = listeningHelperPID() {
            if externalHelperPID != pid {
                externalHelperPID = pid
                isRunning = true
                status = "运行中（已有 helper）"
            }
        } else if externalHelperPID != nil {
            externalHelperPID = nil
            isRunning = false
            status = "已停止"
        }
    }

    private func listeningHelperPID() -> pid_t? {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-ti", "tcp:7777", "-sTCP:LISTEN"]
        let pipe = Pipe()
        lsof.standardOutput = pipe
        lsof.standardError = FileHandle.nullDevice
        do {
            try lsof.run()
        } catch {
            return nil
        }
        lsof.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8),
              let firstLine = text.split(separator: "\n").first,
              let pid = pid_t(firstLine) else { return nil }
        return pid
    }

    func acquireInstanceLock() -> Bool {
        guard instanceLockFD < 0 else { return true }

        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Mirage", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let path = support.appendingPathComponent("menu.lock").path

        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        if fd < 0 { return true }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        instanceLockFD = fd
        return true
    }

    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        mode = newMode
        UserDefaults.standard.set(newMode.rawValue, forKey: "mode")
        if isRunning {
            restart()
        }
    }

    func setResolution(_ newResolution: Resolution) {
        guard newResolution != resolution else { return }
        resolution = newResolution
        UserDefaults.standard.set(newResolution.width, forKey: "resolutionWidth")
        UserDefaults.standard.set(newResolution.height, forKey: "resolutionHeight")
        if isRunning {
            restart()
        }
    }

    func setFPS(_ newFPS: Int) {
        guard newFPS != fps else { return }
        fps = newFPS
        UserDefaults.standard.set(newFPS, forKey: "fps")
        if isRunning {
            restart()
        }
    }

    func setAutoStartOnLaunch(_ enabled: Bool) {
        guard enabled != autoStartOnLaunch else { return }
        autoStartOnLaunch = enabled
        UserDefaults.standard.set(enabled, forKey: "autoStartOnLaunch")
    }

    func setUsbBridge(_ enabled: Bool) {
        if enabled {
            startUsbBridge()
        } else {
            stopUsbBridge()
        }
    }

    private func startUsbBridge() {
        guard bridgeProcess == nil else { return }
        if !isRunning {
            start()
        }
        waitForHelperAndStartBridge(attempts: 30)
    }

    private func waitForHelperAndStartBridge(attempts: Int) {
        guard bridgeProcess == nil else { return }
        if listeningHelperPID() != nil {
            launchBridge()
            return
        }
        guard attempts > 0 else {
            status = "USB 连接失败：helper 未就绪"
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.waitForHelperAndStartBridge(attempts: attempts - 1)
        }
    }

    private func launchBridge() {
        guard bridgeProcess == nil else { return }
        guard let bridge = aoaBridgeURL else {
            status = "找不到 mirage-aoa"
            return
        }

        guard let logHandle = openAppendLog() else {
            status = "无法写入日志"
            return
        }

        let child = Process()
        child.executableURL = bridge
        child.arguments = ["--port", "7777"]
        child.standardOutput = logHandle
        child.standardError = logHandle
        child.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async {
                guard let self, self.bridgeProcess === ended else { return }
                self.bridgeProcess = nil
                self.usbBridgeRunning = false
                self.status = "USB 桥接已停止（\(ended.terminationStatus)）· 查看日志"
            }
        }

        do {
            try child.run()
        } catch {
            status = "USB 桥接启动失败：\(error.localizedDescription)"
            return
        }
        bridgeProcess = child
        usbBridgeRunning = true
    }

    private func stopUsbBridge() {
        if let child = bridgeProcess {
            kill(child.processIdentifier, SIGKILL)
        }
        bridgeProcess = nil
        usbBridgeRunning = false
    }

    func toggle() {
        if isRunning {
            stop()
        } else {
            start()
        }
    }

    func start() {
        guard process == nil else { return }
        guard let helper = helperURL else {
            status = "找不到 mirage-helper"
            return
        }

        if let pid = listeningHelperPID() {
            externalHelperPID = pid
            isRunning = true
            status = "运行中（已有 helper）"
            return
        }

        guard let logHandle = openAppendLog() else {
            status = "无法写入日志"
            return
        }

        let child = Process()
        child.executableURL = helper
        var arguments = ["--mode", mode.rawValue, "--port", "7777", "--fps", "\(fps)"]
        if mode == .extend {
            if resolution.isAuto {
                arguments += ["--auto-size"]
            } else {
                arguments += ["--width", "\(resolution.width)", "--height", "\(resolution.height)"]
            }
        } else {
            let maxWidth = resolution.isAuto ? 3840 : resolution.width * 2
            let maxHeight = resolution.isAuto ? 2160 : resolution.height * 2
            arguments += ["--max-width", "\(maxWidth)", "--max-height", "\(maxHeight)"]
        }
        child.arguments = arguments
        child.standardOutput = logHandle
        child.standardError = logHandle
        child.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async {
                guard let self, self.process === ended else { return }
                self.process = nil
                self.isRunning = false
                self.status = ended.terminationStatus == 0
                    ? "已停止"
                    : "已停止（退出码 \(ended.terminationStatus)）· 查看日志"
            }
        }

        process = child
        isRunning = true

        do {
            try child.run()
        } catch {
            process = nil
            isRunning = false
            status = "启动失败：\(error.localizedDescription)"
            return
        }

        status = "运行中 · \(mode.title) · \(fps)fps"
    }

    func stop() {
        stopUsbBridge()
        stopHelperOnly()
        status = "已停止"
    }

    private func stopHelperOnly() {
        if let child = process {
            kill(child.processIdentifier, SIGKILL)
        }
        if let pid = externalHelperPID {
            kill(pid, SIGKILL)
        }
        process = nil
        externalHelperPID = nil
        isRunning = false
    }

    private func restart() {
        if usbBridgeRunning {
            stopHelperOnly()
            status = "重启服务…"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.start()
            }
        } else {
            stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.start()
            }
        }
    }

    private func openAppendLog() -> FileHandle? {
        let fd = open(logURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return nil }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private var helperURL: URL? {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/mirage-helper")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }

        if let executable = Bundle.main.executableURL {
            let sibling = executable.deletingLastPathComponent().appendingPathComponent("mirage-helper")
            if FileManager.default.isExecutableFile(atPath: sibling.path) {
                return sibling
            }
        }

        if let path = ProcessInfo.processInfo.environment["MIRAGE_HELPER"],
           FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private var aoaBridgeURL: URL? {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/mirage-aoa")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }

        if let executable = Bundle.main.executableURL {
            let sibling = executable.deletingLastPathComponent().appendingPathComponent("mirage-aoa")
            if FileManager.default.isExecutableFile(atPath: sibling.path) {
                return sibling
            }
        }

        if let path = ProcessInfo.processInfo.environment["MIRAGE_AOA"],
           FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}