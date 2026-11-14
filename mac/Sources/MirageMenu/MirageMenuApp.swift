import SwiftUI
import AppKit
import Darwin

@main
struct MirageMenuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var controller = HelperController.shared

    var body: some Scene {
        MenuBarExtra("Mirage", systemImage: "display") {
            MenuContent(controller: controller)
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
        }
        HelperController.shared.start()
    }
}

struct MenuContent: View {
    @ObservedObject var controller: HelperController

    var body: some View {
        Text(controller.status)
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
                    + "\(resolution.label)（编码 \(resolution.width * 2)×\(resolution.height * 2)）") {
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
        Button(controller.isRunning ? "停止" : "启动") {
            controller.toggle()
        }
        Button("打开日志") {
            NSWorkspace.shared.open(controller.logURL)
        }
        Divider()
        Button("退出 Mirage") {
            NSApplication.shared.terminate(nil)
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

        var label: String { "\(width)×\(height)" }
    }

    static let resolutions: [Resolution] = [
        Resolution(width: 1280, height: 800),
        Resolution(width: 1600, height: 1000),
        Resolution(width: 1920, height: 1080),
        Resolution(width: 1920, height: 1200),
    ]

    static let frameRates = [30, 60, 90, 120]

    @Published private(set) var mode: Mode
    @Published private(set) var resolution: Resolution
    @Published private(set) var fps: Int
    @Published private(set) var isRunning = false
    @Published private(set) var status = "未运行"

    let logURL: URL

    private var process: Process?
    private var instanceLockFD: Int32 = -1

    private init() {
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

        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Mirage", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        logURL = logs.appendingPathComponent("helper.log")
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

        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard let logHandle = try? FileHandle(forWritingTo: logURL) else {
            status = "无法写入日志"
            return
        }
        logHandle.seekToEndOfFile()

        let child = Process()
        child.executableURL = helper
        var arguments = ["--mode", mode.rawValue, "--port", "7777", "--fps", "\(fps)"]
        if mode == .extend {
            arguments += ["--width", "\(resolution.width)", "--height", "\(resolution.height)"]
        } else {
            arguments += [
                "--max-width", "\(resolution.width * 2)",
                "--max-height", "\(resolution.height * 2)",
            ]
        }
        child.arguments = arguments
        child.standardOutput = logHandle
        child.standardError = logHandle
        child.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async {
                guard let self, self.process === ended else { return }
                self.process = nil
                self.isRunning = false
                self.status = "已停止（\(ended.terminationStatus)）"
            }
        }

        do {
            try child.run()
        } catch {
            status = "启动失败：\(error.localizedDescription)"
            return
        }

        process = child
        isRunning = true
        status = "运行中 · \(mode.title) · \(fps)fps"
    }

    func stop() {
        process?.terminate()
        process = nil
        isRunning = false
        status = "已停止"
    }

    private func restart() {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.start()
        }
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
}