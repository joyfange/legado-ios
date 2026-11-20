import SwiftUI
import AVFoundation
#if SWIFT_PACKAGE
import LegadoCore
#endif

// MARK: - 长按一本书弹出的操作面板（网格、列表、仿真书架共用）

/// 书架上长按一本书（原地松手）弹出的整本书操作面板：
/// 顶部书籍信息卡（封面、书名、作者、书源、书架、进度）→ 书籍类型（文本 / 音频 / 漫画）→
/// 十二个常用操作（置顶、详情、换源、换封面、搜索封面、编辑、分组、刷新目录、刷新章节、关闭更新、清除缓存、删除）→
/// 缓存 → 源变量 / 书籍变量 / 编辑配置 → 角色配音。
struct BookshelfBookActionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: BookLibraryModel
    @EnvironmentObject private var sources: SourceLibraryModel
    @ObservedObject private var pins = BookshelfPinStore.shared
    @ObservedObject private var cacheCenter = BookshelfCacheCenter.shared
    let bookURL: String
    let fallback: Book
    /// 长按时所在的书架（分组 id）：「分组」把书放进这个书架里的文件夹。
    var groupID: Int64 = BookGroup.idAll

    @State private var cachedCount: Int?
    @State private var running: Set<BookAction> = []
    @State private var notice: String?
    @State private var noticeTask: Task<Void, Never>?
    @State private var route: Route?
    @State private var confirmsDelete = false
    @State private var confirmsCache = false

    enum Route: String, Identifiable {
        case detail, switchSource, changeCover, searchCover, edit, group, sourceVariable, bookVariable, editSource, roleVoice
        var id: String { rawValue }
    }

    enum BookAction: Hashable {
        case refreshToc, refreshChapter, clearCache
    }

    private var book: Book { library.books.first { $0.bookUrl == bookURL } ?? fallback }
    private var source: BookSource? { sources.sources.first { $0.bookSourceUrl == book.origin } }
    private var isLocal: Bool { book.origin == "local" }
    private var isPinned: Bool { pins.isPinned(bookURL) }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                headerCard
                typePicker
                actionGrid
                cacheRow
                if !isLocal { variableCard }
                roleVoiceRow
            }
            .padding(.horizontal, 16)
            .padding(.top, 22)
            .padding(.bottom, 28)
        }
        .readingCanvas()
        .overlay(alignment: .bottom) {
            if let notice {
                Text(notice)
                    .font(AppFontStyle.footnote.weight(.medium).themed)
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.78), in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .allowsHitTesting(false)
            }
        }
        .readingPresentationDetents([.medium, .large])
        .readingPresentationDragIndicator()
        .task { await reloadCachedCount() }
        .onChange(of: cacheCenter.progress[bookURL]?.isCaching ?? false) { caching in
            if !caching { Task { await reloadCachedCount() } }
        }
        .sheet(item: $route) { route in
            routeView(route)
        }
        .confirmationDialog("从书架移除《\(book.name)》？", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                let target = book
                Task {
                    await BookshelfRemoval.remove(target, library: library)
                    dismiss()
                }
            }
            Button("取消", role: .cancel) {}
        }
        .alert("缓存", isPresented: $confirmsCache) {
            Button("取消", role: .cancel) {}
            Button("开始") { startCaching() }
        } message: {
            Text(cacheMessage)
        }
    }

    // MARK: 书籍信息

    private var headerCard: some View {
        HStack(alignment: .center, spacing: 14) {
            BookshelfCover(book: book, width: 64, height: 90)
                .frame(width: 64, height: 90)
            VStack(alignment: .leading, spacing: 4) {
                Text(book.name)
                    .font(AppFontStyle.headline.themed)
                    .foregroundStyle(ReadingTheme.ink)
                    .lineLimit(1)
                Text(book.author.isEmpty ? "未知作者" : book.author)
                    .font(AppFontStyle.subheadline.themed)
                    .foregroundStyle(ReadingTheme.secondaryInk)
                    .lineLimit(1)
                infoLine("building.columns", isLocal ? "本地书籍" : (book.originName.isEmpty ? (source?.bookSourceName ?? "网络书籍") : book.originName))
                infoLine("folder", groupLabel)
                HStack(spacing: 4) {
                    Text("\(progressPercent)%")
                        .font(AppFontStyle.footnote.weight(.semibold).themed)
                        .foregroundStyle(ReadingTheme.accent)
                    Text("· \(BookReadingPresentation.position(book))")
                        .font(AppFontStyle.footnote.themed)
                        .foregroundStyle(ReadingTheme.secondaryInk)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card(18))
        .accessibilityElement(children: .combine)
    }

    private func infoLine(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(AppFontStyle.system(size: 11).themed)
                .frame(width: 14)
            Text(text).lineLimit(1)
        }
        .font(AppFontStyle.footnote.themed)
        .foregroundStyle(ReadingTheme.secondaryInk)
    }

    private var progressPercent: Int {
        Int((BookReadingPresentation.progress(book) * 100).rounded())
    }

    /// 书所在的自定义书架（多个用顿号连接）与文件夹；都没有时显示「默认（无分组）」。
    private var groupLabel: String {
        var names = library.groups
            .filter { $0.groupId > 0 && (book.group & $0.groupId) != 0 }
            .map(\.groupName)
        if let folder = BookshelfFolderStore.shared.folders.first(where: { $0.bookURLs.contains(bookURL) }) {
            names.append("文件夹「\(folder.name)」")
        }
        return names.isEmpty ? "默认（无分组）" : names.joined(separator: "、")
    }

    // MARK: 书籍类型

    private enum Kind: CaseIterable {
        case text, audio, image
        var title: String {
            switch self {
            case .text: "文本"
            case .audio: "音频"
            case .image: "漫画"
            }
        }
        var icon: String {
            switch self {
            case .text: "doc.plaintext"
            case .audio: "headphones"
            case .image: "photo.on.rectangle"
            }
        }
        /// Legado 的书籍类型位：文本 8、音频 32、图片 64。
        var flag: Int {
            switch self {
            case .text: 8
            case .audio: 32
            case .image: 64
            }
        }
    }

    private var currentKind: Kind {
        if book.type & 64 != 0 { return .image }
        if book.type & 32 != 0 { return .audio }
        return .text
    }

    private var typePicker: some View {
        HStack(spacing: 4) {
            ForEach(Kind.allCases, id: \.self) { kind in
                let selected = kind == currentKind
                Button {
                    setKind(kind)
                } label: {
                    Label(kind.title, systemImage: kind.icon)
                        .font(AppFontStyle.subheadline.weight(selected ? .semibold : .regular).themed)
                        .foregroundStyle(selected ? ReadingTheme.accent : ReadingTheme.secondaryInk)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(selected ? ReadingTheme.accent.opacity(0.12) : Color.clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(card(16))
    }

    private func setKind(_ kind: Kind) {
        guard kind != currentKind else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        var updated = book
        updated.type = (updated.type & ~(8 | 32 | 64)) | kind.flag
        Task { await library.addOrUpdate(updated) }
        showNotice("已设为\(kind.title)")
    }

    // MARK: 常用操作

    private struct GridItemSpec: Identifiable {
        let id: String
        let title: String
        let icon: String
        let tint: Color
        var enabled = true
        var busy = false
        let action: () -> Void
    }

    private var gridItems: [GridItemSpec] {
        let network = !isLocal && source != nil
        return [
            GridItemSpec(id: "pin", title: isPinned ? "取消置顶" : "置顶", icon: isPinned ? "pin.slash" : "pin",
                         tint: .orange) { togglePin() },
            GridItemSpec(id: "detail", title: "详情", icon: "info.circle", tint: .blue) { openDetail() },
            GridItemSpec(id: "switch", title: "换源", icon: "arrow.triangle.2.circlepath", tint: .pink,
                         enabled: !isLocal) { route = .switchSource },
            GridItemSpec(id: "cover", title: "换封面", icon: "photo.on.rectangle.angled", tint: .indigo) { route = .changeCover },
            GridItemSpec(id: "searchCover", title: "搜索封面", icon: "magnifyingglass", tint: .purple) { route = .searchCover },
            GridItemSpec(id: "edit", title: "编辑", icon: "pencil", tint: .teal) { route = .edit },
            GridItemSpec(id: "group", title: "分组", icon: "folder", tint: .blue) { route = .group },
            GridItemSpec(id: "toc", title: "刷新目录", icon: "arrow.clockwise", tint: .green,
                         enabled: network, busy: running.contains(.refreshToc)) { refreshToc() },
            GridItemSpec(id: "chapter", title: "刷新章节", icon: "doc.badge.arrow.up", tint: .mint,
                         enabled: network, busy: running.contains(.refreshChapter)) { refreshChapter() },
            GridItemSpec(id: "update", title: book.canUpdate ? "关闭更新" : "开启更新",
                         icon: book.canUpdate ? "bell" : "bell.slash", tint: .orange, enabled: !isLocal) { toggleUpdate() },
            GridItemSpec(id: "clear", title: "清除缓存", icon: "xmark.bin", tint: .pink,
                         busy: running.contains(.clearCache)) { clearCache() },
            GridItemSpec(id: "delete", title: "删除", icon: "trash", tint: .red) { confirmsDelete = true }
        ]
    }

    private var actionGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), spacing: 12) {
            ForEach(gridItems) { item in
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    item.action()
                } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            Circle().fill(item.tint.opacity(0.16))
                            if item.busy {
                                ProgressView().tint(item.tint)
                            } else {
                                Image(systemName: item.icon)
                                    .font(AppFontStyle.system(size: 17, weight: .medium).themed)
                                    .foregroundStyle(item.tint)
                            }
                        }
                        .frame(width: 42, height: 42)
                        Text(item.title)
                            .font(AppFontStyle.system(size: 11).themed)
                            .foregroundStyle(ReadingTheme.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .opacity(item.enabled ? 1 : 0.35)
                }
                .buttonStyle(.plain)
                .disabled(!item.enabled || item.busy)
                .accessibilityLabel(item.title)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .background(card(18))
    }

    // MARK: 缓存

    private var cacheProgress: BookshelfCacheCenter.Progress? { cacheCenter.progress[bookURL] }

    private var cacheRow: some View {
        Button {
            if cacheProgress?.isCaching == true {
                cacheCenter.cancel(bookURL)
            } else {
                confirmsCache = true
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle")
                    .font(AppFontStyle.system(size: 18).themed)
                    .foregroundStyle(ReadingTheme.accent)
                    .frame(width: 24)
                Text("缓存")
                    .font(AppFontStyle.body.weight(.medium).themed)
                    .foregroundStyle(ReadingTheme.ink)
                Spacer()
                if let progress = cacheProgress, progress.isCaching {
                    ProgressView().scaleEffect(0.8)
                    Text(progress.total > 0 ? "缓存中 \(progress.completed)/\(progress.total) · 停止" : "准备中 · 停止")
                        .font(AppFontStyle.footnote.themed)
                        .foregroundStyle(ReadingTheme.secondaryInk)
                } else {
                    Text(cachedLabel)
                        .font(AppFontStyle.footnote.themed)
                        .foregroundStyle(ReadingTheme.secondaryInk)
                }
                Image(systemName: "chevron.right")
                    .font(AppFontStyle.system(size: 12, weight: .semibold).themed)
                    .foregroundStyle(ReadingTheme.tertiaryInk)
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLocal || source == nil)
        .opacity(isLocal || source == nil ? 0.45 : 1)
        .background(card(16))
    }

    private var cachedLabel: String {
        if isLocal { return "本地书籍无需缓存" }
        let count = cachedCount.map(String.init) ?? "…"
        return book.totalChapterNum > 0 ? "已缓存 \(count)/\(book.totalChapterNum)" : "已缓存 \(count)"
    }

    private var cacheMessage: String {
        let start = max(book.durChapterIndex, 0) + 1
        let total = book.totalChapterNum
        guard total > 0 else { return "从第 \(start) 章开始缓存后面的全部章节。" }
        let remaining = max(total - (cachedCount ?? 0), 0)
        return "从第 \(start) 章开始，剩余 \(remaining)/\(total) 章未缓存。"
    }

    private func startCaching() {
        guard let source else { return }
        cacheCenter.start(book: book, source: source, sources: sources.sources)
        showNotice("开始缓存，可以关掉面板，后台会继续")
    }

    private func reloadCachedCount() async {
        guard !isLocal else { return }
        let url = bookURL
        let counts = try? await ChapterContentCache.live().cachedChapterCounts(bookURLs: [url])
        cachedCount = counts?[url] ?? 0
    }

    // MARK: 源变量 / 书籍变量 / 编辑配置

    private var variableCard: some View {
        VStack(spacing: 0) {
            navRow("curlybraces", "源变量", enabled: source != nil) { route = .sourceVariable }
            divider
            navRow("square.text.square", "书籍变量") { route = .bookVariable }
            divider
            navRow("doc.badge.gearshape", "编辑配置", enabled: source != nil) { route = .editSource }
        }
        .background(card(16))
    }

    private var roleVoiceRow: some View {
        navRow("person.2.wave.2", "角色配音") { route = .roleVoice }
            .background(card(16))
    }

    private var divider: some View {
        Rectangle()
            .fill(ReadingTheme.separator.opacity(0.6))
            .frame(height: 0.5)
            .padding(.leading, 50)
    }

    private func navRow(_ icon: String, _ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(AppFontStyle.system(size: 16).themed)
                    .foregroundStyle(ReadingTheme.accent)
                    .frame(width: 24)
                Text(title)
                    .font(AppFontStyle.body.themed)
                    .foregroundStyle(ReadingTheme.ink)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(AppFontStyle.system(size: 12, weight: .semibold).themed)
                    .foregroundStyle(ReadingTheme.tertiaryInk)
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    /// 面板里的卡片：与外观主题卡片同一种底（系统玻璃 / 透明 / 毛玻璃跟随主题）。
    private func card(_ radius: CGFloat) -> some View {
        ThemeSurface(shape: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    // MARK: 子面板

    @ViewBuilder
    private func routeView(_ route: Route) -> some View {
        switch route {
        case .detail:
            BookshelfQuickDetailSheet(bookURL: bookURL, fallback: book, open: { destination in
                closeAll(then: destination)
            }, switchSource: { newBook in
                applySourceSwitch(newBook)
            })
            .environmentObject(library)
            .environmentObject(sources)
        case .switchSource:
            ReadingNavigationStack {
                SourceSwitchView(book: book, sources: sources.sources) { report, _ in
                    applySourceSwitch(report.book)
                }
            }
        case .changeCover:
            BookCoverSwitchSheet(book: book) { cover in applyCover(cover) }
                .environmentObject(sources)
        case .searchCover:
            BookWebCoverSearchSheet(book: book) { cover in applyCover(cover) }
        case .edit:
            BookInfoEditView(book: book).environmentObject(library).environmentObject(sources)
        case .group:
            // 「分组」＝书架上的文件夹（与拖书合并、多选「加入分组」同一份数据）；移到别的书架在面板底部。
            BookshelfBookFolderSheet(book: book, groupID: groupID) { text in
                showNotice(text)
            }
            .environmentObject(library)
            .readingPresentationDetents([.medium, .large])
        case .sourceVariable:
            if let source {
                BookVariableEditorSheet(
                    title: "源变量",
                    caption: "源变量 (sourceVariable)",
                    hint: "可在 JS 中通过 source.getVariable() 获取",
                    clearTitle: "清除源变量",
                    initial: BookSourceRuntimeStore.shared.get(sourceID: source.bookSourceUrl, key: "sourceVariable")
                ) { value in
                    BookSourceRuntimeStore.shared.put(sourceID: source.bookSourceUrl, key: "sourceVariable", value: value)
                    showNotice(value.isEmpty ? "已清除源变量" : "源变量已保存")
                }
            }
        case .bookVariable:
            BookVariableEditorSheet(
                title: "书籍变量",
                caption: "书籍变量 (bookVariable)",
                hint: "可在 JS 中通过 book.getVariable(\"custom\") 获取",
                clearTitle: "清除书籍变量",
                initial: BookVariableCoding.customValue(book.variable)
            ) { value in
                var updated = book
                updated.variable = BookVariableCoding.setting(value, in: updated.variable)
                Task { await library.addOrUpdate(updated) }
                showNotice(value.isEmpty ? "已清除书籍变量" : "书籍变量已保存")
            }
        case .editSource:
            if let source {
                SourceEditorView(source: source).environmentObject(sources)
            }
        case .roleVoice:
            BookRoleVoiceSheet(book: book)
        }
    }

    // MARK: 操作

    private func showNotice(_ text: String) {
        noticeTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { notice = text }
        noticeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) { notice = nil }
        }
    }

    private func togglePin() {
        let wasPinned = isPinned
        withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) { pins.toggle(bookURL) }
        showNotice(wasPinned ? "已取消置顶" : "已置顶")
    }

    /// 「详情」：在操作面板上面再叠一层「作品详情」卡片面板（操作面板留在后面），关掉回到操作面板。
    private func openDetail() {
        route = .detail
    }

    /// 从详情里开始阅读 / 打开完整详情页：整叠面板一起收起，再打开。
    private func closeAll(then destination: BookshelfShelfDestination) {
        BookshelfSheetRouter.shared.sheet = nil
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            BookshelfFolderStore.shared.openRequest = destination
        }
    }

    private func toggleUpdate() {
        var updated = book
        updated.canUpdate.toggle()
        let enabled = updated.canUpdate
        Task { await library.addOrUpdate(updated) }
        showNotice(enabled ? "已开启更新" : "已关闭更新，检查更新时跳过这本书")
    }

    private func applyCover(_ cover: String) {
        var updated = book
        updated.customCoverUrl = cover
        Task { await library.addOrUpdate(updated) }
        showNotice("封面已更换")
    }

    /// 换源后书籍链接可能变化：文件夹、置顶跟着换到新链接，阅读进度保留。
    private func applySourceSwitch(_ newBook: Book) {
        let oldURL = bookURL
        var updated = newBook
        let stored = book
        updated.group = stored.group
        updated.customCoverUrl = stored.customCoverUrl
        updated.customIntro = stored.customIntro
        updated.customTag = stored.customTag
        updated.canUpdate = stored.canUpdate
        updated.readConfig = stored.readConfig
        if updated.bookUrl != oldURL {
            let folders = BookshelfFolderStore.shared
            if let folder = folders.folders.first(where: { $0.bookURLs.contains(oldURL) }) {
                folders.add(updated.bookUrl, to: folder.id)
                folders.remove([oldURL], from: folder.id)
            }
            if pins.isPinned(oldURL) {
                pins.toggle(oldURL)
                pins.toggle(updated.bookUrl)
            }
        }
        let replacement = updated
        Task {
            await library.replace(oldBookURL: oldURL, with: replacement)
            if replacement.bookUrl != oldURL { dismiss() }
        }
        showNotice("已换到「\(replacement.originName)」")
    }

    private func refreshToc() {
        guard let source, !running.contains(.refreshToc) else { return }
        running.insert(.refreshToc)
        let stored = book
        let all = sources.sources
        Task {
            let model = BookDetailViewModel(book: stored, source: source)
            await model.refresh(sources: all)
            running.remove(.refreshToc)
            guard model.state == .ready else {
                showNotice("目录刷新失败，稍后再试")
                return
            }
            let latest = library.books.first { $0.bookUrl == stored.bookUrl } ?? stored
            model.restoreUserSettings(from: latest)
            model.restoreReadingProgress(from: latest)
            var updated = model.book
            updated.type = latest.type
            updated.variable = latest.variable
            if updated.bookUrl == latest.bookUrl {
                await library.addOrUpdate(updated)
            }
            let count = model.chapters.filter { !$0.isVolume }.count
            showNotice("目录已刷新，共 \(count) 章")
            await reloadCachedCount()
        }
    }

    private func refreshChapter() {
        guard let source, !running.contains(.refreshChapter) else { return }
        running.insert(.refreshChapter)
        let stored = book
        Task {
            defer { running.remove(.refreshChapter) }
            let chapters = (try? await AppBookChapterRepository.live().load(bookURL: stored.bookUrl)) ?? []
            guard !chapters.isEmpty else {
                showNotice("还没有目录，先刷新目录")
                return
            }
            var index = min(max(stored.durChapterIndex, 0), chapters.count - 1)
            if let title = stored.durChapterTitle, let match = chapters.firstIndex(where: { !$0.isVolume && $0.title == title }) {
                index = match
            }
            while index < chapters.count - 1, chapters[index].isVolume { index += 1 }
            let chapter = chapters[index]
            let next = chapters[(index + 1)...].first { !$0.isVolume }?.url
            try? await ChapterContentCache.live().remove(bookURL: stored.bookUrl, chapterURL: chapter.url)
            let ok = await ChapterContentCoordinator().prefetch(book: stored, chapter: chapter, source: source, nextChapterURL: next)
            showNotice(ok ? "已重新获取「\(chapter.title)」" : "章节获取失败，稍后再试")
            await reloadCachedCount()
        }
    }

    private func clearCache() {
        guard !running.contains(.clearCache) else { return }
        running.insert(.clearCache)
        cacheCenter.cancel(bookURL)
        let url = bookURL
        Task {
            try? await ChapterContentCache.live().remove(bookURL: url)
            await library.refreshDownloaded()
            running.remove(.clearCache)
            await reloadCachedCount()
            showNotice("已清除这本书的章节缓存")
        }
    }
}

// MARK: - 后台缓存

/// 面板里点「缓存」开始的离线缓存：放在共享对象里，关掉面板也会继续，再打开面板能看到进度。
@MainActor
final class BookshelfCacheCenter: ObservableObject {
    static let shared = BookshelfCacheCenter()

    struct Progress: Equatable {
        var isCaching: Bool
        var completed: Int
        var total: Int
    }

    @Published private(set) var progress: [String: Progress] = [:]
    private var models: [String: BookDetailViewModel] = [:]
    private var watchers: [String: Task<Void, Never>] = [:]

    func start(book: Book, source: BookSource, sources: [BookSource]) {
        let url = book.bookUrl
        cancel(url)
        let model = BookDetailViewModel(book: book, source: source)
        models[url] = model
        progress[url] = Progress(isCaching: true, completed: 0, total: 0)
        watchers[url] = Task { [weak self] in
            await model.load(sources: sources)
            guard !Task.isCancelled else { return }
            model.cacheRemaining()
            // 缓存任务在模型里跑；这里每半秒把进度同步出来，直到结束。
            while !Task.isCancelled {
                self?.progress[url] = Progress(isCaching: model.isCaching, completed: model.cacheCompleted, total: model.cacheTotal)
                if !model.isCaching { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            self?.progress[url]?.isCaching = false
            self?.models[url] = nil
            self?.watchers[url] = nil
        }
    }

    func cancel(_ url: String) {
        watchers[url]?.cancel()
        watchers[url] = nil
        models[url]?.cancelCaching()
        models[url] = nil
        if progress[url]?.isCaching == true { progress[url]?.isCaching = false }
    }
}

// MARK: - 书籍变量

enum BookVariableCoding {
    /// 书籍变量里 "custom" 键的值（JS 里 book.getVariable("custom")）。
    static func customValue(_ variable: String?) -> String {
        guard let object = parse(variable), let value = object["custom"] else { return "" }
        if let text = value as? String { return text }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
           let text = String(data: data, encoding: .utf8) { return text }
        return String(describing: value)
    }

    static func setting(_ value: String, in variable: String?) -> String? {
        var object = parse(variable) ?? [:]
        if value.isEmpty { object.removeValue(forKey: "custom") } else { object["custom"] = value }
        guard !object.isEmpty, let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func parse(_ variable: String?) -> [String: Any]? {
        guard let data = variable?.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// 源变量、书籍变量共用的编辑面板：取消 / 保存，底部「清除」。
struct BookVariableEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let caption: String
    let hint: String
    let clearTitle: String
    let onSave: (String) -> Void
    @State private var text: String
    @FocusState private var focused: Bool

    init(title: String, caption: String, hint: String, clearTitle: String, initial: String, onSave: @escaping (String) -> Void) {
        self.title = title
        self.caption = caption
        self.hint = hint
        self.clearTitle = clearTitle
        self.onSave = onSave
        _text = State(initialValue: initial)
    }

    var body: some View {
        ReadingNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(caption)
                        .font(AppFontStyle.subheadline.weight(.semibold).themed)
                        .foregroundStyle(ReadingTheme.ink)
                    ZStack(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(hint)
                                .font(AppFontStyle.system(size: 14, design: .monospaced).themed)
                                .foregroundStyle(ReadingTheme.tertiaryInk)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $text)
                            .font(AppFontStyle.system(size: 14, design: .monospaced).themed)
                            .frame(minHeight: 180)
                            .readingScrollContentBackgroundHidden()
                            .focused($focused)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .padding(8)
                    .background(ThemeSurface(shape: RoundedRectangle(cornerRadius: 14, style: .continuous)))
                    Button(role: .destructive) {
                        onSave("")
                        dismiss()
                    } label: {
                        Label(clearTitle, systemImage: "trash")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .frame(height: 46)
                            .background(ThemeSurface(shape: RoundedRectangle(cornerRadius: 14, style: .continuous)))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.red)
                }
                .padding(16)
            }
            .readingCanvas()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(text.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - 换封面（在书源里找同一本书的封面）

struct BookCoverSwitchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var sourceLibrary: SourceLibraryModel
    let book: Book
    let onPick: (String) -> Void
    @State private var candidates: [Candidate] = []
    @State private var searching = false
    @State private var task: Task<Void, Never>?

    struct Candidate: Identifiable, Hashable {
        let url: String
        let sourceName: String
        var id: String { url }
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        ReadingNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 6) {
                        if searching { ProgressView().scaleEffect(0.8) }
                        Text(searching ? "已找到 \(candidates.count) 个封面，搜索中…" : "共找到 \(candidates.count) 个封面")
                            .font(AppFontStyle.footnote.themed)
                            .foregroundStyle(ReadingTheme.secondaryInk)
                    }
                    LazyVGrid(columns: columns, spacing: 14) {
                        coverTile(url: book.displayCoverUrl, label: "当前封面", selected: true) {}
                        ForEach(candidates) { candidate in
                            coverTile(url: candidate.url, label: candidate.sourceName, selected: false) {
                                onPick(candidate.url)
                                dismiss()
                            }
                        }
                    }
                    if !searching && candidates.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "photo")
                                .font(AppFontStyle.system(size: 30).themed)
                                .foregroundStyle(ReadingTheme.tertiaryInk)
                            Text("暂无封面").font(AppFontStyle.headline.themed)
                            Text("未找到可用封面，可点击左上角刷新重试")
                                .font(AppFontStyle.footnote.themed)
                                .foregroundStyle(ReadingTheme.secondaryInk)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    }
                }
                .padding(16)
            }
            .readingCanvas()
            .navigationTitle("换封面")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { search() } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(searching)
                        .accessibilityLabel("刷新")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("关闭")
                }
            }
        }
        .onAppear { if candidates.isEmpty && !searching { search() } }
        .onDisappear { task?.cancel() }
    }

    private func coverTile(url: String?, label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                BookCoverArtwork(title: book.name, author: book.author, remoteURL: url, width: 96, height: 134, cornerRadius: 6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(ReadingTheme.accent, lineWidth: selected ? 2 : 0)
                    )
                Text(label)
                    .font(AppFontStyle.system(size: 11).themed)
                    .foregroundStyle(ReadingTheme.secondaryInk)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    /// 按书名在启用的书源里搜，同名（作者对得上或没有作者）且带封面的结果收进来，去重。
    private func search() {
        let keyword = book.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        task?.cancel()
        candidates = []
        searching = true
        let enabled = sourceLibrary.sources.filter(\.enabled)
        let byID = Dictionary(enabled.map { ($0.bookSourceUrl, $0) }, uniquingKeysWith: { first, _ in first })
        let wantedAuthor = book.author.trimmingCharacters(in: .whitespacesAndNewlines)
        let own = book.displayCoverUrl
        task = Task {
            var seen = Set<String>()
            if let own, !own.isEmpty { seen.insert(own) }
            for await outcome in BookSearchService().searchOutcomes(keyword: keyword, page: 1, sources: enabled) {
                if Task.isCancelled { break }
                for result in outcome.books {
                    guard result.name.trimmingCharacters(in: .whitespacesAndNewlines) == keyword,
                          wantedAuthor.isEmpty || result.author.isEmpty || result.author.contains(wantedAuthor) || wantedAuthor.contains(result.author),
                          let cover = result.coverURL?.trimmingCharacters(in: .whitespacesAndNewlines), !cover.isEmpty,
                          seen.insert(cover).inserted else { continue }
                    if let source = byID[outcome.sourceID] {
                        CoverRequestRegistry.shared.register(cover: cover, source: source)
                    }
                    candidates.append(Candidate(url: cover, sourceName: byID[outcome.sourceID]?.bookSourceName ?? result.originName))
                }
                if candidates.count >= 30 { break }
            }
            searching = false
        }
    }
}

// MARK: - 搜索封面（网络图片）

struct BookWebCoverSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    let book: Book
    let onPick: (String) -> Void
    @State private var keyword: String
    @State private var results: [WebCoverImage] = []
    @State private var searching = false
    @State private var failed = false
    @State private var task: Task<Void, Never>?

    init(book: Book, onPick: @escaping (String) -> Void) {
        self.book = book
        self.onPick = onPick
        _keyword = State(initialValue: "\(book.name) 小说封面")
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        ReadingNavigationStack {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    TextField("书名 小说封面", text: $keyword)
                        .textFieldStyle(.plain)
                        .submitLabel(.search)
                        .onSubmit { search() }
                        .padding(.horizontal, 12)
                        .frame(height: 38)
                        .background(ThemeSurface(shape: RoundedRectangle(cornerRadius: 12, style: .continuous)))
                    Button("搜索") { search() }
                        .disabled(keyword.trimmingCharacters(in: .whitespaces).isEmpty || searching)
                }
                .padding(.horizontal, 16)
                ScrollView {
                    if searching && results.isEmpty {
                        ProgressView().padding(.top, 60)
                    } else if results.isEmpty {
                        Text(failed ? "搜索失败，检查网络后再试" : "没有找到图片，换个关键词试试")
                            .font(AppFontStyle.footnote.themed)
                            .foregroundStyle(ReadingTheme.secondaryInk)
                            .padding(.top, 60)
                    } else {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(results) { image in
                                Button {
                                    onPick(image.full)
                                    dismiss()
                                } label: {
                                    AsyncImage(url: URL(string: image.thumbnail)) { phase in
                                        switch phase {
                                        case .success(let picture):
                                            picture.resizable().scaledToFill()
                                        case .failure:
                                            Image(systemName: "photo").foregroundStyle(ReadingTheme.tertiaryInk)
                                        default:
                                            ProgressView()
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 150)
                                    .background(ReadingTheme.separator.opacity(0.3))
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
            .padding(.top, 8)
            .readingCanvas()
            .navigationTitle("搜索封面")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
        }
        .onAppear { if results.isEmpty && !searching { search() } }
        .onDisappear { task?.cancel() }
    }

    private func search() {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        task?.cancel()
        searching = true
        failed = false
        results = []
        task = Task {
            let found = await WebCoverSearch.images(for: query)
            guard !Task.isCancelled else { return }
            results = found ?? []
            failed = found == nil
            searching = false
        }
    }
}

struct WebCoverImage: Identifiable, Hashable, Sendable {
    let full: String
    let thumbnail: String
    var id: String { full }
}

/// 网络图片搜索（必应图片）：解析结果页里每张图的原图地址（murl）和缩略图地址（turl）。
enum WebCoverSearch {
    static func images(for query: String) async -> [WebCoverImage]? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        let hosts = ["https://cn.bing.com", "https://www.bing.com"]
        for host in hosts {
            guard let url = URL(string: "\(host)/images/async?q=\(encoded)&first=0&count=48&mmasync=1") else { continue }
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
                             forHTTPHeaderField: "User-Agent")
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let html = String(data: data, encoding: .utf8) else { continue }
            let found = parse(html)
            if !found.isEmpty { return found }
        }
        return nil
    }

    static func parse(_ html: String) -> [WebCoverImage] {
        let text = html.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
        guard let regex = try? NSRegularExpression(pattern: #""murl":"(https?://[^"]+)".*?"turl":"(https?://[^"]+)""#) else { return [] }
        var seen = Set<String>()
        var result: [WebCoverImage] = []
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let fullRange = Range(match.range(at: 1), in: text),
                  let thumbRange = Range(match.range(at: 2), in: text) else { continue }
            let full = String(text[fullRange])
            guard seen.insert(full).inserted else { continue }
            result.append(.init(full: full, thumbnail: String(text[thumbRange])))
        }
        return result
    }
}

// MARK: - 角色配音（每本书）

/// 每本书的配音：旁白声音、未识别出性别的角色用谁的声音（按书名保存，朗读时读取）。
struct AIRoleBookVoice: Codable, Equatable, Sendable {
    /// 旁白的系统声音；空 = 跟随朗读设置。
    var narratorVoiceID = ""
    /// 未知角色："narrator" 跟随旁白，"male" / "female" 用男 / 女角色的声音。
    var unknownMode = "narrator"

    private static func key(_ bookName: String) -> String { "speech.aiRole.book." + bookName }

    static func load(bookName: String) -> AIRoleBookVoice {
        guard !bookName.isEmpty, let data = UserDefaults.standard.data(forKey: key(bookName)),
              let value = try? JSONDecoder().decode(AIRoleBookVoice.self, from: data) else { return AIRoleBookVoice() }
        return value
    }

    func save(bookName: String) {
        guard !bookName.isEmpty else { return }
        if self == AIRoleBookVoice() {
            UserDefaults.standard.removeObject(forKey: Self.key(bookName))
        } else if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key(bookName))
        }
    }
}

struct BookRoleVoiceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = AIRoleSpeechStore.shared
    let book: Book
    @State private var voice: AIRoleBookVoice
    @State private var cleared = false

    init(book: Book) {
        self.book = book
        _voice = State(initialValue: AIRoleBookVoice.load(bookName: book.name))
    }

    private var voices: [AVSpeechSynthesisVoice] { SpeechVoiceCatalog.chineseVoices }

    private var narratorLabel: String {
        guard let current = AVSpeechSynthesisVoice(identifier: voice.narratorVoiceID) else { return "跟随朗读设置" }
        return current.name
    }

    private var unknownLabel: String {
        switch voice.unknownMode {
        case "male": "男声角色"
        case "female": "女声角色"
        default: "跟随旁白"
        }
    }

    var body: some View {
        ReadingNavigationStack {
            List {
                Section {
                    Menu {
                        Button { voice.narratorVoiceID = "" } label: {
                            menuLabel("跟随朗读设置", selected: voice.narratorVoiceID.isEmpty)
                        }
                        ForEach(voices, id: \.identifier) { item in
                            Button { voice.narratorVoiceID = item.identifier } label: {
                                menuLabel(SpeechVoiceCatalog.label(item), selected: voice.narratorVoiceID == item.identifier)
                            }
                        }
                    } label: {
                        row(icon: "book", title: "旁白", value: narratorLabel)
                    }
                    Menu {
                        ForEach([("narrator", "跟随旁白"), ("male", "男声角色"), ("female", "女声角色")], id: \.0) { mode, title in
                            Button { voice.unknownMode = mode } label: {
                                menuLabel(title, selected: voice.unknownMode == mode)
                            }
                        }
                    } label: {
                        row(icon: "questionmark.circle", title: "未知角色", value: unknownLabel)
                    }
                } header: {
                    Text("角色与语音")
                } footer: {
                    Text("未单独绑定的角色会跟随旁白；未知角色用于无法可靠识别说话人的对话。男声 / 女声角色的声音在「朗读 → AI 多角色朗读」里设置。")
                }
                .readingRowBackground()

                Section {
                    NavigationLink {
                        AIRoleSpeechView()
                    } label: {
                        HStack {
                            Label("AI 多角色朗读", systemImage: "person.2.wave.2")
                            Spacer()
                            Text(store.settings.isActive ? "已开启" : "未开启")
                                .foregroundStyle(ReadingTheme.secondaryInk)
                        }
                    }
                    Button(role: .destructive) {
                        store.clearCache()
                        cleared = true
                    } label: {
                        Label(cleared ? "已清除角色分析缓存" : "清除角色分析缓存", systemImage: "trash")
                    }
                    .disabled(cleared)
                }
                .readingRowBackground()
            }
            .readingThemedListBackground()
            .navigationTitle("角色配音")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        voice.save(bookName: book.name)
                        dismiss()
                    }
                }
            }
        }
        .readingPresentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func menuLabel(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private func row(icon: String, title: String, value: String) -> some View {
        HStack {
            Label(title, systemImage: icon).foregroundStyle(ReadingTheme.ink)
            Spacer()
            Text(value).foregroundStyle(ReadingTheme.secondaryInk).lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(AppFontStyle.system(size: 11).themed)
                .foregroundStyle(ReadingTheme.tertiaryInk)
        }
    }
}

// MARK: - 作品详情（叠在长按操作面板上的卡片面板）

/// 长按面板里点「详情」弹出的作品详情：叠在操作面板上面（操作面板留在后面），左上角关掉回到操作面板。
/// 书籍信息卡 → 开始阅读 / 已在书架 → 分组、类型、更新 → 简介（可展开）→ 目录（前几章，点章节从该章开始读）→ 来源（换源）。
struct BookshelfQuickDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: BookLibraryModel
    @EnvironmentObject private var sources: SourceLibraryModel
    let bookURL: String
    let fallback: Book
    /// 开始阅读、从某章阅读、完整详情页：由操作面板收起整叠面板后打开。
    let open: (BookshelfShelfDestination) -> Void
    /// 换源：交给操作面板的换源流程（文件夹、置顶跟着换到新链接，阅读进度保留）。
    let switchSource: (Book) -> Void

    @State private var chapters: [BookChapter] = []
    @State private var loadingChapters = true
    @State private var introExpanded = false
    @State private var showsGroup = false
    @State private var showsSwitchSource = false
    @State private var notice: String?
    @State private var noticeTask: Task<Void, Never>?

    private var book: Book { library.books.first { $0.bookUrl == bookURL } ?? fallback }
    private var source: BookSource? { sources.sources.first { $0.bookSourceUrl == book.origin } }
    private var isLocal: Bool { book.origin == "local" }
    private var inLibrary: Bool { library.books.contains { $0.bookUrl == bookURL } }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(spacing: 12) {
                    headerCard
                    actionButtons
                    infoCard
                    introCard
                    tocCard
                    sourceCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 28)
            }
        }
        .readingCanvas()
        .overlay(alignment: .bottom) {
            if let notice {
                Text(notice)
                    .font(AppFontStyle.footnote.weight(.medium).themed)
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.78), in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .allowsHitTesting(false)
            }
        }
        .readingPresentationDetents([.medium, .large])
        .readingPresentationDragIndicator()
        .task { await loadChapters() }
        .sheet(isPresented: $showsGroup) {
            BookShelfPickerSheet(book: book, inLibrary: false, title: "移至书架") { groupIDs, reading in
                Task {
                    guard let stored = library.books.first(where: { $0.bookUrl == bookURL }) else { return }
                    await library.setBook(stored, groupIDs: groupIDs)
                    if let latest = library.books.first(where: { $0.bookUrl == bookURL }) {
                        await library.setReadingStatus(latest, reading: reading)
                    }
                }
            } onRemove: {}
            .environmentObject(library)
            .readingPresentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showsSwitchSource) {
            ReadingNavigationStack {
                SourceSwitchView(book: book, sources: sources.sources) { report, _ in
                    showsSwitchSource = false
                    switchSource(report.book)
                }
            }
        }
    }

    // MARK: 顶栏

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(AppFontStyle.system(size: 16, weight: .semibold).themed)
                    .foregroundStyle(ReadingTheme.ink)
                    .frame(width: 40, height: 40)
                    .background { ThemeSurface(shape: Circle()) }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
            Spacer()
            Text("作品详情")
                .font(AppFontStyle.headline.themed)
                .foregroundStyle(ReadingTheme.ink)
            Spacer()
            Menu {
                Button { open(.info(book)) } label: { Label("完整详情页", systemImage: "doc.text.magnifyingglass") }
                Button {
                    UIPasteboard.general.string = book.name
                    showNotice("已复制书名")
                } label: { Label("复制书名", systemImage: "doc.on.doc") }
                if !isLocal {
                    Button {
                        UIPasteboard.general.string = book.bookUrl
                        showNotice("已复制书籍链接")
                    } label: { Label("复制书籍链接", systemImage: "link") }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(AppFontStyle.system(size: 16, weight: .semibold).themed)
                    .foregroundStyle(ReadingTheme.ink)
                    .frame(width: 40, height: 40)
                    .background { ThemeSurface(shape: Circle()) }
                    .contentShape(Circle())
            }
            .accessibilityLabel("更多")
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }

    // MARK: 书籍信息

    private var headerCard: some View {
        HStack(alignment: .center, spacing: 14) {
            BookshelfCover(book: book, width: 70, height: 98)
                .frame(width: 70, height: 98)
            VStack(alignment: .leading, spacing: 6) {
                Text(book.name)
                    .font(AppFontStyle.title3.weight(.semibold).themed)
                    .foregroundStyle(ReadingTheme.ink)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    Image(systemName: "person.fill").font(AppFontStyle.system(size: 11).themed)
                    Text(book.author.isEmpty ? "未知作者" : book.author).lineLimit(1)
                }
                .font(AppFontStyle.footnote.themed)
                .foregroundStyle(ReadingTheme.secondaryInk)
                HStack(spacing: 6) {
                    if let words = book.wordCount?.trimmingCharacters(in: .whitespacesAndNewlines), !words.isEmpty {
                        tag(words, color: .green)
                    }
                    if let kinds = kindText {
                        tag(kinds, color: ReadingTheme.coral)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card(18))
        .accessibilityElement(children: .combine)
    }

    private var kindText: String? {
        let words = (book.kind ?? "")
            .split(whereSeparator: { ",，、|/ \n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        return words.prefix(3).joined(separator: "·")
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(AppFontStyle.system(size: 11, weight: .medium).themed)
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }

    // MARK: 开始阅读

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                open(.read(book))
            } label: {
                Label(BookReadingPresentation.hasStarted(book) ? "继续阅读" : "开始阅读", systemImage: "book.fill")
                    .font(AppFontStyle.subheadline.weight(.semibold).themed)
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(ReadingTheme.accent, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            Label(inLibrary ? "已在书架" : "未在书架", systemImage: inLibrary ? "checkmark" : "plus")
                .font(AppFontStyle.subheadline.themed)
                .foregroundStyle(ReadingTheme.secondaryInk)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
        }
    }

    // MARK: 分组 / 类型 / 更新

    private var infoCard: some View {
        HStack(spacing: 0) {
            infoCell(icon: "folder.fill", tint: .blue, caption: "分组", value: groupLabel) { showsGroup = true }
            Menu {
                ForEach(BookKindChoice.allCases, id: \.self) { kind in
                    Button {
                        setKind(kind)
                    } label: {
                        if kind == currentKind {
                            Label(kind.title, systemImage: "checkmark")
                        } else {
                            Text(kind.title)
                        }
                    }
                }
            } label: {
                infoLabel(icon: currentKind.icon, tint: .pink, caption: "类型", value: currentKind.title)
            }
            .buttonStyle(.plain)
            infoCell(icon: book.canUpdate ? "bell.fill" : "bell.slash.fill", tint: .orange, caption: "更新",
                     value: book.canUpdate ? "开启更新" : "关闭更新", enabled: !isLocal) { toggleUpdate() }
        }
        .padding(.vertical, 12)
        .background(card(18))
    }

    private func infoCell(icon: String, tint: Color, caption: String, value: String, enabled: Bool = true,
                          action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            infoLabel(icon: icon, tint: tint, caption: caption, value: value)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }

    private func infoLabel(icon: String, tint: Color, caption: String, value: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(AppFontStyle.system(size: 17).themed)
                .foregroundStyle(tint)
                .frame(height: 22)
            Text(caption)
                .font(AppFontStyle.system(size: 10).themed)
                .foregroundStyle(ReadingTheme.tertiaryInk)
            Text(value)
                .font(AppFontStyle.system(size: 12, weight: .medium).themed)
                .foregroundStyle(ReadingTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private var groupLabel: String {
        let names = library.groups
            .filter { $0.groupId > 0 && (book.group & $0.groupId) != 0 }
            .map(\.groupName)
        return names.isEmpty ? "未分组" : names.joined(separator: "、")
    }

    private enum BookKindChoice: CaseIterable {
        case text, audio, image
        var title: String {
            switch self {
            case .text: "文本"
            case .audio: "音频"
            case .image: "漫画"
            }
        }
        var icon: String {
            switch self {
            case .text: "doc.plaintext.fill"
            case .audio: "headphones"
            case .image: "photo.fill.on.rectangle.fill"
            }
        }
        var flag: Int {
            switch self {
            case .text: 8
            case .audio: 32
            case .image: 64
            }
        }
    }

    private var currentKind: BookKindChoice {
        if book.type & 64 != 0 { return .image }
        if book.type & 32 != 0 { return .audio }
        return .text
    }

    private func setKind(_ kind: BookKindChoice) {
        guard kind != currentKind else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        var updated = book
        updated.type = (updated.type & ~(8 | 32 | 64)) | kind.flag
        Task { await library.addOrUpdate(updated) }
        showNotice("已设为\(kind.title)")
    }

    private func toggleUpdate() {
        var updated = book
        updated.canUpdate.toggle()
        let enabled = updated.canUpdate
        Task { await library.addOrUpdate(updated) }
        showNotice(enabled ? "已开启更新" : "已关闭更新")
    }

    // MARK: 简介

    private var introText: String {
        let custom = book.customIntro?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let raw = custom.isEmpty ? (book.intro ?? "") : custom
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "暂无简介" : trimmed
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("text.alignleft", "简介")
            Text(introText)
                .font(AppFontStyle.subheadline.themed)
                .foregroundStyle(ReadingTheme.ink)
                .lineSpacing(4)
                .lineLimit(introExpanded ? nil : 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if introText.count > 80 {
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) { introExpanded.toggle() }
                } label: {
                    HStack(spacing: 3) {
                        Text(introExpanded ? "收起" : "展开全部")
                        Image(systemName: introExpanded ? "chevron.up" : "chevron.down")
                    }
                    .font(AppFontStyle.footnote.weight(.medium).themed)
                    .foregroundStyle(ReadingTheme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card(18))
    }

    // MARK: 目录

    /// 目录里显示的几章：从正在读的那一章开始（没读过从第一章开始），最多 5 章。
    private struct ChapterEntry: Identifiable {
        let offset: Int
        let chapter: BookChapter
        var id: Int { offset }
    }

    private var visibleChapters: [ChapterEntry] {
        let all = chapters.indices.filter { !chapters[$0].isVolume }
        guard !all.isEmpty else { return [] }
        let current = min(max(book.durChapterIndex, 0), chapters.count - 1)
        let start = all.firstIndex { $0 >= current } ?? 0
        return all[start..<min(start + 5, all.count)].map { ChapterEntry(offset: $0, chapter: chapters[$0]) }
    }

    private var tocCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("list.bullet", "目录")
                Spacer()
                if !chapters.isEmpty {
                    Button { open(.info(book)) } label: {
                        HStack(spacing: 2) {
                            Text("共 \(chapters.filter { !$0.isVolume }.count) 章")
                            Image(systemName: "chevron.right").font(AppFontStyle.system(size: 10, weight: .semibold).themed)
                        }
                        .font(AppFontStyle.footnote.themed)
                        .foregroundStyle(ReadingTheme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            if loadingChapters {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("加载目录中…")
                        .font(AppFontStyle.footnote.themed)
                        .foregroundStyle(ReadingTheme.secondaryInk)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            } else if visibleChapters.isEmpty {
                Text(book.latestChapterTitle.map { "最新：\($0)" } ?? "还没有目录，打开阅读或刷新目录后显示")
                    .font(AppFontStyle.footnote.themed)
                    .foregroundStyle(ReadingTheme.secondaryInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(visibleChapters) { item in
                        Button {
                            readFrom(item.offset, chapter: item.chapter)
                        } label: {
                            HStack(spacing: 8) {
                                Text(item.chapter.title)
                                    .font(AppFontStyle.subheadline.themed)
                                    .foregroundStyle(item.offset == book.durChapterIndex
                                                     ? ReadingTheme.accent : ReadingTheme.ink)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right")
                                    .font(AppFontStyle.system(size: 11, weight: .semibold).themed)
                                    .foregroundStyle(ReadingTheme.tertiaryInk)
                            }
                            .frame(height: 40)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card(18))
    }

    private func loadChapters() async {
        let loaded = (try? await AppBookChapterRepository.live().load(bookURL: bookURL)) ?? []
        chapters = loaded
        withAnimation(.easeOut(duration: 0.2)) { loadingChapters = false }
    }

    /// 点目录里的一章：从这一章开头开始读。
    private func readFrom(_ index: Int, chapter: BookChapter) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let original = book
        var updated = original
        if index != updated.durChapterIndex {
            updated.durChapterIndex = index
            updated.durChapterTitle = chapter.title
            updated.durChapterPos = 0
        }
        let target = updated
        Task {
            if target.durChapterIndex != original.durChapterIndex || target.durChapterTitle != original.durChapterTitle {
                await library.addOrUpdate(target)
            }
            open(.read(target))
        }
    }

    // MARK: 来源

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("globe", "来源")
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(isLocal ? "本地书籍" : (book.originName.isEmpty ? (source?.bookSourceName ?? "网络书籍") : book.originName))
                        .font(AppFontStyle.subheadline.weight(.semibold).themed)
                        .foregroundStyle(ReadingTheme.ink)
                        .lineLimit(1)
                    if !isLocal {
                        Text(book.origin)
                            .font(AppFontStyle.caption.themed)
                            .foregroundStyle(ReadingTheme.tertiaryInk)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if !isLocal {
                    Button { showsSwitchSource = true } label: {
                        HStack(spacing: 2) {
                            Text("换源")
                            Image(systemName: "chevron.right").font(AppFontStyle.system(size: 10, weight: .semibold).themed)
                        }
                        .font(AppFontStyle.footnote.weight(.medium).themed)
                        .foregroundStyle(ReadingTheme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card(18))
    }

    // MARK: 公共

    private func sectionTitle(_ icon: String, _ title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(AppFontStyle.system(size: 12).themed)
            Text(title).font(AppFontStyle.footnote.weight(.semibold).themed)
        }
        .foregroundStyle(ReadingTheme.secondaryInk)
    }

    private func card(_ radius: CGFloat) -> some View {
        ThemeSurface(shape: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    private func showNotice(_ text: String) {
        noticeTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { notice = text }
        noticeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) { notice = nil }
        }
    }
}


// MARK: - 分组（书架文件夹）

/// 长按面板「分组」：把这本书放进当前书架的某个分组（文件夹），或新建一个分组；也可以移出分组。
/// 面板底部保留「移至其他书架」（正在读 / 想读 / 自定义书架）。
struct BookshelfBookFolderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: BookLibraryModel
    @ObservedObject private var folderStore = BookshelfFolderStore.shared
    let book: Book
    let groupID: Int64
    let onNotice: (String) -> Void
    @State private var newName = ""
    @State private var showsShelfPicker = false
    @FocusState private var nameFocused: Bool

    private var folders: [BookshelfFolder] { folderStore.folders(inGroup: groupID) }
    private var current: BookshelfFolder? { folders.first { $0.bookURLs.contains(book.bookUrl) } }
    private var shelfName: String {
        library.visibleGroups.first { $0.groupId == groupID }?.groupName ?? "当前书架"
    }
    private var trimmedName: String { newName.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ReadingNavigationStack {
            List {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "folder.badge.plus").foregroundStyle(ReadingTheme.accent)
                        TextField(folderStore.nextName(inGroup: groupID), text: $newName)
                            .focused($nameFocused)
                            .submitLabel(.done)
                            .onSubmit(createFolder)
                        Button("新建", action: createFolder)
                            .font(AppFontStyle.subheadline.weight(.semibold).themed)
                            .foregroundStyle(ReadingTheme.accent)
                            .buttonStyle(.borderless)
                    }
                } header: {
                    Text("新建分组")
                } footer: {
                    Text("《\(book.name)》会放进新分组，显示在「\(shelfName)」书架上。名称留空时自动命名。")
                }
                .readingRowBackground()

                if !folders.isEmpty {
                    Section {
                        ForEach(folders) { folder in
                            Button {
                                move(to: folder)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: current?.id == folder.id ? "folder.fill" : "folder")
                                        .foregroundStyle(ReadingTheme.accent)
                                    Text(folder.name).foregroundStyle(ReadingTheme.ink)
                                    Spacer()
                                    Text("\(folder.bookURLs.count) 本").foregroundStyle(ReadingTheme.secondaryInk)
                                    if current?.id == folder.id {
                                        Image(systemName: "checkmark").foregroundStyle(ReadingTheme.accent)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(current?.id == folder.id ? .isSelected : [])
                        }
                    } header: {
                        Text("已有分组")
                    }
                    .readingRowBackground()
                }

                if let current {
                    Section {
                        Button(role: .destructive) {
                            folderStore.remove([book.bookUrl], from: current.id)
                            finish("已移出分组「\(current.name)」")
                        } label: {
                            Label("移出分组「\(current.name)」", systemImage: "folder.badge.minus")
                        }
                    } footer: {
                        Text("分组里只剩这一本书时，移出后分组会自动解散。")
                    }
                    .readingRowBackground()
                }

                Section {
                    Button {
                        showsShelfPicker = true
                    } label: {
                        HStack {
                            Label("移至其他书架", systemImage: "books.vertical")
                                .foregroundStyle(ReadingTheme.ink)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(AppFontStyle.system(size: 12, weight: .semibold).themed)
                                .foregroundStyle(ReadingTheme.tertiaryInk)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } footer: {
                    Text("分组是书架里的文件夹；「正在读」「想读」和自定义书架在这里切换。")
                }
                .readingRowBackground()
            }
            .readingThemedListBackground()
            .navigationTitle("分组")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
        }
        .sheet(isPresented: $showsShelfPicker) {
            BookShelfPickerSheet(book: book, inLibrary: false, title: "移至书架") { groupIDs, reading in
                Task {
                    guard let stored = library.books.first(where: { $0.bookUrl == book.bookUrl }) else { return }
                    await library.setBook(stored, groupIDs: groupIDs)
                    if let latest = library.books.first(where: { $0.bookUrl == book.bookUrl }) {
                        await library.setReadingStatus(latest, reading: reading)
                    }
                }
            } onRemove: {}
            .environmentObject(library)
            .readingPresentationDetents([.medium, .large])
        }
    }

    private func move(to folder: BookshelfFolder) {
        guard current?.id != folder.id else {
            dismiss()
            return
        }
        folderStore.add(book.bookUrl, to: folder.id)
        finish("已放进分组「\(folder.name)」")
    }

    private func createFolder() {
        let folder = folderStore.makeFolder(groupID: groupID, bookURLs: [book.bookUrl],
                                            name: trimmedName.isEmpty ? nil : trimmedName)
        finish("已新建分组「\(folder.name)」")
    }

    private func finish(_ text: String) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onNotice(text)
        dismiss()
    }
}
