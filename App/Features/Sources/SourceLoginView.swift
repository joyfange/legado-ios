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
        if !rows.isEmpty || !(source.loginUrl ?? "").trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("http") {
            SourceLoginFormView(source: source, rows: rows)
        } else {
            webLogin
        }
    }

    private var webLogin: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill").foregroundStyle(ReadingTheme.accent)
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
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
                do { _ = try await webView.evaluateJavaScript(script) }
                catch { finish(.failure(error)); return }
            }
            do {
                let html = try await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String ?? ""
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
    var id: String { type + "|" + name }

    var title: String {
        guard var text = viewName?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return name }
        if text.count >= 2, let first = text.first, first == text.last, first == "'" || first == "\"" {
            text = String(text.dropFirst().dropLast())
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    static func parse(_ raw: String?) -> [SourceLoginUIRow] {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), raw.hasPrefix("["),
              let data = raw.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let name = item["name"].map({ String(describing: $0) }), !name.isEmpty else { return nil }
            let chars = (item["chars"] as? [Any])?.map { String(describing: $0) } ?? []
            let basis = ((item["style"] as? [String: Any])?["layout_flexBasisPercent"] as? NSNumber)?.doubleValue ?? 1
            return SourceLoginUIRow(
                name: name,
                type: (item["type"] as? String ?? "text").lowercased(),
                action: (item["action"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                chars: chars,
                defaultValue: item["default"].map { String(describing: $0) } ?? "",
                viewName: item["viewName"] as? String,
                fullWidth: basis >= 0.99
            )
        }
    }
}

struct SourceLoginFormView: View {
    let source: BookSource
    let rows: [SourceLoginUIRow]
    @State private var values: [String: String] = [:]
    @State private var status: String?
    @State private var isRunning = false

    var body: some View {
        Form {
            if let status {
                Section {
                    Text(status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                Section(section.0) {
                    ForEach(section.1) { row in rowView(row) }
                }
            }
        }
        .disabled(isRunning)
        .overlay { if isRunning { ProgressView().controlSize(.large) } }
        .navigationTitle("登录 · \(source.bookSourceName)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") { Task { await saveAndLogin() } }
            }
        }
        .onAppear(perform: loadValues)
    }

    /// 没有 action 的 button 在安卓上通常是分组标题。
    private var sections: [(String, [SourceLoginUIRow])] {
        var result: [(String, [SourceLoginUIRow])] = []
        var header = ""
        var current: [SourceLoginUIRow] = []
        for row in rows {
            if row.type == "button", row.action == nil {
                if !current.isEmpty || !header.isEmpty { result.append((header, current)) }
                header = row.title
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
        case "password":
            LabeledContent(row.title) {
                SecureField(row.defaultValue, text: binding(row)).multilineTextAlignment(.trailing)
            }
        case "toggle":
            Button {
                let options = row.chars.isEmpty ? ["🔳", "✅"] : row.chars
                let current = values[row.name] ?? row.defaultValue
                let index = options.firstIndex(of: current) ?? -1
                values[row.name] = options[(index + 1) % options.count]
                persist()
                if let action = row.action { Task { await run(action) } }
            } label: {
                HStack {
                    Text(row.title).foregroundStyle(.primary)
                    Spacer()
                    Text(values[row.name] ?? row.defaultValue)
                }
            }
        case "select":
            Picker(row.title, selection: Binding(
                get: { values[row.name] ?? row.defaultValue },
                set: {
                    values[row.name] = $0
                    persist()
                    if let action = row.action { Task { await run(action) } }
                }
            )) {
                ForEach(row.chars, id: \.self) { Text($0).tag($0) }
            }
        case "button":
            Button(row.title) {
                if let action = row.action { Task { await run(action) } }
            }
        default:
            LabeledContent(row.title) {
                TextField(row.defaultValue, text: binding(row)).multilineTextAlignment(.trailing)
            }
        }
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

    private func run(_ action: String) async {
        persist()
        isRunning = true
        defer { isRunning = false }
        let script = loginScript + "\n" + action
        do {
            let result = try await JavaScriptRuleEvaluator(maximumScriptLength: 8 * 1_024 * 1_024)
                .evaluateAsync(script: script, result: .string(""), executionContext: .init(baseURL: source.bookSourceUrl, source: source))
            loadValues()
            if let toast = result.variables[JavaScriptRuleEvaluator.toastKey], !toast.isEmpty {
                status = toast
            } else {
                let value = result.value.stringValue
                status = value.isEmpty || value == "null" || value == "undefined" ? "已执行" : String(value.prefix(400))
            }
        } catch {
            status = "执行失败：\(error.localizedDescription)"
        }
    }

    private func saveAndLogin() async {
        persist()
        await run("typeof login === 'function' ? login() : ''")
        if status == "已执行" { status = "已保存" }
    }
}
