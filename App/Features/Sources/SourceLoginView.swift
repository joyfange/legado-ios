@preconcurrency import WebKit
import SwiftUI
import UIKit

struct SourceLoginView: View {
    let source: BookSource
    @State private var reloadID = UUID()
    @State private var status = "打开登录页后，Cookie 会自动同步给搜索与阅读请求。"
    @State private var isChecking = false

    var body: some View {
        let rows = SourceLoginUIRow.parse(source.loginUi)
        let login = (source.loginUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isWebAddress = !login.contains("\n") && (login.hasPrefix("http") || login.hasPrefix("about:") || login.contains("://"))
        if !rows.isEmpty || !isWebAddress || SourceLoginUIRow.dynamicScript(source.loginUi) != nil {
            SourceLoginFormView(source: source, rows: rows)
        } else {
            webLogin
        }
    }

    private var webLogin: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill").foregroundStyle(ReadingTheme.accent)
                Text(status).font(AppFontStyle.caption.themed).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if isChecking { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color(uiColor: .secondarySystemBackground))

            if let request = loginRequest {
                SourceLoginWebView(
                    request: request,
                    sourceURL: source.bookSourceUrl,
                    sourceID: source.id,
                    loginCheckJavaScript: source.loginCheckJs,
                    reloadID: reloadID,
                    status: $status,
                    isChecking: $isChecking
                )
            } else {
                ReadingUnavailableView("登录地址无效", systemImage: "link.badge.plus", description: Text(source.loginUrl ?? "书源没有配置登录地址"))
            }
        }
        .navigationTitle("登录 · \(source.bookSourceName)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("重新载入", systemImage: "arrow.clockwise") { reloadID = UUID() }
            }
        }
    }

    private var loginRequest: URLRequest? {
        guard let value = source.loginUrl,
              let prepared = try? LegadoURLBuilder().prepare(
                value,
                baseURL: URL(string: source.bookSourceUrl),
                defaultHeaders: sourceHeaders
              ) else { return nil }
        return prepared.urlRequest(handleCookies: source.enabledCookieJar ?? true)
    }

    private var sourceHeaders: [String: String] {
        guard let value = source.header,
              let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object.mapValues { String(describing: $0) }
    }
}

private struct SourceLoginWebView: UIViewRepresentable {
    let request: URLRequest
    let sourceURL: String
    let sourceID: String
    let loginCheckJavaScript: String?
    let reloadID: UUID
    @Binding var status: String
    @Binding var isChecking: Bool

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = UIColor(ReadingTheme.canvas)
        webView.scrollView.backgroundColor = UIColor(ReadingTheme.canvas)
        webView.navigationDelegate = context.coordinator
        context.coordinator.installExistingCookies(in: webView) { webView.load(request) }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.lastReloadID != reloadID else { return }
        context.coordinator.lastReloadID = reloadID
        webView.reload()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: SourceLoginWebView
        var lastReloadID: UUID

        init(parent: SourceLoginWebView) {
            self.parent = parent
            lastReloadID = parent.reloadID
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
            parent.status = "正在打开登录页…"
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            syncCookies(from: webView)
            guard let script = parent.loginCheckJavaScript?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !script.isEmpty else {
                parent.status = "页面已载入；登录后 Cookie 会自动同步。"
                return
            }
            parent.isChecking = true
            webView.evaluateJavaScript(script) { [weak self] value, error in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.parent.isChecking = false
                    if let error {
                        self.parent.status = "登录检测脚本失败：\(error.localizedDescription)"
                    } else {
                        self.parent.status = Self.truthy(value) ? "书源登录检测已通过" : "页面已载入，尚未检测到登录状态"
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
            parent.status = "登录页加载失败：\(error.localizedDescription)"
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
            parent.status = "登录页加载失败：\(error.localizedDescription)"
        }

        func installExistingCookies(in webView: WKWebView, completion: @escaping () -> Void) {
            guard let url = URL(string: parent.sourceURL) else {
                completion()
                return
            }
            let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
            guard !cookies.isEmpty else {
                completion()
                return
            }
            let group = DispatchGroup()
            for cookie in cookies {
                group.enter()
                webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { group.leave() }
            }
            group.notify(queue: .main, execute: completion)
        }

        private func syncCookies(from webView: WKWebView) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                cookies.forEach(HTTPCookieStorage.shared.setCookie)
                guard let url = URL(string: self.parent.sourceURL) else { return }
                let matching = HTTPCookieStorage.shared.cookies(for: url) ?? []
                let header = HTTPCookie.requestHeaderFields(with: matching)["Cookie"] ?? ""
                Task {
                    await SourceNetworkPolicy.shared.setCookieHeader(
                        header,
                        sourceID: self.parent.sourceID,
                        url: url
                    )
                }
            }
        }

        private static func truthy(_ value: Any?) -> Bool {
            if let value = value as? Bool { return value }
            if let value = value as? NSNumber { return value.boolValue }
            guard let text = value.map(String.init(describing:))?.lowercased() else { return false }
            return !text.isEmpty && !["false", "0", "null", "undefined"].contains(text)
        }
    }
}

final class WKSourceWebViewExecutor: NSObject, SourceWebViewRequestExecuting, @unchecked Sendable {
    @MainActor
    func execute(_ prepared: PreparedRequest, source: BookSource, timeout: TimeInterval) async throws -> HTTPResponse {
        let override = ApplicationSettingsStore.shared.settings.timeoutSeconds
        return try await BackgroundWebViewRequest(prepared: prepared, source: source, timeout: override > 0 ? Double(override) : timeout).run()
    }
}

@MainActor
private final class BackgroundWebViewRequest: NSObject, WKNavigationDelegate {
    private let prepared: PreparedRequest
    private let source: BookSource
    private let timeout: TimeInterval
    private let webView: WKWebView
    private var continuation: CheckedContinuation<HTTPResponse, Error>?
    private var responseStatus = 200
    private var responseHeaders: [String: String] = [:]
    private var completed = false
    private var timeoutTask: Task<Void, Never>?

    init(prepared: PreparedRequest, source: BookSource, timeout: TimeInterval) {
        self.prepared = prepared
        self.source = source
        self.timeout = timeout
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func run() async throws -> HTTPResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                installRequestCookies { [weak self] in self?.startLoading() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }

    private func startLoading() {
        timeoutTask = Task { [weak self] in
            let seconds = min(max(self?.timeout ?? 30, 1), 300)
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.finish(.failure(URLError(.timedOut))) }
        }
        webView.load(prepared.urlRequest(timeout: timeout, handleCookies: true))
    }

    private func installRequestCookies(completion: @escaping () -> Void) {
        guard let header = prepared.headers.first(where: { $0.key.caseInsensitiveCompare("Cookie") == .orderedSame })?.value,
              let host = prepared.url.host, !header.isEmpty else {
            completion()
            return
        }
        let cookies = header.split(separator: ";").compactMap { part -> HTTPCookie? in
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { return nil }
            return HTTPCookie(properties: [
                .name: pair[0].trimmingCharacters(in: .whitespaces),
                .value: pair[1],
                .domain: host,
                .path: "/",
                .secure: prepared.url.scheme == "https" ? "TRUE" : "FALSE"
            ])
        }
        guard !cookies.isEmpty else { completion(); return }
        let group = DispatchGroup()
        for cookie in cookies {
            group.enter()
            webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { group.leave() }
        }
        group.notify(queue: .main, execute: completion)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        if let response = navigationResponse.response as? HTTPURLResponse {
            responseStatus = response.statusCode
            responseHeaders = response.allHeaderFields.reduce(into: [:]) { result, entry in
                result[String(describing: entry.key)] = String(describing: entry.value)
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        Task { [weak self] in
            guard let self else { return }
            if prepared.webViewDelayMilliseconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(max(0, prepared.webViewDelayMilliseconds)) * 1_000_000)
            }
            guard !Task.isCancelled, !completed else { return }
            if let script = prepared.webJavaScript, !script.isEmpty {
                do { _ = try await evaluateString(script) }
                catch { finish(.failure(error)); return }
            }
            do {
                let html = try await evaluateString("document.documentElement.outerHTML") ?? ""
                let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                cookies.forEach(HTTPCookieStorage.shared.setCookie)
                let cookieHeader = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"] ?? ""
                if !cookieHeader.isEmpty {
                    await SourceNetworkPolicy.shared.setCookieHeader(cookieHeader, sourceID: source.id, url: prepared.url)
                }
                var headers = responseHeaders
                if !cookieHeader.isEmpty { headers["Set-Cookie"] = cookieHeader }
                finish(.success(.init(
                    data: Data(html.utf8),
                    statusCode: responseStatus,
                    headers: headers,
                    finalURL: webView.url ?? prepared.url,
                    requestedCharset: "utf-8"
                )))
            } catch {
                finish(.failure(error))
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
        finish(.failure(error))
    }

    /// 不用 `async evaluateJavaScript`：脚本结果为 undefined/null 时它会因隐式解包 nil 直接崩溃
    /// （书源 webJs 常以 `xxx.click()` 结尾）。返回 DOM 节点等不支持的类型也不应让整个请求失败。
    private func evaluateString(_ script: String) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    if let wkError = error as? WKError, wkError.code == .javaScriptResultTypeIsUnsupported {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(throwing: error)
                    }
                } else {
                    continuation.resume(returning: value as? String)
                }
            }
        }
    }

    private func finish(_ result: Result<HTTPResponse, Error>) {
        guard !completed else { return }
        completed = true
        timeoutTask?.cancel()
        webView.stopLoading()
        continuation?.resume(with: result)
        continuation = nil
    }
}

private extension WKHTTPCookieStore {
    func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            getAllCookies { continuation.resume(returning: $0) }
        }
    }
}

// MARK: - loginUi 表单（安卓「阅读」书源登录界面）

struct SourceLoginUIRow: Identifiable, Equatable {
    var name: String
    var type: String
    var action: String?
    var chars: [String]
    var defaultValue: String
    var viewName: String?
    var fullWidth: Bool
    /// 安卓 FlexboxLayout 的 layout_flexBasisPercent：0.4 一行两个，0.24 一行四个，1 独占一行。
    var basis: Double = 1
    var id: String { type + "|" + name }

    /// 分组标题：没有动作（或动作是 `void 0`）的按钮。
    var isHeader: Bool {
        guard type == "button" else { return false }
        guard let action = action?.trimmingCharacters(in: .whitespacesAndNewlines) else { return true }
        return action == "void 0" || action == "void 0;" || action == "void(0)" || action == "void(0);"
    }

    /// 补齐网格的占位格（书源用「※」占位）。
    var isPlaceholder: Bool {
        let text = title.trimmingCharacters(in: .whitespaces)
        return text == "※" || text.isEmpty || (action?.contains("这是占位符") ?? false)
    }

    /// 安卓把 viewName（没有时用 name）当 JS 表达式求值，例如
    /// `'🌐 当前线路：'+(source.get('sqWeb')||'…')`。单纯的字符串字面量直接去引号。
    var rawTitle: String {
        let text = (viewName?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? name
        return text.trimmingCharacters(in: .whitespaces)
    }

    var titleExpression: String? {
        let text = rawTitle
        guard let first = text.first, first == "'" || first == "\"" else { return nil }
        if Self.isPlainLiteral(text) { return nil }
        return text
    }

    var title: String {
        let text = rawTitle
        if Self.isPlainLiteral(text) { return String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces) }
        return text
    }

    static func isPlainLiteral(_ text: String) -> Bool {
        guard text.count >= 2, let first = text.first, first == text.last, first == "'" || first == "\"" else { return false }
        return !text.dropFirst().dropLast().contains(first)
    }

    /// `@js:` / `<js>` 写法的 loginUi：脚本运行后才得到界面 JSON（番茄等书源的分支菜单式登录页）。
    static func dynamicScript(_ raw: String?) -> String? {
        guard var script = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !script.isEmpty else { return nil }
        if script.lowercased().hasPrefix("@js:") { return String(script.dropFirst(4)) }
        if script.lowercased().hasPrefix("<js>") {
            script = String(script.dropFirst(4))
            if let end = script.range(of: "</js>", options: [.caseInsensitive, .backwards]) {
                script = String(script[..<end.lowerBound])
            }
            return script
        }
        return nil
    }

    static func parse(_ raw: String?) -> [SourceLoginUIRow] {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), raw.hasPrefix("["),
              let data = raw.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var seen: [String: Int] = [:]
        return items.compactMap { item in
            let named = item["name"].map({ String(describing: $0) }).flatMap { $0.isEmpty ? nil : $0 }
            let titled = item["title"].map({ String(describing: $0) }).flatMap { $0.isEmpty ? nil : $0 }
            guard var name = named ?? titled else { return nil }
            let chars = (item["chars"] as? [Any])?.map { String(describing: $0) } ?? []
            let basis = ((item["style"] as? [String: Any])?["layout_flexBasisPercent"] as? NSNumber)?.doubleValue ?? 1
            // 同名占位格、同名标题不能共用一个 id，否则 ForEach 会把它们合并。
            let type = (item["type"] as? String ?? "text").lowercased()
            let count = seen[type + "|" + name, default: 0]
            seen[type + "|" + name] = count + 1
            if count > 0, type == "button" { name += String(repeating: "\u{200B}", count: count) }
            return SourceLoginUIRow(
                name: name,
                type: (item["type"] as? String ?? "text").lowercased(),
                action: (item["action"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                chars: chars,
                defaultValue: item["default"].map { String(describing: $0) } ?? "",
                viewName: item["viewName"] as? String,
                fullWidth: basis >= 0.99,
                basis: basis > 0 ? min(basis, 1) : 1
            )
        }
    }
}

struct SourceLoginFormView: View {
    let source: BookSource
    @State private var rows: [SourceLoginUIRow]
    @State private var values: [String: String] = [:]
    @State private var status: String?
    @State private var isRunning = false
    @State private var titles: [String: String] = [:]
    @State private var isBuilding: Bool
    @State private var showsLog = false
    @State private var confirmsHeaderDeletion = false
    /// 书源 toast / longToast：像安卓「阅读」一样浮在页面中间，几秒后自动消失，不再挤在页面顶部。
    @State private var toast: String?
    @State private var toastToken = UUID()
    @State private var lastRunToasted = false
    private let dynamicScript: String?

    init(source: BookSource, rows: [SourceLoginUIRow]) {
        self.source = source
        dynamicScript = SourceLoginUIRow.dynamicScript(source.loginUi)
        _rows = State(initialValue: rows)
        _isBuilding = State(initialValue: rows.isEmpty && SourceLoginUIRow.dynamicScript(source.loginUi) != nil)
    }

    /// 书源按网格设计（一行放两个、四个按钮）时用卡片网格，和安卓「阅读」的登录页一致。
    private var usesGrid: Bool { dynamicScript != nil || rows.contains { $0.basis < 0.99 } }

    var body: some View {
        Group {
            if usesGrid { gridBody } else { formBody }
        }
        .disabled(isRunning)
        .overlay { if isRunning || isBuilding { ProgressView().controlSize(.large) } }
        .overlay {
            if let toast {
                SourceLoginToast(text: toast)
                    .onTapGesture { withAnimation(.easeOut(duration: 0.18)) { self.toast = nil } }
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: toast)
        .onAppear { SourceWebLoginPresenter.install() }
        .onDisappear { SourceWebLoginPresenter.uninstall() }
        .navigationTitle("登录 · \(source.bookSourceName)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { Task { await saveAndLogin() } } label: { Image(systemName: "checkmark") }
                    .accessibilityLabel("保存并登录")
                Menu {
                    Button("查看登录头", systemImage: "eye") { showLoginHeader() }
                    Button("删除登录头", systemImage: "trash", role: .destructive) { confirmsHeaderDeletion = true }
                    Divider()
                    Button("日志", systemImage: "doc.text") { showsLog = true }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("更多")
            }
        }
        .confirmationDialog("删除登录头？", isPresented: $confirmsHeaderDeletion, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                BookSourceRuntimeStore.shared.put(sourceID: source.bookSourceUrl, key: "loginHeader", value: "")
                showToast("登录头已删除")
            }
        } message: {
            Text("删除后需要重新登录，书源的请求才会带上登录信息。")
        }
        .sheet(isPresented: $showsLog) {
            ReadingNavigationStack {
                DiagnosticLogView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("关闭") { showsLog = false } }
                    }
            }
        }
        .onAppear(perform: loadValues)
        .task {
            await rebuildRows()
            await evaluateTitles()
        }
    }

    private func showLoginHeader() {
        let header = BookSourceRuntimeStore.shared.get(sourceID: source.bookSourceUrl, key: "loginHeader")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        showToast(header.isEmpty ? "还没有登录头" : "登录头：\(header)")
    }

    private func showToast(_ text: String) {
        let token = UUID()
        toastToken = token
        toast = text
        let seconds = min(max(2.2, Double(text.count) * 0.06), 6)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if toastToken == token { toast = nil }
        }
    }

    /// 书源登录脚本里打开的网页登录地址（如番茄的 fanqienovel.com），做成页面底部的「网页登录」按钮。
    private var webLoginURL: String? {
        let script = source.loginUrl ?? ""
        let pattern = #"startBrowserAwait\(\s*['"](https?://[^'"]+)['"]"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: script, range: NSRange(script.startIndex..., in: script)),
              let range = Range(match.range(at: 1), in: script) else { return nil }
        return String(script[range])
    }

    private var webLoginTitle: String {
        let name = source.bookSourceName.prefix { $0.isLetter || $0.isNumber }
        return (name.isEmpty ? "网页" : String(name)) + "登录"
    }

    private func openWebLogin(_ url: String) async {
        let escaped = url.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        await run("java.startBrowserAwait('\(escaped)', '\(webLoginTitle)'); java.toast('网页登录状态已同步');")
    }

    /// 脚本生成的登录页：每次执行按钮后重新运行 loginUi，切换「主菜单 → 子页」。
    private func rebuildRows() async {
        guard let dynamicScript else { return }
        defer { isBuilding = false }
        var info: [String: JSONValue] = [:]
        for row in rows where row.type != "button" { info[row.name] = .string(values[row.name] ?? row.defaultValue) }
        do {
            let result = try await JavaScriptRuleEvaluator(maximumScriptLength: 8 * 1_024 * 1_024)
                .evaluateAsync(script: dynamicScript, result: .object(info),
                               executionContext: .init(baseURL: source.bookSourceUrl, source: source))
            var text = result.value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.hasPrefix("["), case .array = result.value, let data = try? JSONEncoder().encode(result.value),
               let encoded = String(data: data, encoding: .utf8) {
                text = encoded
            }
            let parsed = SourceLoginUIRow.parse(text)
            if parsed.isEmpty {
                if rows.isEmpty { status = "登录界面生成失败：书源脚本没有返回界面配置" }
            } else {
                withAnimation(.easeInOut(duration: 0.18)) { rows = parsed }
                var next = values
                for row in parsed where row.type != "button" && next[row.name] == nil {
                    next[row.name] = row.defaultValue
                }
                values = next
            }
        } catch {
            status = "登录界面生成失败：\(error.localizedDescription)"
        }
    }

    private var gridBody: some View {
        ScrollView {
            VStack(spacing: 10) {
                if let status {
                    Text(status)
                        .font(AppFontStyle.footnote.themed)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(ReadingTheme.groupedCanvas, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                ForEach(Array(gridLines.enumerated()), id: \.offset) { _, line in
                    HStack(spacing: 10) {
                        ForEach(line) { row in gridCell(row) }
                    }
                }
                if let url = webLoginURL {
                    Button {
                        Task { await openWebLogin(url) }
                    } label: {
                        Label(webLoginTitle, systemImage: "globe")
                            .font(AppFontStyle.subheadline.weight(.semibold).themed)
                            .foregroundStyle(ReadingTheme.onAccent)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(ReadingTheme.accentFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .readingCanvas()
    }

    /// 按 flexBasisPercent 把格子排成行：一行放满（合计不超过 100%）就换行。
    private var gridLines: [[SourceLoginUIRow]] {
        var lines: [[SourceLoginUIRow]] = []
        var current: [SourceLoginUIRow] = []
        var used = 0.0
        for row in rows {
            let basis = row.isHeader ? 1 : row.basis
            if !current.isEmpty, used + basis > 1.0001 || row.isHeader || basis >= 0.99 {
                lines.append(current)
                current = []
                used = 0
            }
            current.append(row)
            used += basis
            if row.isHeader || basis >= 0.99 {
                lines.append(current)
                current = []
                used = 0
            }
        }
        if !current.isEmpty { lines.append(current) }
        // 一行全是占位格就不显示。
        return lines.filter { !$0.allSatisfy(\.isPlaceholder) }
    }

    @ViewBuilder private func gridCell(_ row: SourceLoginUIRow) -> some View {
        if row.isPlaceholder && row.type == "button" {
            Color.clear.frame(maxWidth: .infinity, minHeight: 1)
        } else if row.isHeader {
            Text(title(row))
                .font(AppFontStyle.footnote.weight(.semibold).themed)
                .foregroundStyle(ReadingTheme.secondaryInk)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
        } else {
            switch row.type {
            case "button":
                Button {
                    if let action = row.action { Task { await run(action) } }
                } label: {
                    Text(title(row))
                        .font(AppFontStyle.subheadline.weight(.medium).themed)
                        .foregroundStyle(ReadingTheme.ink)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 11)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(ReadingTheme.groupedCanvas, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            case "toggle", "select":
                Menu {
                    ForEach(row.chars.isEmpty ? ["🔳", "✅"] : row.chars, id: \.self) { option in
                        Button(option) {
                            values[row.name] = option
                            persist()
                            if let action = row.action { Task { await run(action, quiet: true) } }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(title(row)).foregroundStyle(ReadingTheme.secondaryInk)
                        Text(values[row.name] ?? row.defaultValue).foregroundStyle(ReadingTheme.ink)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
                    }
                    .font(AppFontStyle.subheadline.themed)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(ReadingTheme.groupedCanvas, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            default:
                VStack(alignment: .leading, spacing: 6) {
                    Text(title(row))
                        .font(AppFontStyle.caption.themed)
                        .foregroundStyle(ReadingTheme.secondaryInk)
                    Group {
                        if row.type == "password" {
                            SecureField(row.defaultValue.isEmpty ? title(row) : row.defaultValue, text: binding(row))
                        } else {
                            TextField(row.defaultValue.isEmpty ? title(row) : row.defaultValue, text: binding(row))
                                .disableAutocorrection(true)
                                .textInputAutocapitalization(.never)
                        }
                    }
                    .font(AppFontStyle.subheadline.themed)
                    .onSubmit(persist)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ReadingTheme.groupedCanvas, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private var formBody: some View {
        Form {
            if let status {
                Section {
                    Text(status).font(AppFontStyle.callout.themed).foregroundStyle(.secondary).textSelection(.enabled)
                }.readingRowBackground()
            }
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                Section {
                    ForEach(section.1) { row in rowView(row) }
                } header: {
                    Text(section.0)
                } footer: {
                    if let note = footer(for: section.0) { Text(note) }
                }.readingRowBackground()
            }
        }.readingThemedListBackground()
    }

    private func title(_ row: SourceLoginUIRow) -> String { titles[row.id] ?? row.title }

    /// 一次执行所有需要求值的标题，避免逐行重复加载 jsLib。
    private func evaluateTitles() async {
        let dynamic = rows.filter { $0.titleExpression != nil }
        guard !dynamic.isEmpty else { return }
        let parts = dynamic.map { "(function(){try{var v=(\($0.titleExpression!));return v==null?null:String(v)}catch(e){return null}})()" }
        let script = "JSON.stringify([" + parts.joined(separator: ",") + "])"
        var info: [String: JSONValue] = [:]
        for row in rows where row.type != "button" { info[row.name] = .string(values[row.name] ?? row.defaultValue) }
        guard let result = try? await JavaScriptRuleEvaluator(maximumScriptLength: 8 * 1_024 * 1_024)
            .evaluateAsync(script: script, result: .object(info), executionContext: .init(baseURL: source.bookSourceUrl, source: source)),
              let data = result.value.stringValue.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return }
        var next = titles
        for (row, value) in zip(dynamic, array) {
            if let text = value as? String, !text.isEmpty { next[row.id] = text.trimmingCharacters(in: .whitespaces) }
        }
        titles = next
    }

    /// 没有 action 的 button 在安卓上通常是分组标题。
    private var sections: [(String, [SourceLoginUIRow])] {
        var result: [(String, [SourceLoginUIRow])] = []
        var header = ""
        var current: [SourceLoginUIRow] = []
        for row in rows {
            if row.isHeader {
                if !current.isEmpty || !header.isEmpty { result.append((header, current)) }
                header = title(row)
                current = []
            } else {
                current.append(row)
            }
        }
        if !current.isEmpty || !header.isEmpty { result.append((header, current)) }
        return result
    }

    @ViewBuilder private func rowView(_ row: SourceLoginUIRow) -> some View {
        switch row.type {
        case "toggle" where row.chars.count == 2 || row.chars.isEmpty:
            Toggle(title(row), isOn: Binding(
                get: {
                    let on = row.chars.last ?? "✅"
                    let value = values[row.name] ?? row.defaultValue
                    return value == on || ["1", "true", "开", "开启"].contains(value.lowercased())
                },
                set: { isOn in
                    let options = row.chars.isEmpty ? ["🔳", "✅"] : row.chars
                    values[row.name] = isOn ? options[1] : options[0]
                    persist()
                    if let action = row.action { Task { await run(action, quiet: true) } }
                }
            ))
        case "toggle":
            Picker(title(row), selection: Binding(
                get: { values[row.name] ?? row.defaultValue },
                set: {
                    values[row.name] = $0
                    persist()
                    if let action = row.action { Task { await run(action, quiet: true) } }
                }
            )) {
                ForEach(row.chars, id: \.self) { Text($0).tag($0) }
            }
        case "select":
            Picker(title(row), selection: Binding(
                get: { values[row.name] ?? row.defaultValue },
                set: {
                    values[row.name] = $0
                    persist()
                    if let action = row.action { Task { await run(action, quiet: true) } }
                }
            )) {
                ForEach(row.chars, id: \.self) { Text($0).tag($0) }
            }
        case "button":
            Button(title(row)) {
                if let action = row.action { Task { await run(action) } }
            }
        default:
            if isLongField(row) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title(row))
                    TextEditor(text: binding(row))
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 90)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
                }
                .padding(.vertical, 4)
            } else if isColorField(row) {
                HStack {
                    Text(title(row))
                    Spacer()
                    TextField(row.defaultValue, text: binding(row))
                        .multilineTextAlignment(.trailing)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: 110)
                        .textInputAutocapitalization(.characters)
                        .disableAutocorrection(true)
                    ColorPicker("", selection: colorBinding(row), supportsOpacity: false).labelsHidden()
                }
            } else if row.type == "password" {
                HStack {
                    Text(title(row))
                    SecureField(row.defaultValue, text: binding(row)).multilineTextAlignment(.trailing)
                }
            } else {
                HStack {
                    Text(title(row))
                    TextField(row.defaultValue, text: binding(row))
                        .multilineTextAlignment(.trailing)
                        .disableAutocorrection(true)
                }
            }
        }
    }

    /// 自定义气泡等模板字段：内容是一整段 SVG，单行输入框放不下。
    private func isLongField(_ row: SourceLoginUIRow) -> Bool {
        row.name.contains("气泡") || row.name.contains("模板内容") || (values[row.name] ?? row.defaultValue).count > 40
    }

    private func isColorField(_ row: SourceLoginUIRow) -> Bool {
        row.defaultValue.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil
    }

    private func colorBinding(_ row: SourceLoginUIRow) -> Binding<Color> {
        Binding(
            get: { Color(uiColor: UIColor(loginHex: values[row.name] ?? row.defaultValue) ?? .label) },
            set: { values[row.name] = UIColor($0).loginHex; persist() }
        )
    }

    /// 和阅读器设置的关系说明，写在对应分组底下。
    private func footer(for header: String) -> String? {
        if header.contains("评论") || header.contains("段评") {
            return "开关改完后返回阅读页，下拉刷新本章即可生效。气泡的形状跟随「阅读设置 › 段评气泡」，这里设置的颜色会用在气泡上；半屏高度和评论主题用于点开后的评论页。"
        }
        if header.contains("气泡") {
            return "这里的 SVG 气泡模板是给安卓「阅读」用的，本软件不使用；想换气泡样式，请在「阅读设置 › 段评气泡」里选择，支持导入自定义图片。"
        }
        return nil
    }

    private func binding(_ row: SourceLoginUIRow) -> Binding<String> {
        Binding(get: { values[row.name] ?? row.defaultValue }, set: { values[row.name] = $0 })
    }

    private func loadValues() {
        var stored: [String: String] = [:]
        let raw = BookSourceRuntimeStore.shared.get(sourceID: source.id, key: "loginInfo")
        if let data = raw.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            stored = object.mapValues { String(describing: $0) }
        }
        for row in rows where row.type != "button" {
            stored[row.name] = stored[row.name] ?? row.defaultValue
        }
        values = stored
    }

    private func persist() {
        var info: [String: String] = [:]
        for row in rows where row.type != "button" { info[row.name] = values[row.name] ?? row.defaultValue }
        if let data = try? JSONSerialization.data(withJSONObject: info),
           let text = String(data: data, encoding: .utf8) {
            BookSourceRuntimeStore.shared.put(sourceID: source.id, key: "loginInfo", value: text)
        }
    }

    private var loginScript: String {
        var script = (source.loginUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if script.lowercased().hasPrefix("http") { return "" }
        if script.lowercased().hasPrefix("@js:") { script = String(script.dropFirst(4)) }
        if script.lowercased().hasPrefix("<js>") {
            script = String(script.dropFirst(4))
            if let end = script.range(of: "</js>", options: [.caseInsensitive, .backwards]) {
                script = String(script[..<end.lowerBound])
            }
        }
        return script
    }

    /// 安卓的按钮脚本以 `result` 拿到表单里填的值（loginInfo）。
    private func run(_ action: String, quiet: Bool = false) async {
        lastRunToasted = false
        persist()
        if !quiet { isRunning = true }
        defer { isRunning = false }
        let script = loginScript + "\n" + action
        var info: [String: JSONValue] = [:]
        for row in rows where row.type != "button" { info[row.name] = .string(values[row.name] ?? row.defaultValue) }
        do {
            let result = try await JavaScriptRuleEvaluator(maximumScriptLength: 8 * 1_024 * 1_024)
                .evaluateAsync(script: script, result: .object(info), executionContext: .init(baseURL: source.bookSourceUrl, source: source))
            if let toast = result.variables[JavaScriptRuleEvaluator.toastKey]?.trimmingCharacters(in: .whitespacesAndNewlines), !toast.isEmpty {
                showToast(toast)
                lastRunToasted = true
            } else if !quiet {
                let value = result.value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let readable = !value.isEmpty && value != "null" && value != "undefined" && value != "true"
                    && value != "false" && !value.hasPrefix("{") && !value.hasPrefix("[") && !value.hasPrefix("<")
                if readable { showToast(String(value.prefix(200))); lastRunToasted = true }
            }
        } catch {
            showToast("执行失败：\(error.localizedDescription)")
            lastRunToasted = true
        }
        await rebuildRows()
        await evaluateTitles()
    }

    private func saveAndLogin() async {
        persist()
        await run("typeof login === 'function' ? login() : ''")
        if !lastRunToasted { showToast("已保存") }
    }
}

private extension UIColor {
    convenience init?(loginHex: String) {
        var hex = loginHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    var loginHex: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        func c(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }
}

/// 登录页的提示框：书源 toast 的内容（可多行），浮在页面中间。
private struct SourceLoginToast: View {
    let text: String

    var body: some View {
        ScrollView(showsIndicators: false) {
            Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(AppFontStyle.subheadline.themed)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
        }
        .frame(maxWidth: 300)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxHeight: 420)
        .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
        .padding(32)
        .accessibilityAddTraits(.isStaticText)
    }
}

/// 把书源脚本的 `java.startBrowserAwait` 接到真正的网页：弹出网页，用户登录后点「完成」或下滑关闭，
/// 把网页里的 Cookie 同步进 App，脚本再继续执行（比如读取 sessionid 完成登录）。
enum SourceWebLoginPresenter {
    @MainActor static func install() {
        JavaScriptWebLoginBridge.presenter = { url, title, html, done in
            Task { @MainActor in
                guard let target = URL(string: url), let top = topController() else { done(); return }
                let controller = SourceAwaitBrowserController(url: target, html: html) { done() }
                controller.title = title.isEmpty ? "登录" : title
                let navigation = UINavigationController(rootViewController: controller)
                navigation.presentationController?.delegate = controller
                top.present(navigation, animated: true)
            }
        }
    }

    @MainActor static func uninstall() {
        JavaScriptWebLoginBridge.presenter = nil
    }

    @MainActor private static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var controller = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
            ?? scene?.windows.first?.rootViewController
        while let presented = controller?.presentedViewController, !presented.isBeingDismissed {
            controller = presented
        }
        return controller
    }
}

private final class SourceAwaitBrowserController: UIViewController, WKNavigationDelegate, UIAdaptivePresentationControllerDelegate {
    private let url: URL
    private let html: String?
    private let onClose: @MainActor @Sendable () -> Void
    private var webView: WKWebView?
    private var closed = false
    private let progress = UIProgressView(progressViewStyle: .bar)
    private var observation: NSKeyValueObservation?

    init(url: URL, html: String?, onClose: @escaping @MainActor @Sendable () -> Void) {
        self.url = url
        self.html = html
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: view.bounds, configuration: configuration)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        view.addSubview(webView)
        self.webView = webView
        progress.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progress)
        NSLayoutConstraint.activate([
            progress.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progress.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
        ])
        observation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] web, _ in
            let value = Float(web.estimatedProgress)
            Task { @MainActor in
                self?.progress.setProgress(value, animated: true)
                self?.progress.isHidden = value >= 1
            }
        }
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(finish))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(finish))
        if let html {
            webView.loadHTMLString(html, baseURL: url)
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    @objc private func finish() {
        guard !closed else { return }
        closed = true
        syncCookies { [weak self] in
            guard let self else { return }
            self.dismiss(animated: true)
            self.onClose()
        }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard !closed else { return }
        closed = true
        syncCookies { [weak self] in self?.onClose() }
    }

    private func syncCookies(_ completion: @escaping @MainActor @Sendable () -> Void) {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            for cookie in cookies {
                HTTPCookieStorage.shared.setCookie(cookie)
                let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                guard !domain.isEmpty else { continue }
                LegadoCookieStore.shared.setCookie("\(cookie.name)=\(cookie.value)", for: "https://\(domain)")
            }
            Task { @MainActor in completion() }
        }
    }
}
