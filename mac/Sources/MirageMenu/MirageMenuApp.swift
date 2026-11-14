import SwiftUI
import AppKit

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
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--autostart"),
              index + 1 < arguments.count,
              let mode = HelperController.Mode(rawValue: arguments[index + 1]) else {
            return
        }
        HelperController.shared.setMode(mode)
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

    @Published private(set) var mode: Mode
    @Published private(set) var isRunning = false
    @Published private(set) var status = "未运行"

    let logURL: URL

    private var process: Process?

    private init() {
        let saved = UserDefaults.standard.string(forKey: "mode").flatMap(Mode.init(rawValue:)) ?? .mirror
        mode = saved

        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Mirage", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        logURL = logs.appendingPathComponent("helper.log")
    }

    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        mode = newMode
        UserDefaults.standard.set(newMode.rawValue, forKey: "mode")
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
        child.arguments = ["--mode", mode.rawValue, "--port", "7777"]
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
        status = "运行中 · \(mode.title)"
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