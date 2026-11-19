import SwiftUI
import CryptoKit

/// 发现页内存缓存：分区列表和每个分区第一页的书。返回发现页、切换布局、书籍详情的同题材作品
/// 都直接复用，不再重复请求书源；下拉刷新时跳过缓存。
@MainActor
final class ExploreCache {
    static let shared = ExploreCache()
    private struct Entry<Value> { let value: Value; let time: Date }
    private var kinds: [String: Entry<ExploreKindsReport>] = [:]
    private var pages: [String: Entry<SourceSearchOutcome>] = [:]
    private var kindTasks: [String: Task<ExploreKindsReport, Never>] = [:]
    private var pageTasks: [String: Task<SourceSearchOutcome, Never>] = [:]
    private let lifetime: TimeInterval = 20 * 60
    /// 下拉刷新过的书源：本次运行不再用旧的磁盘缓存。
    private var skipDisk: Set<String> = []

    private func sourceKey(_ source: BookSource) -> String {
        source.bookSourceUrl + "\u{1F}" + (source.exploreUrl ?? "") + "\u{1F}" + String(source.lastUpdateTime)
    }

    private func pageKey(_ source: BookSource, _ kind: ExploreKind) -> String {
        sourceKey(source) + "\u{1F}" + kind.title + "\u{1F}" + (kind.navigableURL ?? "")
    }

    func cachedFirstPage(source: BookSource, kind: ExploreKind) -> SourceSearchOutcome? {
        let key = pageKey(source, kind)
        if let entry = pages[key], Date().timeIntervalSince(entry.time) < lifetime { return entry.value }
        // 内存里没有就读磁盘缓存（上次打开时存下的第一页），先显示，后台再刷新。
        if !skipDisk.contains(where: { key.hasPrefix($0) }),
           let books: [SearchBook] = ExploreDiskCache.read(key, maxAge: 12 * 3600), !books.isEmpty {
            let outcome = SourceSearchOutcome(sourceID: source.id, books: books, diagnostics: [])
            pages[key] = Entry(value: outcome, time: Date().addingTimeInterval(-lifetime + 30))
            revalidatePage(source: source, kind: kind, key: key)
            return outcome
        }
        return nil
    }

    /// 后台刷新一个分区的第一页（不打断界面，回来后更新内存与磁盘缓存）。
    private func revalidatePage(source: BookSource, kind: ExploreKind, key: String) {
        guard pageTasks[key] == nil else { return }
        let task = Task { await BookExploreService().explore(source: source, kind: kind, page: 1) }
        pageTasks[key] = task
        Task {
            let outcome = await task.value
            pageTasks[key] = nil
            if !outcome.books.isEmpty {
                pages[key] = Entry(value: outcome, time: Date())
                ExploreDiskCache.write(key, outcome.books)
            }
        }
    }

    /// 同一个书源的分区列表同时只请求一次（发现页和详情页同时要时共用一个请求）。
    func kinds(for source: BookSource, force: Bool = false) async -> ExploreKindsReport {
        let key = sourceKey(source)
        if !force, let entry = kinds[key], Date().timeIntervalSince(entry.time) < lifetime { return entry.value }
        if !force, let running = kindTasks[key] { return await running.value }
        // 磁盘里有上次的分区列表：立刻返回（进书源不用再等脚本跑完），后台重新计算一次。
        if !force, let stored: [ExploreKind] = ExploreDiskCache.read("kinds" + key, maxAge: 3 * 86400), !stored.isEmpty {
            let report = ExploreKindsReport(kinds: stored)
            kinds[key] = Entry(value: report, time: Date().addingTimeInterval(-lifetime + 60))
            let task = Task { await BookExploreService().kinds(for: source) }
            kindTasks[key] = task
            Task {
                let fresh = await task.value
                kindTasks[key] = nil
                if !fresh.kinds.isEmpty {
                    kinds[key] = Entry(value: fresh, time: Date())
                    ExploreDiskCache.write("kinds" + key, fresh.kinds)
                }
            }
            return report
        }
        let task = Task { await BookExploreService().kinds(for: source) }
        kindTasks[key] = task
        let report = await task.value
        kindTasks[key] = nil
        if !report.kinds.isEmpty {
            kinds[key] = Entry(value: report, time: Date())
            ExploreDiskCache.write("kinds" + key, report.kinds)
        }
        return report
    }

    /// 分区第一页：有缓存直接返回；同一分区同时只发一个请求。请求不随视图消失而取消，
    /// 滑走再滑回来时直接用已经回来的结果。
    func firstPage(source: BookSource, kind: ExploreKind, force: Bool = false) async -> SourceSearchOutcome {
        let key = pageKey(source, kind)
        if !force, let cached = cachedFirstPage(source: source, kind: kind) { return cached }
        if !force, let running = pageTasks[key] { return await running.value }
        let task = Task { await BookExploreService().explore(source: source, kind: kind, page: 1) }
        pageTasks[key] = task
        let outcome = await task.value
        pageTasks[key] = nil
        if !outcome.books.isEmpty {
            pages[key] = Entry(value: outcome, time: Date())
            ExploreDiskCache.write(key, outcome.books)
        }
        if pages.count > 400 { pages.removeAll() }
        return outcome
    }

    private var prewarmedSources: Set<String> = []
    private var prewarmTask: Task<Void, Never>?

    /// 打开 App 后在后台预先算好各书源的分区列表和前两个分区的第一页（存进内存与磁盘缓存），
    /// 之后切到这些书源时直接显示，不用再等书源脚本和服务器（番茄等书源首次要十几秒）。
    func prewarm(_ sources: [BookSource]) {
        let pending = sources.filter { !prewarmedSources.contains(sourceKey($0)) }
        guard !pending.isEmpty, prewarmTask == nil else { return }
        prewarmTask = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            for source in pending.prefix(16) {
                guard let self, !Task.isCancelled else { break }
                self.prewarmedSources.insert(self.sourceKey(source))
                let report = await self.kinds(for: source)
                let first = report.kinds.filter { $0.navigableURL != nil }.prefix(2)
                for kind in first { _ = await self.firstPage(source: source, kind: kind) }
            }
            self?.prewarmTask = nil
        }
    }

    func clear(source: BookSource) {
        let prefix = sourceKey(source)
        skipDisk.insert(prefix)
        ExploreDiskCache.remove("kinds" + prefix)
        for key in pages.keys where key.hasPrefix(prefix) { ExploreDiskCache.remove(key) }
        kinds[prefix] = nil
        pages = pages.filter { !$0.key.hasPrefix(prefix) }
    }
}

/// 发现页磁盘缓存：分区列表和各分区第一页存成小 JSON 文件，下次进书源秒开。
enum ExploreDiskCache {
    private static let directory: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado/Explore", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static func file(_ key: String) -> URL {
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".json")
    }

    static func read<Value: Decodable>(_ key: String, maxAge: TimeInterval) -> Value? {
        let url = file(key)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < maxAge,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    static func write<Value: Encodable>(_ key: String, _ value: Value) {
        let url = file(key)
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(value) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    static func remove(_ key: String) {
        try? FileManager.default.removeItem(at: file(key))
    }
}

@MainActor
final class ExploreSourceViewModel: ObservableObject {
    enum State: Equatable { case idle, loading, ready, empty, failed }
    enum SectionState: Equatable { case loading, loaded([SearchBook]), failed(String) }

    let source: BookSource
    @Published private(set) var kinds: [ExploreKind] = []
    /// 书源返回的全部发现项（含没有链接的分组标题），发现页设置里按分组显示。
    @Published private(set) var allKinds: [ExploreKind] = []
    /// 杂志布局：每个分区第一页的书。
    @Published private(set) var sections: [String: SectionState] = [:]
    @Published private(set) var selectedKind: ExploreKind?
    @Published private(set) var books: [SearchBook] = []
    @Published private(set) var diagnostics: [RuleDiagnostic] = []
    @Published private(set) var state: State = .idle
    @Published private(set) var isLoadingMore = false
    /// 书源发现脚本给出的下拉 / 开关控件（如番茄源的「模式」「频道」），显示在发现页顶部。
    @Published private(set) var controls: [ExploreKind] = []
    @Published private(set) var controlValues: [String: String] = [:]
    @Published private(set) var applyingControl: String?

    private let service: BookExploreService
    private var page = 1
    private var canLoadMore = false
    private var stalePages = 0
    private var paginationTask: Task<Void, Never>?

    init(source: BookSource, service: BookExploreService = .init()) {
        self.source = source
        self.service = service
    }

    deinit { paginationTask?.cancel() }

    func load() async {
        guard state == .idle else { return }
        await reload()
    }

    func reload(force: Bool = false) async {
        if force { ExploreCache.shared.clear(source: source) }
        paginationTask?.cancel()
        selectedKind = nil
        kinds = []
        allKinds = []
        sections = [:]
        books = []
        diagnostics = []
        page = 1
        canLoadMore = false
        state = .loading

        let report = await ExploreCache.shared.kinds(for: source, force: force)
        allKinds = report.kinds
        controls = report.kinds.filter(Self.isControl)
        controlValues = Self.storedInfoMap(source)
        kinds = report.kinds.filter { $0.navigableURL != nil }
        diagnostics = report.diagnostics
        guard !kinds.isEmpty else {
            state = diagnostics.contains(where: { $0.severity == .error }) ? .failed : .empty
            return
        }
        if ExploreDisplaySettings.shared.layout == .magazine {
            state = .ready
            // 不等分区出现在屏幕上，先并行请求最前面几个分区。
            for kind in visibleKinds.prefix(3) { startSection(kind) }
            return
        }
        await selectFirstVisible()
    }

    static func isControl(_ kind: ExploreKind) -> Bool {
        let type = kind.type.lowercased()
        guard type == "select" || type == "toggle" else { return false }
        return !(kind.chars ?? []).compactMap { $0 }.filter { !$0.isEmpty }.isEmpty
    }

    static func storedInfoMap(_ source: BookSource) -> [String: String] {
        let raw = BookSourceRuntimeStore.shared.get(sourceID: source.bookSourceUrl, key: "__infoMap")
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object.mapValues { String(describing: $0) }
    }

    func value(of control: ExploreKind) -> String {
        // 正在切换时显示刚选的值；平时以脚本给出的 default 为准（它反映书源当前配置，
        // 登录页里改了模式也能对上），没有 default 才用存下的 infoMap。
        if applyingControl == control.title, let value = controlValues[control.title], !value.isEmpty { return value }
        if let value = control.defaultValue, !value.isEmpty { return value }
        if let value = controlValues[control.title], !value.isEmpty { return value }
        return (control.chars ?? []).compactMap { $0 }.first ?? ""
    }

    /// 选中下拉项：写入 infoMap，执行书源给的 action（通常是保存配置），再重新生成发现分区。
    func choose(_ control: ExploreKind, value: String) async {
        guard applyingControl == nil, value != self.value(of: control) else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        applyingControl = control.title
        defer { applyingControl = nil }
        var info = Self.storedInfoMap(source)
        info[control.title] = value
        controlValues = info
        if let data = try? JSONSerialization.data(withJSONObject: info),
           let text = String(data: data, encoding: .utf8) {
            BookSourceRuntimeStore.shared.put(sourceID: source.bookSourceUrl, key: "__infoMap", value: text)
        }
        if let action = control.action?.trimmingCharacters(in: .whitespacesAndNewlines), !action.isEmpty {
            var script = action
            if script.lowercased().hasPrefix("@js:") { script = String(script.dropFirst(4)) }
            _ = try? await JavaScriptRuleEvaluator(maximumScriptLength: 8 * 1_024 * 1_024)
                .evaluateAsync(script: script, result: .null,
                               executionContext: .init(baseURL: source.bookSourceUrl, source: source))
        }
        await reload(force: true)
    }

    /// 发现页设置里隐藏的分区不显示；选中的分区被隐藏后改选第一个可见分区。
    var visibleKinds: [ExploreKind] {
        let settings = ExploreDisplaySettings.shared
        return kinds.filter { !settings.isHidden($0, in: source) }
    }

    func selectFirstVisible() async {
        if let selectedKind, visibleKinds.contains(where: { $0.id == selectedKind.id }) { return }
        guard let first = visibleKinds.first ?? kinds.first else { return }
        await select(kind: first)
    }

    /// 单个分区的完整列表页（杂志布局点分区标题进入、同题材作品「查看全部」进入）。
    func showOnly(_ kind: ExploreKind) async {
        guard state == .idle else { return }
        kinds = [kind]
        allKinds = [kind]
        await select(kind: kind)
    }

    /// 开始加载分区但不等待结果（预加载用）。
    func startSection(_ kind: ExploreKind) {
        guard sections[kind.id] == nil, kind.navigableURL != nil else { return }
        Task { await loadSection(kind) }
    }

    func loadSection(_ kind: ExploreKind) async {
        guard sections[kind.id] == nil, kind.navigableURL != nil else { return }
        if ProcessInfo.processInfo.arguments.contains("-uiDemo") {
            sections[kind.id] = .loaded(DemoContent.exploreBooks)
            return
        }
        if let cached = ExploreCache.shared.cachedFirstPage(source: source, kind: kind) {
            sections[kind.id] = .loaded(Self.newBooks(cached.books, excluding: []))
            return
        }
        sections[kind.id] = .loading
        let outcome = await ExploreCache.shared.firstPage(source: source, kind: kind)
        let found = Self.newBooks(outcome.books, excluding: [])
        sections[kind.id] = found.isEmpty
            ? .failed(outcome.diagnostics.first?.message ?? "这个分区暂时没有内容")
            : .loaded(found)
    }

    func retrySection(_ kind: ExploreKind) {
        sections[kind.id] = nil
        Task {
            sections[kind.id] = .loading
            let outcome = await ExploreCache.shared.firstPage(source: source, kind: kind, force: true)
            let found = Self.newBooks(outcome.books, excluding: [])
            sections[kind.id] = found.isEmpty
                ? .failed(outcome.diagnostics.first?.message ?? "这个分区暂时没有内容")
                : .loaded(found)
        }
    }

    func select(kind: ExploreKind) async {
        guard kind.navigableURL != nil else { return }
        paginationTask?.cancel()
        selectedKind = kind
        books = []
        diagnostics = []
        page = 1
        canLoadMore = false
        state = .loading

        if ProcessInfo.processInfo.arguments.contains("-uiDemo") {
            books = DemoContent.exploreBooks
            state = .ready
            canLoadMore = true
            return
        }

        let outcome = await ExploreCache.shared.firstPage(source: source, kind: kind)
        guard selectedKind?.id == kind.id else { return }
        diagnostics = outcome.diagnostics
        books = Self.newBooks(outcome.books, excluding: [])
        stalePages = 0
        canLoadMore = !books.isEmpty
        state = books.isEmpty ? (outcome.diagnostics.isEmpty ? .empty : .failed) : .ready
    }

    /// 本页中真正的新书：链接、或书名+作者已出现过的都算重复。
    static func newBooks(_ incoming: [SearchBook], excluding existing: [SearchBook]) -> [SearchBook] {
        var urls = Set(existing.map(\.bookURL))
        var keys = Set(existing.map(identityKey))
        var result: [SearchBook] = []
        for book in incoming {
            guard urls.insert(book.bookURL).inserted else { continue }
            guard keys.insert(identityKey(book)).inserted else { continue }
            result.append(book)
        }
        return result
    }

    private static func identityKey(_ book: SearchBook) -> String {
        let name = book.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let author = book.author.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(name)\u{1F}\(author)"
    }

    func loadNextPageIfNeeded(current book: SearchBook) {
        guard book.id == books.last?.id,
              canLoadMore,
              !isLoadingMore,
              let kind = selectedKind else { return }
        isLoadingMore = true
        let nextPage = page + 1
        paginationTask = Task { [service, source] in
            if ProcessInfo.processInfo.arguments.contains("-uiDemo") {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                canLoadMore = false
                isLoadingMore = false
                return
            }
            let outcome = await service.explore(source: source, kind: kind, page: nextPage)
            guard !Task.isCancelled, selectedKind?.id == kind.id else {
                isLoadingMore = false
                return
            }
            // 有的书源到最后一页后仍返回同一批书（或换了链接参数的同一批书），
            // 只按链接去重会一直翻页、列表不停重复。按链接 + 书名作者去重，
            // 连续两页没有新书就认为到底了。
            let added = Self.newBooks(outcome.books, excluding: books)
            books.append(contentsOf: added)
            diagnostics += outcome.diagnostics
            page = nextPage
            stalePages = added.isEmpty ? stalePages + 1 : 0
            canLoadMore = !outcome.books.isEmpty && stalePages < 2 && nextPage < 500
            isLoadingMore = false
        }
    }
}

struct ExploreView: View {
    @EnvironmentObject private var sourceLibrary: SourceLibraryModel

    private var sources: [BookSource] {
        sourceLibrary.sources
            .filter { $0.enabled && $0.enabledExplore && !($0.exploreUrl?.isEmpty ?? true) }
            .sorted {
                if $0.customOrder != $1.customOrder { return $0.customOrder < $1.customOrder }
                return $0.bookSourceName.localizedStandardCompare($1.bookSourceName) == .orderedAscending
            }
    }

    var body: some View {
        // 标题栏固定、只滚内容（仿 bookon）：上滑内容在标题下沿直接裁掉，下拉时背景不动。
        VStack(alignment: .leading, spacing: 0) {
            ReadingPageHeader(title: "发现", subtitle: "下一本好书，在这里遇见", bottomPadding: 0) {
                NavigationLink { SearchView() } label: {
                    ReadingToolbarIcon(systemName: "magnifyingglass")
                }
                .accessibilityLabel("搜索")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 16) {
                        Image(systemName: "safari")
                            .font(AppFontStyle.system(size: 30, weight: .ultraLight).themed)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("从喜欢的书源开始").font(AppFontStyle.headline.themed)
                            Text("浏览分类与榜单，发现更多故事")
                                .font(AppFontStyle.caption.themed).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background { ThemeCardSurface(radius: 20) }

                    HStack(alignment: .firstTextBaseline) {
                        Text("分类与榜单").font(AppFontStyle.title3.bold().themed)
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        Text("\(sources.count)个书源").font(AppFontStyle.caption.themed).foregroundStyle(.secondary)
                    }
                    if sources.isEmpty {
                        ReadingUnavailableView {
                            Label("暂无发现书源", systemImage: "books.vertical")
                        } description: {
                            Text("添加带有发现分类的书源，即可在这里浏览书籍。")
                        } actions: {
                            NavigationLink("管理书源") { SourceManagementView() }
                                .readingProminentButtonStyle()
                        }
                    } else {
                        // 每个书源一张玻璃卡片（仿 bookon 发现页），跟随外观主题的卡片材质、圆角与边框。
                        LazyVStack(spacing: 10) {
                            ForEach(sources) { source in
                                NavigationLink { ExploreLazyView { ExploreSourceView(source: source) } } label: {
                                    HStack(spacing: 12) {
                                        ExploreSourceRow(source: source)
                                        Spacer(minLength: 0)
                                        Image(systemName: "chevron.right")
                                            .font(AppFontStyle.caption.themed).foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background { ThemeCardSurface(radius: 18) }
                                    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    NavigationLink { SourceManagementView() } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "slider.horizontal.3")
                                .font(AppFontStyle.system(size: 20).themed)
                                .frame(width: 40, height: 44)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("管理书源").font(AppFontStyle.subheadline.weight(.semibold).themed)
                                Text("添加与整理阅读来源").font(AppFontStyle.caption.themed).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right").font(AppFontStyle.subheadline.themed)
                        }
                        .foregroundStyle(ReadingTheme.ink)
                        .padding(18)
                        .background { ThemeCardSurface(radius: 18) }
                        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("explore.manageSources")
                }
                .padding(.horizontal, 24)
                // 标题与内容之间的间距放进滚动区：卡片阴影不会在滚动区上沿被切出横线。
                .padding(.top, 20)
                .padding(.bottom, 32)
            }
            .readingTopScrollEdgeHidden()
        }
        .readingCanvas()
        .navigationBarHidden(true)
    }
}

private struct ExploreSourceRow: View {
    let source: BookSource

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: source.bookSourceType == 1 ? "headphones" : "books.vertical")
                .font(AppFontStyle.system(size: 20).themed)
                .foregroundStyle(ReadingTheme.accent)
                .frame(width: 44, height: 48)
                .background { ThemeSurface(shape: RoundedRectangle(cornerRadius: 12, style: .continuous)) }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(source.bookSourceName)
                    .font(AppFontStyle.body.weight(.medium).themed)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(source.groups.isEmpty ? (URL(string: source.bookSourceUrl)?.host ?? source.bookSourceUrl) : source.groups.joined(separator: " · "))
                    .font(AppFontStyle.caption.themed)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}

/// 发现页显示设置（所有书源共用）：布局、竖排榜单关键词、榜单展示数量、预加载；
/// 以及每个书源各自隐藏的分区。
@MainActor
final class ExploreDisplaySettings: ObservableObject {
    static let shared = ExploreDisplaySettings()

    enum Layout: String, CaseIterable, Identifiable {
        case list, magazine
        var id: String { rawValue }
        var title: String { self == .list ? "列表" : "杂志" }
        var symbol: String { self == .list ? "list.bullet" : "square.grid.2x2" }
    }

    static let defaultKeywords = ["榜", "排行", "畅销", "暢銷", "热销", "熱銷", "热门", "熱門", "完本", "完结", "完結", "top"]
    static let verticalCountOptions = [3, 4, 5, 6, 8, 10]
    /// 0 表示全部。
    static let horizontalCountOptions = [6, 8, 10, 12, 15, 20, 0]
    static let preloadOptions = [0, 1, 2, 3, 5]

    private enum Key {
        static let layout = "explore.layout"
        static let keywords = "explore.verticalKeywords"
        static let verticalCount = "explore.verticalCount"
        static let horizontalCount = "explore.horizontalCount"
        static let preload = "explore.preloadCount"
        static let hidden = "explore.hiddenKinds"
    }

    @Published var layout: Layout { didSet { defaults.set(layout.rawValue, forKey: Key.layout) } }
    @Published var verticalKeywords: [String] { didSet { defaults.set(verticalKeywords, forKey: Key.keywords) } }
    @Published var verticalCount: Int { didSet { defaults.set(verticalCount, forKey: Key.verticalCount) } }
    @Published var horizontalCount: Int { didSet { defaults.set(horizontalCount, forKey: Key.horizontalCount) } }
    @Published var preloadCount: Int { didSet { defaults.set(preloadCount, forKey: Key.preload) } }
    /// 书源地址 → 隐藏的分区标题。
    @Published private var hidden: [String: [String]] { didSet { defaults.set(hidden, forKey: Key.hidden) } }

    private let defaults = UserDefaults.standard

    private init() {
        let stored = UserDefaults.standard
        layout = Layout(rawValue: stored.string(forKey: Key.layout) ?? "") ?? .list
        verticalKeywords = stored.stringArray(forKey: Key.keywords) ?? Self.defaultKeywords
        verticalCount = (stored.object(forKey: Key.verticalCount) as? Int) ?? 4
        horizontalCount = (stored.object(forKey: Key.horizontalCount) as? Int) ?? 0
        preloadCount = (stored.object(forKey: Key.preload) as? Int) ?? 2
        hidden = stored.dictionary(forKey: Key.hidden) as? [String: [String]] ?? [:]
    }

    func isHidden(_ kind: ExploreKind, in source: BookSource) -> Bool {
        hidden[source.bookSourceUrl]?.contains(kind.title) ?? false
    }

    func toggle(_ kind: ExploreKind, in source: BookSource) {
        var list = hidden[source.bookSourceUrl] ?? []
        if let index = list.firstIndex(of: kind.title) {
            list.remove(at: index)
        } else {
            list.append(kind.title)
        }
        hidden[source.bookSourceUrl] = list.isEmpty ? nil : list
    }

    func showAll(in source: BookSource) { hidden[source.bookSourceUrl] = nil }

    func hideAll(_ kinds: [ExploreKind], keeping keep: ExploreKind?, in source: BookSource) {
        // 至少保留一个分区，否则页面会空掉。
        let titles = kinds.map(\.title).filter { $0 != (keep ?? kinds.first)?.title }
        hidden[source.bookSourceUrl] = titles.isEmpty ? nil : titles
    }

    func hiddenCount(in source: BookSource) -> Int { hidden[source.bookSourceUrl]?.count ?? 0 }

    /// 分区标题含任一关键词时按竖排序号榜单显示，其余用横滑封面。
    func isVertical(_ title: String) -> Bool {
        let lowered = title.lowercased()
        return verticalKeywords.contains { !$0.isEmpty && lowered.contains($0.lowercased()) }
    }

    func addKeyword(_ keyword: String) {
        let value = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !verticalKeywords.contains(value) else { return }
        verticalKeywords.append(value)
    }

    func resetKeywords() { verticalKeywords = Self.defaultKeywords }
}

private struct ExploreSourceView: View {
    @StateObject private var model: ExploreSourceViewModel
    @ObservedObject private var settings = ExploreDisplaySettings.shared
    @State private var showsKindSettings = false
    /// 进过登录页：登录页里切换模式 / 线路后，回来时按新配置重新生成发现分区。
    @State private var openedLogin = false
    @State private var loginSnapshot = ""

    init(source: BookSource) {
        _model = StateObject(wrappedValue: ExploreSourceViewModel(source: source))
    }

    var body: some View {
        Group {
            if settings.layout == .magazine, model.state != .idle, !model.kinds.isEmpty {
                ExploreMagazineContent(model: model, settings: settings)
            } else {
                listContent
            }
        }
        .readingCanvas()
        .navigationTitle(model.source.bookSourceName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showsKindSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .disabled(model.allKinds.isEmpty)
                .accessibilityLabel("发现页设置")
                // 登录入口放在书源页右上角；书源没有登录功能就不显示。
                if model.source.loginUrl?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    || model.source.loginUi?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    NavigationLink {
                        ExploreLazyView { SourceLoginView(source: model.source) }
                            .onAppear {
                                openedLogin = true
                                loginSnapshot = sourceConfigSnapshot
                            }
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                    .accessibilityLabel("登录 \(model.source.bookSourceName)")
                }
            }
        }
        .task { await model.load() }
        .onAppear {
            guard openedLogin else { return }
            openedLogin = false
            if sourceConfigSnapshot != loginSnapshot { Task { await model.reload(force: true) } }
        }
        .onChange(of: settings.layout) { layout in
            if layout == .list { Task { await model.selectFirstVisible() } }
        }
        .sheet(isPresented: $showsKindSettings, onDismiss: {
            if settings.layout == .list { Task { await model.selectFirstVisible() } }
        }) {
            ExploreKindSettingsSheet(source: model.source, kinds: model.allKinds,
                                     selected: model.selectedKind) { kind in
                showsKindSettings = false
                if settings.layout == .list { Task { await model.select(kind: kind) } }
            }
        }
    }

    /// 书源配置（源变量 + infoMap）的快照，用来判断登录页里是否改了配置。
    private var sourceConfigSnapshot: String {
        let id = model.source.bookSourceUrl
        return BookSourceRuntimeStore.shared.get(sourceID: id, key: "sourceVariable")
            + "\u{1F}" + BookSourceRuntimeStore.shared.get(sourceID: id, key: "__infoMap")
    }

    private var listContent: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ExploreBookList(model: model)
                        .padding(.horizontal, 16)
                } header: {
                    VStack(alignment: .leading, spacing: 0) {
                        if !model.controls.isEmpty {
                            ExploreControlBar(model: model).padding(.top, 6)
                        }
                        if model.visibleKinds.count > 1 {
                            ExploreKindChips(kinds: model.visibleKinds, selected: model.selectedKind) { kind in
                                Task { await model.select(kind: kind) }
                            }
                            .padding(.vertical, 8)
                        }
                    }
                    .background(ReadingTheme.canvas.opacity(0.96))
                }.readingRowBackground()
            }
            .padding(.bottom, 12)
        }
        .refreshable { await model.reload(force: true) }
    }
}

/// 一个分区的完整书单（可翻页加载）。
private struct ExploreBookList: View {
    @ObservedObject var model: ExploreSourceViewModel

    var body: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView("正在加载小说…")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 80)
        case .empty:
            ReadingUnavailableView(
                "暂无小说",
                systemImage: "books.vertical",
                description: Text("当前书源或分类暂时没有内容，可以下拉刷新。")
            )
            .padding(.vertical, 40)
        case .failed where model.books.isEmpty:
            ReadingUnavailableView(
                "加载失败",
                systemImage: "exclamationmark.triangle",
                description: Text(model.diagnostics.first?.message ?? "书源发现规则解析失败。")
            )
            .padding(.vertical, 40)
        default:
            LazyVStack(spacing: 0) {
                ForEach(model.books) { book in
                    NavigationLink {
                        ExploreLazyView { BookDetailView(searchBook: book, source: model.source) }
                    } label: {
                        ExploreBookRow(book: book)
                    }
                    .buttonStyle(.plain)
                    .onAppear { model.loadNextPageIfNeeded(current: book) }
                }
                if model.isLoadingMore { ProgressView("继续加载…").padding(.vertical, 12) }
            }
        }
    }
}

/// 顶部一排胶囊分类，选中的实心高亮，横向滑动，吸顶。
/// 书源的下拉控件：「模式：短篇模式 ⌄」这样的胶囊，点开选项菜单，选中后整页按新配置刷新。
private struct ExploreControlBar: View {
    @ObservedObject var model: ExploreSourceViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(model.controls.enumerated()), id: \.element.id) { index, control in
                    let current = model.value(of: control)
                    Menu {
                        ForEach((control.chars ?? []).compactMap { $0 }.filter { !$0.isEmpty }, id: \.self) { option in
                            Button {
                                Task { await model.choose(control, value: option) }
                            } label: {
                                if option == current { Label(option, systemImage: "checkmark") } else { Text(option) }
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text("\(control.title)：\(current)")
                                .font(AppFontStyle.footnote.weight(.medium).themed)
                                .lineLimit(1)
                            if model.applyingControl == control.title {
                                ProgressView().controlSize(.small).scaleEffect(0.7)
                            } else {
                                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                            }
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .foregroundStyle(index == 0 ? ReadingTheme.onAccent : ReadingTheme.ink)
                        .background { if index == 0 { Capsule().fill(ReadingTheme.accentFill) } else { ThemeSurface(shape: Capsule()) } }
                        .contentShape(Capsule())
                    }
                    .disabled(model.applyingControl != nil)
                    .accessibilityLabel("\(control.title)，当前\(current)")
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

private struct ExploreKindChips: View {
    let kinds: [ExploreKind]
    let selected: ExploreKind?
    let select: (ExploreKind) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(kinds) { kind in
                        let on = selected?.id == kind.id
                        Button { select(kind) } label: {
                            Text(kind.title)
                                .font(AppFontStyle.subheadline.weight(on ? .semibold : .regular).themed)
                                .lineLimit(1)
                                .padding(.horizontal, 14)
                                .frame(minHeight: 34)
                                .foregroundStyle(on ? ReadingTheme.onAccent : ReadingTheme.ink)
                                .background { if on { Capsule().fill(ReadingTheme.accentFill) } else { ThemeSurface(shape: Capsule()) } }
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .id(kind.id)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 16)
            }
            .onChange(of: selected?.id) { id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

/// 杂志布局：每个分区一栏。标题含榜单关键词的分区用竖排序号榜单，其余横滑封面。
private struct ExploreMagazineContent: View {
    @ObservedObject var model: ExploreSourceViewModel
    @ObservedObject var settings: ExploreDisplaySettings

    /// 杂志布局的一行：榜单分区按出现顺序就近两个一组，组成一个横向翻页栏（两列竖排并排，左右滑动切换）；
    /// 普通分区是横滑封面。排列时有规律地交替：一组榜单 → 一个横滑分区 → 下一组榜单 → 下一个横滑分区……
    /// 榜单不再全部挤在一起。某一类用完后，另一类按原顺序接在后面；落单的一个榜单照常竖排。
    private enum Row: Identifiable {
        case single(ExploreKind, index: Int)
        case ranks([ExploreKind], index: Int)
        var id: String {
            switch self {
            case .single(let kind, _): kind.id
            case .ranks(let kinds, _): "ranks:" + kinds.map(\.id).joined(separator: "|")
            }
        }
    }

    private func rows(_ kinds: [ExploreKind]) -> [Row] {
        let rankIndices = kinds.indices.filter { settings.isVertical(kinds[$0].title) }
        let otherIndices = kinds.indices.filter { !settings.isVertical(kinds[$0].title) }
        var rankRows: [Row] = []
        var position = 0
        while position < rankIndices.count {
            let first = rankIndices[position]
            if position + 1 < rankIndices.count {
                let second = rankIndices[position + 1]
                rankRows.append(.ranks([kinds[first], kinds[second]], index: second))
            } else {
                rankRows.append(.single(kinds[first], index: first))
            }
            position += 2
        }
        let otherRows = otherIndices.map { Row.single(kinds[$0], index: $0) }
        guard !rankRows.isEmpty, !otherRows.isEmpty else { return rankRows + otherRows }
        // 谁在书源里排在前面，就从谁开始交替。
        let ranksFirst = (rankIndices.first ?? .max) < (otherIndices.first ?? .max)
        var result: [Row] = []
        var rankIterator = rankRows.makeIterator()
        var otherIterator = otherRows.makeIterator()
        var nextRank = rankIterator.next()
        var nextOther = otherIterator.next()
        var takeRank = ranksFirst
        while nextRank != nil || nextOther != nil {
            if takeRank, let row = nextRank {
                result.append(row)
                nextRank = rankIterator.next()
            } else if !takeRank, let row = nextOther {
                result.append(row)
                nextOther = otherIterator.next()
            } else if let row = nextRank {
                result.append(row)
                nextRank = rankIterator.next()
            } else if let row = nextOther {
                result.append(row)
                nextOther = otherIterator.next()
            }
            takeRank.toggle()
        }
        return result
    }

    var body: some View {
        let kinds = model.visibleKinds
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                if !model.controls.isEmpty {
                    ExploreControlBar(model: model).padding(.bottom, -10)
                }
                ForEach(rows(kinds)) { row in
                    switch row {
                    case .single(let kind, let index):
                        // 每个分区是独立的 Equatable 子视图：某个分区加载完成时只重画它自己，
                        // 不再整页所有分区一起重算（之前上下滑动卡顿的主要原因）。
                        ExploreMagazineSection(kind: kind, state: model.sections[kind.id],
                                               vertical: settings.isVertical(kind.title),
                                               verticalCount: settings.verticalCount,
                                               horizontalCount: settings.horizontalCount,
                                               source: model.source,
                                               retry: { [weak model = self.model] in model?.retrySection(kind) })
                            .equatable()
                            .task(id: kind.id) { await load(kind, at: index, in: kinds) }
                    case .ranks(let group, let index):
                        ExploreRankPager(kinds: group, states: group.map { model.sections[$0.id] },
                                         verticalCount: settings.verticalCount, source: model.source,
                                         retry: { [weak model = self.model] kind in model?.retrySection(kind) })
                            .equatable()
                            .task(id: row.id) {
                                for kind in group { model.startSection(kind) }
                                preload(after: index, in: kinds)
                            }
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .refreshable { await model.reload(force: true) }
    }

    private func load(_ kind: ExploreKind, at index: Int, in kinds: [ExploreKind]) async {
        preload(after: index, in: kinds)
        await model.loadSection(kind)
    }

    /// 顺便并行加载后面几个分区，滑到时已经有内容。
    private func preload(after index: Int, in kinds: [ExploreKind]) {
        let upper = min(index + settings.preloadCount, kinds.count - 1)
        guard upper > index else { return }
        for next in kinds[(index + 1)...upper] { model.startSection(next) }
    }

}

/// 让 NavigationLink 的目标页在点进去时才创建（iOS 15/16 会提前构建所有行的目标页）。
struct ExploreLazyView<Content: View>: View {
    let build: () -> Content
    init(_ build: @escaping () -> Content) { self.build = build }
    var body: some View { build() }
}

private struct ExploreSectionHeader: View {
    let kind: ExploreKind
    let source: BookSource

    var body: some View {
        NavigationLink {
            ExploreLazyView { ExploreKindBooksView(source: source, kind: kind) }
        } label: {
            HStack(spacing: 4) {
                Text(kind.title).font(AppFontStyle.title3.bold().themed).foregroundStyle(ReadingTheme.ink).lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(AppFontStyle.subheadline.weight(.semibold).themed)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct ExploreSectionRetry: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        Button(action: retry) {
            Label("\(message)，点按重试", systemImage: "arrow.clockwise")
                .font(AppFontStyle.footnote.themed)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 60)
        }
        .buttonStyle(.plain)
    }
}

/// 杂志布局的一个普通分区（横滑封面或竖排榜单）。
private struct ExploreMagazineSection: View, Equatable {
    let kind: ExploreKind
    let state: ExploreSourceViewModel.SectionState?
    let vertical: Bool
    let verticalCount: Int
    let horizontalCount: Int
    let source: BookSource
    let retry: () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.state == rhs.state && lhs.vertical == rhs.vertical
            && lhs.verticalCount == rhs.verticalCount && lhs.horizontalCount == rhs.horizontalCount
            && lhs.source.bookSourceUrl == rhs.source.bookSourceUrl
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ExploreSectionHeader(kind: kind, source: source)
                .padding(.horizontal, 16)
            switch state {
            case .loaded(let books):
                if vertical {
                    ExploreRankedList(books: Array(books.prefix(verticalCount)), source: source)
                        .padding(.horizontal, 16)
                } else {
                    ExploreCoverStrip(books: horizontalCount > 0 ? Array(books.prefix(horizontalCount)) : books,
                                      source: source)
                }
            case .failed(let message):
                ExploreSectionRetry(message: message, retry: retry)
            case .loading, .none:
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            }
        }
    }
}

/// 榜单横向翻页：每列一个榜单，露出下一列的一部分，左右滑动切换。
private struct ExploreRankPager: View, Equatable {
    let kinds: [ExploreKind]
    let states: [ExploreSourceViewModel.SectionState?]
    let verticalCount: Int
    let source: BookSource
    let retry: (ExploreKind) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kinds == rhs.kinds && lhs.states == rhs.states && lhs.verticalCount == rhs.verticalCount
            && lhs.source.bookSourceUrl == rhs.source.bookSourceUrl
    }

    var body: some View {
        let width = max(UIScreen.main.bounds.width - 60, 260)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(Array(kinds.enumerated()), id: \.element.id) { offset, kind in
                    VStack(alignment: .leading, spacing: 12) {
                        ExploreSectionHeader(kind: kind, source: source)
                        switch offset < states.count ? states[offset] : nil {
                        case .loaded(let books):
                            ExploreRankedList(books: Array(books.prefix(verticalCount)), source: source)
                        case .failed(let message):
                            ExploreSectionRetry(message: message) { retry(kind) }
                        case .loading, .none:
                            ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                        }
                    }
                    .frame(width: width, alignment: .topLeading)
                }
            }
            .readingScrollTargetLayout()
            .padding(.horizontal, 16)
        }
        .readingViewAlignedScrolling()
    }
}

private struct ExploreRankedList: View {
    let books: [SearchBook]
    let source: BookSource

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(books.enumerated()), id: \.element.id) { offset, book in
                NavigationLink {
                    ExploreLazyView { BookDetailView(searchBook: book, source: source) }
                } label: {
                    HStack(spacing: 12) {
                        BookCoverArtwork(title: book.name, author: book.author, remoteURL: book.coverURL, width: 46, height: 64)
                        Text("\(offset + 1)")
                            .font(AppFontStyle.system(size: 18, weight: .bold).themed)
                            .foregroundStyle(offset < 3 ? ReadingTheme.accent : Color.secondary)
                            .frame(minWidth: 18)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(book.name)
                                .font(AppFontStyle.subheadline.weight(.medium).themed)
                                .foregroundStyle(ReadingTheme.ink)
                                .lineLimit(1)
                            Text(book.author.isEmpty ? "未知作者" : book.author)
                                .font(AppFontStyle.caption.themed).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if offset < books.count - 1 {
                    Rectangle().fill(ReadingTheme.separator).frame(height: 0.5).padding(.leading, 88)
                }
            }
        }
    }
}

/// 横滑封面（杂志布局的分区、书籍详情里的同题材作品共用）。
struct ExploreCoverStrip: View {
    let books: [SearchBook]
    let source: BookSource

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(books) { book in
                    NavigationLink {
                        ExploreLazyView { BookDetailView(searchBook: book, source: source) }
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            BookCoverArtwork(title: book.name, author: book.author, remoteURL: book.coverURL, width: 94, height: 132)
                            Text(book.name)
                                .font(AppFontStyle.footnote.weight(.medium).themed)
                                .foregroundStyle(ReadingTheme.ink)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .frame(width: 94, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(book.author)
                                .font(AppFontStyle.caption2.themed)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(width: 94, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

/// 单个分区的完整书单页。
struct ExploreKindBooksView: View {
    @StateObject private var model: ExploreSourceViewModel
    private let kind: ExploreKind

    init(source: BookSource, kind: ExploreKind) {
        self.kind = kind
        _model = StateObject(wrappedValue: ExploreSourceViewModel(source: source))
    }

    var body: some View {
        ScrollView {
            ExploreBookList(model: model)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .readingCanvas()
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.showOnly(kind) }
    }
}

/// 发现页设置（半屏）：搜索分区、全部显示/隐藏、按分组点选显示哪些分区；右上角进入显示设置。
private struct ExploreKindSettingsSheet: View {
    let source: BookSource
    let kinds: [ExploreKind]
    let selected: ExploreKind?
    let onOpen: (ExploreKind) -> Void
    @ObservedObject private var settings = ExploreDisplaySettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private struct KindGroup: Identifiable {
        let id: Int
        let title: String
        let kinds: [ExploreKind]
    }

    private var navigable: [ExploreKind] { kinds.filter { $0.navigableURL != nil } }

    /// 没有链接的发现项是分组标题（如「全部榜单」），把它后面的分区归到这一组。
    private var groups: [KindGroup] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [KindGroup] = []
        var title = "全部分区"
        var bucket: [ExploreKind] = []
        func flush() {
            if !bucket.isEmpty { result.append(KindGroup(id: result.count, title: title, kinds: bucket)) }
            bucket = []
        }
        for kind in kinds {
            if kind.navigableURL == nil {
                flush()
                let trimmed = kind.title.trimmingCharacters(in: .whitespacesAndNewlines)
                title = trimmed.isEmpty ? "其他" : trimmed
            } else if keyword.isEmpty || kind.title.localizedCaseInsensitiveContains(keyword) {
                bucket.append(kind)
            }
        }
        flush()
        return result
    }

    var body: some View {
        ReadingNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索发现项目", text: $query)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if !query.isEmpty {
                            Button { query = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("清除")
                        }
                    }
                    .font(AppFontStyle.body.themed)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .background { ThemeSurface(shape: Capsule(), isCard: true) }

                    card {
                        Text("快捷操作").font(AppFontStyle.footnote.themed).foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            quickButton("全部显示", filled: settings.hiddenCount(in: source) == 0) {
                                settings.showAll(in: source)
                            }
                            quickButton("只留当前", filled: false) {
                                settings.hideAll(navigable, keeping: selected, in: source)
                            }
                        }
                    }

                    ForEach(groups) { group in
                        card {
                            Text(group.title).font(AppFontStyle.footnote.themed).foregroundStyle(.secondary)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 8)], alignment: .leading, spacing: 8) {
                                ForEach(group.kinds) { kind in chip(kind) }
                            }
                        }
                    }
                    if groups.isEmpty {
                        Text("没有找到匹配的分区").font(AppFontStyle.footnote.themed).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 24)
                    }
                    Text("点按分区切换显示或隐藏；长按分区直接打开。隐藏的分区不会出现在分类栏和杂志布局里。")
                        .font(AppFontStyle.caption.themed).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }
            .readingCanvas()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("关闭")
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text("发现页设置").font(AppFontStyle.headline.themed)
                        Text("选择想看的分区").font(AppFontStyle.caption2.themed).foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { ExploreDisplaySettingsView() } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("显示设置")
                }
            }
        }
        .readingPresentationDetents([.medium, .large])
        .readingPresentationDragIndicator()
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { ThemeCardSurface(radius: 18) }
    }

    private func quickButton(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(AppFontStyle.subheadline.weight(.medium).themed)
                .padding(.horizontal, 14)
                .frame(minHeight: 34)
                .foregroundStyle(filled ? ReadingTheme.onAccent : ReadingTheme.accent)
                .background(filled ? ReadingTheme.accentFill : ReadingTheme.accentSoft, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func chip(_ kind: ExploreKind) -> some View {
        let hidden = settings.isHidden(kind, in: source)
        return Text(kind.title)
            .strikethrough(hidden, color: .secondary)
            .font(AppFontStyle.subheadline.themed)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .foregroundStyle(hidden ? Color.secondary : ReadingTheme.ink)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(hidden ? Color.clear : ReadingTheme.canvas, in: Capsule())
            .overlay(Capsule().strokeBorder(hidden ? ReadingTheme.separator : Color.clear,
                                            style: StrokeStyle(lineWidth: 0.8, dash: [3, 2])))
            .contentShape(Capsule())
            .onTapGesture {
                UISelectionFeedbackGenerator().selectionChanged()
                settings.toggle(kind, in: source)
            }
            .onLongPressGesture {
                if hidden { settings.toggle(kind, in: source) }
                onOpen(kind)
            }
            .accessibilityElement()
            .accessibilityLabel(kind.title)
            .accessibilityValue(hidden ? "已隐藏" : "显示")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { settings.toggle(kind, in: source) }
    }
}

/// 显示设置：布局（列表/杂志）、竖排榜单关键词、榜单展示数量、预加载。
private struct ExploreDisplaySettingsView: View {
    @ObservedObject private var settings = ExploreDisplaySettings.shared
    @State private var newKeyword = ""

    var body: some View {
        List {
            Section {
                Picker(selection: $settings.layout) {
                    ForEach(ExploreDisplaySettings.Layout.allCases) { layout in
                        Label(layout.title, systemImage: layout.symbol).tag(layout)
                    }
                } label: {
                    Label("布局", systemImage: "rectangle.split.2x1")
                }
                .pickerStyle(.menu)
            } footer: {
                Text("列表是上方一排分类、下方所选分类的书；杂志是每个分类一排书架或一栏榜单。这页的设置适用于每个书源的发现页。")
            }.readingRowBackground()

            if settings.layout == .magazine {
                Section {
                    ForEach(settings.verticalKeywords, id: \.self) { keyword in
                        Label {
                            Text(keyword)
                        } icon: {
                            Image(systemName: "number").foregroundStyle(ReadingTheme.accent)
                        }
                    }
                    .onDelete { settings.verticalKeywords.remove(atOffsets: $0) }
                    HStack {
                        Image(systemName: "plus.circle").foregroundStyle(.secondary)
                        TextField("新增关键词", text: $newKeyword)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .onSubmit {
                                settings.addKeyword(newKeyword)
                                newKeyword = ""
                            }
                    }
                } header: {
                    Text("竖排榜单关键词")
                } footer: {
                    Text("标题含任一关键词的分类用竖排序号，其余用横滑封面。左滑可删除。")
                }.readingRowBackground()

                Section {
                    Button {
                        settings.resetKeywords()
                    } label: {
                        Label("恢复默认关键词", systemImage: "arrow.counterclockwise")
                    }
                }.readingRowBackground()

                Section("榜单展示数量") {
                    Picker(selection: $settings.verticalCount) {
                        ForEach(ExploreDisplaySettings.verticalCountOptions, id: \.self) { Text("\($0)").tag($0) }
                    } label: {
                        Label("竖排展示数", systemImage: "list.number")
                    }
                    .pickerStyle(.menu)
                    Picker(selection: $settings.horizontalCount) {
                        ForEach(ExploreDisplaySettings.horizontalCountOptions, id: \.self) {
                            Text($0 == 0 ? "全部" : "\($0)").tag($0)
                        }
                    } label: {
                        Label("横滑展示数", systemImage: "rectangle.split.3x1")
                    }
                    .pickerStyle(.menu)
                }.readingRowBackground()

                Section {
                    Picker(selection: $settings.preloadCount) {
                        ForEach(ExploreDisplaySettings.preloadOptions, id: \.self) { Text("\($0)").tag($0) }
                    } label: {
                        Label("预加载数量", systemImage: "arrow.down.circle")
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("预加载")
                } footer: {
                    Text("滚到某个分类时，顺便排队加载后面几个分类。数字越大越少看到加载中，但书源请求也越多。")
                }.readingRowBackground()
            }
        }
        .readingThemedListBackground()
        .navigationTitle("显示设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ExploreBookRow: View {
    let book: SearchBook

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            BookCoverArtwork(title: book.name, author: book.author, remoteURL: book.coverURL, width: 52, height: 74)
            VStack(alignment: .leading, spacing: 6) {
                Text(book.name)
                    .font(AppFontStyle.body.weight(.medium).themed)
                    .foregroundStyle(ReadingTheme.ink)
                    .lineLimit(2)
                Text(book.author.isEmpty ? "未知作者" : book.author)
                    .font(AppFontStyle.caption.themed)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let kind = book.kind, !kind.isEmpty {
                    Text(kind)
                        .font(AppFontStyle.caption.themed)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let intro = book.intro, !intro.isEmpty {
                    Text(intro)
                        .font(AppFontStyle.caption.themed)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(AppFontStyle.caption.weight(.semibold).themed)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(ReadingTheme.separator).frame(height: 0.5)
                .padding(.leading, 65)
        }
    }
}
