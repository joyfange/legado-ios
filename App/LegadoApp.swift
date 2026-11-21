import SwiftUI
import MachO

@main
struct LegadoApp: App {
    @UIApplicationDelegateAdaptor(LegadoAppDelegate.self) private var appDelegate
    @StateObject private var sourceLibrary: SourceLibraryModel
    @StateObject private var bookLibrary: BookLibraryModel
    @StateObject private var replaceRuleLibrary: ReplaceRuleLibraryModel
    @StateObject private var readingActivity: ReadingActivityModel
    @StateObject private var rssLibrary: RSSLibraryModel
    @StateObject private var ruleSubscriptions: RuleSubscriptionModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var crashReport: CrashReportItem?

    init() {
        AppDiagnostics.shared.start()
        SourceWebViewExecutorRegistry.shared.register(WKSourceWebViewExecutor())
        let demo = ProcessInfo.processInfo.arguments.contains("-uiDemo")
        _sourceLibrary = StateObject(wrappedValue: demo
            ? SourceLibraryModel.demo(sources: DemoContent.sources)
            : SourceLibraryModel.live())
        _bookLibrary = StateObject(wrappedValue: demo
            ? BookLibraryModel.demo(books: DemoContent.books)
            : BookLibraryModel.live())
        _replaceRuleLibrary = StateObject(wrappedValue: demo
            ? ReplaceRuleLibraryModel.demo()
            : ReplaceRuleLibraryModel.live())
        _readingActivity = StateObject(wrappedValue: demo
            ? ReadingActivityModel.demo(bookmarks: DemoContent.bookmarks, records: DemoContent.readRecords)
            : ReadingActivityModel.live())
        _rssLibrary = StateObject(wrappedValue: RSSLibraryModel.live())
        _ruleSubscriptions = StateObject(wrappedValue: RuleSubscriptionModel())
    }

    var body: some Scene {
        WindowGroup {
            AppThemeShell { RootTabView() }
                .environmentObject(sourceLibrary)
                .environmentObject(bookLibrary)
                .environmentObject(replaceRuleLibrary)
                .environmentObject(readingActivity)
                .environmentObject(rssLibrary)
                .environmentObject(ruleSubscriptions)
                .task {
                    // 先读书架，首屏尽快显示书籍；书源较多时读取较慢，放在后面。
                    await bookLibrary.load()
                    await sourceLibrary.load()
                    if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-uiAutomationImportURL"),
                       ProcessInfo.processInfo.arguments.indices.contains(index + 1),
                       let url = URL(string: ProcessInfo.processInfo.arguments[index + 1]) {
                        await sourceLibrary.handleDeepLink(url)
                        if ProcessInfo.processInfo.arguments.contains("-uiAutomation") {
                            sourceLibrary.notice = nil
                        }
                    }
                    await replaceRuleLibrary.load()
                    await readingActivity.load()
                    await rssLibrary.load()
                    await ruleSubscriptions.load()
                    if UserDefaults.standard.bool(forKey: "auto_refresh") {
                        await bookLibrary.checkForUpdates(sources: sourceLibrary.sources, onlyRead: UserDefaults.standard.bool(forKey: "onlyUpdateRead"))
                    }
                    await ruleSubscriptions.checkAutomaticUpdates(bookSources: sourceLibrary, rssSources: rssLibrary, replaceRules: replaceRuleLibrary)
                }
                .onAppear {
                    if let report = LegadoCrashLog.pendingReport {
                        LegadoCrashLog.pendingReport = nil
                        crashReport = CrashReportItem(text: report)
                    }
                }
                .sheet(item: $crashReport) { item in CrashReportSheet(report: item.text) }
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .background: LegadoCrashLog.markClean()
                    case .active: LegadoCrashLog.mark("回到前台")
                    default: break
                    }
                }
                .onOpenURL { url in
                    Task {
                        if url.isFileURL && url.pathExtension.lowercased() == "epub" {
                            let file = LocalBookImportFile(url: url)
                            await bookLibrary.load()
                            await bookLibrary.importPickedLocalFiles([file])
                            sourceLibrary.notice = .init(kind: bookLibrary.errorMessage == nil ? .success : .error,
                                                         title: bookLibrary.errorMessage == nil ? "EPUB 已加入书架" : "导入失败",
                                                         detail: bookLibrary.errorMessage ?? url.lastPathComponent)
                            return
                        }
                        await sourceLibrary.load()
                        if url.scheme?.lowercased() == "legado", url.path.lowercased() == "/replacerule" {
                            await replaceRuleLibrary.load()
                            await replaceRuleLibrary.importText(url.absoluteString)
                            if let notice = replaceRuleLibrary.notice {
                                sourceLibrary.notice = .init(kind: notice.kind == .error ? .error : .success, title: notice.title, detail: notice.detail)
                                replaceRuleLibrary.notice = nil
                            }
                        } else { await sourceLibrary.handleDeepLink(url) }
                    }
                }
        }
    }
}

final class LegadoAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        LegadoCrashLog.install()
        // 手机上旧版存下的「反向竖屏」会让打开书时闪退，换成竖向。
        if UIDevice.current.userInterfaceIdiom == .phone, UserDefaults.standard.string(forKey: "screenOrientation") == "4" {
            UserDefaults.standard.set("1", forKey: "screenOrientation")
        }
        return true
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        ReaderScreenOrientation.supportedOrientations
    }
}

/// 闪退记录：未捕获的异常 / 致命信号（含栈溢出，信号处理跑在单独的栈上）写进应用文件夹的「闪退日志.txt」，
/// 同时记录打开书籍的每一步（「运行轨迹.txt」）。下次启动时如果上次异常退出，直接弹出日志，可一键复制。
enum LegadoCrashLog {
    nonisolated(unsafe) static var crashFD: Int32 = -1
    nonisolated(unsafe) static var header: UnsafeMutablePointer<CChar>?
    nonisolated(unsafe) static var trailFD: Int32 = -1

    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    static var crashURL: URL { directory.appendingPathComponent("闪退日志.txt") }
    static var trailURL: URL { directory.appendingPathComponent("运行轨迹.txt") }
    static var previousTrailURL: URL { directory.appendingPathComponent("上次运行轨迹.txt") }
    static let cleanMark = "【正常】"

    /// 上次运行异常退出时的报告（闪退日志 + 最后的运行轨迹），没有则为 nil。
    nonisolated(unsafe) static var pendingReport: String?

    @MainActor static func install() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // 上次的轨迹：最后一行不是「正常」标记，说明是被系统杀掉或闪退。
        let previousTrail = (try? String(contentsOf: trailURL, encoding: .utf8)) ?? ""
        let crashText = (try? String(contentsOf: crashURL, encoding: .utf8)) ?? ""
        try? fm.removeItem(at: previousTrailURL)
        if !previousTrail.isEmpty { try? previousTrail.write(to: previousTrailURL, atomically: true, encoding: .utf8) }
        let lastLine = previousTrail.split(separator: "\n").last.map(String.init) ?? ""
        let abnormal = !previousTrail.isEmpty && !lastLine.contains(cleanMark)
        if !crashText.isEmpty || abnormal {
            let tail = previousTrail.split(separator: "\n").suffix(40).joined(separator: "\n")
            pendingReport = (crashText.isEmpty ? "（没有捕获到信号，可能被系统直接结束）\n" : crashText)
                + "\n—— 上次运行轨迹 ——\n" + tail
            // 已经展示过的闪退日志改名保存，避免每次启动都弹。
            if !crashText.isEmpty {
                let old = directory.appendingPathComponent("闪退日志-已读.txt")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: crashURL, to: old)
            }
        }
        trailFD = open(trailURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        crashFD = open(crashURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] ?? "")(\(info?["CFBundleVersion"] ?? ""))"
        let base = String(UInt(bitPattern: _dyld_get_image_header(0)), radix: 16)
        header = strdup("\n==== 闪退 版本 \(version) 主程序基址 0x\(base) \(UIDevice.current.model) iOS \(UIDevice.current.systemVersion) ====\n")
        mark("启动 版本 \(version)")

        NSSetUncaughtExceptionHandler { exception in
            LegadoCrashLog.writeHeader()
            let text = "未捕获异常 \(exception.name.rawValue): \(exception.reason ?? "")\n"
                + exception.callStackSymbols.joined(separator: "\n") + "\n"
            LegadoCrashLog.writeRaw(text)
        }
        // 栈溢出时原来的栈已经用完，信号处理必须跑在另一块栈上。
        let stackSize = 256 * 1024
        var stack = stack_t()
        stack.ss_sp = UnsafeMutableRawPointer.allocate(byteCount: stackSize, alignment: 16)
        stack.ss_size = stackSize
        stack.ss_flags = 0
        sigaltstack(&stack, nil)
        for signalNumber in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE] {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = { number in
                LegadoCrashLog.writeHeader()
                LegadoCrashLog.writeSignal(number)
                if LegadoCrashLog.crashFD >= 0 {
                    var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 128)
                    let count = backtrace(&frames, 128)
                    backtrace_symbols_fd(&frames, count, LegadoCrashLog.crashFD)
                    fsync(LegadoCrashLog.crashFD)
                }
                signal(number, SIG_DFL)
                raise(number)
            }
            action.sa_flags = SA_ONSTACK
            sigemptyset(&action.sa_mask)
            sigaction(signalNumber, &action, nil)
        }
    }

    /// 记录一步（打开书籍的各个阶段）。
    static func mark(_ step: String) {
        guard trailFD >= 0 else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let line = "\(formatter.string(from: Date())) \(step)\n"
        _ = line.withCString { write(trailFD, $0, strlen($0)) }
    }

    /// 正常进入后台 / 退出：下次启动不弹报告。
    static func markClean() { mark(cleanMark) }

    static func writeHeader() {
        guard crashFD >= 0, let header else { return }
        _ = write(crashFD, header, strlen(header))
    }

    static func writeSignal(_ number: Int32) {
        guard crashFD >= 0 else { return }
        var buffer: [CChar] = Array("信号 ".utf8CString.dropLast())
        var digits: [CChar] = []
        var value = number
        repeat { digits.insert(CChar(48 + value % 10), at: 0); value /= 10 } while value > 0
        buffer += digits
        buffer.append(10)
        buffer.withUnsafeBufferPointer { _ = write(crashFD, $0.baseAddress, $0.count) }
    }

    static func writeRaw(_ text: String) {
        guard crashFD >= 0 else { return }
        _ = text.withCString { write(crashFD, $0, strlen($0)) }
        fsync(crashFD)
    }
}

struct CrashReportItem: Identifiable {
    let id = UUID()
    let text: String
}

/// 上次异常退出时弹出的报告页：可复制全部内容发给开发者。
struct CrashReportSheet: View {
    let report: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        ReadingNavigationStack {
            ScrollView {
                Text(report)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("上次闪退记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(copied ? "已复制" : "复制全部") {
                        UIPasteboard.general.string = report
                        copied = true
                    }
                }
            }
        }
    }
}
