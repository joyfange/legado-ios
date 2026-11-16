import SwiftUI

struct BookDetailView: View {
    @EnvironmentObject private var library: BookLibraryModel
    @EnvironmentObject private var sourceLibrary: SourceLibraryModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var model: BookDetailViewModel
    @State private var showsSourceSwitch = false
    @State private var showsRemoveConfirmation = false
    @State private var showsTableOfContents = false
    @State private var showsReader = false
    @State private var showsCompactBar = false
    @State private var introExpanded = false
    /// 同题材作品放在页面自己的模型里加载：以前挂在一个可能为空的 Group 上，
    /// 区块还没内容时 Group 里没有视图，.task 根本不会执行，于是永远不显示。
    @StateObject private var similar = BookSimilarModel()

    init(searchBook: SearchBook, source: BookSource) {
        _model = StateObject(wrappedValue: BookDetailViewModel(searchBook: searchBook, source: source))
    }

    init(book: Book, source: BookSource) {
        _model = StateObject(wrappedValue: BookDetailViewModel(book: book, source: source))
    }

    init(demoBook: Book, source: BookSource, chapters: [BookChapter]) {
        _model = StateObject(wrappedValue: BookDetailViewModel(demoBook: demoBook, source: source, chapters: chapters))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                hero
                if let intro = MetadataTextSanitizer().clean(model.book.displayIntro), !intro.isEmpty {
                    introSection(intro)
                }
                chapterCard
                if model.isCaching || model.cacheCompleted > 0 { cacheProgressCard }
                if similar.hasContent {
                    BookSimilarSection(book: model.book, source: model.source, model: similar)
                }
                infoSection
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 34)
            // 内容不满一屏时也要能把书名推到导航栏下面：否则只能拉到临界处又回弹，
            // 右上角的「开始阅读」一出一收地闪。留出一屏高度，滑下去后停得住。
            .frame(minHeight: UIScreen.main.bounds.height + 300, alignment: .top)
        }
        .task(id: model.source.bookSourceUrl + "\u{1F}" + model.book.bookUrl + "\u{1F}" + (model.book.kind ?? "")) {
            await similar.load(for: model.book, source: model.source)
        }
        .coordinateSpace(name: "bookDetailScroll")
        .readingCanvas()
        .navigationTitle("书籍详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(model.book.name)
                    .font(AppFontStyle.subheadline.weight(.semibold).themed)
                    .lineLimit(1)
                    .opacity(showsCompactBar ? 1 : 0)
                    .accessibilityHidden(!showsCompactBar)
            }
            ToolbarItem(placement: .topBarTrailing) {
                // 只有书名滚出屏幕后才放「开始阅读」；以前用透明度隐藏，按钮仍占位，
                // 右上角出现一大块空白的胶囊。
                HStack(spacing: 14) {
                    moreMenu
                    if showsCompactBar {
                        Button { showsReader = true } label: {
                            Text(readButtonTitle)
                                .font(AppFontStyle.subheadline.weight(.semibold).themed)
                                .foregroundStyle(ReadingTheme.ink)
                                .lineLimit(1)
                                .fixedSize()
                        }
                        .buttonStyle(.plain)
                        .disabled(model.chapters.isEmpty)
                        .opacity(model.chapters.isEmpty ? 0.5 : 1)
                        .transition(.opacity)
                    }
                }
            }
        }
        .readingNavigationDestination(isPresented: $showsReader) { readingDestination }
        .task {
            model.restoreSourceAfterReading(from: library.books, sources: sourceLibrary.sources)
            let oldURL = model.book.bookUrl
            let shouldPersistUpdate = library.contains(model.book)
            if let stored = library.books.first(where: { $0.bookUrl == oldURL }) {
                model.restoreLibraryBook(from: stored, sources: sourceLibrary.sources)
            }
            await model.load(sources: sourceLibrary.sources)
            if shouldPersistUpdate {
                if let stored = library.books.first(where: { $0.bookUrl == model.book.bookUrl }) {
                    model.restoreUserSettings(from: stored)
                    model.restoreReadingProgress(from: stored)
                }
                if oldURL != model.book.bookUrl {
                    await library.replace(oldBookURL: oldURL, with: model.book)
                } else {
                    await saveCurrentBook()
                }
            }
        }
        .sheet(isPresented: $showsSourceSwitch) {
            ReadingNavigationStack {
                SourceSwitchView(book: model.book, sources: sourceLibrary.sources) { report, source in
                    let oldURL = model.book.bookUrl
                    model.applySourceSwitch(report, source: source)
                    Task { await library.replace(oldBookURL: oldURL, with: report.book) }
                }
            }
        }
        .sheet(isPresented: $showsTableOfContents) {
            BookTableOfContentsView(book: model.book, chapters: model.chapters, source: model.source)
        }
        .confirmationDialog("从书架移除《\(model.book.name)》？", isPresented: $showsRemoveConfirmation) {
            Button("移出书架", role: .destructive) {
                Task { await library.remove(bookURL: model.book.bookUrl) }
            }
            Button("取消", role: .cancel) { }
        }
    }

    /// 状态栏 + 导航栏的高度：书名底边滚到这条线以上，就是被导航栏挡住了。
    private var compactThreshold: CGFloat {
        let top = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows.first(where: \.isKeyWindow)?.safeAreaInsets.top }
            .first ?? 47
        return top + 44
    }

    private var readButtonTitle: String {
        model.book.durChapterIndex > 0 || model.book.durChapterPos > 0 ? "继续阅读" : "开始阅读"
    }

    private var moreMenu: some View {
        Menu {
            Button("换源", systemImage: "arrow.triangle.2.circlepath") { showsSourceSwitch = true }
                .disabled(sourceLibrary.sources.filter(\.enabled).count < 2)
            Button("允许更新", systemImage: model.book.canUpdate ? "checkmark" : "circle") {
                model.toggleCanUpdate()
                Task { await saveCurrentBook() }
            }
            Button("刷新", systemImage: "arrow.clockwise") {
                Task {
                    let oldURL = model.book.bookUrl
                    let wasInLibrary = library.contains(model.book)
                    await model.refresh(sources: sourceLibrary.sources)
                    if wasInLibrary, oldURL != model.book.bookUrl {
                        await library.replace(oldBookURL: oldURL, with: model.book)
                    } else if wasInLibrary {
                        await saveCurrentBook()
                    }
                }
            }
            if model.source.loginUrl?.isEmpty == false {
                NavigationLink {
                    SourceLoginView(source: model.source)
                } label: {
                    Label("登录", systemImage: "person.badge.key")
                }
            }
            ReadingShareLink(item: model.book.bookUrl) {
                Label("分享", systemImage: "square.and.arrow.up")
            }
            Divider()
            Button("缓存接下来 10 章", systemImage: "arrow.down.circle") { model.cacheNextTen() }
                .disabled(model.chapters.isEmpty || model.isCaching)
            Button("缓存剩余章节", systemImage: "square.and.arrow.down.on.square") { model.cacheRemaining() }
                .disabled(model.chapters.isEmpty || model.isCaching)
            if model.isCaching {
                Divider()
                Button("停止缓存", systemImage: "stop.circle", role: .destructive) { model.cancelCaching() }
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("更多")
    }

    /// 书的分类拆成几个小标签（「连载中玄幻小说」「连载中」「玄幻小说」）。
    private var tags: [String] {
        guard let kind = model.book.kind else { return [] }
        let separators = CharacterSet(charactersIn: ",，|/、;；\n\t ")
        var seen = Set<String>()
        return kind.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(4)
            .map { $0 }
    }

    private func introSection(_ intro: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("简介").font(AppFontStyle.title3.bold().themed)
            Text(intro)
                .font(AppFontStyle.subheadline.themed)
                .foregroundStyle(ReadingTheme.ink.opacity(0.82))
                .lineSpacing(5)
                .lineLimit(introExpanded ? nil : 4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if intro.count > 60 || intro.contains("\n") {
                HStack {
                    Spacer()
                    Button(introExpanded ? "收起" : "更多") {
                        withAnimation(.easeInOut(duration: 0.2)) { introExpanded.toggle() }
                    }
                    .font(AppFontStyle.subheadline.themed)
                    .foregroundStyle(ReadingTheme.accent)
                }
            }
        }
    }

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("作品信息").font(AppFontStyle.title3.bold().themed).padding(.bottom, 6)
            if let words = model.book.wordCount?.trimmingCharacters(in: .whitespacesAndNewlines), !words.isEmpty {
                infoRow("字数") { Text(words) }
            }
            let chapterCount = model.chapters.filter { !$0.isVolume }.count
            if chapterCount > 0 {
                infoRow("章节") { Text("\(chapterCount)") }
            }
            if let latest = model.book.latestChapterTitle, !latest.isEmpty {
                infoRow("最新") { Text(latest).lineLimit(1) }
            }
            infoRow("来源", last: true) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(model.source.bookSourceName).lineLimit(1)
                    Button {
                        showsSourceSwitch = true
                    } label: {
                        HStack(spacing: 2) {
                            Text("换源")
                            Image(systemName: "chevron.right").font(AppFontStyle.caption2.weight(.semibold).themed)
                        }
                        .font(AppFontStyle.caption.themed)
                        .foregroundStyle(ReadingTheme.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(sourceLibrary.sources.filter(\.enabled).count < 2)
                }
            }
        }
    }

    private func infoRow<Value: View>(_ title: String, last: Bool = false, @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            value().foregroundStyle(ReadingTheme.ink)
        }
        .font(AppFontStyle.subheadline.themed)
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(ReadingTheme.separator).frame(height: 0.5) }
        }
    }

    private var cacheProgressCard: some View {
        ReadingCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(model.isCaching ? "正在缓存章节" : "章节缓存完成", systemImage: model.isCaching ? "arrow.down.circle.fill" : "checkmark.circle.fill")
                        .font(AppFontStyle.headline.themed)
                    Spacer()
                    Text("\(model.cacheCompleted)/\(model.cacheTotal)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                ProgressView(value: Double(model.cacheCompleted), total: Double(max(model.cacheTotal, 1)))
                    .tint(ReadingTheme.accent)
                if model.isCaching {
                    Button("停止缓存", role: .destructive) { model.cancelCaching() }
                        .font(AppFontStyle.subheadline.themed)
                }
            }
        }
    }

    private var hero: some View {
        VStack(spacing: 12) {
            BookCoverArtwork(
                title: model.book.name,
                author: model.book.author,
                remoteURL: model.book.displayCoverUrl,
                width: 108,
                height: 154
            )
            .shadow(color: .black.opacity(0.16), radius: 10, y: 6)
            Text(model.book.name)
                .font(AppFontStyle.title3.weight(.bold).themed)
                .foregroundStyle(ReadingTheme.ink)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.top, 4)
                .background(GeometryReader { proxy in
                    // 书名滚到导航栏下面后，导航栏显示书名和「开始阅读」，随时可以开始读。
                    // 显示和隐藏用两条不同的线（回滞）：只用一条线时，手指停在临界处或按钮插入引起的
                    // 微小位移会让状态来回切换，右上角一闪一闪。
                    let maxY = proxy.frame(in: .global).maxY
                    Color.clear.onChange(of: Int(maxY)) { value in
                        let y = CGFloat(value)
                        if !showsCompactBar, y < compactThreshold - 6 {
                            withAnimation(.easeOut(duration: 0.2)) { showsCompactBar = true }
                        } else if showsCompactBar, y > compactThreshold + 28 {
                            withAnimation(.easeOut(duration: 0.2)) { showsCompactBar = false }
                        }
                    }
                })
            NavigationLink {
                SearchView(initialKeyword: model.book.author)
            } label: {
                HStack(spacing: 3) {
                    Text(model.book.author.isEmpty ? "未知作者" : model.book.author)
                    Image(systemName: "chevron.right").font(AppFontStyle.caption2.weight(.semibold).themed)
                }
                .font(AppFontStyle.subheadline.themed)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(model.book.author.isEmpty)
            .accessibilityLabel("作者 \(model.book.author)，搜索作者的书")
            if !tags.isEmpty {
                HStack(spacing: 10) {
                    ForEach(tags, id: \.self) { tag in
                        NavigationLink {
                            SearchView(initialKeyword: tag)
                        } label: {
                            HStack(spacing: 2) {
                                Text(tag).lineLimit(1)
                                Image(systemName: "chevron.right").font(AppFontStyle.system(size: 8, weight: .semibold).themed)
                            }
                            .font(AppFontStyle.caption.themed)
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 12) { readingActions }
                } else {
                    HStack(spacing: 14) { readingActions }
                }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var readingActions: some View {
        Button { showsReader = true } label: {
            Text(readButtonTitle)
                .font(AppFontStyle.body.weight(.semibold).themed)
                .frame(maxWidth: .infinity, minHeight: 46)
                .foregroundStyle(ReadingTheme.onAccent)
                .background(ReadingTheme.accentFill, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(model.chapters.isEmpty)
        .opacity(model.chapters.isEmpty ? 0.45 : 1)
        Button {
            if library.contains(model.book) {
                showsRemoveConfirmation = true
            } else {
                Task { await saveCurrentBook() }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: library.contains(model.book) ? "checkmark" : "plus")
                Text(library.contains(model.book) ? "已在书架" : "加入书架")
            }
            .font(AppFontStyle.subheadline.weight(.medium).themed)
            .foregroundStyle(ReadingTheme.ink)
            .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil, minHeight: 46)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(library.contains(model.book) ? "已在书架" : "加入书架")
    }

    @ViewBuilder
    private var readingDestination: some View {
        let index = min(max(model.book.durChapterIndex, 0), max(model.chapters.count - 1, 0))
        if ProcessInfo.processInfo.arguments.contains("-uiDemo") {
            ReaderView(demoBook: model.book, chapters: model.chapters, initialIndex: index, content: DemoContent.readerText)
        } else {
            ReaderView(book: model.book, chapters: model.chapters, initialIndex: index, source: model.source)
        }
    }

    private func saveCurrentBook() async {
        await library.addOrUpdate(model.book)
        if let stored = library.books.first(where: { $0.bookUrl == model.book.bookUrl }) {
            model.restoreReadingProgress(from: stored)
        }
    }

    private var chapterCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("目录").font(AppFontStyle.title3.bold().themed)
                Spacer()
                Button { showsTableOfContents = true } label: {
                    HStack(spacing: 3) {
                        Text("查看全部")
                        Image(systemName: "chevron.right").font(AppFontStyle.caption.weight(.semibold).themed)
                    }
                    .font(AppFontStyle.subheadline.themed)
                    .foregroundStyle(ReadingTheme.accent)
                }
                .buttonStyle(.plain)
                .disabled(model.chapters.isEmpty)
                .opacity(model.chapters.isEmpty ? 0 : 1)
            }
            .padding(.bottom, 8)
            if let latest = model.book.latestChapterTitle ?? model.chapters.last(where: { !$0.isVolume })?.title,
               !latest.isEmpty {
                Label {
                    Text(latest).lineLimit(1)
                } icon: {
                    Image(systemName: "clock")
                }
                .font(AppFontStyle.caption.themed)
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
            }
            if model.state == .loading || model.state == .idle {
                HStack { Spacer(); ProgressView("正在加载目录…"); Spacer() }.padding(.vertical, 24)
            } else if model.state == .findingSource {
                HStack { Spacer(); ProgressView("当前源不可用，正在自动寻找可用源…"); Spacer() }
                    .padding(.vertical, 24)
            } else if model.state == .failed {
                ReadingUnavailableView(
                    "没有找到可用目录",
                    systemImage: "exclamationmark.arrow.triangle.2.circlepath",
                    description: Text("已自动尝试其他可搜索书源，可稍后刷新重试或手动换源。")
                )
                .padding(.vertical, 12)
            } else {
                let preview = Array(model.chapters.filter { !$0.isVolume }.prefix(5))
                ForEach(Array(preview.enumerated()), id: \.element.id) { offset, chapter in
                    NavigationLink {
                        ReaderView(
                            book: model.book,
                            chapters: model.chapters,
                            initialIndex: chapter.index,
                            source: model.source
                        )
                    } label: {
                        HStack(spacing: 10) {
                            Text(chapter.title)
                                .font(AppFontStyle.subheadline.themed)
                                .foregroundStyle(ReadingTheme.ink)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if chapter.isVip { Image(systemName: "lock.fill").font(AppFontStyle.caption.themed).foregroundStyle(.orange) }
                            Image(systemName: "chevron.right").font(AppFontStyle.caption.weight(.semibold).themed).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .bottom) {
                        if offset < preview.count - 1 {
                            Rectangle().fill(ReadingTheme.separator).frame(height: 0.5)
                        }
                    }
                }
            }
        }
    }
}

/// 同题材作品：按这本书的分类在当前书源的发现分区里找同类书，横滑封面；可切换分区，「查看全部」进分区书单。
/// 书源没有发现、分区对不上或分区没有书时，改用分类词在书源里搜索（大多数书源都有搜索），区块不再消失。
private struct BookSimilarSection: View {
    let book: Book
    let source: BookSource
    @ObservedObject var model: BookSimilarModel

    var body: some View {
        Group {
            if model.hasContent {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("同题材作品").font(AppFontStyle.title3.bold().themed)
                        titleSwitcher
                        Spacer()
                        seeAllLink
                    }
                    if model.isLoading && model.books.isEmpty {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 150)
                    } else {
                        ExploreCoverStrip(books: model.books, source: source)
                            .padding(.horizontal, -18)
                    }
                }
            }
        }
    }

    @ViewBuilder private var titleSwitcher: some View {
        if let kind = model.kind, model.kinds.count > 1 {
            Menu {
                ForEach(model.kinds) { option in
                    Button {
                        Task { await model.select(option, source: source, excluding: book) }
                    } label: {
                        if option.id == kind.id {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                }
            } label: {
                HStack(spacing: 2) {
                    Text(kind.title).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(AppFontStyle.system(size: 9, weight: .semibold).themed)
                }
                .font(AppFontStyle.subheadline.themed)
                .foregroundStyle(ReadingTheme.accent)
            }
        } else if let title = model.kind?.title ?? model.keyword {
            Text(title).lineLimit(1)
                .font(AppFontStyle.subheadline.themed)
                .foregroundStyle(ReadingTheme.accent)
        }
    }

    @ViewBuilder private var seeAllLink: some View {
        let label = HStack(spacing: 3) {
            Text("查看全部")
            Image(systemName: "chevron.right").font(AppFontStyle.caption.weight(.semibold).themed)
        }
        .font(AppFontStyle.subheadline.themed)
        .foregroundStyle(ReadingTheme.accent)
        if let kind = model.kind {
            NavigationLink { ExploreKindBooksView(source: source, kind: kind) } label: { label }
                .buttonStyle(.plain)
        } else if let keyword = model.keyword {
            NavigationLink { SearchView(initialKeyword: keyword) } label: { label }
                .buttonStyle(.plain)
        }
    }
}

@MainActor
final class BookSimilarModel: ObservableObject {
    @Published private(set) var kinds: [ExploreKind] = []
    @Published private(set) var kind: ExploreKind?
    /// 发现分区用不上时改用搜索，记下搜索词（分类词）。
    @Published private(set) var keyword: String?
    @Published private(set) var books: [SearchBook] = []
    @Published private(set) var isLoading = false
    private var loadedKey: String?
    private var loadTask: Task<Void, Never>?

    var hasContent: Bool { (kind != nil || keyword != nil) && (!books.isEmpty || isLoading) }

    /// 同样放在模型自己的任务里，页面重新出现时不会因取消而永远不显示。
    func load(for book: Book, source: BookSource) async {
        let key = source.bookSourceUrl + "\u{1F}" + book.bookUrl + "\u{1F}" + (book.kind ?? "")
        guard loadedKey != key else {
            await loadTask?.value
            return
        }
        guard !ProcessInfo.processInfo.arguments.contains("-uiDemo") else { return }
        // 分类还没从详情页拿到时先不急着兜底，等 kind 更新后 task 会再跑一次。
        loadedKey = key
        loadTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            if !(source.exploreUrl?.isEmpty ?? true), source.enabledExplore {
                let report = await ExploreCache.shared.kinds(for: source)
                guard !Task.isCancelled else { return }
                let options = report.kinds.filter { $0.navigableURL != nil }
                self.kinds = options
                if let match = BookSimilarModel.matchingKind(for: book, in: options) {
                    await self.select(match, source: source, excluding: book)
                    if !self.books.isEmpty || Task.isCancelled { return }
                }
            }
            await self.searchFallback(for: book, source: source, explore: self.kinds)
        }
        loadTask = task
        await task.value
    }

    func select(_ option: ExploreKind, source: BookSource, excluding book: Book) async {
        kind = option
        keyword = nil
        books = []
        isLoading = true
        let outcome = await ExploreCache.shared.firstPage(source: source, kind: option)
        guard kind?.id == option.id else { return }
        books = Self.filtered(outcome.books, excluding: book)
        isLoading = false
    }

    /// 用分类词在本书源搜索；搜不到再用发现里第一个像样的分区兜底。
    private func searchFallback(for book: Book, source: BookSource, explore: [ExploreKind]) async {
        for word in Self.kindWords(book.kind).prefix(2) where source.searchUrl?.isEmpty == false {
            kind = nil
            keyword = word
            books = []
            isLoading = true
            let outcome = await BookSearchService().search(keyword: word, page: 1, source: source)
            guard !Task.isCancelled, keyword == word else { return }
            let found = Self.filtered(outcome.books, excluding: book)
            isLoading = false
            if !found.isEmpty {
                books = found
                return
            }
        }
        keyword = nil
        isLoading = false
        if let fallback = Self.fallbackKind(in: explore) {
            await select(fallback, source: source, excluding: book)
            if books.isEmpty { kind = nil }
        }
    }

    private static func filtered(_ books: [SearchBook], excluding book: Book) -> [SearchBook] {
        var seen = Set<String>()
        return books.filter { $0.name != book.name && seen.insert($0.name + "\u{1F}" + $0.author).inserted }
            .prefix(20).map { $0 }
    }

    /// 分类拆词：去掉「小说」「连载中」「已完结」之类，留下题材词。
    static func kindWords(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        let noise = ["连载中", "连载", "已完结", "完结", "完本", "全本", "小说"]
        var seen = Set<String>()
        return raw.components(separatedBy: CharacterSet(charactersIn: ",，|/、;；\n\t ·"))
            .map { word in
                var value = word.trimmingCharacters(in: .whitespacesAndNewlines)
                for item in noise { value = value.replacingOccurrences(of: item, with: "") }
                return value
            }
            .filter { $0.count >= 2 && $0.count <= 8 && !$0.contains(where: \.isNumber) && seen.insert($0).inserted }
    }

    static func fallbackKind(in kinds: [ExploreKind]) -> ExploreKind? {
        kinds.first { kind in
            !["最近", "更新", "最新", "推荐", "新书"].contains { kind.title.contains($0) }
        } ?? kinds.first
    }

    /// 书的分类里任一词出现在分区标题里，就是同题材分区。
    static func matchingKind(for book: Book, in kinds: [ExploreKind]) -> ExploreKind? {
        for word in kindWords(book.kind) {
            if let hit = kinds.first(where: { $0.title.contains(word) || word.contains($0.title) && $0.title.count >= 2 }) {
                return hit
            }
        }
        return nil
    }
}

private struct BookTableOfContentsView: View {
    @Environment(\.dismiss) private var dismiss
    let book: Book
    let chapters: [BookChapter]
    let source: BookSource
    @State private var searchText = ""
    @State private var descending = false

    private var displayedChapters: [BookChapter] {
        let filtered = searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? chapters
            : chapters.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
        return descending ? Array(filtered.reversed()) : filtered
    }

    private var currentChapterID: BookChapter.ID? {
        chapters.first { $0.index == book.durChapterIndex && !$0.isVolume }?.id
    }

    private var hasProgress: Bool {
        book.durChapterTitle?.isEmpty == false || book.durChapterIndex > 0
    }

    var body: some View {
        ReadingNavigationStack {
            ScrollViewReader { proxy in
            List(displayedChapters) { chapter in
                if chapter.isVolume {
                    Text(chapter.title).font(AppFontStyle.headline.themed).foregroundStyle(ReadingTheme.accent)
                } else {
                    NavigationLink {
                        ReaderView(book: book, chapters: chapters, initialIndex: chapter.index, source: source)
                    } label: {
                        HStack(spacing: 12) {
                            Text("\(chapter.index + 1)")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
                            Text(chapter.title).lineLimit(2)
                            Spacer()
                            if chapter.index == book.durChapterIndex {
                                Image(systemName: "location.fill").foregroundStyle(ReadingTheme.accent)
                            }
                            if chapter.isVip { Image(systemName: "lock.fill").foregroundStyle(.orange) }
                        }
                    }
                }
            }.readingThemedListBackground()
            .readingInlineSearch(text: $searchText, prompt: "搜索目录")
            .navigationTitle("目录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(descending ? "正序" : "倒序", systemImage: "arrow.up.arrow.down") {
                        descending.toggle()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                // 底部改为悬浮的小胶囊：显示读到哪一章，点一下定位到那一章；没读过时只显示总章数。
                Button {
                    guard let id = currentChapterID else { return }
                    searchText = ""
                    withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: hasProgress ? "location.fill" : "list.bullet")
                            .font(AppFontStyle.caption2.themed)
                            .foregroundStyle(ReadingTheme.accent)
                        if hasProgress {
                            Text(book.durChapterTitle ?? "第 \(book.durChapterIndex + 1) 章")
                                .lineLimit(1)
                                .foregroundStyle(ReadingTheme.ink)
                            Text("\(min(book.durChapterIndex + 1, chapters.count))/\(chapters.count)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        } else {
                            Text("共 \(chapters.filter { !$0.isVolume }.count) 章").foregroundStyle(.secondary)
                        }
                    }
                    .font(AppFontStyle.footnote.themed)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 34)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(ReadingTheme.separator.opacity(0.6), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
                    .frame(maxWidth: 300)
                }
                .buttonStyle(.plain)
                .disabled(currentChapterID == nil)
                .padding(.bottom, 6)
                .accessibilityLabel(hasProgress ? "定位到当前阅读章节" : "目录章节数")
            }
            }
        }
    }
}
