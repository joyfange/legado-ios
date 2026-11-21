import SwiftUI
import UniformTypeIdentifiers
import PhotosUI

struct RootTabView: View {
    @EnvironmentObject private var sourceLibrary: SourceLibraryModel
    private enum Tab: Hashable { case bookshelf, explore, statistics, my, search }
    /// 切换或编辑主题后根视图会整体刷新，记住当前标签，刷新后停留在原处。
    @MainActor private static var lastSelection: Tab?
    @Environment(\.appTheme) private var appTheme
    @Environment(\.colorScheme) private var colorScheme
    @State private var selection: Tab
    @State private var showsDemoReader = false
    @State private var didOpenDemoReader = false
    @State private var sourceImportIsPresented = false
    @State private var displayedSourceNotice: SourceLibraryModel.Notice?
    @AppStorage("themeMode") private var themeMode = "0"

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let requested = arguments.firstIndex(of: "-uiDemoTab")
            .flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        let initial: Tab = switch requested {
        case "explore": .explore
        case "statistics": .statistics
        case "settings": .my
        default:
            switch UserDefaults.standard.string(forKey: "defaultHomePage") {
            case "explore": .explore
            case "statistics": .statistics
            case "settings": .my
            default: .bookshelf
            }
        }
        var start = Self.lastSelection ?? initial
        // 字体管理里换了界面字体（应用刚整体刷新）：留在「我的」，由「我的」重新打开字体管理。
        if FontManagementRestore.pendingPart != nil { start = .my }
        // 搜索按钮在外观里关掉了：不要停在一个不存在的标签上。
        if start == .search, AppThemeRuntime.current.customization?.showsSearchTab == false { start = .bookshelf }
        _selection = State(initialValue: start)
    }

    var body: some View {
        tabContainer
        .task(id: sourceLibrary.sources.count) {
            // 后台预热发现页：各书源的分区和第一页提前算好，切书源时秒开。
            let candidates = sourceLibrary.sources
                .filter { $0.enabled && $0.enabledExplore && !($0.exploreUrl?.isEmpty ?? true) }
                .sorted { $0.customOrder < $1.customOrder }
            ExploreCache.shared.prewarm(candidates)
        }
        .onChange(of: selection) { Self.lastSelection = $0 }
        .overlay { BookshelfFolderOverlay() }
        .background(CoverRegistrySync())
        .preferredColorScheme(themeMode == "2" ? .dark : (themeMode == "1" || themeMode == "3" ? .light : nil))
        .transaction { transaction in
            if themeMode == "3" { transaction.animation = nil }
        }
        .sheet(item: $sourceLibrary.pendingImport, onDismiss: {
            sourceImportIsPresented = false
            displayedSourceNotice = sourceLibrary.notice
        }) { pending in
            SourceImportReviewView(pending: pending)
                .environmentObject(sourceLibrary)
                .onAppear { sourceImportIsPresented = true }
        }
        .onChange(of: sourceLibrary.notice?.id) { _ in
            if !sourceImportIsPresented { displayedSourceNotice = sourceLibrary.notice }
        }
        .alert(item: $displayedSourceNotice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.detail),
                dismissButton: .default(Text("好")) { sourceLibrary.notice = nil }
            )
        }
        .tint(ReadingTheme.accent)
        .toggleStyle(SwitchToggleStyle(tint: ReadingTheme.toggleTint))
    }

    /// 底栏：iOS 26 用系统新版 Tab 栏（悬浮 Liquid Glass、右侧独立的搜索圆钮、向下滚动时收起成小胶囊，
    /// 拖动时有玻璃气泡跟手）；更早的系统保持原来的底栏与「经典底栏」设置。
    @ViewBuilder
    private var tabContainer: some View {
        if #available(iOS 26.0, *) {
            TabView(selection: $selection) {
                SwiftUI.Tab(value: Tab.bookshelf) { shelfTab } label: {
                    themedTabItem(.shelf, selected: selection == .bookshelf)
                }
                SwiftUI.Tab(value: Tab.explore) { exploreTab } label: {
                    themedTabItem(.discover, selected: selection == .explore)
                }
                SwiftUI.Tab(value: Tab.statistics) { statisticsTab } label: {
                    themedTabItem(.statistics, selected: selection == .statistics)
                }
                SwiftUI.Tab(value: Tab.my) { profileTab } label: {
                    themedTabItem(.profile, selected: selection == .my)
                }
                if appTheme.customization?.showsSearchTab ?? true {
                    SwiftUI.Tab(value: Tab.search, role: .search) {
                        ReadingNavigationStack { SearchView() }
                            .environment(\.themePageScope, .search)
                    } label: {
                        themedTabItem(.search, selected: selection == .search)
                    }
                }
            }
            .tabBarMinimizeBehavior((appTheme.customization?.tabBarMinimizesOnScroll ?? true) ? .onScrollDown : .never)
        } else {
            TabView(selection: $selection) {
                shelfTab
                    .tabItem { themedTabItem(.shelf, selected: selection == .bookshelf) }
                    .tag(Tab.bookshelf)
                exploreTab
                    .tabItem { themedTabItem(.discover, selected: selection == .explore) }
                    .tag(Tab.explore)
                statisticsTab
                    .tabItem { themedTabItem(.statistics, selected: selection == .statistics) }
                    .tag(Tab.statistics)
                profileTab
                    .tabItem { themedTabItem(.profile, selected: selection == .my) }
                    .tag(Tab.my)
            }
            .readingTabBarBackground(classic: appTheme.customization?.classicTabBar ?? true)
        }
    }

    private var shelfTab: some View {
        ReadingNavigationStack {
            Group {
                if ProcessInfo.processInfo.arguments.contains("-uiDemoSourceSwitch") {
                    SourceSwitchView(
                        book: DemoContent.books[0],
                        sources: DemoContent.sources,
                        demoCandidates: DemoContent.sourceSwitchCandidates
                    ) { _, _ in }
                } else if ProcessInfo.processInfo.arguments.contains("-uiDemoBookDetail") {
                    BookDetailView(
                        demoBook: DemoContent.books[0],
                        source: DemoContent.sources[0],
                        chapters: DemoContent.readerChapters
                    )
                } else if requestedDemoPage == "search" {
                    SearchView(initialKeyword: automationSearchKeyword)
                } else if requestedDemoPage == "sources" {
                    SourceManagementView()
                } else if requestedDemoPage == "rss" {
                    RSSHomeView()
                } else if requestedDemoPage == "rss-photo" {
                    RSSPhotoView(value: "data:image/png;base64,", source: RssSource(sourceUrl: "https://appearance.invalid", sourceName: "图片外观检查"))
                } else {
                    BookshelfView()
                }
            }
            .readingNavigationDestination(isPresented: $showsDemoReader) {
                ReaderView(
                    demoBook: DemoContent.books[0],
                    chapters: DemoContent.readerChapters,
                    initialIndex: 0,
                    content: DemoContent.readerText
                )
            }
            .task {
                guard !didOpenDemoReader else { return }
                didOpenDemoReader = true
                showsDemoReader = ProcessInfo.processInfo.arguments.contains("-uiDemoReader")
            }
        }
            .environment(\.themePageScope, .shelf)
    }

    private var exploreTab: some View {
        ReadingNavigationStack { ExploreView() }
            .environment(\.themePageScope, .discover)
    }

    private var statisticsTab: some View {
        ReadingNavigationStack { ReadingStatisticsView() }
            .environment(\.themePageScope, .statistics)
    }

    private var profileTab: some View {
        ReadingNavigationStack {
            if ProcessInfo.processInfo.arguments.contains("-uiDemoRules") {
                ReplaceRuleManagementView()
            } else if ProcessInfo.processInfo.arguments.contains("-uiDemoHistory") {
                ReadingHistoryView()
            } else if ProcessInfo.processInfo.arguments.contains("-uiDemoFiles") {
                FileManagementView()
            } else if ProcessInfo.processInfo.arguments.contains("-uiDemoOtherSettings") {
                OtherSettingsView()
            } else if ProcessInfo.processInfo.arguments.contains("-uiDemoAbout") {
                AboutView()
            } else if ProcessInfo.processInfo.arguments.contains("-uiDemoLogs") {
                DiagnosticLogView()
            } else {
                SettingsView()
            }
        }
            .environment(\.themePageScope, .settings)
    }

    /// 底栏标签：跟随主题的「Tab栏」显示方式（图标和文字 / 仅图标 / 仅文字）与自定义图标。
    @ViewBuilder
    private func themedTabItem(_ tab: LibraryTab, selected: Bool) -> some View {
        // 「Tab 栏」：图标大小与未选中 / 选中 / 深色未选中 / 深色选中四种状态的自定义图片。
        let size = CGFloat(appTheme.customization?.tabIconSize ?? 25)
        let state = ThemeTabIconState.state(selected: selected, dark: colorScheme == .dark)
        switch appTheme.customization?.tabStyle ?? .iconsAndText {
        case .iconsAndText:
            ThemeTabIconImage.image(tab: tab, theme: appTheme, size: size, state: state)
            Text(tab.title)
        case .icons:
            ThemeTabIconImage.image(tab: tab, theme: appTheme, size: size, state: state)
        case .text:
            Text(tab.title)
        }
    }

    private var requestedDemoPage: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-uiDemoTab"), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private var automationSearchKeyword: String {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-uiAutomationSearch"),
              arguments.indices.contains(index + 1) else { return "" }
        return arguments[index + 1]
    }
}

private struct BookshelfView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.appTheme) private var appTheme
    @EnvironmentObject private var library: BookLibraryModel
    @EnvironmentObject private var sources: SourceLibraryModel
    @ObservedObject private var folderStore = BookshelfFolderStore.shared
    @ObservedObject private var selection = BookshelfSelection.shared
    @ObservedObject private var sheetRouter = BookshelfSheetRouter.shared
    @ObservedObject private var dragSession = BookshelfDragSession.shared
    @ObservedObject private var pins = BookshelfPinStore.shared
    @State private var showsLocalImporter = false
    @State private var pendingLocalFiles: [LocalBookImportFile] = []
    @State private var selectedGroupID = BookGroup.idReading
    @State private var showsGroupManager = false
    @State private var shelfBarExpanded = false
    @State private var showsNewShelf = false
    @State private var newShelfName = ""
    @AppStorage("bookshelfSortMode") private var sortMode = 0
    @AppStorage("bookshelfSortAscending") private var sortAscending = false
    @State private var showsOrnamentManager = false
    @State private var showsShelfSettings = false
    @AppStorage("bookshelfLayout") private var bookshelfLayout = "grid3"
    @AppStorage(BookshelfShelfSettings.sideSwitcherKey) private var sideSwitcher = true
    @AppStorage(BookshelfShelfSettings.hideShelfBaseKey) private var hideShelfBase = true
    @AppStorage(BookshelfShelfSettings.boardStyleKey) private var boardStyle = "solid"
    @State private var shelfDestination: BookshelfShelfDestination?

    private static let gridSpacing: CGFloat = 16

    private var selectedGroup: BookGroup {
        library.visibleGroups.first(where: { $0.id == selectedGroupID })
            ?? library.visibleGroups.first
            ?? BookGroup(groupId: BookGroup.idAll, groupName: "全部")
    }

    /// 书架顶部样式里的搜索框：按书名或作者筛选当前书架。
    @State private var bookFilter = ""

    private var shelfTopStyle: ThemeShelfTopStyle { (appTheme.customization ?? ThemeCustomization()).shelfTopStyle }

    private var displayedBooks: [Book] {
        let books = sorted(library.books(in: selectedGroup))
        let keyword = bookFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard shelfTopStyle.showsSearch, !keyword.isEmpty else { return books }
        return books.filter { $0.name.localizedCaseInsensitiveContains(keyword) || $0.author.localizedCaseInsensitiveContains(keyword) }
    }

    /// 书架排序：最近阅读 / 最近更新 / 书名 / 加入顺序；可正序倒序。
    private func sorted(_ books: [Book]) -> [Book] {
        let indexed = Array(books.enumerated())
        let result: [(offset: Int, element: Book)]
        switch sortMode {
        case 1:
            result = indexed.sorted { max($0.element.latestChapterTime, $0.element.lastCheckTime) > max($1.element.latestChapterTime, $1.element.lastCheckTime) }
        case 2:
            result = indexed.sorted { $0.element.name.localizedStandardCompare($1.element.name) == .orderedAscending }
        case 3:
            result = indexed
        default:
            result = indexed.sorted { $0.element.durChapterTime == $1.element.durChapterTime
                ? $0.offset < $1.offset : $0.element.durChapterTime > $1.element.durChapterTime }
        }
        let ordered = result.map(\.element)
        // 置顶的书（长按面板「置顶」）始终排在最前，按置顶先后排列，不受正倒序影响。
        return pins.pinnedFirst(sortAscending ? ordered.reversed() : ordered)
    }

    private static let sortTitles = ["最近阅读", "最近更新", "书名", "加入顺序"]

    private var recentBook: Book? {
        displayedBooks.filter(BookReadingPresentation.hasStarted)
            .sorted { $0.durChapterTime > $1.durChapterTime }
            .first
    }

    /// 大标题：平时是「书架」，多选时显示已选数量。
    private var shelfTitle: String {
        selection.isActive ? "已选 \(selection.urls.count) 本" : "书架"
    }

    /// 右侧竖向切换条已取消：书架切换统一用顶部的切换条。
    private var showsSideSwitcher: Bool { false }

    /// 书架内容宽度：左右各留 24pt 边距。
    private var contentWidth: CGFloat { max(UIScreen.main.bounds.width - 48, 120) }

    var body: some View {
        // 仿 bookon：标题栏固定在顶部，只有下面的内容滚动；上滑时内容在标题栏下沿直接裁掉，
        // 下拉时背景和标题都不动，只有书本身被拉下来，不会露出一截主题色。
        VStack(spacing: 0) {
            ScrollView {
                // 大标题放在懒加载列表外面：滚得很远时标题也不会被回收，顶部栏状态保持正确。
                VStack(alignment: .leading, spacing: 0) {
                ReadingLargeTitle(title: shelfTitle)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 6)
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !library.hasLoaded {
                        // 书架还没读完：保持空白，不闪「空书架」占位。
                        Color.clear.frame(height: 1)
                    } else if library.books.isEmpty {
                        EmptyBookshelfHero { showsLocalImporter = true }
                    } else if displayedBooks.isEmpty {
                        // 当前书架是空的（比如「已读完」还没有书）：书架切换条照样显示，才能切到别的书架。
                        bookshelfSummary
                        VStack(spacing: 8) {
                            Image(systemName: "books.vertical")
                                .font(AppFontStyle.system(size: 30).themed)
                                .foregroundStyle(.tertiary)
                            Text(bookFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                 ? "「\(selectedGroup.groupName)」里还没有书" : "没有找到相关书籍")
                                .font(AppFontStyle.subheadline.themed)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                    } else {
                        if let book = recentBook {
                            VStack(alignment: .leading, spacing: 12) {
                                NavigationLink {
                                    BookshelfBookDestination(book: book, source: sources.sources.first { $0.bookSourceUrl == book.origin })
                                } label: {
                                    ContinueReadingCard(book: book)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("继续阅读，\(book.name)，\(BookReadingPresentation.position(book))")
                                .accessibilityIdentifier("bookshelf.continue")
                            }
                            .padding(.bottom, 20)
                        }
                        bookshelfSummary
                        if bookshelfLayout == "shelf" {
                            BookshelfShelfView(books: displayedBooks, groupID: selectedGroup.groupId) {
                                shelfDestination = $0
                            }
                        } else if bookshelfLayout.hasPrefix("grid") {
                            gridSection
                        } else {
                            listSection
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 6)
                .padding(.bottom, 32)
                }
            }
            .readingTopScrollEdgeHidden()
        }
        .readingCanvas()
        .readingLargeTitleBar(title: shelfTitle) {
            if selection.isActive {
                selectionHeaderButtons
            } else {
                normalHeaderButtons
            }
        }
        .overlay(alignment: .trailing) {
            if showsSideSwitcher {
                sideSwitcherBar
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: showsSideSwitcher)
        .overlay(alignment: .bottom) {
            if selection.isActive {
                BookshelfSelectionBar(groupID: selectedGroup.groupId)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay {
            if showsNewShelf {
                newShelfDialog.transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            if let toast = dragSession.toast {
                Text(toast)
                    .font(AppFontStyle.footnote.weight(.medium).themed)
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.75), in: Capsule())
                    .padding(.top, 60)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .allowsHitTesting(false)
            }
        }
        .readingTabBarHidden(selection.isActive)
        .onChange(of: selectedGroupID) { _ in selection.urls = [] }
        .onDisappear { if selection.isActive { selection.end() } }
        .navigationBarHidden(true)
        .onReceive(library.$books) { books in
            ReadRecordCoverStore.remember(books)
            if library.hasLoaded {
                folderStore.prune(existing: Set(books.map(\.bookUrl)))
            }
        }
        .onAppear {
            Task {
                await migrateLegacyFolders()
                await library.refreshDownloaded()
            }
        }
        .onChange(of: library.hasLoaded) { loaded in
            if loaded { Task { await migrateLegacyFolders() } }
        }
        .readingNavigationDestination(isPresented: Binding(
            get: { shelfDestination != nil },
            set: { if !$0 { shelfDestination = nil } }
        )) {
            switch shelfDestination {
            case .read(let book):
                BookshelfBookDestination(book: book, source: sources.sources.first { $0.bookSourceUrl == book.origin })
            case .info(let book):
                if let source = sources.sources.first(where: { $0.bookSourceUrl == book.origin }) {
                    BookDetailView(book: book, source: source)
                } else {
                    LocalBookDetailView(book: book)
                }
            case nil:
                EmptyView()
            }
        }
        .readingLocalBookFileImporter(isPresented: $showsLocalImporter) { files in
            pendingLocalFiles = files
        } onError: { error in
            library.reportError(error)
        }
        .sheet(isPresented: Binding(
            get: { !pendingLocalFiles.isEmpty },
            set: { if !$0 { pendingLocalFiles = [] } }
        )) {
            LocalBookImportReviewView(files: pendingLocalFiles) {
                pendingLocalFiles = []
            }
            .environmentObject(library)
        }
        .sheet(isPresented: $showsOrnamentManager) {
            ShelfOrnamentManagerSheet()
        }
        .dismissesSheetOnOutsideTap($showsShelfSettings)
        .sheet(isPresented: $showsShelfSettings) {
            BookshelfShelfSettingsSheet()
        }
        .onReceive(BookshelfFolderStore.shared.$openRequest) { request in
            guard let request else { return }
            BookshelfFolderStore.shared.openRequest = nil
            // 长按刚弹出操作面板时不再打开书（轻点与长按同时触发时的兜底）。
            if case .read = request, case .actions? = sheetRouter.sheet { return }
            shelfDestination = request
        }
        .sheet(isPresented: $showsGroupManager) {
            BookshelfManagerSheet()
                .environmentObject(library)
                .readingPresentationDetents([.medium, .large])
        }
        .sheet(item: $sheetRouter.sheet) { sheet in
            switch sheet {
            case .moveToShelf(let book):
                // 和详情页「加入书架」同一个面板：正在读 / 想读 + 自定义书架，可就地新建书架。
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
            case .editInfo(let book):
                BookInfoEditView(book: book).environmentObject(library).environmentObject(sources)
            case .actions(let book):
                BookshelfBookActionsSheet(bookURL: book.bookUrl, fallback: book, groupID: selectedGroup.groupId)
                    .environmentObject(library)
                    .environmentObject(sources)
            }
        }
        .alert("本地书导入失败", isPresented: Binding(
            get: { library.errorMessage != nil },
            set: { if !$0 { library.clearError() } }
        )) {
            Button("好") { library.clearError() }
        } message: {
            Text(library.errorMessage ?? "未知错误")
        }
        .alert("书架更新", isPresented: Binding(
            get: { library.updateMessage != nil },
            set: { if !$0 { library.clearUpdateMessage() } }
        )) {
            Button("好") { library.clearUpdateMessage() }
        } message: {
            Text(library.updateMessage ?? "")
        }
    }

    /// 书架切换条（替代原来的「全部书籍」标题）：排序、正倒序、书架胶囊（带本数）、展开面板。
    /// 外观主题「书架 → 顶部样式」：分组与搜索 / 仅分组 / 仅搜索 / 仅标题。
    private var bookshelfSummary: some View {
        let style = shelfTopStyle
        return VStack(alignment: .leading, spacing: 10) {
            if style.showsSearch { shelfBookSearchField }
            if style.showsGroups { shelfChipScroller }
        }
        .padding(.bottom, style == .plain ? 4 : 16)
        .zIndex(2)
    }

    private var shelfBookSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(AppFontStyle.system(size: 15).themed)
                .foregroundStyle(ReadingTheme.tertiaryInk)
                .accessibilityHidden(true)
            TextField("搜索书名或作者", text: $bookFilter)
                .font(AppFontStyle.system(size: 15).themed)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .submitLabel(.search)
                .accessibilityIdentifier("bookshelf.filter")
            if !bookFilter.isEmpty {
                Button { bookFilter = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(ReadingTheme.tertiaryInk)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background { ThemeSurface(shape: Capsule(), isCard: true) }
    }

    private var shelfChipScroller: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(library.visibleGroups) { group in
                        shelfChip(group).id(group.id)
                    }
                }
                .padding(.vertical, 2)
            }
            .onAppear { proxy.scrollTo(selectedGroup.id, anchor: .center) }
            .onChange(of: selectedGroupID) { id in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }


    private func shelfChip(_ group: BookGroup, compact: Bool = false) -> some View {
        let isSelected = selectedGroup.id == group.id
        return Button {
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(.easeOut(duration: 0.2)) {
                selectedGroupID = group.id
                if compact { shelfBarExpanded = false }
            }
        } label: {
            shelfChipLabel(group, selected: isSelected, compact: compact)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(group.groupName)，\(library.count(in: group)) 本")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func shelfChipLabel(_ group: BookGroup, selected: Bool, compact: Bool) -> some View {
        let fill: Color = selected || !compact ? .clear : Color.secondary.opacity(0.08)
        return HStack(spacing: 3) {
            Text(group.groupName)
                .font(AppFontStyle.system(size: compact ? 12 : 13, weight: selected ? .semibold : .regular).themed)
            Text("\(library.count(in: group))")
                .font(.system(size: compact ? 9.5 : 10.5, weight: .medium).monospacedDigit())
                .opacity(0.65)
        }
        .lineLimit(1)
        .foregroundStyle(selected ? ReadingTheme.onAccent : Color.secondary)
        .padding(.horizontal, compact ? 10 : 12)
        .frame(height: compact ? 26 : 30)
        .background(fill, in: Capsule())
        .background {
            // 未选中的胶囊走主题玻璃（与右上角按钮同一套材质），选中的用强调色实底。
            if selected {
                Capsule().fill(ReadingTheme.accentFill)
            } else if !compact {
                ThemeSurface(shape: Capsule())
            }
        }
        .contentShape(Capsule())
    }

    /// 新建书架小弹窗（iOS 15 也能用，不依赖 alert 里的输入框）。
    private var newShelfDialog: some View {
        ZStack {
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { showsNewShelf = false } }
            VStack(alignment: .leading, spacing: 16) {
                Text("新建书架")
                    .font(AppFontStyle.system(size: 17, weight: .semibold).themed)
                TextField("输入书架名称", text: $newShelfName)
                    .font(AppFontStyle.system(size: 15).themed)
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                HStack(spacing: 8) {
                    Spacer()
                    Button("取消") {
                        withAnimation(.easeOut(duration: 0.2)) { showsNewShelf = false }
                    }
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 56, minHeight: 36)
                    Button { createShelf() } label: {
                        Text("创建").font(AppFontStyle.system(size: 15, weight: .semibold).themed)
                    }
                        .foregroundStyle(ReadingTheme.accent)
                        .frame(minWidth: 56, minHeight: 36)
                        .disabled(newShelfName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .font(AppFontStyle.system(size: 15).themed)
                .buttonStyle(.plain)
            }
            .padding(20)
            .frame(maxWidth: 300)
            .background { ThemeSurface(shape: RoundedRectangle(cornerRadius: 22, style: .continuous)) }
            .shadow(color: .black.opacity(0.18), radius: 20, y: 8)
        }
    }

    private func createShelf() {
        let name = newShelfName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.2)) { showsNewShelf = false }
        Task {
            if let existing = library.groups.first(where: { $0.groupName == name }) {
                if !existing.show { await library.setGroupVisible(existing, visible: true) }
                selectedGroupID = existing.groupId
                return
            }
            await library.createGroup(name: name)
            if let created = library.groups.first(where: { $0.groupName == name }) {
                selectedGroupID = created.groupId
            }
        }
    }

    /// 书架页视图快捷切换（与「书架设置 → 书架页视图」同一个设置）。
    private var layoutSwitcher: some View {
        let isGrid = bookshelfLayout.hasPrefix("grid")
        let isShelf = bookshelfLayout == "shelf"
        let isList = !isGrid && !isShelf
        return HStack(spacing: 2) {
            layoutSwitchButton("square.grid.2x2", label: "网格封面", selected: isGrid) {
                if !isGrid { bookshelfLayout = "grid\(BookshelfShelfSettings.lastGridCount)" }
            }
            layoutSwitchButton("list.bullet", label: "行卡列表", selected: isList) {
                if !isList { bookshelfLayout = "list" }
            }
            layoutSwitchButton("books.vertical", label: "仿真书架", selected: isShelf) {
                if !isShelf { bookshelfLayout = "shelf" }
            }
        }
        .padding(3)
        .background { ThemeSurface(shape: Capsule()) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bookshelf.layoutSwitcher")
    }

    private func layoutSwitchButton(_ systemName: String, label: String, selected: Bool,
                                    action: @escaping () -> Void) -> some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(.easeInOut(duration: 0.22)) { action() }
        } label: {
            Image(systemName: systemName)
                .font(AppFontStyle.system(size: 13, weight: selected ? .semibold : .regular).themed)
                .foregroundStyle(selected ? ReadingTheme.onAccent : Color.secondary)
                .frame(width: 34, height: 28)
                .background(selected ? ReadingTheme.accentFill : Color.clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: 网格

    /// 主题「书架」设置（列数、封面宽度）：只在所选主题启用了自定义界面设置时生效。
    private var themeShelfMetrics: ThemeShelfMetrics? {
        guard let customization = appTheme.customization else { return nil }
        return ThemeShelfMetrics(width: contentWidth + 48, customization: customization,
                                 accessibility: dynamicTypeSize.isAccessibilitySize)
    }

    private var gridColumnCount: Int {
        if let metrics = themeShelfMetrics { return metrics.columns }
        if dynamicTypeSize.isAccessibilitySize { return 2 }
        let minimum = BookshelfShelfSettings.gridCount(bookshelfLayout)
        // 宽屏自动加列：每列至少约 110pt。
        let fit = Int((contentWidth + Self.gridSpacing) / (110 + Self.gridSpacing))
        return max(minimum, fit)
    }

    private var gridSection: some View {
        let entries = folderStore.entries(for: displayedBooks, groupID: selectedGroup.groupId)
        let columns = max(gridColumnCount, 1)
        let inset: CGFloat = hideShelfBase ? 0 : 6
        let available = contentWidth - inset * 2
        let fitted = ((available - CGFloat(columns - 1) * Self.gridSpacing) / CGFloat(columns)).rounded(.down)
        let cellWidth = max(themeShelfMetrics.map { min(fitted, $0.coverWidth.rounded(.down)) } ?? fitted, 44)
        // 封面在每格里均匀铺开：多出来的宽度平均分给列间距，最后一行不满时用空位占住，
        // 保证每一列都落在同一位置。
        let spacing = columns > 1 ? max((available - cellWidth * CGFloat(columns)) / CGFloat(columns - 1), 4) : 0
        let coverHeight = BookshelfGridMetrics.coverHeight(width: cellWidth)
        let rows = stride(from: 0, to: entries.count, by: columns).map { Array(entries[$0..<min($0 + columns, entries.count)]) }
        let solid = boardStyle == "solid"
        let boardHeight: CGFloat = solid ? 12 : 5
        // 层板的台面往上伸进封面底边下面：书底压在台面上，看起来是「立在」书架上，而不是躲在书架后面。
        let tuck: CGFloat = solid ? 5 : 1
        return VStack(alignment: .leading, spacing: hideShelfBase ? 20 : 22) {
            ForEach(rows.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(rows[index]) { entry in
                        gridCell(entry, width: cellWidth)
                            .zIndex(isDragging(entry) ? 1 : 0)
                    }
                    ForEach(0..<(columns - rows[index].count), id: \.self) { _ in
                        Color.clear.frame(width: cellWidth, height: 1)
                    }
                }
                .padding(.horizontal, inset)
                .frame(width: contentWidth, alignment: columns > 1 ? .leading : .center)
                .background(alignment: .topLeading) {
                    // 书立在书板上：书板紧贴封面底边，书名和作者在书板下面。
                    if !hideShelfBase {
                        BookshelfBoard(width: contentWidth, height: boardHeight + tuck, solid: solid)
                            .offset(y: coverHeight - tuck)
                            .allowsHitTesting(false)
                    }
                }
                // 正在拖的书所在的那一行放到最上层：书拖过下面几行时不会被盖住。
                .zIndex(rows[index].contains(where: isDragging) ? 1 : 0)
            }
        }
    }

    @ViewBuilder
    private func gridCell(_ entry: BookshelfEntry, width: CGFloat) -> some View {
        switch entry {
        case .book(let book):
            BookshelfBookLink(book: book, mode: .grid(width), groupID: selectedGroup.groupId)
                // 进入 / 退出多选时整格重建：之前只有部分格子收到 isActive 变化，
                // 选择圈只出现在个别书上，点一下勾选（urls 变化）后才全部刷新出来。
                .id("\(book.bookUrl)#\(selection.isActive)")
        case .folder(let folder, let inside):
            Button {
                openFolder(folder)
            } label: {
                BookshelfFolderGridTile(folder: folder, books: inside, width: width)
            }
            .buttonStyle(.plain)
            .opacity(selection.isActive ? 0.4 : 1)
            .disabled(selection.isActive)
            .modifier(BookshelfDropTarget(id: "f:" + folder.id))
            .accessibilityLabel("文件夹「\(folder.name)」，\(inside.count) 本书")
            .accessibilityHint("轻点打开")
        }
    }

    // MARK: 列表

    private var listSection: some View {
        let entries = folderStore.entries(for: displayedBooks, groupID: selectedGroup.groupId)
        let compact = bookshelfLayout == "compact"
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(entries) { entry in
                switch entry {
                case .book(let book):
                    BookshelfBookLink(book: book, mode: compact ? .compact : .list, groupID: selectedGroup.groupId)
                        .id("\(book.bookUrl)#\(selection.isActive)")
                        .zIndex(isDragging(entry) ? 1 : 0)
                case .folder(let folder, let inside):
                    Button {
                        openFolder(folder)
                    } label: {
                        BookshelfFolderRow(folder: folder, books: inside, compact: compact)
                    }
                    .buttonStyle(.plain)
                    .opacity(selection.isActive ? 0.4 : 1)
                    .disabled(selection.isActive)
                    .modifier(BookshelfDropTarget(id: "f:" + folder.id, cornerRadius: BookshelfRow.cornerRadius))
                }
            }
        }
    }

    private func isDragging(_ entry: BookshelfEntry) -> Bool {
        guard let url = dragSession.draggingURL else { return false }
        return entry.id == "b:" + url
    }

    private func openFolder(_ folder: BookshelfFolder) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            folderStore.presentedFolderID = folder.id
        }
    }

    // MARK: 右侧切换条

    private var sideSwitcherBar: some View {
        VStack(spacing: 2) {
            ForEach(library.visibleGroups) { group in
                let isSelected = selectedGroup.id == group.id
                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    withAnimation(.easeOut(duration: 0.2)) { selectedGroupID = group.id }
                } label: {
                    Text(Self.verticalLabel(group.groupName))
                        .font(AppFontStyle.system(size: 10.5, weight: isSelected ? .semibold : .regular).themed)
                        .multilineTextAlignment(.center)
                        .lineSpacing(0)
                        .foregroundStyle(isSelected ? ReadingTheme.onAccent : Color.secondary)
                        .frame(width: 20)
                        .padding(.vertical, 6)
                        .background(isSelected ? ReadingTheme.accentFill : Color.clear, in: Capsule())
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(group.groupName)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background { ThemeSurface(shape: Capsule()) }
        .padding(.trailing, 2)
    }

    private static func verticalLabel(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.prefix(4).map(String.init).joined(separator: "\n")
    }

    /// 右上角只保留两个按钮：搜索 + 「⋯」（视图、排序、书架、导入等全部收进菜单）。
    @ViewBuilder
    private var normalHeaderButtons: some View {
        NavigationLink { SearchView() } label: {
            ReadingToolbarIcon(systemName: "magnifyingglass")
        }
        .accessibilityLabel("搜索")
        bookshelfMenu
    }

    /// 多选时右上角：全选 / 全不选。
    private var selectionHeaderButtons: some View {
        let selectable = displayedBooks.map(\.bookUrl)
        let allSelected = !selectable.isEmpty && selectable.allSatisfy { selection.urls.contains($0) }
        return Button {
            UISelectionFeedbackGenerator().selectionChanged()
            if allSelected { selection.urls.subtract(selectable) } else { selection.urls.formUnion(selectable) }
        } label: {
            Text(allSelected ? "全不选" : "全选")
                .font(AppFontStyle.subheadline.weight(.medium).themed)
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background { ThemeSurface(shape: Capsule()) }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var bookshelfMenu: some View {
        if library.isCheckingUpdates {
            ProgressView().controlSize(.small).frame(width: 44, height: 44)
        } else {
            Menu {
                Section {
                    Picker(selection: Binding(
                        get: { bookshelfLayout.hasPrefix("grid") ? "grid" : (bookshelfLayout == "shelf" ? "shelf" : "list") },
                        set: { value in
                            withAnimation(.easeInOut(duration: 0.22)) {
                                switch value {
                                case "grid": bookshelfLayout = "grid\(BookshelfShelfSettings.lastGridCount)"
                                case "shelf": bookshelfLayout = "shelf"
                                default: bookshelfLayout = "list"
                                }
                            }
                        }
                    )) {
                        Label("网格", systemImage: "square.grid.2x2").tag("grid")
                        Label("列表", systemImage: "list.bullet").tag("list")
                        Label("仿真书架", systemImage: "books.vertical").tag("shelf")
                    } label: { Label("视图", systemImage: "square.grid.2x2") }
                    Menu {
                        Picker("排序方式", selection: $sortMode) {
                            ForEach(Self.sortTitles.indices, id: \.self) { index in
                                Text(Self.sortTitles[index]).tag(index)
                            }
                        }
                        Picker("顺序", selection: $sortAscending) {
                            Text("倒序").tag(false)
                            Text("正序").tag(true)
                        }
                    } label: {
                        Label("排序：\(Self.sortTitles[min(max(sortMode, 0), 3)])", systemImage: "arrow.up.arrow.down")
                    }
                }
                Section {
                    if bookshelfLayout != "shelf" {
                        Button { selection.begin() } label: { Label("选择", systemImage: "checkmark.circle") }
                    }
                    Button {
                        Task { await library.checkForUpdates(sources: sources.sources) }
                    } label: { Label("更新目录", systemImage: "arrow.clockwise") }
                    Button { showsLocalImporter = true } label: { Label("导入本地书", systemImage: "plus") }
                }
                Section {
                    Button {
                        newShelfName = ""
                        withAnimation(.easeOut(duration: 0.2)) { showsNewShelf = true }
                    } label: { Label("新建书架", systemImage: "plus.rectangle.on.rectangle") }
                    Button { showsGroupManager = true } label: { Label("管理书架", systemImage: "rectangle.3.group") }
                    Button { showsShelfSettings = true } label: { Label("书架设置", systemImage: "slider.horizontal.3") }
                    if bookshelfLayout == "shelf" {
                        Button { showsOrnamentManager = true } label: { Label("书架摆件", systemImage: "leaf") }
                    }
                    NavigationLink {
                        FileManagementView()
                    } label: {
                        Label("文件管理", systemImage: "folder")
                    }
                }
            } label: {
                ReadingToolbarIcon(systemName: "ellipsis")
            }
            .accessibilityLabel("更多")
        }
    }

    /// 上一版把文件夹存成书架分组：改成「全部」书架里的文件夹，并删掉那些分组。
    @MainActor
    private func migrateLegacyFolders() async {
        let ids = folderStore.legacyGroupIDs
        guard library.hasLoaded, !ids.isEmpty else { return }
        let styles = Dictionary(ids.map { ($0, folderStore.legacyStyle(for: $0)) }, uniquingKeysWith: { first, _ in first })
        folderStore.clearLegacy()
        for id in ids {
            guard let group = library.groups.first(where: { $0.groupId == id }) else { continue }
            let urls = library.books.filter { ($0.group & id) != 0 }.map(\.bookUrl)
            if !urls.isEmpty {
                folderStore.makeFolder(groupID: BookGroup.idAll, bookURLs: urls, name: group.groupName,
                                       style: styles[id] ?? 0)
            }
            await library.deleteGroup(group)
        }
    }
}

/// 一本书在网格、列表、紧凑列表里的入口。
private enum BookshelfLinkMode {
    case grid(CGFloat)
    case list
    case compact

    var isCompact: Bool {
        if case .compact = self { return true }
        return false
    }

    var isGrid: Bool {
        if case .grid = self { return true }
        return false
    }
}

private struct BookshelfBookLink: View {
    let book: Book
    let mode: BookshelfLinkMode
    let groupID: Int64
    @ObservedObject private var selection = BookshelfSelection.shared
    @ObservedObject private var session = BookshelfDragSession.shared
    /// 长按浮起后手指移动的距离（书跟着手指走）。
    @State private var dragOffset: CGSize = .zero
    @State private var lifted = false
    @GestureState private var pressing = false

    @ViewBuilder private var label: some View {
        switch mode {
        case .grid(let width):
            // 选择圈直接画在封面上（每本书都有），不再靠外层叠一层按高度对齐的框。
            BookshelfGridItem(book: book, width: width,
                              selected: selection.isActive ? selection.urls.contains(book.bookUrl) : nil)
        case .list, .compact:
            BookshelfRow(book: book, compact: mode.isCompact,
                         selected: selection.isActive ? selection.urls.contains(book.bookUrl) : nil)
        }
    }

    var body: some View {
        if selection.isActive {
            // 多选时整块（封面 + 书名）都能点选：直接用点按手势，避免长按、拖动等手势把轻点吃掉。
            label
                .contentShape(Rectangle())
                .onTapGesture { selection.toggle(book.bookUrl) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAddTraits(selection.urls.contains(book.bookUrl) ? .isSelected : [])
                .accessibilityAction { selection.toggle(book.bookUrl) }
        } else {
            interactive
        }
    }

    /// 轻点打开阅读；长按浮起：原地松手弹出操作面板，拖到另一本书 / 文件夹上合并。
    private var interactive: some View {
        label
            .contentShape(Rectangle())
            .scaleEffect(lifted ? 1.06 : 1, anchor: .center)
            .shadow(color: .black.opacity(lifted ? 0.28 : 0), radius: lifted ? 12 : 0, y: lifted ? 8 : 0)
            .offset(dragOffset)
            .zIndex(lifted ? 10 : 0)
            .animation(.spring(response: 0.26, dampingFraction: 0.78), value: lifted)
            .onTapGesture {
                guard BookshelfLongPressGuard.allowsTap, !lifted else { return }
                BookshelfFolderStore.shared.openRequest = .read(book)
            }
            .gesture(pressAndDrag)
            .onChange(of: pressing) { active in
                if !active { finish() }
            }
            .modifier(BookshelfDropTarget(id: "b:" + book.bookUrl,
                                          cornerRadius: mode.isGrid ? 6 : BookshelfRow.cornerRadius))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("轻点打开阅读，长按打开操作面板，长按后拖到另一本书上可装进文件夹")
            .accessibilityAction(named: "更多操作") { BookshelfSheetRouter.shared.sheet = .actions(book) }
    }

    private var pressAndDrag: some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .updating($pressing) { value, state, _ in
                if case .second(true, _) = value { state = true }
            }
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if !lifted {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    BookshelfLongPressGuard.lift()
                    lifted = true
                    session.begin(url: book.bookUrl, groupID: groupID)
                }
                if let drag {
                    dragOffset = drag.translation
                    session.update(location: drag.location, translation: drag.translation)
                }
            }
    }

    private func finish() {
        guard lifted else { return }
        BookshelfLongPressGuard.end()
        let outcome = session.end()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
            dragOffset = .zero
            lifted = false
        }
        if outcome == .press {
            BookshelfSheetRouter.shared.sheet = .actions(book)
        }
    }
}

/// 书架置顶（长按面板「置顶」）：置顶的书在网格、列表、仿真书架里都排在最前，按置顶先后排列。
@MainActor
final class BookshelfPinStore: ObservableObject {
    static let shared = BookshelfPinStore()
    private static let storageKey = "bookshelfPinnedBooks"

    /// 置顶顺序：最近置顶的在最前。
    @Published private(set) var urls: [String]

    private init() {
        urls = UserDefaults.standard.stringArray(forKey: Self.storageKey) ?? []
    }

    func isPinned(_ url: String) -> Bool { urls.contains(url) }

    func toggle(_ url: String) {
        if let index = urls.firstIndex(of: url) {
            urls.remove(at: index)
        } else {
            urls.insert(url, at: 0)
        }
        UserDefaults.standard.set(urls, forKey: Self.storageKey)
    }

    func forget(_ url: String) {
        guard urls.contains(url) else { return }
        urls.removeAll { $0 == url }
        UserDefaults.standard.set(urls, forKey: Self.storageKey)
    }

    /// 置顶的书提到最前（保持置顶先后），其余保持原顺序。
    func pinnedFirst(_ books: [Book]) -> [Book] {
        guard !urls.isEmpty else { return books }
        var rank: [String: Int] = [:]
        for (index, url) in urls.enumerated() where rank[url] == nil { rank[url] = index }
        let pinned = books.filter { rank[$0.bookUrl] != nil }.sorted { rank[$0.bookUrl]! < rank[$1.bookUrl]! }
        guard !pinned.isEmpty else { return books }
        return pinned + books.filter { rank[$0.bookUrl] == nil }
    }

    /// 仿真书架的混排顺序里，含置顶书的项（书或装着置顶书的文件夹）提到最前。
    func rank(of urlsInItem: [String]) -> Int? {
        urlsInItem.compactMap { urls.firstIndex(of: $0) }.min()
    }
}

/// 书架上长按菜单打开的面板，由书架页（不在懒加载格子里）统一弹出。
@MainActor
final class BookshelfSheetRouter: ObservableObject {
    static let shared = BookshelfSheetRouter()

    enum Sheet: Identifiable {
        case moveToShelf(Book)
        case editInfo(Book)
        /// 长按一本书弹出的整本书操作面板（网格、列表、仿真书架共用）。
        case actions(Book)

        var id: String {
            switch self {
            case .moveToShelf(let book): "move:" + book.bookUrl
            case .editInfo(let book): "edit:" + book.bookUrl
            case .actions(let book): "actions:" + book.bookUrl
            }
        }
    }

    @Published var sheet: Sheet?
}

/// 网格尺寸：封面高宽比与书名区到封面底边的距离（让出书板的高度）。
enum BookshelfGridMetrics {
    static func coverHeight(width: CGFloat) -> CGFloat { (width / 0.7).rounded() }

    static func labelGap(hideShelfBase: Bool, boardStyle: String) -> CGFloat {
        hideShelfBase ? 8 : (boardStyle == "solid" ? 12 : 5) + 8
    }
}

/// 网格封面下方的书名与作者。
private struct BookshelfGridLabel: View {
    let title: String?
    let subtitle: String?
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let title {
                Text(title)
                    .font(AppFontStyle.system(size: width < 90 ? 12 : 13, weight: .medium).themed)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let subtitle {
                Text(subtitle)
                    .font(AppFontStyle.system(size: width < 90 ? 10 : 11).themed)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: width, alignment: .leading)
    }
}

/// 网格封面：封面立在书板上，书名和作者写在书板下方；阅读进度是封面底边的一条细线。
private struct BookshelfGridItem: View {
    let book: Book
    let width: CGFloat
    /// 多选时的选中状态；nil 表示不在多选。
    var selected: Bool? = nil
    @AppStorage(BookshelfShelfSettings.gridShowTitleKey) private var showsGridTitle = true
    @AppStorage(BookshelfShelfSettings.gridShowAuthorKey) private var showsGridAuthor = true
    @AppStorage(BookshelfShelfSettings.hideShelfBaseKey) private var hideShelfBase = true
    @AppStorage(BookshelfShelfSettings.boardStyleKey) private var boardStyle = "solid"
    @AppStorage(BookshelfShelfSettings.coverStyleKey) private var coverStyle = "flat"

    var body: some View {
        let height = BookshelfGridMetrics.coverHeight(width: width)
        VStack(alignment: .leading, spacing: 0) {
            // 封面底部不再画阅读进度条（它的半透明底轨就是每本书底下那条透明长条）。
            BookshelfCover(book: book, width: width, height: height)
                .overlay(alignment: .topTrailing) {
                    if book.lastCheckCount > 0 {
                        BookshelfUpdateBadge(count: book.lastCheckCount, compact: width < 76)
                            .offset(x: 5, y: -6)
                    }
                }
                .frame(width: width, height: height)
                // 书底贴着台面的接触阴影：让书「压」在层板上。
                .background(alignment: .bottom) {
                    if !hideShelfBase, coverStyle == "solid" {
                        Ellipse()
                            .fill(Color.black.opacity(0.32))
                            .frame(width: width * 0.96, height: 7)
                            .blur(radius: 3)
                            .offset(y: 2.5)
                            .allowsHitTesting(false)
                    }
                }
                .overlay {
                    // 多选：每本书都画选择圈（不做出入场动画，避免部分书的圈停在透明态），
                    // 选中的书再加一圈主题色描边和淡色蒙层，即使圈被遮住也看得出选没选。
                    if let selected {
                        ZStack(alignment: .bottomTrailing) {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selected ? ReadingTheme.accent.opacity(0.18) : Color.black.opacity(0.06))
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(selected ? ReadingTheme.accent : Color.clear, lineWidth: 2.5)
                            BookshelfSelectionBadge(selected: selected)
                        }
                        .frame(width: width, height: height)
                        .allowsHitTesting(false)
                        .id(selected)
                    }
                }
                .zIndex(1)
            if showsGridTitle || showsGridAuthor {
                BookshelfGridLabel(title: showsGridTitle ? book.name : nil,
                                   subtitle: showsGridAuthor ? (book.author.isEmpty ? "未知作者" : book.author) : nil,
                                   width: width)
                    .padding(.top, BookshelfGridMetrics.labelGap(hideShelfBase: hideShelfBase, boardStyle: boardStyle))
            }
        }
        .frame(width: width, alignment: .topLeading)
        .contentShape(Rectangle())
    }
}

/// 网格里的文件夹：前四本书的封面拼成一格，文件夹名与本数写在书板下方。
private struct BookshelfFolderGridTile: View {
    let folder: BookshelfFolder
    let books: [Book]
    let width: CGFloat
    @AppStorage(BookshelfShelfSettings.gridShowTitleKey) private var showsGridTitle = true
    @AppStorage(BookshelfShelfSettings.hideShelfBaseKey) private var hideShelfBase = true
    @AppStorage(BookshelfShelfSettings.boardStyleKey) private var boardStyle = "solid"

    var body: some View {
        let height = BookshelfGridMetrics.coverHeight(width: width)
        VStack(alignment: .leading, spacing: 0) {
            BookshelfFolderIcon(books: books, width: width, height: height)
                .overlay(alignment: .topLeading) {
                    Image(systemName: "folder.fill")
                        .font(AppFontStyle.system(size: 10, weight: .semibold).themed)
                        .foregroundStyle(Color.white)
                        .padding(5)
                        .background(Color.black.opacity(0.45), in: Circle())
                        .padding(5)
                }
                .frame(width: width, height: height)
            if showsGridTitle {
                BookshelfGridLabel(title: folder.name, subtitle: "\(books.count) 本", width: width)
                    .padding(.top, BookshelfGridMetrics.labelGap(hideShelfBase: hideShelfBase, boardStyle: boardStyle))
            }
        }
        .frame(width: width, alignment: .topLeading)
        .contentShape(Rectangle())
    }
}

/// 列表里的文件夹。
private struct BookshelfFolderRow: View {
    let folder: BookshelfFolder
    let books: [Book]
    let compact: Bool
    @ScaledMetric(relativeTo: .body) private var coverWidth = 52

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            BookshelfFolderIcon(books: books, width: compact ? 44 : 58, height: compact ? 62 : 84)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .font(AppFontStyle.caption.themed)
                        .foregroundStyle(ReadingTheme.accent)
                    Text(folder.name)
                        .font(AppFontStyle.body.weight(.medium).themed)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                Text("\(books.count) 本 · " + books.prefix(3).map(\.name).joined(separator: "、"))
                    .font(AppFontStyle.caption.themed).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(AppFontStyle.caption.weight(.semibold).themed)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, compact ? 9 : 10)
        .frame(maxWidth: .infinity, minHeight: compact ? 80 : 104, alignment: .leading)
        .background { ThemeCardSurface(radius: BookshelfRow.cornerRadius) }
        .contentShape(RoundedRectangle(cornerRadius: BookshelfRow.cornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("文件夹「\(folder.name)」，\(books.count) 本书")
    }
}

private struct BookshelfBookDestination: View {
    let book: Book
    let source: BookSource?

    var body: some View {
        if ProcessInfo.processInfo.arguments.contains("-uiDemo"), book.origin != "local" {
            ReaderView(demoBook: book, chapters: DemoContent.readerChapters, initialIndex: 0, content: DemoContent.readerText)
        } else {
            BookshelfReadView(book: book, source: source)
        }
    }
}

private struct ContinueReadingCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let book: Book

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if !dynamicTypeSize.isAccessibilitySize {
                BookCoverArtwork(title: book.name, author: book.author, remoteURL: book.displayCoverUrl, width: 44, height: 62)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(book.name)
                    .font(AppFontStyle.subheadline.weight(.semibold).themed)
                    .foregroundStyle(ReadingTheme.ink)
                    .lineLimit(1)
                Text(BookReadingPresentation.position(book))
                    .font(AppFontStyle.caption.themed).foregroundStyle(.secondary)
                    .lineLimit(1)
                if book.totalChapterNum > 0 {
                    HStack(spacing: 8) {
                        ReadingProgressLine(value: BookReadingPresentation.progress(book))
                        Text("\(Int((BookReadingPresentation.progress(book) * 100).rounded()))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                Text("继续")
                Image(systemName: "arrow.right")
            }
            .font(AppFontStyle.caption.weight(.semibold).themed)
            .foregroundStyle(ReadingTheme.onAccent)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(ReadingTheme.accentFill, in: Capsule())
        }
        .padding(12)
        .background { ThemeCardSurface(radius: 14) }
    }
}

/// 管理书架：拖动调整顺序、眼睛按钮显示或隐藏、轻点改名、新建书架、批量删除；齿轮进入书架设置。
private struct BookshelfManagerSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var library: BookLibraryModel
    @State private var showsCreate = false
    @State private var editingGroup: BookGroup?
    @State private var draft = ""
    @State private var dialogError: String?
    @State private var deleting = false
    @State private var marked = Set<Int64>()
    @State private var confirmsDelete = false

    private var orderedGroups: [BookGroup] {
        library.groups.sorted { $0.order == $1.order ? $0.groupId < $1.groupId : $0.order < $1.order }
    }

    private var visibleCount: Int { library.groups.filter(\.show).count }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 22)
                .padding(.bottom, 8)
            List {
                ForEach(orderedGroups) { group in
                    row(group)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 16))
                }
                .onMove { offsets, destination in
                    var ids = orderedGroups.map(\.groupId)
                    ids.move(fromOffsets: offsets, toOffset: destination)
                    Task { await library.reorderGroups(ids) }
                }
            }
            .readingScrollContentBackgroundHidden()
            .listStyle(.plain)
            if deleting {
                Button {
                    confirmsDelete = true
                } label: {
                    Text(marked.isEmpty ? "选择要删除的书架" : "删除所选书架（\(marked.count)）")
                        .font(AppFontStyle.system(size: 15, weight: .semibold).themed)
                        .foregroundStyle(marked.isEmpty ? Color.secondary : Color.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(marked.isEmpty ? Color.secondary.opacity(0.15) : ReadingTheme.coral, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(marked.isEmpty)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay {
            if showsCreate || editingGroup != nil {
                nameDialog
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: deleting)
        .animation(.easeOut(duration: 0.2), value: showsCreate)
        .animation(.easeOut(duration: 0.2), value: editingGroup?.groupId)
        .alert("删除书架", isPresented: $confirmsDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                let targets = library.groups.filter { marked.contains($0.groupId) }
                marked.removeAll()
                deleting = false
                Task {
                    for group in targets {
                        await library.deleteGroup(group)
                        for folder in BookshelfFolderStore.shared.folders(inGroup: group.groupId) {
                            BookshelfFolderStore.shared.dissolve(folder.id)
                        }
                    }
                }
            }
        } message: {
            Text("只删除书架本身，书仍在「全部」里。")
        }
        .readingSheetCanvas()
        .readingPresentationDragIndicator()
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text("管理书架")
                .font(AppFontStyle.title3.bold().themed)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button {
                draft = ""
                dialogError = nil
                showsCreate = true
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(AppFontStyle.system(size: 17).themed)
                    .frame(width: 40, height: 40)
            }
            .accessibilityLabel("新建书架")
            Button {
                deleting.toggle()
                marked.removeAll()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: deleting ? "xmark" : "trash")
                        .font(AppFontStyle.system(size: 14).themed)
                    Text(deleting ? "取消" : "批量删除")
                        .font(AppFontStyle.system(size: 14).themed)
                }
                .frame(minHeight: 40)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    private func row(_ group: BookGroup) -> some View {
        let isCustom = group.groupId > 0
        let isMarked = marked.contains(group.groupId)
        return HStack(spacing: 12) {
            if deleting {
                Button {
                    guard isCustom else { return }
                    if isMarked { marked.remove(group.groupId) } else { marked.insert(group.groupId) }
                } label: {
                    Image(systemName: isMarked ? "checkmark.circle.fill" : "circle")
                        .font(AppFontStyle.system(size: 19).themed)
                        .foregroundStyle(isMarked ? ReadingTheme.coral : Color.secondary.opacity(isCustom ? 1 : 0.35))
                        .frame(width: 26, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCustom ? (isMarked ? "取消选择" : "选择") : "系统书架不能删除")
            } else {
                Image(systemName: "line.3.horizontal")
                    .font(AppFontStyle.system(size: 14, weight: .medium).themed)
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 44)
                    .accessibilityHidden(true)
            }
            Button {
                if deleting {
                    guard isCustom else { return }
                    if isMarked { marked.remove(group.groupId) } else { marked.insert(group.groupId) }
                } else {
                    draft = group.groupName
                    dialogError = nil
                    editingGroup = group
                }
            } label: {
                Text(group.groupName)
                    .font(AppFontStyle.body.themed)
                    .foregroundStyle(group.show ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(deleting ? "" : "轻点改名，长按拖动调整顺序")
            Text("\(library.books(in: group).count) 本")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button {
                guard !(group.show && visibleCount <= 1) else { return }
                Task { await library.setGroupVisible(group, visible: !group.show) }
            } label: {
                Image(systemName: group.show ? "eye" : "eye.slash")
                    .font(AppFontStyle.system(size: 15).themed)
                    .foregroundStyle(group.show ? Color.primary : Color.secondary)
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(group.show ? "隐藏书架 \(group.groupName)" : "显示书架 \(group.groupName)")
        }
    }

    private var nameDialog: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture { closeDialog() }
            VStack(alignment: .leading, spacing: 16) {
                Text(editingGroup == nil ? "新建书架" : "重命名书架")
                    .font(AppFontStyle.system(size: 17, weight: .semibold).themed)
                TextField("输入书架名称", text: $draft)
                    .font(AppFontStyle.system(size: 15).themed)
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .onChange(of: draft) { _ in dialogError = nil }
                if let dialogError {
                    Text(dialogError)
                        .font(AppFontStyle.system(size: 12).themed)
                        .foregroundStyle(ReadingTheme.coral)
                }
                HStack(spacing: 8) {
                    Spacer()
                    Button("取消") { closeDialog() }
                        .font(AppFontStyle.system(size: 15).themed)
                        .foregroundStyle(.primary)
                        .frame(width: 64, height: 38)
                    Button(editingGroup == nil ? "创建" : "保存") { submit() }
                        .font(AppFontStyle.system(size: 15, weight: .semibold).themed)
                        .foregroundStyle(ReadingTheme.accent)
                        .frame(width: 64, height: 38)
                }
                .buttonStyle(.plain)
            }
            .padding(20)
            .frame(width: 300)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(colorScheme == .dark ? Color(white: 0.16) : Color.white)
            )
            .shadow(color: .black.opacity(0.2), radius: 22, y: 8)
            .padding(.bottom, 120)
        }
    }

    private func closeDialog() {
        showsCreate = false
        editingGroup = nil
    }

    private func submit() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            dialogError = "名称不能为空"
            return
        }
        if library.groups.contains(where: { $0.groupName == name && $0.groupId != editingGroup?.groupId }) {
            dialogError = "已经有名为「\(name)」的书架了"
            return
        }
        if let group = editingGroup {
            Task { await library.renameGroup(group, name: name) }
        } else {
            Task { await library.createGroup(name: name) }
        }
        closeDialog()
    }
}

private struct LocalBookImportReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: BookLibraryModel
    let files: [LocalBookImportFile]
    let onFinish: () -> Void
    @State private var selectedPaths: Set<String>
    @State private var isImporting = false

    private var urls: [URL] { files.map(\.url) }

    init(files: [LocalBookImportFile], onFinish: @escaping () -> Void) {
        self.files = files
        self.onFinish = onFinish
        _selectedPaths = State(initialValue: Set(files.map { $0.url.path }))
    }

    var body: some View {
        ReadingNavigationStack {
            List(urls, id: \.path) { url in
                Button {
                    if !selectedPaths.insert(url.path).inserted { selectedPaths.remove(url.path) }
                } label: {
                    HStack {
                        Image(systemName: selectedPaths.contains(url.path) ? "checkmark.square.fill" : "square")
                            .foregroundStyle(selectedPaths.contains(url.path) ? ReadingTheme.accent : .secondary)
                        VStack(alignment: .leading) {
                            Text(url.deletingPathExtension().lastPathComponent).foregroundStyle(.primary)
                            Text(url.lastPathComponent).font(AppFontStyle.caption.themed).foregroundStyle(.secondary)
                        }
                    }
                }
                .readingRowBackground()
            }.readingThemedListBackground()
            .overlay { if isImporting { ProgressView("正在导入…") } }
            .navigationTitle("导入本地书")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { finish() }.disabled(isImporting)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(selectedPaths.count == urls.count ? "取消全选" : "全选") {
                        if selectedPaths.count == urls.count { selectedPaths.removeAll() }
                        else { selectedPaths = Set(urls.map(\.path)) }
                    }
                    .disabled(isImporting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") {
                        isImporting = true
                        let selected = files.filter { selectedPaths.contains($0.url.path) }
                        Task {
                            await library.importPickedLocalFiles(selected)
                            finish()
                        }
                    }
                    .disabled(selectedPaths.isEmpty || isImporting)
                }
            }
        }
        .interactiveDismissDisabled(isImporting)
    }

    private func finish() {
        onFinish()
        dismiss()
    }
}

private struct EmptyBookshelfHero: View {
    let onImport: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "books.vertical")
                .font(AppFontStyle.system(size: 40, weight: .ultraLight).themed)
                .foregroundStyle(ReadingTheme.accent)
                .accessibilityHidden(true)
            VStack(spacing: 10) {
                Text("书架还是空的").font(AppFontStyle.title3.weight(.semibold).themed)
                Text("导入本地书，或添加书源后搜索书籍。")
                    .font(AppFontStyle.subheadline.themed).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 12) {
                Button("导入本地书", action: onImport)
                    .readingProminentButtonStyle()
                    .controlSize(.large)
                NavigationLink("添加书源") { SourceManagementView() }
                    .font(AppFontStyle.subheadline.themed)
                    .frame(minHeight: 44)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }
}

struct BookshelfReadView: View {
    let book: Book
    let source: BookSource?
    @StateObject private var model = BookshelfReadViewModel()

    var body: some View {
        Group {
            if !model.chapters.isEmpty, let resolvedBook = model.resolvedBook {
                if let source {
                    ReaderView(
                        book: resolvedBook,
                        chapters: model.chapters,
                        initialIndex: resolvedBook.durChapterIndex,
                        source: source
                    )
                } else {
                    ReaderView(book: resolvedBook, chapters: model.chapters, initialIndex: resolvedBook.durChapterIndex)
                }
            } else if let errorMessage = model.errorMessage {
                ReadingUnavailableView("无法打开书籍", systemImage: "book.closed", description: Text(errorMessage))
            } else {
                ReaderOpeningPlaceholder()
            }
        }
        .task {
            LegadoCrashLog.mark("打开书籍《\(book.name)》 来源 \(source?.bookSourceName ?? "本地")")
            await model.load(book: book, source: source)
            LegadoCrashLog.mark("目录读取完成 \(model.chapters.count) 章 错误 \(model.errorMessage ?? "无")")
        }
    }
}

/// 打开书籍时、目录还没读完的过渡页：直接用阅读背景，不出现白底和返回栏，
/// 读得快时用户看不到任何过渡；超过半秒才显示一个小的加载圈。
private struct ReaderOpeningPlaceholder: View {
    @AppStorage("readerTheme") private var theme = "wechat"
    @AppStorage("themeMode") private var themeMode = "0"
    @Environment(\.dismiss) private var dismiss
    @State private var showsSpinner = false
    @State private var backgroundImage: UIImage?

    private var style: ReaderStylePreset {
        if themeMode == "3" { return .eInk }
        return ReaderStylePreset.boundToAppTheme(themeMode: themeMode) ?? ReaderStylePreset.resolve(theme)
    }

    init() {
        let defaults = UserDefaults.standard
        let themeMode = defaults.string(forKey: "themeMode") ?? "0"
        // 旧版「使用背景图」或选中的自定义主题（浅色 / 深色）带的背景图。
        let url = themeMode == "3" ? nil
            : ReaderCustomThemeImage.activeImageURL(for: ReaderStylePreset.resolve(defaults.string(forKey: "readerTheme") ?? "wechat"))
        _backgroundImage = State(initialValue: url.flatMap { ReaderBackgroundStore.load(from: $0) })
    }

    var body: some View {
        ZStack {
            Color(uiColor: style.background)
            if let backgroundImage {
                Image(uiImage: backgroundImage).resizable().scaledToFill()
            }
            if showsSpinner {
                ProgressView()
                    .tint(Color(uiColor: style.foreground))
                    .transition(.opacity)
            }
        }
        .clipped()
        .ignoresSafeArea()
        .overlay(alignment: .topLeading) {
            // 加载较慢（需要联网刷新目录）时给出返回按钮，避免被卡在过渡页。
            if showsSpinner {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(AppFontStyle.system(size: 17, weight: .semibold).themed)
                        .foregroundStyle(Color(uiColor: style.foreground))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .padding(.leading, 6)
                .accessibilityLabel("返回")
                .transition(.opacity)
            }
        }
        .preferredColorScheme(style.isDark ? .dark : .light)
        .navigationBarBackButtonHidden(true)
        .readingTabBarHidden()
        .task {
            LegadoCrashLog.mark("过渡页出现")
            try? await Task.sleep(nanoseconds: 500_000_000)
            withAnimation(.easeIn(duration: 0.2)) { showsSpinner = true }
        }
    }
}

/// 列表视图的一行：圆角卡片，左边封面（右上角有更新标记），右边书名、作者 · 未读章数、读至哪一章、最新章节。
private struct BookshelfRow: View {
    static let cornerRadius: CGFloat = 16
    let book: Book
    var compact = false
    /// 多选时是否已选中；nil 表示不在多选。
    var selected: Bool? = nil
    @Environment(\.appTheme) private var appTheme

    /// 外观主题「书架 → 显示标签」：来源（在线 / 本地）与分类。
    private var tags: [String] {
        let custom = appTheme.customization ?? ThemeCustomization()
        guard custom.shelfShowTags else { return [] }
        var result = [book.origin == "local" ? "本地" : "在线"]
        let separators: Set<Character> = [",", "，", "/", " ", "　", "|", "、", ";", "；"]
        for word in (book.kind ?? "").split(whereSeparator: { separators.contains($0) }) {
            let value = String(word).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.count <= 6, !result.contains(value) else { continue }
            result.append(value)
            if result.count >= 3 { break }
        }
        return result
    }

    private var started: Bool {
        book.durChapterIndex > 0 || book.durChapterPos > 0 || book.durChapterTime > 0
            || !(book.durChapterTitle ?? "").isEmpty
    }

    private var statusLine: String {
        let author = book.author.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = author.isEmpty ? "作者未知" : author
        let status: String
        if !started {
            status = "未读过"
        } else if book.totalChapterNum > 0 {
            let remaining = book.totalChapterNum - book.durChapterIndex - 1
            status = remaining > 0 ? "\(remaining)章未读" : "已读完"
        } else {
            status = "阅读中"
        }
        return "\(name) · \(status)"
    }

    private var currentLine: String? {
        guard started else { return nil }
        if let title = book.durChapterTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return "读至 " + title
        }
        return "读至 第\(book.durChapterIndex + 1)章"
    }

    private var latestLine: String {
        if let title = book.latestChapterTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        return "暂无章节信息"
    }

    var body: some View {
        let coverWidth: CGFloat = compact ? 44 : 58
        let coverHeight: CGFloat = compact ? 62 : 84
        HStack(alignment: .center, spacing: 12) {
            BookshelfCover(book: book, width: coverWidth, height: coverHeight)
                .frame(width: coverWidth, height: coverHeight)
                .overlay(alignment: .topTrailing) {
                    if book.lastCheckCount > 0 {
                        BookshelfUpdateBadge(count: book.lastCheckCount, compact: true)
                            .offset(x: 6, y: -6)
                    }
                }
            VStack(alignment: .leading, spacing: compact ? 4 : 7) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(book.name)
                            .font(AppFontStyle.headline.themed)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        ForEach(Array(tags.enumerated()), id: \.offset) { index, tag in
                            BookshelfTagChip(text: tag, index: index)
                        }
                    }
                    detail(statusLine)
                }
                if let currentLine { detail(currentLine) }
                if !compact { detail(latestLine) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let selected {
                BookshelfSelectionBadge(selected: selected)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, compact ? 9 : 10)
        .frame(maxWidth: .infinity, minHeight: compact ? 80 : 104, alignment: .leading)
        .background { ThemeCardSurface(radius: Self.cornerRadius) }
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityValue(book.lastCheckCount > 0 ? "有 \(book.lastCheckCount) 章更新" : "")
    }

    private func detail(_ text: String) -> some View {
        Text(text)
            .font(AppFontStyle.subheadline.themed)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

/// 书架列表里的小标签；颜色跟随外观主题「书架 → 文字颜色」（彩色 / 文字色 / 自定义）。
struct BookshelfTagChip: View {
    let text: String
    var index = 0
    @Environment(\.appTheme) private var appTheme

    private static let colorful: [Color] = [
        Color(red: 0.0, green: 0.48, blue: 1.0), Color(red: 0.2, green: 0.7, blue: 0.35),
        Color(red: 1.0, green: 0.58, blue: 0.0), Color(red: 0.69, green: 0.32, blue: 0.87)
    ]

    private var color: Color {
        let custom = appTheme.customization ?? ThemeCustomization()
        switch custom.shelfTagColor {
        case .colorful: return Self.colorful[index % Self.colorful.count]
        case .text: return ReadingTheme.secondaryInk
        case .custom: return AppThemeColor.color(custom.shelfTagCustomColor)
        }
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .fixedSize()
    }
}

/// 封面右上角的更新标记：暖红渐变胶囊、白描边，带一点投影。
struct BookshelfUpdateBadge: View {
    let count: Int
    var compact = false

    var body: some View {
        let number = count > 99 ? "99+" : "\(count)"
        HStack(spacing: 2) {
            if !compact {
                Image(systemName: "sparkle")
                    .font(.system(size: 7.5, weight: .heavy))
            }
            Text(compact ? number : "更新 \(number)")
                .font(.system(size: compact ? 9.5 : 9.5, weight: .bold).monospacedDigit())
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, compact ? 5 : 6)
        .frame(minWidth: 17, minHeight: 17)
        .background(
            Capsule().fill(LinearGradient(colors: [Color(red: 1.0, green: 0.46, blue: 0.33),
                                                   Color(red: 0.93, green: 0.22, blue: 0.32)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(Capsule().strokeBorder(Color.white, lineWidth: 1.2))
        .shadow(color: Color(red: 0.93, green: 0.22, blue: 0.32).opacity(0.35), radius: 3, y: 1.5)
        .fixedSize()
        .allowsHitTesting(false)
        .accessibilityLabel("更新 \(count) 章")
    }
}

/// 仿真书架书脊右上角的更新小圆点：暖红渐变、白描边、微微发光。
struct BookshelfUpdateDot: View {
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [Color(red: 1.0, green: 0.55, blue: 0.40),
                                          Color(red: 0.93, green: 0.20, blue: 0.30)],
                                 center: .topLeading, startRadius: 0, endRadius: size))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.95), lineWidth: max(size * 0.14, 1)))
            .frame(width: size, height: size)
            .shadow(color: Color(red: 0.93, green: 0.20, blue: 0.30).opacity(0.6), radius: 2.5)
    }
}

/// 搜索页（功能与布局按 bookon 的搜索页搬运）：
/// - 顶部常驻输入框（不再使用系统搜索栏，清除、聚焦都不会让下面的内容上下跳动）；
/// - 四个选项：分组（记住）、精确（记住）、单源（每次重新指定）、不聚合（记住）；改了选项且已有结果时自动按新条件重搜；
/// - 搜索历史以胶囊呈现，自动换行；点胶囊再次搜索，胶囊里的 × 删除单条，清空需确认；
/// - 进度显示「已完成/总数，找到 N 本，K 个书源失败」，搜索中可随时停止。
struct SearchView: View {
    @EnvironmentObject private var library: SourceLibraryModel
    @ThemePalette private var palette
    let fixedSource: BookSource?
    private let initialKeyword: String
    @State private var keyword: String
    @StateObject private var model = SearchViewModel()
    @State private var showsScope = false
    @State private var selectedGroups = Set<String>()
    @State private var selectedSourceID: String?
    @State private var didStartInitialSearch = false
    @State private var confirmsClearHistory = false
    @FocusState private var fieldFocused: Bool
    @AppStorage("precisionSearch") private var precisionSearch = false
    @AppStorage("search.scope.group") private var scopeGroup = ""
    @AppStorage("search.noAggregate") private var noAggregate = false

    init(fixedSource: BookSource? = nil, initialKeyword: String = "") {
        self.fixedSource = fixedSource
        self.initialKeyword = initialKeyword
        _keyword = State(initialValue: initialKeyword)
    }

    var body: some View {
        searchContent.environment(\.themePageScope, .search)
    }

    @ViewBuilder
    private var searchContent: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                header
                switch model.state {
                case .idle:
                    idleContent
                case .searching where model.books.isEmpty:
                    initialLoadingView
                case .unavailable:
                    unavailableView
                case .empty:
                    emptyResultsView
                case .searching, .finished:
                    resultsContent
                }
                if model.state != .searching, !model.diagnostics.isEmpty { diagnosticsCard }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .readingCanvas()
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .readingScrollDismissesKeyboard()
        .onDisappear {
            if model.state == .searching || model.isLoadingMore { model.cancel() }
        }
        .onChange(of: keyword) { value in
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model.cancel(reset: true)
            }
        }
        .onChange(of: library.sources.count) { _ in
            normalizeScope()
            guard !didStartInitialSearch,
                  !initialKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !library.sources.isEmpty else { return }
            didStartInitialSearch = true
            startSearch()
        }
        .onChange(of: scopeGroup) { _ in rerun() }
        .onChange(of: selectedSourceID) { _ in rerun() }
        .onChange(of: selectedGroups) { _ in rerun() }
        .onChange(of: precisionSearch) { _ in rerun() }
        .onChange(of: noAggregate) { value in model.setAggregate(!value) }
        .task {
            normalizeScope()
            await model.loadSearchKeywords()
            // 进入搜索页不自动弹出键盘，点输入框再输入。
            if !initialKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !library.sources.isEmpty, !didStartInitialSearch {
                didStartInitialSearch = true
                startSearch()
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 4) {
                    if model.state == .searching || model.isLoadingMore {
                        Button("停止") { model.cancel() }
                            .accessibilityIdentifier("search.stop")
                    }
                    Menu {
                        Button("选择分组或书源", systemImage: "scope") { showsScope = true }
                        NavigationLink {
                            SourceManagementView()
                        } label: {
                            Label("书源管理", systemImage: "network")
                        }
                        if model.state == .searching {
                            Button("停止搜索", systemImage: "stop.fill", role: .destructive) {
                                model.cancel()
                            }
                        } else if model.isPaused {
                            Button("继续搜索", systemImage: "play.fill") { model.resume() }
                        }
                    } label: {
                        Label("搜索选项", systemImage: "slider.horizontal.3")
                    }
                    .accessibilityLabel("搜索选项")
                    .accessibilityIdentifier("search.options")
                }
            }
        }
        .sheet(isPresented: $showsScope) {
            SearchScopeSheet(
                sources: library.sources.filter(\.enabled),
                groups: library.visibleGroups,
                selectedGroups: $selectedGroups,
                selectedSourceID: $selectedSourceID
            )
        }
        .alert("清空搜索历史？", isPresented: $confirmsClearHistory) {
            Button("清空全部记录", role: .destructive) { Task { await model.clearSearchKeywords() } }
            Button("取消", role: .cancel) {}
        } message: { Text("仅删除本机搜索记录，不影响书架和阅读进度。") }
    }

    // MARK: 顶部：输入框 + 四个选项

    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(palette.secondary)
                    .accessibilityHidden(true)
                TextField("书名或作者", text: $keyword)
                    .focused($fieldFocused)
                    .submitLabel(.search)
                    .onSubmit { startSearch() }
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .accessibilityIdentifier("search.field")
                if !keyword.isEmpty {
                    Button {
                        // 只清空文字、保留键盘：输入框位置固定，内容不会上下跳动。
                        keyword = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(palette.secondary)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除输入")
                }
            }
            .font(AppFontStyle.body.themed)
            .padding(.leading, 14)
            .padding(.trailing, keyword.isEmpty ? 14 : 6)
            .frame(minHeight: 44)
            .modifier(ShelfGlass(shape: Capsule(), isCard: true))

            if fixedSource == nil {
                HStack(spacing: 8) {
                    Menu {
                        Picker("分组", selection: groupSelection) {
                            Text("全部分组").tag("")
                            ForEach(availableGroups, id: \.self) { Text($0).tag($0) }
                        }
                    } label: {
                        optionLabel(groupTitle, symbol: "square.stack.3d.up",
                                    active: (!scopeGroup.isEmpty || !selectedGroups.isEmpty) && selectedSourceID == nil)
                    }
                    .accessibilityIdentifier("search.group")
                    optionToggle("精确", isOn: $precisionSearch, id: "search.precision")
                    Menu {
                        Picker("书源", selection: sourceSelection) {
                            Text("全部书源").tag("")
                            ForEach(searchableSources) { Text($0.bookSourceName).tag($0.id) }
                        }
                    } label: {
                        optionLabel(searchableSources.first { $0.id == selectedSourceID }?.bookSourceName ?? "单源",
                                    symbol: "scope", active: selectedSourceID != nil)
                    }
                    .accessibilityIdentifier("search.single")
                    optionToggle("不聚合", isOn: $noAggregate, id: "search.noAggregate")
                }
            }
        }
        .padding(.bottom, 4)
    }

    private func optionLabel(_ title: String, symbol: String, active: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(AppFontStyle.system(size: 12, weight: .semibold).themed)
            Text(title).lineLimit(1).minimumScaleFactor(0.75)
        }
        .font(AppFontStyle.footnote.themed)
        .foregroundStyle(active ? palette.accent : palette.primary)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 34)
        .modifier(ShelfGlass(shape: Capsule(), isCard: true))
        .overlay {
            if active { Capsule().strokeBorder(palette.accent.opacity(0.6), lineWidth: 1) }
        }
        .contentShape(Capsule())
    }

    private func optionToggle(_ title: String, isOn: Binding<Bool>, id: String) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            optionLabel(title, symbol: isOn.wrappedValue ? "checkmark.circle.fill" : "circle", active: isOn.wrappedValue)
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOn.wrappedValue ? "已开启" : "已关闭")
        .accessibilityIdentifier(id)
    }

    private var searchableSources: [BookSource] {
        library.sources.filter { $0.enabled && $0.searchUrl?.isEmpty == false }
    }

    private var availableGroups: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for source in searchableSources {
            for group in source.groups where !group.isEmpty && !library.hiddenGroups.contains(group)
                && seen.insert(group).inserted {
                out.append(group)
            }
        }
        return out
    }

    private var groupTitle: String {
        if !scopeGroup.isEmpty { return scopeGroup }
        if selectedGroups.count == 1, let only = selectedGroups.first { return only }
        if selectedGroups.count > 1 { return "\(selectedGroups.count) 个分组" }
        return "全部分组"
    }

    private var groupSelection: Binding<String> {
        Binding(get: { scopeGroup }, set: { value in
            selectedGroups = []
            selectedSourceID = nil
            scopeGroup = value
        })
    }

    private var sourceSelection: Binding<String> {
        Binding(get: { selectedSourceID ?? "" }, set: { value in
            selectedSourceID = value.isEmpty ? nil : value
        })
    }

    /// 记住的分组已不存在（书源被删或改组）时回到全部分组。
    private func normalizeScope() {
        guard !library.sources.isEmpty else { return }
        if !scopeGroup.isEmpty, !availableGroups.contains(scopeGroup) { scopeGroup = "" }
    }

    /// 改了范围或选项后，已有结果或正在搜索时自动按新条件重搜。
    private func rerun() {
        guard !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              model.state != .idle else { return }
        startSearch()
    }

    @ViewBuilder
    private var idleContent: some View {
        HStack(spacing: 6) {
            Image(systemName: "books.vertical").font(AppFontStyle.caption.themed)
            Text("\(searchableSourceCount) 个书源 · \(scopeDisplay)")
                .font(AppFontStyle.caption.themed)
            Spacer(minLength: 0)
        }
        .foregroundStyle(palette.secondary)
        .padding(.horizontal, 4)
        searchHistoryView
    }

    private var initialLoadingView: some View {
        VStack(spacing: 12) {
            ReadingCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.regular)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("正在搜索“\(model.submittedKeyword)”").font(AppFontStyle.headline.themed)
                            Text(searchProgressText).font(AppFontStyle.caption.themed).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("停止", role: .destructive) { model.cancel() }
                            .font(AppFontStyle.subheadline.weight(.medium).themed)
                    }
                    ProgressView(value: searchProgress)
                        .tint(ReadingTheme.accent)
                    Text("结果会在书源返回后立即显示，无需等待全部完成。")
                        .font(AppFontStyle.caption.themed).foregroundStyle(.secondary)
                }
            }
            ForEach(0..<2, id: \.self) { _ in SearchLoadingRow() }
        }
    }

    private var resultsContent: some View {
        Group {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("“\(model.submittedKeyword)”").font(AppFontStyle.headline.themed).lineLimit(1)
                        Text(model.isShowingCachedResults
                             ? (model.state == .searching ? "已显示缓存结果，正在更新书源" : "已显示缓存结果")
                             : resultSummary)
                            .font(AppFontStyle.caption.themed).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.isPaused {
                        Button("继续", systemImage: "play.fill") { model.resume() }
                            .readingSecondaryButtonStyle()
                            .controlSize(.small)
                    } else if model.state == .searching {
                        StatusPill(text: "\(model.completedSourceCount)/\(model.totalSourceCount)", systemImage: "magnifyingglass")
                    } else {
                        StatusPill(text: scopeDisplay, systemImage: "scope")
                    }
                }
                if model.state == .searching {
                    ProgressView(value: searchProgress).tint(ReadingTheme.accent)
                }
            }
            .padding(.vertical, 4)

            ForEach(model.books) { book in
                if let source = library.sources.first(where: { $0.bookSourceUrl == book.origin }) {
                    NavigationLink {
                        BookDetailView(searchBook: book, source: source)
                    } label: {
                        SearchBookRow(book: book)
                    }
                    .buttonStyle(.plain)
                    .onAppear { loadMoreIfNeeded(book) }
                } else {
                    SearchBookRow(book: book)
                        .onAppear { loadMoreIfNeeded(book) }
                }
            }
            if model.isLoadingMore {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在查找更多结果…").font(AppFontStyle.subheadline.themed).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else if !model.hasMore, model.state == .finished {
                Text("已经到底了")
                    .font(AppFontStyle.caption.themed).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
        }
    }

    private var emptyResultsView: some View {
        SearchStateCard(
            title: model.isPaused ? "搜索已停止" : "没有找到“\(model.submittedKeyword)”",
            detail: emptyResultsDetail,
            systemImage: model.isPaused ? "pause.circle" : "book.closed"
        ) {
            if model.isPaused {
                Button("继续搜索", systemImage: "play.fill") { model.resume() }
                    .readingProminentButtonStyle()
            }
            Button("修改关键词", systemImage: "text.cursor") { fieldFocused = true }
                .readingSecondaryButtonStyle()
        }
    }

    private var unavailableView: some View {
        SearchStateCard(
            title: "当前范围没有可搜索书源",
            detail: "请启用带搜索规则的书源，或调整当前搜索范围。",
            systemImage: "network.slash"
        ) {
            Button("调整范围", systemImage: "scope") { showsScope = true }
                .readingProminentButtonStyle()
            NavigationLink {
                SourceManagementView()
            } label: {
                Label("管理书源", systemImage: "network")
            }
            .readingSecondaryButtonStyle()
        }
    }

    private var resultSummary: String {
        var parts = [model.state == .searching
                     ? "\(model.completedSourceCount)/\(model.totalSourceCount)，找到 \(model.books.count) 本"
                     : "找到 \(model.books.count) 本"]
        let failed = Set(model.diagnostics.map(\.message)).count
        if failed > 0 { parts.append("\(failed) 个书源未返回") }
        parts.append(noAggregate ? "未聚合" : "已合并重复来源")
        return parts.joined(separator: "，")
    }

    private var searchProgress: Double {
        guard model.totalSourceCount > 0 else { return 0 }
        return Double(model.completedSourceCount) / Double(model.totalSourceCount)
    }

    private var emptyResultsDetail: String {
        if model.isPaused { return "你可以继续搜索剩余书源，或修改关键词重新搜索。" }
        if precisionSearch { return "试试更短的书名、作者名，或关闭精准搜索。" }
        return "试试更短的书名、作者名，或调整搜索范围。"
    }

    private var searchProgressText: String {
        model.completedSourceCount == 0
            ? "正在连接 \(model.totalSourceCount) 个书源"
            : "已完成 \(model.completedSourceCount) / \(model.totalSourceCount) 个书源"
    }

    private var searchableSourceCount: Int {
        scopedSources.filter { $0.enabled && $0.searchUrl?.isEmpty == false }.count
    }

    private func loadMoreIfNeeded(_ book: SearchBook) {
        if model.state != .searching, book.id == model.books.last?.id { model.loadMore() }
    }

    private var diagnosticsCard: some View {
        DisclosureGroup("部分书源未返回结果（\(model.diagnostics.count)）") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.diagnostics.prefix(20)) { diagnostic in
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(diagnostic.message).font(AppFontStyle.subheadline.themed)
                            Text(diagnostic.code).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.top, 10)
        }
        .padding(16)
        .background { ThemeCardSurface(radius: 18) }
    }

    private var searchHistoryView: some View {
        ReadingCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("搜索历史").font(AppFontStyle.subheadline.weight(.semibold).themed)
                    Spacer()
                    if !model.searchKeywords.isEmpty {
                        Button("清空") { confirmsClearHistory = true }
                            .font(AppFontStyle.subheadline.themed)
                            .buttonStyle(.plain)
                            .foregroundStyle(palette.accent)
                            .accessibilityIdentifier("searchHistory.clear")
                    }
                }
                if model.searchKeywords.isEmpty {
                    Text("暂无搜索记录").font(AppFontStyle.subheadline.themed).foregroundStyle(palette.secondary)
                        .accessibilityIdentifier("searchHistory.empty")
                } else if #available(iOS 16.0, *) {
                    SearchHistoryFlow(spacing: 8) {
                        ForEach(model.searchKeywords) { item in historyChip(item.word) }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.searchKeywords) { item in historyChip(item.word) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func historyChip(_ query: String) -> some View {
        HStack(spacing: 2) {
            Button { keyword = query; startSearch() } label: {
                Text(query).font(AppFontStyle.subheadline.themed).foregroundStyle(palette.primary)
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.leading, 13).padding(.trailing, 4).padding(.vertical, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("再次搜索：" + query)
            .accessibilityIdentifier("searchHistory.query." + query)
            Button { Task { await model.deleteSearchKeyword(query) } } label: {
                Image(systemName: "xmark").font(AppFontStyle.system(size: 10, weight: .semibold).themed)
                    .foregroundStyle(palette.secondary)
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
            .accessibilityLabel("删除搜索记录：" + query)
            .accessibilityIdentifier("searchHistory.delete." + query)
        }
        .modifier(ShelfGlass(shape: Capsule()))
    }

    private var scopedSources: [BookSource] {
        if var fixedSource { fixedSource.enabled = true; return [fixedSource] }
        let enabled = library.sources.filter(\.enabled)
        if let selectedSourceID { return enabled.filter { $0.id == selectedSourceID } }
        let groups = activeGroups
        guard !groups.isEmpty else { return enabled }
        return enabled.filter { source in groups.contains(where: source.hasGroup) }
    }

    /// 顶部「分组」选项（记住）与「分组或书源」面板里多选的分组。
    private var activeGroups: Set<String> {
        scopeGroup.isEmpty ? selectedGroups : selectedGroups.union([scopeGroup])
    }

    private var scopeDisplay: String {
        if let fixedSource { return fixedSource.bookSourceName }
        if let selectedSourceID, let source = library.sources.first(where: { $0.id == selectedSourceID }) { return source.bookSourceName }
        return activeGroups.isEmpty ? "全部书源" : activeGroups.sorted().joined(separator: ",")
    }

    private func startSearch() {
        let value = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        fieldFocused = false
        model.search(keyword: value, sources: scopedSources, precision: precisionSearch, aggregate: !noAggregate)
    }
}

/// 胶囊自动换行布局：一行放不下就换到下一行，行高取该行最高的胶囊。
@available(iOS 16.0, *)
private struct SearchHistoryFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var width: CGFloat = 0, rowWidth: CGFloat = 0, rowHeight: CGFloat = 0, height: CGFloat = 0
        for view in subviews {
            var size = view.sizeThatFits(.unspecified)
            size.width = min(size.width, maxWidth)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                width = max(width, rowWidth)
                height += rowHeight + spacing
                rowWidth = 0; rowHeight = 0
            }
            rowWidth += rowWidth == 0 ? size.width : size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        width = max(width, rowWidth)
        height += rowHeight
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            var size = view.sizeThatFits(.unspecified)
            size.width = min(size.width, bounds.width)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private struct SearchLoadingRow: View {
    var body: some View {
        ReadingCard {
            HStack(spacing: 15) {
                RoundedRectangle(cornerRadius: 8).fill(.secondary.opacity(0.12)).frame(width: 58, height: 82)
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 4).fill(.secondary.opacity(0.14)).frame(width: 150, height: 14)
                    RoundedRectangle(cornerRadius: 4).fill(.secondary.opacity(0.1)).frame(width: 90, height: 11)
                    RoundedRectangle(cornerRadius: 4).fill(.secondary.opacity(0.08)).frame(maxWidth: .infinity).frame(height: 11)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct SearchStateCard<Actions: View>: View {
    let title: String
    let detail: String
    let systemImage: String
    @ViewBuilder let actions: Actions

    var body: some View {
        ReadingCard {
            VStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(AppFontStyle.system(size: 32).themed)
                    .foregroundStyle(ReadingTheme.accent)
                    .frame(width: 64, height: 64)
                    .background(ReadingTheme.accentSoft.opacity(0.5), in: Circle())
                VStack(spacing: 5) {
                    Text(title).font(AppFontStyle.headline.themed).multilineTextAlignment(.center)
                    Text(detail).font(AppFontStyle.subheadline.themed).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                HStack(spacing: 10) { actions }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
    }
}

private struct SearchBookRow: View {
    @ThemePalette private var palette
    let book: SearchBook

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            BookCoverArtwork(
                title: book.name,
                author: book.author,
                remoteURL: book.coverURL,
                width: 52,
                height: 74
            )
            VStack(alignment: .leading, spacing: 6) {
                Text(book.name).font(AppFontStyle.body.weight(.medium).themed).foregroundStyle(.primary).lineLimit(2)
                Text(book.author.isEmpty ? "未知作者" : book.author)
                    .font(AppFontStyle.caption.themed).foregroundStyle(.secondary)
                if let latest = book.latestChapterTitle, !latest.isEmpty {
                    Text(latest)
                        .font(AppFontStyle.caption.themed).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(book.origins.count > 1
                         ? "来源：\(book.originName) 等 \(book.origins.count) 个书源"
                         : "来源：" + book.originName)
                        .lineLimit(1)
                    if let wordCount = book.wordCount, !wordCount.isEmpty {
                        Text("·")
                        Text(wordCount).lineLimit(1)
                    }
                }
                .font(AppFontStyle.caption.themed)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(AppFontStyle.caption.bold().themed).foregroundStyle(.tertiary)
        }
        .padding(14)
        .background {
            ThemeSurface(shape: RoundedRectangle(cornerRadius: palette.cornerRadius(default: AppLayout.radiusCard),
                                                 style: .continuous), isCard: true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct SettingsView: View {
    @ThemePalette private var palette
    @ObservedObject private var fonts = ReadingFontManager.shared
    @EnvironmentObject private var activity: ReadingActivityModel
    @EnvironmentObject private var library: BookLibraryModel
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("themeMode") private var themeMode = "0"
    @ScaledMetric(relativeTo: .body) private var rowHeight = 52
    /// 换界面字体后应用整体刷新：重新打开字体管理（不带推入动画）。
    @State private var reopensFonts = false
    @State private var reopenedFontPart: FontManagementView.Part = .interface

    var body: some View {
        // 标题固定在顶部、只滚下面的设置（与书架 / 发现 / 统计一致，仿 bookon）：
        // 不再铺装饰插画和渐变色带，下拉时背景纹丝不动，不会露出主题色，照片背景也不会被插画盖住。
        // 顶部只保留大标题（随内容滚动），上滑后顶部栏淡入小标题，仿系统大标题导航的上滑效果。
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    ReadingLargeTitle(title: "我的")
                        .padding(.bottom, -10)
                    readingSection
                    rulesSection
                    settingSection("文件与存储") {
                        settingLink("文件管理", icon: "folder", showsSeparator: false) {
                            FileManagementView()
                        }
                    }
                    supportSection
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .readingTopScrollEdgeHidden()
            .accessibilityIdentifier("profile.scroll")
        }
        .readingCanvas()
        .readingLargeTitleBar(title: "我的")
        .navigationBarHidden(true)
        .readingNavigationDestination(isPresented: $reopensFonts) {
            FontManagementView(initialPart: reopenedFontPart)
        }
        .onAppear {
            guard let part = FontManagementRestore.pendingPart else { return }
            FontManagementRestore.pendingPart = nil
            reopenedFontPart = part
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { reopensFonts = true }
        }
    }

    private var readingSection: some View {
        settingSection("阅读") {
            settingLink("阅读设置", icon: "textformat.size") { ReaderSettingsPage() }
            // 字体管理：书籍字体 + 界面字体，右侧显示已导入的字体数量。
            NavigationLink { FontManagementView() } label: {
                settingRow("字体管理", icon: "f.cursive", value: "\(fonts.importedFonts.count) 个")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("profile.fonts")
            appearanceEntry
            .accessibilityLabel("外观")
            .accessibilityValue(appearanceTitle)
            .accessibilityIdentifier("profile.appearance")
            settingLink("朗读", icon: "waveform") { HttpTTSManagementView() }
            settingLink("书签", icon: "bookmark") { AllBookmarksView() }
            settingLink("阅读记录", icon: "clock", showsSeparator: false) {
                ReadingHistoryView()
            }
        }
    }

    private var rulesSection: some View {
        settingSection("书源与规则") {
            settingLink("书源管理", icon: "globe") { SourceManagementView() }
            settingLink("规则订阅", icon: "link") { RuleSubscriptionView() }
            settingLink("替换净化", icon: "text.badge.checkmark") { ReplaceRuleManagementView() }
            settingLink("TXT 目录规则", icon: "list.bullet.rectangle", showsSeparator: false) {
                TxtTocRuleManagementView()
            }
        }
    }

    private var supportSection: some View {
        settingSection("更多") {
            settingLink("其他设置", icon: "gearshape") { OtherSettingsView() }
            settingLink("关于", icon: "info.circle", showsSeparator: false) { AboutView() }
        }
    }

    /// 打开「外观主题」（所有系统版本都可用）。
    private var appearanceEntry: some View {
        Button { AppearanceHubPresenter.shared.isPresented = true } label: {
            settingRow("外观主题", icon: "circle.lefthalf.filled",
                       value: appearanceThemeName,
                       showsValuePill: true)
        }
        .buttonStyle(.plain)
    }

    /// 外观主题行右侧显示的名称：选了「主题切换」配色（如琥珀金）时显示配色名，
    /// 否则显示主题名（去掉自动生成的「· 我的外观」后缀）。
    private var appearanceThemeName: String {
        let theme = AppThemeStore.shared.selectedTheme
        if let custom = theme.customization, let light = ThemeColorPreset.find(custom.colorThemeID, in: custom) {
            if custom.separateDarkTheme, let dark = ThemeColorPreset.find(custom.darkColorThemeID, in: custom), dark.id != light.id {
                return "\(light.name) · \(dark.name)"
            }
            return light.name
        }
        let name = theme.name.replacingOccurrences(of: " · 我的外观", with: "")
        return name.isEmpty ? theme.name : name
    }

    private var appearanceTitle: String {
        switch themeMode {
        case "1": "浅色"
        case "2": "深色"
        case "3": "E-Ink 模式"
        default: "跟随系统"
        }
    }

    private func settingSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(AppFontStyle.body.themed)
                .foregroundStyle(ProfileTheme.secondary)
                .accessibilityAddTraits(.isHeader)
            // 和「外观主题」页一样：每一项是一条独立的圆角小卡片，项与项之间留 8pt 间距（不再整组装进一张卡片）。
            VStack(spacing: 8, content: content)
        }
    }

    private func settingLink<Destination: View>(
        _ title: String,
        icon: String,
        showsSeparator: Bool = true,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink(destination: destination) {
            settingRow(title, icon: icon, showsSeparator: showsSeparator)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("profile.\(icon)")
    }

    private func settingRow(
        _ title: String,
        icon: String,
        value: String? = nil,
        showsValuePill: Bool = false,
        isExternal: Bool = false,
        showsSeparator: Bool = true
    ) -> some View {
        // 外观主题同款行卡片（AppearanceCard）：圆角、高度、内边距和卡片底一致，跟随「界面效果」三种模式。
        AppearanceCard {
            HStack(spacing: 18) {
                ProfileSettingIcon(systemName: icon)
                    .frame(width: 26, height: 24)
                    .accessibilityHidden(true)
                Text(title)
                    .font(AppFontStyle.body.themed)
                    .foregroundStyle(ProfileTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let value {
                    Text(value)
                        .font(AppFontStyle.footnote.themed)
                        .foregroundStyle(ProfileTheme.secondary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, showsValuePill ? 10 : 0)
                        .padding(.vertical, showsValuePill ? 4 : 0)
                        .overlay {
                            if showsValuePill {
                                Capsule().strokeBorder(ProfileTheme.separator, lineWidth: 0.5)
                            }
                        }
                }
                Image(systemName: isExternal ? "arrow.up.right" : "chevron.right")
                    .font(AppFontStyle.caption.weight(.medium).themed)
                    .foregroundStyle(ProfileTheme.secondary.opacity(0.65))
                    .accessibilityHidden(true)
            }
            .frame(minHeight: max(0, rowHeight - 22))
        }
        .accessibilityElement(children: .combine)
    }
}

private enum ProfileTheme {
    static var canvas: Color { ReadingTheme.canvas }
    static var surface: Color { ReadingTheme.surface }
    static var appCardTint: Color { AppThemeRuntime.color { AppThemeColor.mix($0.surface, $0.accent, fraction: 0.06) } }
    static var ink: Color { ReadingTheme.ink }
    static var secondary: Color { ReadingTheme.secondaryInk }
    static let detail = adaptive(0xBA916B, dark: 0xD1AB84)
    static var separator: Color { ReadingTheme.separator }

    private static func adaptive(_ light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255,
                alpha: 1
            )
        })
    }
}

private struct ProfileSettingIcon: View {
    let systemName: String
    /// 跟随主题刷新：选了「主题切换」里的配色（如琥珀金）时，图标改用主题强调色。
    @ThemePalette private var palette
    @Environment(\.appTheme) private var theme

    private var hasColorPreset: Bool { theme.customization?.colorThemeID != nil }

    /// 选了配色：图标主体用强调色、点缀用强调色的浅色；没选配色（经典黑白等）保持原来的墨色 + 暖棕点缀。
    private var ink: Color { hasColorPreset ? palette.accent : ProfileTheme.ink }
    private var detail: Color { hasColorPreset ? palette.accent.opacity(0.55) : ProfileTheme.detail }

    var body: some View {
        let ink = self.ink
        let detail = self.detail
        return Group {
            if systemName == "textformat.size" {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("A").font(AppFontStyle.system(size: 24, weight: .light).themed).foregroundStyle(ink)
                    Text("A").font(AppFontStyle.system(size: 13, weight: .medium).themed).foregroundStyle(detail)
                }
            } else if ["circle.lefthalf.filled", "waveform", "bookmark", "clock", "globe"].contains(systemName) {
                Canvas { context, size in
                    context.scaleBy(x: size.width / 24, y: size.height / 24)
                    draw(in: &context, ink: ink, detail: detail)
                }
                .frame(width: 22, height: 22)
            } else {
                Image(systemName: systemName)
                    .font(AppFontStyle.system(size: 20, weight: .regular).themed)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(ink, detail)
            }
        }
    }

    private func draw(in context: inout GraphicsContext, ink: Color, detail: Color) {
        let stroke = StrokeStyle(lineWidth: 1.65, lineCap: .round, lineJoin: .round)
        let circle = Path(ellipseIn: CGRect(x: 2.5, y: 2.5, width: 19, height: 19))
        switch systemName {
        case "circle.lefthalf.filled":
            var half = Path()
            half.addArc(center: CGPoint(x: 12, y: 12), radius: 9.5, startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
            half.closeSubpath()
            context.fill(half, with: .color(ink))
            context.stroke(circle, with: .color(ink), style: stroke)
            var edge = Path()
            edge.addArc(center: CGPoint(x: 12, y: 12), radius: 10.2, startAngle: .degrees(105), endAngle: .degrees(255), clockwise: false)
            context.stroke(edge, with: .color(detail), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        case "waveform":
            for (index, height) in [4.0, 12.0, 21.0, 14.0, 5.0].enumerated() {
                let bar = CGRect(x: 2 + Double(index) * 4.4, y: (24 - height) / 2, width: 2.4, height: height)
                context.fill(Path(roundedRect: bar, cornerRadius: 1.2), with: .color(index > 2 ? detail : ink))
            }
        case "bookmark":
            var bookmark = Path()
            bookmark.move(to: CGPoint(x: 5, y: 21))
            bookmark.addLine(to: CGPoint(x: 5, y: 4))
            bookmark.addQuadCurve(to: CGPoint(x: 7, y: 2), control: CGPoint(x: 5, y: 2))
            bookmark.addLine(to: CGPoint(x: 17, y: 2))
            bookmark.addQuadCurve(to: CGPoint(x: 19, y: 4), control: CGPoint(x: 19, y: 2))
            bookmark.addLine(to: CGPoint(x: 19, y: 21))
            bookmark.addLine(to: CGPoint(x: 12, y: 16))
            bookmark.closeSubpath()
            context.stroke(bookmark, with: .color(detail), style: stroke)
        case "clock":
            context.stroke(circle, with: .color(ink), style: stroke)
            var hands = Path()
            hands.move(to: CGPoint(x: 12, y: 6))
            hands.addLine(to: CGPoint(x: 12, y: 12))
            hands.addLine(to: CGPoint(x: 16, y: 15))
            context.stroke(hands, with: .color(detail), style: stroke)
        case "globe":
            let meridian = Path(ellipseIn: CGRect(x: 7.5, y: 2.5, width: 9, height: 19))
            context.stroke(meridian, with: .color(detail), style: stroke)
            var parallels = Path()
            for y in [7.0, 17.0] {
                parallels.move(to: CGPoint(x: 4, y: y))
                parallels.addQuadCurve(to: CGPoint(x: 20, y: y), control: CGPoint(x: 12, y: 12))
            }
            context.stroke(parallels, with: .color(detail), style: stroke)
            context.stroke(circle, with: .color(ink), style: stroke)
        default: break
        }
    }
}

private struct AllBookmarksView: View {
    @EnvironmentObject private var activity: ReadingActivityModel
    @EnvironmentObject private var library: BookLibraryModel
    @EnvironmentObject private var sources: SourceLibraryModel
    @State private var editingBookmark: Bookmark?
    @State private var exportsJSON = false
    @State private var exportsMarkdown = false

    private var sections: [BookmarkSection] {
        var output: [BookmarkSection] = []
        for bookmark in activity.bookmarks {
            let id = bookmark.bookName + "\u{0}" + bookmark.bookAuthor
            if output.last?.id == id {
                output[output.count - 1].bookmarks.append(bookmark)
            } else {
                output.append(.init(id: id, bookName: bookmark.bookName, author: bookmark.bookAuthor, bookmarks: [bookmark]))
            }
        }
        return output
    }

    var body: some View {
        List {
            if activity.bookmarks.isEmpty {
                ReadingUnavailableView(
                    "暂无书签",
                    systemImage: "bookmark.slash",
                    description: Text("阅读时可从菜单或点击区域添加书签。")
                )
                .readingRowBackground()
            } else {
                ForEach(sections) { section in
                    Section("\(section.bookName)(\(section.author))") {
                        ForEach(section.bookmarks) { bookmark in
                            bookmarkLink(bookmark)
                                .contextMenu {
                                    Button("编辑书签", systemImage: "square.and.pencil") { editingBookmark = bookmark }
                                }
                        }
                    }.readingRowBackground()
                }
            }
        }.readingThemedListBackground()
        .navigationTitle("书签")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !activity.bookmarks.isEmpty {
                    Menu("导出", systemImage: "square.and.arrow.up") {
                        Button("导出 JSON") { exportsJSON = true }
                        Button("导出 Markdown") { exportsMarkdown = true }
                    }
                }
            }
        }
        .sheet(item: $editingBookmark) { bookmark in
            BookmarkEditorView(bookmark: bookmark)
        }
        .fileExporter(
            isPresented: $exportsJSON,
            document: BookmarkExportDocument(data: jsonExportData),
            contentType: .json,
            defaultFilename: exportFilename(extension: "json")
        ) { _ in }
        .fileExporter(
            isPresented: $exportsMarkdown,
            document: BookmarkExportDocument(data: Data(markdownExport.utf8)),
            contentType: .plainText,
            defaultFilename: exportFilename(extension: "md")
        ) { _ in }
    }

    private func matchingBook(_ bookmark: Bookmark) -> Book? {
        library.books.first { $0.name == bookmark.bookName && $0.author == bookmark.bookAuthor }
    }

    @ViewBuilder private func bookmarkLink(_ bookmark: Bookmark) -> some View {
        if let book = matchingBook(bookmark) {
            NavigationLink {
                BookmarkReaderDestination(
                    book: book,
                    bookmark: bookmark,
                    source: sources.sources.first { $0.bookSourceUrl == book.origin }
                )
            } label: { bookmarkRow(bookmark) }
        } else {
            Button { editingBookmark = bookmark } label: { bookmarkRow(bookmark) }
        }
    }

    private func bookmarkRow(_ bookmark: Bookmark) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(bookmark.chapterName.isEmpty ? "第 \(bookmark.chapterIndex + 1) 章" : bookmark.chapterName)
                .font(AppFontStyle.headline.themed).foregroundStyle(ReadingTheme.coral)
            if !bookmark.bookText.isEmpty {
                Text(bookmark.bookText).font(AppFontStyle.footnote.themed).foregroundStyle(.secondary).lineLimit(3)
            }
            if !bookmark.content.isEmpty {
                Label(bookmark.content, systemImage: "note.text").font(AppFontStyle.caption.themed).lineLimit(2)
            }
        }
        .padding(.vertical, 5)
    }

    private var jsonExportData: Data {
        (try? JSONEncoder().encode(activity.bookmarks)) ?? Data("[]".utf8)
    }

    private var markdownExport: String {
        var output = ""
        var name = ""
        var author = ""
        for bookmark in activity.bookmarks {
            if bookmark.bookName != name && bookmark.bookAuthor != author {
                name = bookmark.bookName
                author = bookmark.bookAuthor
                output += "## \(bookmark.bookName) \(bookmark.bookAuthor)\n\n"
            }
            output += "#### \(bookmark.chapterName)\n\n"
            output += "###### 原文\n \(bookmark.bookText)\n\n"
            output += "###### 摘要\n \(bookmark.content)\n\n"
        }
        return output
    }

    private func exportFilename(extension value: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMddHHmmss"
        return "bookmark-\(formatter.string(from: Date())).\(value)"
    }
}

private struct BookmarkSection: Identifiable {
    let id: String
    let bookName: String
    let author: String
    var bookmarks: [Bookmark]
}

private struct BookmarkExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .plainText] }
    let data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { .init(regularFileWithContents: data) }
}

private struct BookmarkEditorView: View {
    @EnvironmentObject private var activity: ReadingActivityModel
    @Environment(\.dismiss) private var dismiss
    let bookmark: Bookmark
    @State private var bookText: String
    @State private var content: String

    init(bookmark: Bookmark) {
        self.bookmark = bookmark
        _bookText = State(initialValue: bookmark.bookText)
        _content = State(initialValue: bookmark.content)
    }

    var body: some View {
        ReadingNavigationStack {
            Form {
                Section("原文") { TextEditor(text: $bookText).frame(minHeight: 150) }.readingRowBackground()
                Section("摘要") { TextEditor(text: $content).frame(minHeight: 120) }.readingRowBackground()
                Section {
                    Button("删除书签", role: .destructive) {
                        Task { await activity.removeBookmark(bookmark); dismiss() }
                    }
                }.readingRowBackground()
            }.readingThemedListBackground()
            .navigationTitle(bookmark.chapterName.isEmpty ? "编辑书签" : bookmark.chapterName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        var updated = bookmark
                        updated.bookText = bookText
                        updated.content = content
                        Task { await activity.updateBookmark(updated); dismiss() }
                    }
                }
            }
        }
    }
}

private struct BookmarkReaderDestination: View {
    let book: Book
    let bookmark: Bookmark
    let source: BookSource?
    @State private var chapters: [BookChapter] = []
    @State private var preparedBook: Book?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let preparedBook, !chapters.isEmpty {
                if book.origin == "local" {
                    ReaderView(book: preparedBook, chapters: chapters, initialIndex: preparedBook.durChapterIndex)
                } else if let source {
                    ReaderView(book: preparedBook, chapters: chapters, initialIndex: preparedBook.durChapterIndex, source: source)
                } else {
                    ReadingUnavailableView("书源不可用", systemImage: "network.slash", description: Text("请先恢复或启用这本书对应的书源。"))
                }
            } else if isLoading {
                ProgressView("正在恢复书签位置…")
            } else {
                ReadingUnavailableView(
                    "无法打开书签",
                    systemImage: "bookmark.slash",
                    description: Text(errorMessage ?? "当前目录中找不到书签对应章节。")
                )
            }
        }
        .navigationTitle(bookmark.chapterName.isEmpty ? book.name : bookmark.chapterName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard isLoading, chapters.isEmpty else { return }
        let loaded: [BookChapter]
        if book.origin == "local" {
            let targetBook = book
            do {
                loaded = try await Task.detached {
                    try LocalBookService.live().loadChapters(book: targetBook).chapters
                }.value
            } catch {
                errorMessage = error.localizedDescription
                isLoading = false
                return
            }
        } else {
            guard let source else {
                errorMessage = "书源已删除或未启用。"
                isLoading = false
                return
            }
            let coordinator = Self.chapterCoordinator()
            let cached = await coordinator.storedChapters(bookURL: book.bookUrl)
            if cached.isEmpty {
                let report = await coordinator.refresh(book: book, source: source)
                loaded = report.chapters
                if loaded.isEmpty { errorMessage = report.diagnostics.first?.message ?? "目录加载失败。" }
            } else {
                loaded = cached
            }
        }
        guard let target = targetIndex(in: loaded) else {
            isLoading = false
            return
        }
        var restored = book
        if restored.readConfig == nil { restored.readConfig = BookReadConfig() }
        restored.readConfig?.epubLocation = bookmark.epubLocation
        restored.durChapterIndex = target
        restored.durChapterPos = max(bookmark.chapterPosition, 0)
        restored.durChapterTitle = loaded[target].title
        chapters = loaded
        preparedBook = restored
        isLoading = false
    }

    private func targetIndex(in chapters: [BookChapter]) -> Int? {
        bookmark.resolvedChapterIndex(in: chapters) ?? chapters.firstIndex(where: { !$0.isVolume })
    }

    private static func chapterCoordinator() -> BookUpdateCoordinator {
        BookUpdateCoordinator(repository: AppBookChapterRepository.live())
    }
}

private struct SearchScopeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let sources: [BookSource]
    let groups: [String]
    @Binding var selectedGroups: Set<String>
    @Binding var selectedSourceID: String?
    @State private var mode = 0
    @State private var sourceFilter = ""
    @State private var filterIsPresented = false
    @State private var workingGroups: Set<String>
    @State private var workingSourceID: String?

    init(
        sources: [BookSource],
        groups: [String],
        selectedGroups: Binding<Set<String>>,
        selectedSourceID: Binding<String?>
    ) {
        self.sources = sources
        self.groups = groups
        _selectedGroups = selectedGroups
        _selectedSourceID = selectedSourceID
        _workingGroups = State(initialValue: selectedGroups.wrappedValue)
        _workingSourceID = State(initialValue: selectedSourceID.wrappedValue)
        _mode = State(initialValue: selectedSourceID.wrappedValue == nil ? 0 : 1)
    }

    var body: some View {
        ReadingNavigationStack {
            List {
                Picker("范围类型", selection: $mode) {
                    Text("分组").tag(0)
                    Text("书源").tag(1)
                }
                .pickerStyle(.segmented)

                Button("全部书源") {
                    selectedGroups.removeAll()
                    selectedSourceID = nil
                    dismiss()
                }

                if mode == 0 {
                    ForEach(groups, id: \.self) { group in
                        Button {
                            workingSourceID = nil
                            if !workingGroups.insert(group).inserted { workingGroups.remove(group) }
                        } label: {
                            HStack {
                                Text(group).foregroundStyle(.primary)
                                Spacer()
                                if workingGroups.contains(group) { Image(systemName: "checkmark") }
                            }
                        }
                    }.readingRowBackground()
                } else {
                    ForEach(filteredSources) { source in
                        Button {
                            workingGroups.removeAll()
                            workingSourceID = source.id
                            filterIsPresented = false
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(source.bookSourceName).foregroundStyle(.primary)
                                    Text(source.bookSourceUrl).font(AppFontStyle.caption.themed).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if workingSourceID == source.id { Image(systemName: "checkmark") }
                            }
                        }
                    }.readingRowBackground()
                }
            }.readingThemedListBackground()
            .navigationTitle("分组或书源")
            .navigationBarTitleDisplayMode(.inline)
            .readingSearchable(text: $sourceFilter, isPresented: $filterIsPresented, prompt: "筛选书源")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确定") {
                        selectedGroups = workingGroups
                        selectedSourceID = workingSourceID
                        dismiss()
                    }
                }
            }
        }
    }

    private var filteredSources: [BookSource] {
        guard !sourceFilter.isEmpty else { return sources }
        return sources.filter {
            $0.bookSourceName.localizedCaseInsensitiveContains(sourceFilter)
                || $0.bookSourceUrl.localizedCaseInsensitiveContains(sourceFilter)
        }
    }
}

private struct ReadingPreferencesView: View {
    @AppStorage("textSize") private var fontSize = 20.0
    @AppStorage("letterSpacing") private var letterSpacing = 0.1
    @AppStorage("lineSpacingExtra") private var lineSpacing = 12.0
    @AppStorage("paragraphSpacing") private var paragraphSpacing = 2.0
    @AppStorage("paragraphIndent") private var paragraphIndent = "　　"
    @AppStorage("paddingLeft") private var paddingLeft = 16.0
    @AppStorage("paddingRight") private var paddingRight = 16.0
    @AppStorage("paddingTop") private var paddingTop = 6.0
    @AppStorage("paddingBottom") private var paddingBottom = 6.0
    @AppStorage("textBold") private var fontWeight = 0
    @AppStorage("titleMode") private var titleMode = 0
    @AppStorage("titleSize") private var titleSize = 0.0
    @AppStorage("titleTopSpacing") private var titleTopSpacing = 0.0
    @AppStorage("titleBottomSpacing") private var titleBottomSpacing = 0.0
    @AppStorage("underlineMode") private var underlineMode = 0
    @AppStorage("readerTheme") private var theme = "wechat"
    @AppStorage("pageAnim") private var pageAnimation = 0
    @AppStorage("readerKeepScreenOn") private var keepScreenOn = false
    @AppStorage("readerHideHomeIndicator") private var hideHomeIndicator = false

    var body: some View {
        Form {
            Section("排版") {
                AdjustableSlider(title: "字号", value: $fontSize, range: 5...50, format: { String(format: "%.0f", $0) })
                AdjustableSlider(title: "字间距", value: $letterSpacing, range: -0.5...0.5, step: 0.01, format: { String(format: "%.2f", $0) })
                AdjustableSlider(title: "行间距", value: $lineSpacing, range: 0...50, format: { String(format: "%.0f", $0) })
                AdjustableSlider(title: "段距", value: $paragraphSpacing, range: 0...50, format: { String(format: "%.1f", $0) })
                Picker("字重", selection: $fontWeight) {
                    Text("正常").tag(0)
                    Text("粗体").tag(1)
                    Text("细体").tag(2)
                }
                ParagraphIndentControl(indent: $paragraphIndent)
                Picker("下划线", selection: $underlineMode) {
                    Text("关闭").tag(0)
                    Text("实线").tag(1)
                    Text("虚线").tag(2)
                }
            }.readingRowBackground()
            Section("正文边距") {
                paddingSlider("左边距", value: $paddingLeft)
                paddingSlider("右边距", value: $paddingRight)
                paddingSlider("上边距", value: $paddingTop)
                paddingSlider("下边距", value: $paddingBottom)
            }.readingRowBackground()
            Section("章节标题") {
                Picker("标题模式", selection: $titleMode) {
                    Text("左对齐").tag(0)
                    Text("居中").tag(1)
                    Text("隐藏").tag(2)
                }
                AdjustableSlider(title: "字号增量", value: $titleSize, range: -10...30, format: { String(format: "%+.0f", $0) })
                AdjustableSlider(title: "上间距", value: $titleTopSpacing, range: 0...100, format: { String(Int($0)) })
                AdjustableSlider(title: "下间距", value: $titleBottomSpacing, range: 0...100, format: { String(Int($0)) })
            }.readingRowBackground()
            Section("翻页") {
                Picker("翻页模式", selection: $pageAnimation) {
                    Text("覆盖").tag(0)
                    Text("滑动").tag(1)
                    Text("仿真").tag(2)
                    Text("滚动").tag(3)
                    Text("无动画").tag(4)
                }
            }.readingRowBackground()
            Section("屏幕") {
                Toggle("阅读时不自动锁屏", isOn: $keepScreenOn)
                Toggle("阅读时隐藏小横条", isOn: $hideHomeIndicator)
            }.readingRowBackground()
            Section("阅读背景") {
                ForEach(ReaderStylePreset.legadoDefaults) { preset in
                    Button {
                        theme = preset.id
                    } label: {
                        HStack {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color(uiColor: preset.background))
                                .frame(width: 38, height: 28)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.5))
                                }
                            Text(preset.name).foregroundStyle(.primary)
                            Spacer()
                            if ReaderStylePreset.resolve(theme).id == preset.id {
                                Image(systemName: "checkmark").foregroundStyle(ReadingTheme.accent)
                            }
                        }
                    }
                }
            }.readingRowBackground()
            Section("预览") {
                Text("雨落在旧城的瓦檐上，故事从一束灯光开始。")
                    .tracking(letterSpacing * fontSize)
                    .font(AppFontStyle.system(size: fontSize, design: .serif).themed)
                    .lineSpacing(lineSpacing)
                    .foregroundStyle(Color(uiColor: ReaderStylePreset.resolve(theme).foreground))
                    .padding(.vertical, 12)
                    .listRowBackground(Color(uiColor: ReaderStylePreset.resolve(theme).background))
            }.readingRowBackground()
        }.readingThemedListBackground()
        .navigationTitle("阅读设置")
    }

    private func paddingSlider(_ title: String, value: Binding<Double>) -> some View {
        AdjustableSlider(title: title, value: value, range: 0...100, format: { String(Int($0)) })
    }
}


enum BookshelfShelfDestination: Equatable {
    case read(Book)
    case info(Book)
}

/// 书在仿真书架上的摆放姿势，按书籍链接保存。
enum BookshelfShelfPose: Int, CaseIterable {
    case upright = 0, flat = 1, leanLeft = 2, leanRight = 3

    var title: String {
        switch self {
        case .upright: "竖立"
        case .flat: "平躺"
        case .leanLeft: "左倾"
        case .leanRight: "右倾"
        }
    }

    static let storageKey = "bookshelfShelfPoses"
    static func load() -> [String: Int] {
        UserDefaults.standard.dictionary(forKey: storageKey) as? [String: Int] ?? [:]
    }
    static func save(_ poses: [String: Int]) {
        UserDefaults.standard.set(poses, forKey: storageKey)
    }
}

// MARK: - 仿真书架设置

/// 书架设置里的选项（保存在 UserDefaults）。
enum BookshelfShelfSettings {
    static let hideTitlesKey = "shelfHideTitles"
    /// 网格封面下方是否显示书名、作者（与仿真书架的「隐藏书名」分开）。
    static let gridShowTitleKey = "bookshelfGridShowTitle"
    static let gridShowAuthorKey = "bookshelfGridShowAuthor"
    static let bookWidthKey = "shelfBookWidth"
    static let bookHeightKey = "shelfBookHeight"
    static let coverSpineKey = "shelfCoverSpine"
    static let hideRotateKey = "shelfHideRotateButtons"
    /// 抽出书时旁边浮出的深色书名胶囊。
    static let pulledTitleKey = "shelfShowPulledTitle"
    /// 书的高矮、厚薄随字数（或章节数）变化。
    static let variedSizeKey = "shelfVariedBookSizes"
    /// 网格封面样式："flat" 平面，"solid" 实体（左侧有书脊凹陷）。
    static let coverStyleKey = "bookshelfCoverStyle"
    /// 移出书架时同时删除本地书文件。
    static let deleteLocalKey = "bookshelfDeleteLocalOnRemove"
    /// 书架右侧竖向切换条。
    static let sideSwitcherKey = "bookshelfSideSwitcher"
    /// 网格视图不画搁板。
    static let hideShelfBaseKey = "bookshelfHideShelfBase"
    /// 搁板样式："flat" 平面，"solid" 立体。
    static let boardStyleKey = "bookshelfBoardStyle"
    private static let lastGridCountKey = "bookshelfLastGridCount"
    static let widthRange: ClosedRange<Double> = 16...44

    /// 网格列数（3–5），旧版的 2、6 列等按就近处理。
    static func gridCount(_ layout: String) -> Int {
        min(max(Int(layout.dropFirst(4)) ?? 3, 3), 5)
    }

    static var lastGridCount: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: lastGridCountKey)
            return value == 0 ? 3 : min(max(value, 3), 5)
        }
        set { UserDefaults.standard.set(newValue, forKey: lastGridCountKey) }
    }
    static let heightRange: ClosedRange<Double> = 100...200
    static let defaultWidth: Double = 26
    static let defaultHeight: Double = 150
}

/// 仿真书架上书的尺寸与样式。
struct BookshelfShelfStyle: Equatable {
    var bookWidth: CGFloat = 26
    var bookHeight: CGFloat = 150
    var hideTitles = false
    var coverSpine = false
    var hideRotateButtons = false
    var showsPulledTitle = true
    var variedSizes = true

    /// 这本书在书架上的尺寸：设置里的书宽/书高是基准。主要变的是高矮——字数越多书越高
    /// （0.8–1 倍书高，再加一点按书名的错落）；厚薄只轻微变化（0.94–1.1 倍书宽）。
    func sized(for book: Book) -> BookshelfShelfStyle {
        guard variedSizes else { return self }
        let seed = BookshelfSpine.seed(book)
        let jitter = CGFloat(seed % 5) / 100 - 0.02
        let t: CGFloat
        if let words = Self.wordCount(of: book), words > 0 {
            t = CGFloat(min(max((log10(Double(words)) - 4.7) / (6.6 - 4.7), 0), 1))
        } else {
            t = CGFloat((seed / 7) % 21) / 20
        }
        let heightFactor = min(max(0.8 + 0.2 * t + jitter, 0.78), 1)
        let widthFactor = 0.94 + 0.16 * t
        var copy = self
        copy.bookWidth = max(12, (bookWidth * widthFactor).rounded())
        copy.bookHeight = max(60, (bookHeight * heightFactor).rounded())
        return copy
    }

    /// 字数：书源给的「123.4万字」「56789字」等；没有时按章节数估算（每章约 3000 字）。
    static func wordCount(of book: Book) -> Int? {
        if let text = book.wordCount?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
            let number = Double(text.filter { $0.isNumber || $0 == "." }) ?? 0
            if number > 0 {
                if text.contains("亿") { return Int(number * 100_000_000) }
                if text.contains("万") || text.lowercased().contains("w") { return Int(number * 10_000) }
                if text.lowercased().contains("k") || text.contains("千") { return Int(number * 1_000) }
                return Int(number)
            }
        }
        return book.totalChapterNum > 0 ? book.totalChapterNum * 3000 : nil
    }

    func scaled(_ factor: CGFloat) -> BookshelfShelfStyle {
        var copy = self
        copy.bookWidth = max(6, (bookWidth * factor).rounded())
        copy.bookHeight = max(30, (bookHeight * factor).rounded())
        return copy
    }
}

// MARK: - 换装

/// 书脊装帧样式。
enum BookshelfSpineDesign: Int, CaseIterable, Identifiable {
    case auto = 0, classic, thread, label, plain, gilded, cover, custom
    /// 第十二轮新增：三段（上下色块、中间米色书名带）、竹节（皮面横棱）、水墨（宣纸 + 底部远山）、双框（通身双线框）。
    case tripart = 8, ribbed, inkwash, framed

    var id: Int { rawValue }

    /// 可以参与随机、也可以单独指定的装帧（不含「随机」）。
    /// 「封面」样式与书架设置里的「封面书脊」重复，不再放进装扮列表。
    static let concrete: [BookshelfSpineDesign] = [.classic, .label, .thread, .plain, .gilded,
                                                   .tripart, .ribbed, .inkwash, .framed]

    var title: String {
        switch self {
        case .auto: "随机"
        case .classic: "典藏"
        case .thread: "线装"
        case .label: "书签"
        case .plain: "素面"
        case .gilded: "烫金"
        case .cover: "封面"
        case .custom: "自定义"
        case .tripart: "三段"
        case .ribbed: "竹节"
        case .inkwash: "水墨"
        case .framed: "双框"
        }
    }

    /// 兜底：没有经过装扮仓库解析时按书名稳定地分一种。
    func resolved(for book: Book, coverSpine: Bool) -> BookshelfSpineDesign {
        guard self == .auto else { return self }
        if coverSpine { return .cover }
        let all = BookshelfSpineDesign.concrete
        return all[(BookshelfSpine.seed(book) / 3) % all.count]
    }
}

/// 一本书最终的装扮：装帧样式、底色（为空时跟随封面主色）、文字颜色（为空时自动）。
struct BookshelfSpineAppearance: Equatable {
    var design: BookshelfSpineDesign = .auto
    var colorHex: String?
    var textHex: String?
    /// 自定义装帧（design == .custom）的各个部件。
    var parts: ShelfSpineStyle?
}

/// 用户自己做的书脊装帧：可以一直新建，保存后参与随机，也可以指定给某本书。
struct ShelfSpineStyle: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    /// 7 = 部件自由组合；旧版保存的 1…5 按对应的内置装帧画。
    var design: Int
    var color: String
    var text: String?
    var enabled: Bool
    /// 装饰色（饰带、饰线、圆点、布边、描边框）。
    var accent: String?
    /// 顶部：0 无，1 浅色书标，2 双饰线，3 顶部色块，4 菱形徽记，5 竹节横棱。
    var top: Int?
    /// 底部：0 无，1 圆点，2 双饰线，3 朱红印章，4 底部色块，5 菱形，6 竹节横棱。
    var bottom: Int?
    /// 书名区：0 直接印在书脊上，1 白纸书签，2 描边框，3 通栏色带，4 胶囊，5 上下饰线（都贴着书名伸缩）。
    var panel: Int?
    /// 纹理：0 无，1 竖条纹，2 格纹，3 圆点，4 斜纹布。
    var texture: Int?
    /// 左侧装订：0 无，1 线装布边 + 针脚。
    var edge: Int?
    /// 书名字体：true 宋体（默认），false 黑体。
    var serif: Bool?

    static let topTitles = ["无", "书标", "饰线", "色块", "菱形", "竹节"]
    static let bottomTitles = ["无", "圆点", "饰线", "印章", "色块", "菱形", "竹节"]
    /// 书名区：贴着书名的长短自动伸缩（不再是固定大小的方框），通栏色带和上下饰线不占书名宽度。
    static let panelTitles = ["直印", "书签纸", "描边框", "通栏色带", "胶囊", "上下饰线"]
    static let textureTitles = ["无", "竖纹", "格纹", "圆点", "斜纹", "横纹", "菱格"]

    var appearance: BookshelfSpineAppearance {
        let design = BookshelfSpineDesign(rawValue: self.design) ?? .classic
        return BookshelfSpineAppearance(design: design == .auto || design == .cover ? .classic : design,
                                        colorHex: color, textHex: text,
                                        parts: design == .custom ? self : nil)
    }

    /// 从模板开始：把内置装帧拆成部件，再自由改。
    static func template(_ design: BookshelfSpineDesign, id: String, name: String) -> ShelfSpineStyle {
        func hex(_ r: Double, _ g: Double, _ b: Double) -> String { UIColor(red: r, green: g, blue: b, alpha: 1).shelfHex }
        var style = ShelfSpineStyle(id: id, name: name, design: BookshelfSpineDesign.custom.rawValue,
                                    color: hex(0.12, 0.28, 0.22), text: nil, enabled: true,
                                    accent: hex(0.93, 0.91, 0.86), top: 1, bottom: 1, panel: 0, texture: 0, edge: 0, serif: true)
        switch design {
        case .label:
            style.color = hex(0.80, 0.60, 0.22); style.accent = hex(1, 1, 1)
            style.top = 0; style.bottom = 1; style.panel = 1
        case .thread:
            style.color = hex(0.94, 0.90, 0.81); style.accent = hex(0.45, 0.12, 0.13); style.text = hex(0.20, 0.15, 0.11)
            style.top = 2; style.bottom = 3; style.edge = 1
        case .gilded:
            style.color = hex(0.10, 0.10, 0.11); style.accent = hex(0.88, 0.73, 0.44); style.text = hex(0.88, 0.73, 0.44)
            style.top = 2; style.bottom = 2
        case .plain:
            style.color = hex(0.45, 0.12, 0.13); style.top = 0; style.bottom = 0
        case .tripart:
            style.color = hex(0.80, 0.42, 0.18); style.accent = hex(0.96, 0.93, 0.85)
            style.top = 0; style.bottom = 0; style.panel = 3
        case .ribbed:
            style.color = hex(0.30, 0.16, 0.10); style.accent = hex(0.88, 0.73, 0.44); style.text = hex(0.88, 0.73, 0.44)
            style.top = 5; style.bottom = 6
        case .inkwash:
            style.color = hex(0.94, 0.90, 0.81); style.accent = hex(0.20, 0.15, 0.11); style.text = hex(0.20, 0.15, 0.11)
            style.top = 0; style.bottom = 3; style.panel = 5
        case .framed:
            style.color = hex(0.12, 0.19, 0.35); style.accent = hex(0.93, 0.88, 0.76)
            style.top = 2; style.bottom = 2; style.panel = 2
        default:
            break
        }
        return style
    }
}

/// 用户自己做的书匣装扮。
struct ShelfFolderStyle: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var box: String
    var label: String
    var footer: String?
    var enabled: Bool
    /// 纹理：0 无，1 竖条纹，2 格纹，3 圆点，4 斜纹布。
    var pattern: Int?
    /// 正面：0 透明窗（看得到里面的书），1 封闭书匣（中间一块竖排名牌），2 小窗（下半截露书）。
    var window: Int?
    /// 描一道细边框（用文字颜色）。
    var border: Bool?
    /// 顶部文字；为空时显示文件夹名。
    var title: String?

    static let windowTitles = ["透明窗", "封闭", "小窗"]
}

extension UIColor {
    convenience init?(shelfHex hex: String?) {
        guard let hex else { return nil }
        let parts = hex.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        self.init(red: parts[0], green: parts[1], blue: parts[2], alpha: 1)
    }

    var shelfHex: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%.4f,%.4f,%.4f", Double(r), Double(g), Double(b))
    }
}

/// 仿真书架的装扮：书脊和书匣默认从勾选的装帧里随机搭配（每本书固定），
/// 用户可以新建任意多款自定义装帧（保存后一直保留），也可以给单本书 / 单个书匣指定。
@MainActor
final class BookshelfSpineDesignStore: ObservableObject {
    static let shared = BookshelfSpineDesignStore()
    private static let designKey = "bookshelfSpineDesigns"
    private static let colorKey = "bookshelfSpineColors"
    private static let customAssignKey = "bookshelfSpineCustomAssign"
    private static let customStylesKey = "bookshelfSpineCustomStyles"
    private static let disabledDesignsKey = "bookshelfSpineDisabledDesigns"
    private static let colorModeKey = "bookshelfSpineColorMode"
    private static let folderStylesKey = "bookshelfFolderCustomStyles"
    private static let disabledFolderKey = "bookshelfFolderDisabledPresets"
    private static let folderFooterModeKey = "bookshelfFolderFooterMode"
    private static let folderFooterTextKey = "bookshelfFolderFooterText"
    /// 单本书颜色设为「封面色」时保存的值。
    static let coverColorToken = "cover"

    static let swatches: [(String, Double, Double, Double)] = [
        ("酒红", 0.45, 0.12, 0.13), ("墨黑", 0.10, 0.10, 0.11), ("藏青", 0.12, 0.19, 0.35),
        ("墨绿", 0.12, 0.28, 0.22), ("赭石", 0.62, 0.36, 0.20), ("烟灰", 0.55, 0.56, 0.58),
        ("米白", 0.90, 0.86, 0.77), ("雾蓝", 0.47, 0.58, 0.68), ("豆沙", 0.69, 0.47, 0.47),
        ("姜黄", 0.80, 0.60, 0.22), ("黛紫", 0.33, 0.24, 0.40), ("棕褐", 0.36, 0.25, 0.17)
    ]

    static func swatchHex(_ index: Int) -> String {
        let item = swatches[index % swatches.count]
        return UIColor(red: item.1, green: item.2, blue: item.3, alpha: 1).shelfHex
    }

    @Published private var designs: [String: Int]
    @Published private var colors: [String: String]
    @Published private var customAssign: [String: String]
    @Published private(set) var customStyles: [ShelfSpineStyle]
    @Published private(set) var disabledDesigns: Set<Int>
    /// "random" 随机配色；"cover" 跟随封面主色。
    @Published var colorMode: String {
        didSet { UserDefaults.standard.set(colorMode, forKey: Self.colorModeKey) }
    }
    @Published private(set) var folderStyles: [ShelfFolderStyle]
    @Published private(set) var disabledFolderPresets: Set<Int>
    /// 书匣底部文字（内置装扮，以及没填底部文字的自定义书匣）：
    /// "count" 共 N 册，"custom" 自定义文字，"none" 不显示。之前固定显示装扮名（典藏、墨绿……）。
    @Published var folderFooterMode: String {
        didSet { UserDefaults.standard.set(folderFooterMode, forKey: Self.folderFooterModeKey) }
    }
    @Published var folderFooterText: String {
        didSet { UserDefaults.standard.set(folderFooterText, forKey: Self.folderFooterTextKey) }
    }

    static let folderFooterModes: [(String, String)] = [("count", "册数"), ("custom", "自定义"), ("none", "不显示")]

    /// 书匣底部显示的文字。自定义文字里的「#」会换成书的本数。
    func folderFooter(for skin: BookshelfFolderSkin, count: Int) -> String {
        if let text = skin.footer?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
            return text.replacingOccurrences(of: "#", with: "\(count)")
        }
        switch folderFooterMode {
        case "none": return ""
        case "custom":
            let text = folderFooterText.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? "共 \(count) 册" : text.replacingOccurrences(of: "#", with: "\(count)")
        default: return "共 \(count) 册"
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        designs = defaults.dictionary(forKey: Self.designKey) as? [String: Int] ?? [:]
        colors = defaults.dictionary(forKey: Self.colorKey) as? [String: String] ?? [:]
        customAssign = defaults.dictionary(forKey: Self.customAssignKey) as? [String: String] ?? [:]
        customStyles = Self.decode(defaults.data(forKey: Self.customStylesKey)) ?? []
        disabledDesigns = Set(defaults.array(forKey: Self.disabledDesignsKey) as? [Int] ?? [])
        colorMode = defaults.string(forKey: Self.colorModeKey) ?? "random"
        folderStyles = Self.decode(defaults.data(forKey: Self.folderStylesKey)) ?? []
        disabledFolderPresets = Set(defaults.array(forKey: Self.disabledFolderKey) as? [Int] ?? [])
        folderFooterMode = defaults.string(forKey: Self.folderFooterModeKey) ?? "count"
        folderFooterText = defaults.string(forKey: Self.folderFooterTextKey) ?? ""
    }

    private static func decode<T: Decodable>(_ data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(designs, forKey: Self.designKey)
        defaults.set(colors, forKey: Self.colorKey)
        defaults.set(customAssign, forKey: Self.customAssignKey)
        defaults.set(try? JSONEncoder().encode(customStyles), forKey: Self.customStylesKey)
        defaults.set(Array(disabledDesigns), forKey: Self.disabledDesignsKey)
        defaults.set(try? JSONEncoder().encode(folderStyles), forKey: Self.folderStylesKey)
        defaults.set(Array(disabledFolderPresets), forKey: Self.disabledFolderKey)
    }

    /// 稳定的随机种子（FNV-1a），同一本书每次打开都是同一套装扮。
    static func seed(_ text: String) -> Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return Int(hash % 0x7FFF_FFFF)
    }

    // MARK: 书脊

    private enum SpineEntry {
        case builtin(BookshelfSpineDesign)
        case custom(ShelfSpineStyle)
    }

    private var spinePool: [SpineEntry] {
        var pool: [SpineEntry] = BookshelfSpineDesign.concrete
            .filter { !disabledDesigns.contains($0.rawValue) }
            .map { .builtin($0) }
        pool += customStyles.filter(\.enabled).map { .custom($0) }
        return pool.isEmpty ? [.builtin(.classic)] : pool
    }

    private func randomColor(seed: Int) -> String? {
        colorMode == "cover" ? nil : Self.swatchHex(seed / 13)
    }

    /// 书最终的装扮：「封面书脊」总开关 > 单独指定的自定义装帧 > 单独指定的内置装帧 > 随机。
    func appearance(for book: Book, coverSpine: Bool) -> BookshelfSpineAppearance {
        let url = book.bookUrl
        let seed = Self.seed(url + "|" + book.name)
        // 「封面书脊」是总开关：打开后所有有封面的书都显示封面（之前单本指定过装帧的书不受开关影响，
        // 看起来像有的书没生效）。没有封面的书仍按装帧显示，免得出现一条空白的占位封面。
        if coverSpine, let cover = book.coverUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !cover.isEmpty {
            return BookshelfSpineAppearance(design: .cover)
        }
        if let id = customAssign[url], let style = customStyles.first(where: { $0.id == id }) {
            return style.appearance
        }
        let ownColor: String? = colors[url].map { $0 == Self.coverColorToken ? nil : $0 } ?? randomColor(seed: seed)
        if let raw = designs[url], let design = BookshelfSpineDesign(rawValue: raw), design != .auto, design != .custom {
            return BookshelfSpineAppearance(design: design, colorHex: ownColor)
        }
        let pool = spinePool
        switch pool[seed % pool.count] {
        case .builtin(let design):
            return BookshelfSpineAppearance(design: design, colorHex: ownColor)
        case .custom(let style):
            return style.appearance
        }
    }

    /// 这本书单独指定了什么："" 随机，"d:N" 内置装帧，"c:ID" 自定义装帧。
    func choice(for url: String) -> String {
        if let id = customAssign[url], customStyles.contains(where: { $0.id == id }) { return "c:" + id }
        if let raw = designs[url], raw != 0 { return "d:\(raw)" }
        return ""
    }

    func ownColor(for url: String) -> String? { colors[url] }

    func setChoice(_ choice: String, for url: String) {
        customAssign.removeValue(forKey: url)
        designs.removeValue(forKey: url)
        if choice.hasPrefix("c:") {
            customAssign[url] = String(choice.dropFirst(2))
        } else if choice.hasPrefix("d:"), let raw = Int(choice.dropFirst(2)) {
            designs[url] = raw
        }
        persist()
    }

    /// 单本书的颜色：nil 随机（跟随全局配色），"cover" 封面色，或具体颜色。
    func setColor(_ hex: String?, for url: String) {
        if let hex { colors[url] = hex } else { colors.removeValue(forKey: url) }
        persist()
    }

    func reset(_ url: String) {
        designs.removeValue(forKey: url)
        colors.removeValue(forKey: url)
        customAssign.removeValue(forKey: url)
        persist()
    }

    var hasBookOverrides: Bool { !designs.isEmpty || !colors.isEmpty || !customAssign.isEmpty }

    func resetAllBooks() {
        designs.removeAll()
        colors.removeAll()
        customAssign.removeAll()
        persist()
    }

    func toggleDesign(_ design: BookshelfSpineDesign) {
        if disabledDesigns.contains(design.rawValue) { disabledDesigns.remove(design.rawValue) }
        else { disabledDesigns.insert(design.rawValue) }
        persist()
    }

    func saveStyle(_ style: ShelfSpineStyle) {
        if let index = customStyles.firstIndex(where: { $0.id == style.id }) { customStyles[index] = style }
        else { customStyles.append(style) }
        persist()
    }

    func toggleStyle(_ id: String) {
        guard let index = customStyles.firstIndex(where: { $0.id == id }) else { return }
        customStyles[index].enabled.toggle()
        persist()
    }

    func deleteStyle(_ id: String) {
        customStyles.removeAll { $0.id == id }
        customAssign = customAssign.filter { $0.value != id }
        persist()
    }

    // MARK: 书匣

    private enum FolderEntry {
        case preset(Int)
        case custom(ShelfFolderStyle)
    }

    private var folderPool: [FolderEntry] {
        var pool: [FolderEntry] = BookshelfFolderSkin.presets.indices
            .filter { !disabledFolderPresets.contains($0) }
            .map { .preset($0) }
        pool += folderStyles.filter(\.enabled).map { .custom($0) }
        return pool.isEmpty ? [.preset(0)] : pool
    }

    /// 书匣的装扮：单独指定（"p:N" 预设、"c:ID" 自定义）> 随机。
    func folderSkin(for folder: BookshelfFolder) -> BookshelfFolderSkin {
        if let id = folder.skinID {
            if id.hasPrefix("p:"), let index = Int(id.dropFirst(2)), BookshelfFolderSkin.presets.indices.contains(index) {
                return BookshelfFolderSkin.presets[index]
            }
            if id.hasPrefix("c:"), let style = folderStyles.first(where: { $0.id == String(id.dropFirst(2)) }) {
                return BookshelfFolderSkin.custom(style)
            }
        }
        let pool = folderPool
        switch pool[Self.seed("folder|" + folder.id) % pool.count] {
        case .preset(let index): return BookshelfFolderSkin.presets[index]
        case .custom(let style): return BookshelfFolderSkin.custom(style)
        }
    }

    func folderChoice(for folder: BookshelfFolder) -> String {
        guard let id = folder.skinID else { return "" }
        if id.hasPrefix("c:"), !folderStyles.contains(where: { $0.id == String(id.dropFirst(2)) }) { return "" }
        return id
    }

    func togglePreset(_ index: Int) {
        if disabledFolderPresets.contains(index) { disabledFolderPresets.remove(index) }
        else { disabledFolderPresets.insert(index) }
        persist()
    }

    func saveFolderStyle(_ style: ShelfFolderStyle) {
        if let index = folderStyles.firstIndex(where: { $0.id == style.id }) { folderStyles[index] = style }
        else { folderStyles.append(style) }
        persist()
    }

    func toggleFolderStyle(_ id: String) {
        guard let index = folderStyles.firstIndex(where: { $0.id == id }) else { return }
        folderStyles[index].enabled.toggle()
        persist()
    }

    func deleteFolderStyle(_ id: String) {
        folderStyles.removeAll { $0.id == id }
        persist()
    }
}

/// 书匣装扮。
struct BookshelfFolderSkin {
    let name: String
    let box: Color
    let dark: Color
    let label: Color
    let window: Color
    let monospaced: Bool
    /// 自定义的底部标签文字；为空时显示「名称 · N 册」。
    var footer: String?
    /// 纹理（见 `ShelfFolderStyle.pattern`）。
    var pattern: Int = 0
    /// 正面样式（见 `ShelfFolderStyle.window`）。
    var windowStyle: Int = 0
    var border: Bool = false
    /// 顶部文字；为空时显示文件夹名。
    var title: String?

    static let presets: [BookshelfFolderSkin] = [
        .init(name: "典藏", box: Color(red: 0.42, green: 0.14, blue: 0.13), dark: Color(red: 0.27, green: 0.08, blue: 0.08),
              label: Color(red: 0.95, green: 0.86, blue: 0.67), window: Color(red: 0.16, green: 0.05, blue: 0.05), monospaced: false),
        .init(name: "精装", box: Color(red: 0.20, green: 0.21, blue: 0.23), dark: Color(red: 0.11, green: 0.12, blue: 0.13),
              label: Color(red: 0.86, green: 0.87, blue: 0.89), window: Color(red: 0.06, green: 0.06, blue: 0.07), monospaced: true),
        .init(name: "墨绿", box: Color(red: 0.13, green: 0.29, blue: 0.23), dark: Color(red: 0.07, green: 0.17, blue: 0.13),
              label: Color(red: 0.90, green: 0.80, blue: 0.55), window: Color(red: 0.04, green: 0.10, blue: 0.08), monospaced: false),
        .init(name: "藏青", box: Color(red: 0.13, green: 0.20, blue: 0.36), dark: Color(red: 0.07, green: 0.11, blue: 0.22),
              label: Color(red: 0.88, green: 0.84, blue: 0.72), window: Color(red: 0.04, green: 0.06, blue: 0.12), monospaced: false),
        .init(name: "原木", box: Color(red: 0.62, green: 0.45, blue: 0.29), dark: Color(red: 0.45, green: 0.31, blue: 0.19),
              label: Color(red: 0.99, green: 0.95, blue: 0.86), window: Color(red: 0.25, green: 0.17, blue: 0.10), monospaced: false),
        .init(name: "象牙", box: Color(red: 0.93, green: 0.90, blue: 0.83), dark: Color(red: 0.82, green: 0.78, blue: 0.69),
              label: Color(red: 0.30, green: 0.25, blue: 0.20), window: Color(red: 0.36, green: 0.31, blue: 0.26), monospaced: false),
        .init(name: "樱粉", box: Color(red: 0.86, green: 0.62, blue: 0.64), dark: Color(red: 0.70, green: 0.45, blue: 0.48),
              label: Color(red: 1.0, green: 0.96, blue: 0.94), window: Color(red: 0.36, green: 0.20, blue: 0.22), monospaced: false),
        .init(name: "黑金", box: Color(red: 0.10, green: 0.09, blue: 0.08), dark: Color(red: 0.03, green: 0.03, blue: 0.03),
              label: Color(red: 0.85, green: 0.69, blue: 0.38), window: Color(red: 0.02, green: 0.02, blue: 0.02), monospaced: false)
    ]

    static func custom(_ style: ShelfFolderStyle) -> BookshelfFolderSkin {
        let base = UIColor(shelfHex: style.box) ?? UIColor(red: 0.42, green: 0.14, blue: 0.13, alpha: 1)
        let label = UIColor(shelfHex: style.label) ?? UIColor(red: 0.95, green: 0.86, blue: 0.67, alpha: 1)
        var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &sat, brightness: &b, alpha: &a)
        return BookshelfFolderSkin(name: style.name, box: Color(base),
                                   dark: Color(UIColor(hue: h, saturation: sat, brightness: b * 0.62, alpha: 1)),
                                   label: Color(label),
                                   window: Color(UIColor(hue: h, saturation: sat, brightness: b * 0.3, alpha: 1)),
                                   monospaced: false, footer: style.footer,
                                   pattern: style.pattern ?? 0, windowStyle: style.window ?? 0,
                                   border: style.border ?? false, title: style.title)
    }
}

// MARK: - 文件夹

/// 书架上的文件夹：属于某个书架（分组），里面放这个书架里的几本书。
/// 网格、列表、仿真书架三种视图共用同一份数据，所以在哪种视图里建的文件夹，其他视图里都能看到。
struct BookshelfFolder: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    /// 文件夹所在的书架（分组 id，「全部」等系统书架为负数）。
    var groupID: Int64
    var bookURLs: [String]
    /// 仿真书架上的装帧样式：见 `BookshelfFolderSkin.presets`，99 为自定义。
    var style: Int = 0
    /// 自定义装扮：书匣颜色、文字颜色、底部标签文字（为空时显示「册数」）。
    var skinBox: String?
    var skinLabel: String?
    var skinFooter: String?
    /// 书匣装扮：为空时随机；"p:N" 预设，"c:ID" 自定义。
    var skinID: String?
}

/// 书架页上的一项：一本书或一个文件夹（网格与列表视图用）。
enum BookshelfEntry: Identifiable {
    case book(Book)
    case folder(BookshelfFolder, [Book])

    var id: String {
        switch self {
        case .book(let book): "b:" + book.bookUrl
        case .folder(let folder, _): "f:" + folder.id
        }
    }
}

@MainActor
final class BookshelfFolderStore: ObservableObject {
    static let shared = BookshelfFolderStore()
    private static let storageKey = "bookshelfFolders.v2"
    /// 上一版把文件夹存成书架分组，这里记录那些分组 id，用于迁移。
    private static let legacyIDsKey = "bookshelfFolderGroups"
    private static let legacyStylesKey = "bookshelfFolderStyles"
    static let nameLimit = 20

    @Published private(set) var folders: [BookshelfFolder]
    /// 正在打开的文件夹（面板）。
    @Published var presentedFolderID: String?
    /// 在文件夹面板里点了某本书：交给书架页打开。
    @Published var openRequest: BookshelfShelfDestination?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([BookshelfFolder].self, from: data) {
            folders = decoded
        } else {
            folders = []
        }
    }

    var legacyGroupIDs: [Int64] {
        (UserDefaults.standard.array(forKey: Self.legacyIDsKey) as? [NSNumber])?.map(\.int64Value) ?? []
    }

    func legacyStyle(for groupID: Int64) -> Int {
        (UserDefaults.standard.dictionary(forKey: Self.legacyStylesKey) as? [String: Int])?[String(groupID)] ?? 0
    }

    func clearLegacy() {
        UserDefaults.standard.removeObject(forKey: Self.legacyIDsKey)
        UserDefaults.standard.removeObject(forKey: Self.legacyStylesKey)
    }

    func folder(id: String) -> BookshelfFolder? { folders.first { $0.id == id } }

    func folders(inGroup groupID: Int64) -> [BookshelfFolder] { folders.filter { $0.groupID == groupID } }

    /// 把书架里的书按文件夹收起来：文件夹排在它里面第一本书原来的位置。
    func entries(for books: [Book], groupID: Int64) -> [BookshelfEntry] {
        let scoped = folders(inGroup: groupID)
        guard !scoped.isEmpty else { return books.map { .book($0) } }
        var byURL: [String: Book] = [:]
        for book in books where byURL[book.bookUrl] == nil { byURL[book.bookUrl] = book }
        var owner: [String: Int] = [:]
        var contents: [[Book]] = []
        for (index, folder) in scoped.enumerated() {
            var inside: [Book] = []
            for url in folder.bookURLs where owner[url] == nil {
                guard let book = byURL[url] else { continue }
                owner[url] = index
                inside.append(book)
            }
            contents.append(inside)
        }
        var placed = Set<Int>()
        var result: [BookshelfEntry] = []
        for book in books {
            if let index = owner[book.bookUrl] {
                if placed.insert(index).inserted { result.append(.folder(scoped[index], contents[index])) }
            } else {
                result.append(.book(book))
            }
        }
        return result
    }

    func nextName(inGroup groupID: Int64) -> String {
        let names = Set(folders(inGroup: groupID).map(\.name))
        var name = "文件夹"
        var index = 2
        while names.contains(name) {
            name = "文件夹\(index)"
            index += 1
        }
        return name
    }

    /// 新建文件夹并放进这些书（书原来在本书架其他文件夹里的会移过来）。
    @discardableResult
    func makeFolder(groupID: Int64, bookURLs: [String], name: String? = nil, style: Int = 0) -> BookshelfFolder {
        var urls: [String] = []
        for url in bookURLs where !urls.contains(url) { urls.append(url) }
        detach(Set(urls), inGroup: groupID, except: nil)
        var folderName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if folderName.isEmpty || folders(inGroup: groupID).contains(where: { $0.name == folderName }) {
            folderName = folderName.isEmpty ? nextName(inGroup: groupID) : folderName + "2"
        }
        let folder = BookshelfFolder(id: UUID().uuidString, name: String(folderName.prefix(Self.nameLimit)),
                                     groupID: groupID, bookURLs: urls, style: style)
        folders.append(folder)
        save()
        return folder
    }

    func add(_ url: String, to id: String) {
        guard let existing = folders.first(where: { $0.id == id }), !existing.bookURLs.contains(url) else { return }
        detach([url], inGroup: existing.groupID, except: id)
        if let index = folders.firstIndex(where: { $0.id == id }) {
            folders[index].bookURLs.append(url)
        }
        save()
    }

    /// 拖书松手：落在书上就和那本书建一个文件夹，落在文件夹上就放进去。
    func handleDrop(_ url: String, ontoBook target: String?, folder: String?, groupID: Int64) {
        if let folder {
            add(url, to: folder)
        } else if let target, target != url {
            makeFolder(groupID: groupID, bookURLs: [target, url])
        } else {
            return
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// 移出文件夹；文件夹空了就解散。
    func remove(_ urls: Set<String>, from id: String) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].bookURLs.removeAll { urls.contains($0) }
        if folders[index].bookURLs.isEmpty {
            dissolve(id)
        } else {
            save()
        }
    }

    /// 改名，返回错误提示（nil 表示成功或无需修改）。
    func rename(_ id: String, to name: String) -> String? {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.nameLimit))
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return nil }
        guard !name.isEmpty else { return "名称不能为空" }
        guard name != folders[index].name else { return nil }
        let groupID = folders[index].groupID
        if folders.contains(where: { $0.groupID == groupID && $0.id != id && $0.name == name }) {
            return "这个书架已经有「\(name)」了"
        }
        folders[index].name = name
        save()
        return nil
    }

    func toggleStyle(_ id: String) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].style = folders[index].style == 0 ? 1 : 0
        save()
    }

    /// 换装：nil 随机，"p:N" 预设，"c:ID" 自定义。
    func setSkinID(_ id: String, skinID: String?) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].skinID = skinID
        save()
    }

    func dissolve(_ id: String) {
        folders.removeAll { $0.id == id }
        if presentedFolderID == id { presentedFolderID = nil }
        save()
    }

    /// 书移出书架后，从所有文件夹里去掉它。
    func removeBook(_ url: String) {
        guard folders.contains(where: { $0.bookURLs.contains(url) }) else { return }
        for index in folders.indices { folders[index].bookURLs.removeAll { $0 == url } }
        folders.removeAll { $0.bookURLs.isEmpty }
        if let current = presentedFolderID, !folders.contains(where: { $0.id == current }) { presentedFolderID = nil }
        save()
    }

    /// 书架书目变化后，清掉已经不在书架上的书；空文件夹解散。
    func prune(existing: Set<String>) {
        var changed = false
        for index in folders.indices {
            let before = folders[index].bookURLs.count
            folders[index].bookURLs.removeAll { !existing.contains($0) }
            if folders[index].bookURLs.count != before { changed = true }
        }
        if folders.contains(where: { $0.bookURLs.isEmpty }) {
            folders.removeAll { $0.bookURLs.isEmpty }
            changed = true
        }
        guard changed else { return }
        if let current = presentedFolderID, !folders.contains(where: { $0.id == current }) { presentedFolderID = nil }
        save()
    }

    /// 一本书在同一个书架里只放在一个文件夹。
    private func detach(_ urls: Set<String>, inGroup groupID: Int64, except id: String?) {
        for index in folders.indices where folders[index].groupID == groupID && folders[index].id != id {
            folders[index].bookURLs.removeAll { urls.contains($0) }
        }
        folders.removeAll { $0.groupID == groupID && $0.id != id && $0.bookURLs.isEmpty }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(folders) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

/// 从书架移出一本书；打开「移除同时删除本地文件」时，本地书连同导入的原文件一起删除。
@MainActor
enum BookshelfRemoval {
    static func remove(_ book: Book, library: BookLibraryModel) async {
        let deleteLocal = UserDefaults.standard.bool(forKey: BookshelfShelfSettings.deleteLocalKey)
        if deleteLocal, book.origin == "local", let url = URL(string: book.bookUrl), url.isFileURL {
            do {
                try await library.deleteLocalFile(at: url)
            } catch {
                await library.remove(bookURL: book.bookUrl)
            }
        } else {
            await library.remove(bookURL: book.bookUrl)
        }
        BookshelfFolderStore.shared.removeBook(book.bookUrl)
        BookshelfPinStore.shared.forget(book.bookUrl)
    }
}

/// 实体封面左侧的书脊凹槽与高光。
struct BookshelfSolidSpineShade: View {
    let width: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            LinearGradient(stops: [
                .init(color: .black.opacity(0.45), location: 0),
                .init(color: .white.opacity(0.30), location: 0.35),
                .init(color: .black.opacity(0.38), location: 0.72),
                .init(color: .white.opacity(0.14), location: 1)
            ], startPoint: .leading, endPoint: .trailing)
            .frame(width: max(width * 0.09, 3.5))
            LinearGradient(colors: [.black.opacity(0.20), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: max(width * 0.08, 2.5))
        }
        .allowsHitTesting(false)
    }
}

/// 书架页上的封面：按「封面样式」显示平面或实体。
struct BookshelfCover: View {
    let book: Book
    let width: CGFloat
    let height: CGFloat
    @AppStorage(BookshelfShelfSettings.coverStyleKey) private var coverStyle = "flat"

    /// 网格与列表统一的封面圆角：随封面宽度变化（约 8.5%），5…10pt。
    static func cornerRadius(width: CGFloat) -> CGFloat {
        AppThemeRuntime.coverCornerRadius(width: width, legacy: min(max((width * 0.085).rounded(), 5), 10))
    }

    var body: some View {
        let radius = Self.cornerRadius(width: width)
        if coverStyle == "solid" {
            solidCover(radius: radius)
        } else {
            // 平面：没有书脊阴影、没有投影，就是一张圆角封面。
            BookCoverArtwork(title: book.name, author: book.author, remoteURL: book.displayCoverUrl,
                             width: width, height: height, cornerRadius: radius, spineShade: false)
        }
    }

    /// 实体：像一本立在书架上的精装书，而不是一张图片。
    /// · 书脊一侧（左）是几乎直角的硬边，翻口一侧（右）是圆角；
    /// · 左侧压出书脊折痕（暗线 + 高光），书脊带只轻微压暗，不再做成透视，避免看起来是斜放的；
    /// · 右缘一道细高光 + 暗边做出纸板厚度，顶边一线高光，整面一层从左上到右下的极淡光照；
    /// · 投影正下方居中，书是端正立着的。
    private func solidCover(radius: CGFloat) -> some View {
        let groove = max(width * 0.07, 3.5)
        let shape = BookBoardShape(spineRadius: max(radius * 0.25, 1.2), edgeRadius: radius)
        return BookCoverArtwork(title: book.name, author: book.author, remoteURL: book.displayCoverUrl,
                                width: width, height: height, cornerRadius: 0, spineShade: false)
            .overlay {
                // 整面光照：左上略亮，右下略暗，让封面有纸板的体积感。
                LinearGradient(colors: [Color.white.opacity(0.10), .clear, Color.black.opacity(0.10)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .leading) {
                HStack(spacing: 0) {
                    // 书脊带：左缘最暗，往折痕方向变浅
                    LinearGradient(colors: [Color.black.opacity(0.20), Color.black.opacity(0.05)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: groove)
                    // 折痕：暗线 + 高光 + 一小段阴影过渡
                    Rectangle().fill(Color.black.opacity(0.22)).frame(width: 0.7)
                    Rectangle().fill(Color.white.opacity(0.30)).frame(width: 1)
                    LinearGradient(colors: [Color.black.opacity(0.07), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: max(width * 0.04, 2))
                }
                .allowsHitTesting(false)
            }
            .overlay(alignment: .trailing) {
                // 翻口：纸板边缘的一线反光和外缘暗边
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, Color.white.opacity(0.16)], startPoint: .leading, endPoint: .trailing)
                        .frame(width: max(width * 0.03, 2))
                    Rectangle().fill(Color.black.opacity(0.16)).frame(width: 0.6)
                }
                .allowsHitTesting(false)
            }
            .overlay(alignment: .top) {
                Rectangle().fill(Color.white.opacity(0.22)).frame(height: 0.6).allowsHitTesting(false)
            }
            .clipShape(shape)
            .overlay(shape.stroke(Color.black.opacity(0.12), lineWidth: 0.5).allowsHitTesting(false))
            .shadow(color: .black.opacity(0.10), radius: 0.8, x: 0, y: 0.5)
            .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 3)
    }
}

/// 精装书外形：书脊侧（左）两个角几乎是直角，翻口侧（右）两个角是圆角。
struct BookBoardShape: Shape {
    var spineRadius: CGFloat
    var edgeRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let left = min(spineRadius, rect.height / 2, rect.width / 2)
        let right = min(edgeRadius, rect.height / 2, rect.width / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + left, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - right, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - right, y: rect.minY + right), radius: right,
                    startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - right))
        path.addArc(center: CGPoint(x: rect.maxX - right, y: rect.maxY - right), radius: right,
                    startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + left, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + left, y: rect.maxY - left), radius: left,
                    startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + left))
        path.addArc(center: CGPoint(x: rect.minX + left, y: rect.minY + left), radius: left,
                    startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// 网格与列表里的文件夹图标：圆角底板上排着前四本书的封面。
struct BookshelfFolderIcon: View {
    @Environment(\.colorScheme) private var colorScheme
    let books: [Book]
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let inset = max(width * 0.08, 3)
        let gap = max(width * 0.05, 2)
        let cellWidth = (width - inset * 2 - gap) / 2
        let cellHeight = (height - inset * 2 - gap) / 2
        let shown = Array(books.prefix(4))
        RoundedRectangle(cornerRadius: max(width * 0.08, 5), style: .continuous)
            .fill(colorScheme == .dark ? Color(white: 0.22) : Color(white: 0.9))
            .overlay(
                RoundedRectangle(cornerRadius: max(width * 0.08, 5), style: .continuous)
                    .strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5)
            )
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: gap) {
                    ForEach(0..<2, id: \.self) { row in
                        HStack(spacing: gap) {
                            ForEach(0..<2, id: \.self) { column in
                                let index = row * 2 + column
                                if index < shown.count {
                                    BookCoverArtwork(title: shown[index].name, author: shown[index].author,
                                                     remoteURL: shown[index].displayCoverUrl, width: cellWidth, height: cellHeight)
                                } else {
                                    Color.clear.frame(width: cellWidth, height: cellHeight)
                                }
                            }
                        }
                    }
                }
                .padding(inset)
            }
            .frame(width: width, height: height)
            .shadow(color: .black.opacity(0.12), radius: 3, y: 2)
            .accessibilityHidden(true)
    }
}

/// 网格、列表里的长按与拖动（与仿真书架同一套手势，不再用系统拖放）：
/// - 长按约 0.35 秒：书轻轻浮起并震动一下；原地松手 → 弹出整本书的操作面板；
/// - 浮起后直接拖动：书跟着手指走；停到另一本书中间 → 那本书缩小、身后浮出底板（文件夹成形），
///   松手两本书装进一个新文件夹；停到文件夹上 → 松手放进这个文件夹；拖到空白处松手 → 回到原位。
/// 系统拖放（onDrag / onDrop）和系统长按菜单抢同一个长按手势，长按菜单与拖动会互相打断，所以全部改成自己处理。
/// 长按与轻点的仲裁：SwiftUI 的轻点手势按住多久都会在松手时触发，
/// 长按浮起后原地松手会同时弹出操作面板和打开书（「长按有时进入书籍」）。
/// 浮起期间、以及松手后的短暂时间内，打开书的轻点一律忽略。
@MainActor
enum BookshelfLongPressGuard {
    private static var liftedAt: Date?
    private static var endedAt: Date = .distantPast

    /// 长按浮起（书、文件夹、摆件被拿起）。
    static func lift() {
        liftedAt = Date()
    }

    /// 长按手势结束（松手、取消）。
    static func end() {
        liftedAt = nil
        endedAt = Date()
    }

    /// 这次轻点能不能打开书：正在长按、或刚松手 0.5 秒内都不算轻点。
    static var allowsTap: Bool {
        if let liftedAt, Date().timeIntervalSince(liftedAt) < 30 { return false }
        return Date().timeIntervalSince(endedAt) > 0.5
    }
}

@MainActor
final class BookshelfDragSession: ObservableObject {
    static let shared = BookshelfDragSession()

    /// 正在拖动的书（书籍链接）。
    @Published private(set) var draggingURL: String?
    /// 手指下的目标："b:" + 书籍链接，或 "f:" + 文件夹 id。
    @Published private(set) var targetID: String?
    /// 合并后在书架上方短暂显示的提示。
    @Published private(set) var toast: String?

    /// 每一格在屏幕上的位置（全局坐标）；token 用来区分同一本书在不同布局里的两次出现。
    private var frames: [String: (token: UUID, rect: CGRect)] = [:]
    private var groupID: Int64 = BookGroup.idAll
    private var moved = false
    private var toastTask: Task<Void, Never>?

    /// 拖动超过这个距离才算「拖」，否则松手算长按（弹出操作面板）。
    static let moveThreshold: CGFloat = 10

    func report(_ id: String, token: UUID, frame: CGRect) {
        frames[id] = (token, frame)
    }

    func forget(_ id: String, token: UUID) {
        if frames[id]?.token == token { frames[id] = nil }
    }

    func begin(url: String, groupID: Int64) {
        self.groupID = groupID
        moved = false
        targetID = nil
        draggingURL = url
    }

    func update(location: CGPoint, translation: CGSize) {
        guard let draggingURL else { return }
        if !moved, hypot(translation.width, translation.height) > Self.moveThreshold { moved = true }
        guard moved else { return }
        let ownID = "b:" + draggingURL
        var found: String?
        for (id, entry) in frames where id != ownID {
            let rect = entry.rect
            // 只认格子中间的一块：从旁边擦过不会误合并。
            let zone = rect.insetBy(dx: rect.width * 0.18, dy: rect.height * 0.14)
            if zone.contains(location) { found = id; break }
        }
        if found != targetID {
            if found != nil { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { targetID = found }
        }
    }

    enum Outcome { case press, merged, none }

    /// 松手：返回这次手势的结果（原地长按 / 已合并 / 放回原位）。
    @discardableResult
    func end() -> Outcome {
        defer {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                draggingURL = nil
                targetID = nil
            }
            moved = false
        }
        guard let url = draggingURL else { return .none }
        guard moved else { return .press }
        guard let target = targetID else { return .none }
        let store = BookshelfFolderStore.shared
        if target.hasPrefix("b:") {
            let other = String(target.dropFirst(2))
            guard other != url else { return .none }
            let folder = withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
                store.makeFolder(groupID: groupID, bookURLs: [other, url])
            }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            showToast("已建立「\(folder.name)」")
            return .merged
        }
        if target.hasPrefix("f:"), let folder = store.folder(id: String(target.dropFirst(2))) {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) { store.add(url, to: folder.id) }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            showToast("已放入「\(folder.name)」")
            return .merged
        }
        return .none
    }

    private func showToast(_ text: String) {
        toastTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { toast = text }
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) { self.toast = nil }
        }
    }
}

/// 网格、列表的一格：把自己的位置报给拖动会话，被拖到上面时缩小、身后浮出底板（像文件夹正在成形）。
struct BookshelfDropTarget: ViewModifier {
    let id: String
    var cornerRadius: CGFloat = 6
    @ObservedObject private var session = BookshelfDragSession.shared
    @State private var token = UUID()

    func body(content: Content) -> some View {
        let targeted = session.targetID == id
        content
            .scaleEffect(targeted ? 0.9 : 1)
            .opacity(targeted ? 0.6 : 1)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius + 8, style: .continuous)
                    .fill(ReadingTheme.accent.opacity(0.16))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius + 8, style: .continuous)
                            .strokeBorder(ReadingTheme.accent.opacity(0.55), lineWidth: 1.5)
                    )
                    .padding(-6)
                    .scaleEffect(targeted ? 1 : 0.85)
                    .opacity(targeted ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { session.report(id, token: token, frame: proxy.frame(in: .global)) }
                        .onChange(of: proxy.frame(in: .global)) { session.report(id, token: token, frame: $0) }
                }
            )
            .onDisappear { session.forget(id, token: token) }
    }
}


/// 仿真书架上的文件夹外观：两种装帧样式；书脊上的小旋转按钮修改摆放形态与样式。
private struct BookshelfFolderBox: View {
    let folder: BookshelfFolder
    let books: [Book]
    let style: BookshelfShelfStyle
    /// 被轻点「抽出」时才显示旋转按钮（和书一样：第一下抽出、出现按钮，再点一下打开）。
    var isSelected = false
    let onRotate: () -> Void
    @ObservedObject private var dress = BookshelfSpineDesignStore.shared

    static let topLabel: CGFloat = 17
    static let bottomLabel: CGFloat = 15
    static let side: CGFloat = 5
    static let maxShown = 6
    /// 旋转按钮的点击区域（位于外框右上角之内）。
    static let rotateHitWidth: CGFloat = 26
    static let rotateHitHeight: CGFloat = 30

    static func innerScale(_ style: BookshelfShelfStyle) -> CGFloat {
        max((style.bookHeight - topLabel - bottomLabel - 4) / style.bookHeight, 0.3)
    }

    static func size(count: Int, style: BookshelfShelfStyle) -> CGSize {
        let inner = style.scaled(innerScale(style))
        let n = CGFloat(min(max(count, 1), maxShown))
        let width = side * 2 + 4 + n * inner.bookWidth + (n - 1) * 1
        return CGSize(width: max(width, 46).rounded(), height: style.bookHeight)
    }

    private var skin: BookshelfFolderSkin { dress.folderSkin(for: folder) }

    private var colors: (box: Color, dark: Color, label: Color, window: Color) {
        let skin = self.skin
        return (skin.box, skin.dark, skin.label, skin.window)
    }

    private var footer: String { dress.folderFooter(for: skin, count: books.count) }

    var body: some View {
        let size = Self.size(count: books.count, style: style)
        let inner = style.scaled(Self.innerScale(style))
        let colors = self.colors
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(LinearGradient(colors: [colors.box, colors.dark], startPoint: .top, endPoint: .bottom))
            ShelfPatternView(kind: skin.pattern, color: colors.label.opacity(0.16))
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            if skin.border {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .strokeBorder(colors.label.opacity(0.75), lineWidth: 0.7)
                    .frame(width: size.width - 4, height: size.height - 4)
                    .offset(x: 2, y: 2)
            }
            // 左侧高光、右侧暗面，做出盒子的厚度。
            HStack(spacing: 0) {
                LinearGradient(colors: [Color.white.opacity(0.18), Color.clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 4)
                Spacer(minLength: 0)
                LinearGradient(colors: [Color.clear, Color.black.opacity(0.35)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 5)
            }
            // 顶部标签：文件夹名（自定义装扮可改成别的文字），在书匣上左右居中
            // （旋转按钮只在抽出时出现、放在书匣正中，不再占用标签右边的位置）。
            Text(skin.title ?? folder.name)
                .font(AppFontStyle.system(size: 8, weight: .semibold).themed)
                .foregroundStyle(colors.label)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .multilineTextAlignment(.center)
                .frame(width: max(size.width - 12, 12), height: Self.topLabel, alignment: .center)
                .offset(x: 6)
            // 窗口：里面立着文件夹里的书；封闭书匣在中间放一块竖排名牌；小窗只露出书的下半截。
            if skin.windowStyle == 1 {
                let plateWidth = min(max(size.width * 0.42, 14), 26)
                let plateHeight = size.height - Self.topLabel - Self.bottomLabel - 10
                let nameChars = Array(folder.name).filter { !$0.isWhitespace }.map(String.init)
                let font = min(plateWidth * 0.62, 12, plateHeight / (CGFloat(max(nameChars.count, 1)) * 1.12))
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(colors.label.opacity(0.92))
                    .overlay(RoundedRectangle(cornerRadius: 1).strokeBorder(colors.dark.opacity(0.5), lineWidth: 0.5).padding(1.5))
                    .overlay {
                        VStack(spacing: 0) {
                            ForEach(Array(nameChars.enumerated()), id: \.offset) { _, ch in
                                Text(ch)
                                    .font(AppFontStyle.system(size: max(font, 5), weight: .semibold, design: .serif).themed)
                                    .frame(height: max(font, 5) * 1.12)
                            }
                        }
                        .foregroundStyle(colors.dark)
                    }
                    .frame(width: plateWidth, height: plateHeight)
                    .offset(x: (size.width - plateWidth) / 2, y: Self.topLabel + 5)
            } else {
                let windowTop = skin.windowStyle == 2
                    ? Self.topLabel + (size.height - Self.topLabel - Self.bottomLabel) * 0.45
                    : Self.topLabel
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(colors.window)
                    .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .strokeBorder(colors.label.opacity(0.45), lineWidth: 0.6))
                    .frame(width: size.width - Self.side * 2, height: size.height - windowTop - Self.bottomLabel)
                    .offset(x: Self.side, y: windowTop)
                HStack(alignment: .bottom, spacing: 1) {
                    ForEach(books.prefix(Self.maxShown)) { book in
                        BookshelfSpine(book: book, pose: .upright, isSelected: false, style: inner,
                                       appearance: dress.appearance(for: book, coverSpine: style.coverSpine))
                    }
                }
                .frame(width: size.width - Self.side * 2 - 2, height: size.height - Self.topLabel - Self.bottomLabel - 2,
                       alignment: .bottomLeading)
                .frame(width: size.width - Self.side * 2 - 2, height: size.height - windowTop - Self.bottomLabel - 2,
                       alignment: .bottomLeading)
                .clipped()
                .offset(x: Self.side + 2, y: windowTop + 1)
                .allowsHitTesting(false)
            }
            // 底部标签
            Text(footer)
                .font(AppFontStyle.system(size: 6.5, weight: .medium, design: skin.monospaced ? .monospaced : .default).themed)
                .foregroundStyle(colors.label.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(width: size.width - 10, height: Self.bottomLabel)
                .offset(x: 5, y: size.height - Self.bottomLabel)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .overlay {
            // 抽出时书匣正中浮出旋转按钮（和书一样），整块点击区域在外框之内。
            if isSelected {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(AppFontStyle.system(size: 10, weight: .semibold).themed)
                    .foregroundStyle(Color.white)
                    .frame(width: 24, height: 24)
                    .background(Color.black.opacity(0.6), in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.5), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .opacity(style.hideRotateButtons ? 0.011 : 1)
                    .frame(width: min(size.width, 44), height: min(size.height * 0.4, 44))
                    .contentShape(Rectangle())
                    .highPriorityGesture(TapGesture().onEnded {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        onRotate()
                    })
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
                    .accessibilityElement()
                    .accessibilityLabel("修改文件夹摆放形态")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { onRotate() }
            }
        }
        .shadow(color: .black.opacity(0.22), radius: 2, x: 1, y: 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }
}

/// 仿真书架上的一个位置：摆件、书或文件夹。
private enum BookshelfShelfItem {
    case ornament(ShelfOrnament, CGSize)
    case book(Book)
    case folder(BookshelfFolder, [Book])

    var id: String {
        switch self {
        case .ornament(let ornament, _): "o:" + ornament.id
        case .book(let book): "b:" + book.bookUrl
        case .folder(let folder, _): "f:" + folder.id
        }
    }

    var book: Book? {
        if case .book(let book) = self { return book }
        return nil
    }

    /// 书和文件夹可以竖立、平躺或倾斜，摆件不行。
    var isSlab: Bool {
        if case .ornament = self { return false }
        return true
    }

    /// 保存摆放姿势、放摆件用的键：书用书籍链接，文件夹用 "folder:" + id。
    var poseKey: String? {
        switch self {
        case .ornament: nil
        case .book(let book): book.bookUrl
        case .folder(let folder, _): BookshelfShelfItem.folderPoseKey(folder.id)
        }
    }

    static func folderPoseKey(_ id: String) -> String { "folder:" + id }
}

/// 一本书、一个文件夹或一个摆件在某一层上的实际摆放位置（按现实中的支撑关系算出来）。
private struct BookshelfShelfPlacement: Identifiable {
    let item: BookshelfShelfItem
    /// 在全局顺序里的位置（不含放在平躺书上的摆件）。
    let index: Int
    /// 实际摆放姿势：书在一层的最边上无处可靠时，会改为靠向另一侧或竖立。
    let pose: BookshelfShelfPose
    /// 未旋转时外框的左边和尺寸。
    let boxX: CGFloat
    let boxSize: CGSize
    /// 在层板上占据的左右范围（用于拖动定位）。
    let boardMinX: CGFloat
    let boardMaxX: CGFloat
    /// 竖直方向的高度（倾斜书靠在它上面时用）。
    let height: CGFloat
    /// 倾斜书在层板上的支点：左倾为左下角，右倾为右下角。
    let pivotX: CGFloat
    var id: String { item.id }
}

/// 用户拖动调整过的书架顺序（摆件、书、文件夹混排），按 id 保存。
enum BookshelfShelfOrder {
    static let storageKey = "bookshelfShelfOrder"
    static func load() -> [String] { UserDefaults.standard.stringArray(forKey: storageKey) ?? [] }
    static func save(_ ids: [String]) { UserDefaults.standard.set(ids, forKey: storageKey) }
}

/// 放在平躺书上面的摆件：摆件 id → 书籍链接。
enum ShelfOrnamentPerches {
    static let storageKey = "shelfOrnamentPerches"
    static func load() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] ?? [:]
    }
    static func save(_ value: [String: String]) { UserDefaults.standard.set(value, forKey: storageKey) }
}

/// 仿真书架：
/// - 书按现实摆放：竖立的书站在层板上；倾斜的书一角着地、靠在相邻的书上；平躺的书横放，上面可以放摆件；
/// - 轻点一本书：书向外抽出，书脊上出现小按钮改摆放形态；再点这本书打开，点空白恢复；
/// - 长按拖动：放在两件东西之间调整位置（黄线）；把书拖到另一本书上松手，两本书装进一个文件夹；
///   拖到文件夹上松手，书放进这个文件夹；把摆件拖到平躺的书上，摆件就放在这本书上面；
/// - 轻点文件夹：打开文件夹面板（改名、多选移出、解散）；轻点摆件：调整大小或移出书架。
private struct BookshelfShelfView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var library: BookLibraryModel
    let books: [Book]
    /// 当前书架（分组）：只显示属于这个书架的文件夹。
    let groupID: Int64
    let onOpen: (BookshelfShelfDestination) -> Void

    @ObservedObject private var ornamentStore = ShelfOrnamentStore.shared
    @ObservedObject private var folderStore = BookshelfFolderStore.shared
    @AppStorage(BookshelfShelfSettings.bookWidthKey) private var bookWidth = BookshelfShelfSettings.defaultWidth
    @AppStorage(BookshelfShelfSettings.bookHeightKey) private var bookHeight = BookshelfShelfSettings.defaultHeight
    @AppStorage(BookshelfShelfSettings.hideTitlesKey) private var hideTitles = false
    @AppStorage(BookshelfShelfSettings.coverSpineKey) private var coverSpine = false
    @AppStorage(BookshelfShelfSettings.hideRotateKey) private var hideRotateButtons = false
    @AppStorage(BookshelfShelfSettings.pulledTitleKey) private var showsPulledTitle = true
    @AppStorage(BookshelfShelfSettings.variedSizeKey) private var variedSizes = true
    @AppStorage(BookshelfShelfSettings.boardStyleKey) private var boardStyle = "solid"
    @ObservedObject private var designStore = BookshelfSpineDesignStore.shared
    @ObservedObject private var pins = BookshelfPinStore.shared
    /// 换装面板：书（"b:" + 链接）或文件夹（"f:" + id）。
    @State private var dressingTarget: BookshelfDressTarget?
    @State private var poses: [String: Int] = BookshelfShelfPose.load()
    /// 文件夹上的旋转按钮打开的摆放形态选择条。
    @State private var folderPickerID: String?
    /// 被轻点「抽出」的文件夹：向外倾出、正中浮出旋转按钮，再点一下才打开。
    @State private var selectedFolderID: String?
    @State private var order: [String] = BookshelfShelfOrder.load()
    @State private var perches: [String: String] = ShelfOrnamentPerches.load()
    @State private var selectedURL: String?
    @State private var showsPicker = false
    @State private var editingOrnament: ShelfOrnament?
    @State private var draggingID: String?
    @State private var dragTranslation: CGSize = .zero
    @State private var insertionIndex: Int?
    @State private var insertionMarker: (row: Int, x: CGFloat)?
    /// 拖动时手指停在哪件东西上（书 "b:"、文件夹 "f:"）：合并、放进文件夹或放摆件。
    @State private var dropTargetID: String?
    /// 长按后手指是否真的拖动过：没拖动就松手 = 长按，弹出整本书的操作面板。
    @State private var dragMoved = false
    @State private var toast: String?
    @GestureState private var dragGestureActive = false

    private let spacing: CGFloat = 2
    private let rowSpacing: CGFloat = 34
    private let boardHeight: CGFloat = 12
    private static let pickerWidth: CGFloat = 176
    private static let coordinateSpace = "bookshelf.shelf"
    private static let leanRadians = CGFloat(BookshelfSpine.leanAngle * .pi / 180)

    private var style: BookshelfShelfStyle {
        BookshelfShelfStyle(
            bookWidth: CGFloat(min(max(bookWidth, BookshelfShelfSettings.widthRange.lowerBound), BookshelfShelfSettings.widthRange.upperBound)).rounded(),
            bookHeight: CGFloat(min(max(bookHeight, BookshelfShelfSettings.heightRange.lowerBound), BookshelfShelfSettings.heightRange.upperBound)).rounded(),
            hideTitles: hideTitles,
            coverSpine: coverSpine,
            hideRotateButtons: hideRotateButtons,
            showsPulledTitle: showsPulledTitle,
            variedSizes: variedSizes
        )
    }

    /// 书架内容宽度：书架页左右各留 24pt 边距，宽度在布局前就能确定，避免首帧高度跳动。
    private var contentWidth: CGFloat { max(UIScreen.main.bounds.width - 48, 120) }
    private var rowHeight: CGFloat { style.bookHeight + 14 }
    private var rowPitch: CGFloat { rowHeight + boardHeight + rowSpacing }

    private func requestedPose(_ book: Book) -> BookshelfShelfPose {
        requestedPose(key: book.bookUrl)
    }

    private func requestedPose(key: String) -> BookshelfShelfPose {
        BookshelfShelfPose(rawValue: poses[key] ?? 0) ?? .upright
    }

    // MARK: 顺序与分层

    /// 摆件在前、书和文件夹在后的默认顺序，再按用户拖动保存的顺序重排；新加入的放在最后。
    /// 文件夹没有保存过位置时，排在它里面第一本书原来的位置。
    private var allItems: [BookshelfShelfItem] {
        let ornaments = ornamentStore.placed.map {
            BookshelfShelfItem.ornament($0, ornamentStore.displaySize(for: $0, maxWidth: contentWidth * 0.5))
        }
        var defaults = ornaments
        for entry in folderStore.entries(for: books, groupID: groupID) {
            switch entry {
            case .book(let book): defaults.append(.book(book))
            case .folder(let folder, let inside): defaults.append(.folder(folder, inside))
            }
        }
        guard !order.isEmpty else { return pinnedFirst(defaults) }
        var rank: [String: Int] = [:]
        for (index, id) in order.enumerated() where rank[id] == nil { rank[id] = index }
        func itemRank(_ item: BookshelfShelfItem, offset: Int) -> Int {
            if let value = rank[item.id] { return value }
            if case .folder(_, let inside) = item {
                let values = inside.compactMap { rank["b:" + $0.bookUrl] }
                if let first = values.min() { return first }
            }
            return order.count + offset
        }
        return pinnedFirst(defaults.enumerated().sorted { lhs, rhs in
            let l = itemRank(lhs.element, offset: lhs.offset)
            let r = itemRank(rhs.element, offset: rhs.offset)
            return l == r ? lhs.offset < rhs.offset : l < r
        }.map(\.element))
    }

    /// 置顶的书（或装着置顶书的文件夹）排在摆件之后、其余书之前，按置顶先后排列。
    private func pinnedFirst(_ items: [BookshelfShelfItem]) -> [BookshelfShelfItem] {
        guard !pins.urls.isEmpty else { return items }
        func pinRank(_ item: BookshelfShelfItem) -> Int? {
            switch item {
            case .ornament: return nil
            case .book(let book): return pins.rank(of: [book.bookUrl])
            case .folder(_, let inside): return pins.rank(of: inside.map(\.bookUrl))
            }
        }
        let pinned = items.compactMap { item in pinRank(item).map { (item, $0) } }
            .sorted { $0.1 < $1.1 }.map(\.0)
        guard !pinned.isEmpty else { return items }
        let pinnedIDs = Set(pinned.map(\.id))
        var rest = items.filter { !pinnedIDs.contains($0.id) }
        // 插在第一件书 / 文件夹的位置：摆件保持用户摆好的位置不动。
        let position = rest.firstIndex { item in
            if case .ornament = item { return false }
            return true
        } ?? rest.count
        rest.insert(contentsOf: pinned, at: position)
        return rest
    }

    static let perchGap: CGFloat = 2

    /// 平躺的书 / 文件夹横放时的长度（摆件并排放在上面，总宽不能超过它）。
    private func lyingLength(of item: BookshelfShelfItem) -> CGFloat {
        switch item {
        case .book(let book): return style.sized(for: book).bookHeight
        case .folder(_, let inside): return BookshelfFolderBox.size(count: inside.count, style: style).height
        case .ornament: return 0
        }
    }

    /// 放在平躺书上面的摆件（书 → 摆件，可以并排放好几个，放得下就行）。
    /// 书不在当前书架、不再平躺或放不下时，多出来的摆件回到原来的位置。
    private func perchedOrnaments(in items: [BookshelfShelfItem]) -> [String: [(ShelfOrnament, CGSize)]] {
        var lengths: [String: CGFloat] = [:]
        for item in items {
            if let key = item.poseKey, requestedPose(key: key) == .flat { lengths[key] = lyingLength(of: item) }
        }
        var result: [String: [(ShelfOrnament, CGSize)]] = [:]
        var used: [String: CGFloat] = [:]
        for item in items {
            guard case .ornament(let ornament, let size) = item,
                  let url = perches[ornament.id], let length = lengths[url] else { continue }
            let next = (used[url].map { $0 + Self.perchGap } ?? 0) + size.width
            guard next <= length + 0.5 else { continue }
            used[url] = next
            result[url, default: []].append((ornament, size))
        }
        return result
    }

    /// 这本平躺的书上还剩多宽可以放摆件。
    private func perchRoom(for key: String, items: [BookshelfShelfItem], excluding ornamentID: String) -> CGFloat {
        guard let item = items.first(where: { $0.poseKey == key }) else { return 0 }
        let perched = perchedOrnaments(in: items)[key] ?? []
        let others = perched.filter { $0.0.id != ornamentID }
        let used = others.reduce(CGFloat(0)) { $0 + $1.1.width } + CGFloat(others.count) * Self.perchGap
        return lyingLength(of: item) - used
    }

    /// 按现实中的支撑关系摆一层：倾斜的书一角着地，上端刚好靠在相邻的书、文件夹或摆件上。
    private func layoutRow(_ entries: [(item: BookshelfShelfItem, index: Int)],
                           perched: [String: [(ShelfOrnament, CGSize)]]) -> [BookshelfShelfPlacement] {
        let t = Self.leanRadians
        let style = self.style
        var result: [BookshelfShelfPlacement] = []
        for (position, entry) in entries.enumerated() {
            let previous = result.last
            switch entry.item {
            case .ornament(_, let size):
                let left = previous.map { leftEdgeAfter($0, objectHeight: size.height) } ?? 0
                result.append(.init(item: entry.item, index: entry.index, pose: .upright,
                                    boxX: left, boxSize: size, boardMinX: left, boardMaxX: left + size.width,
                                    height: size.height, pivotX: left))
            case .book, .folder:
                let w: CGFloat, h: CGFloat
                if case .folder(_, let inside) = entry.item {
                    let size = BookshelfFolderBox.size(count: inside.count, style: style)
                    w = size.width
                    h = size.height
                } else if case .book(let book) = entry.item {
                    let sized = style.sized(for: book)
                    w = sized.bookWidth
                    h = sized.bookHeight
                } else {
                    w = style.bookWidth
                    h = style.bookHeight
                }
                let key = entry.item.poseKey ?? ""
                var pose = requestedPose(key: key)
                // 一层最左边左倾、最右边右倾：靠在书架的侧板上（之前会被改成另一个方向，
                // 看起来点了「右倾」没反应）。右边侧板放不下时才竖立。
                let leansOnLeftWall = pose == .leanLeft && position == 0
                let leansOnRightWall = pose == .leanRight && position == entries.count - 1
                if leansOnRightWall {
                    let pivot = contentWidth - h * sin(t) - 1
                    let left = pivot - w * cos(t)
                    let minLeft = previous.map { leftEdgeAfter($0, objectHeight: h * cos(t)) } ?? 0
                    if left >= minLeft {
                        result.append(.init(item: entry.item, index: entry.index, pose: .leanRight,
                                            boxX: pivot - w, boxSize: CGSize(width: w, height: h),
                                            boardMinX: left, boardMaxX: pivot, height: h * cos(t), pivotX: pivot))
                        continue
                    }
                    pose = .upright
                }
                if leansOnLeftWall {
                    let pivot = h * sin(t) + 1
                    result.append(.init(item: entry.item, index: entry.index, pose: .leanLeft,
                                        boxX: pivot, boxSize: CGSize(width: w, height: h),
                                        boardMinX: pivot, boardMaxX: pivot + w * cos(t), height: h * cos(t), pivotX: pivot))
                    continue
                }
                switch pose {
                case .upright:
                    let left = previous.map { leftEdgeAfter($0, objectHeight: h) } ?? 0
                    result.append(.init(item: entry.item, index: entry.index, pose: pose,
                                        boxX: left, boxSize: CGSize(width: w, height: h),
                                        boardMinX: left, boardMaxX: left + w, height: h, pivotX: left))
                case .flat:
                    let lying = w + (perched[key]?.map { $0.1.height }.max() ?? 0)
                    let left = previous.map { leftEdgeAfter($0, objectHeight: w) } ?? 0
                    result.append(.init(item: entry.item, index: entry.index, pose: pose,
                                        boxX: left, boxSize: CGSize(width: h, height: w),
                                        boardMinX: left, boardMaxX: left + h, height: lying, pivotX: left))
                case .leanLeft:
                    // 左倾：左下角着地，左侧靠在前一个物体上。
                    guard let previous else { continue }
                    let pivot: CGFloat
                    switch previous.pose {
                    case .leanLeft where previous.item.isSlab:
                        // 同向倾斜，两本书贴在一起。
                        pivot = previous.pivotX + previous.boxSize.width / cos(t)
                    case .leanRight where previous.item.isSlab:
                        // 两本书相对倾斜，顶端互相抵住。
                        pivot = previous.pivotX + (previous.boxSize.height + h) * sin(t)
                    default:
                        let gap = h * cos(t) <= previous.height ? h * sin(t) : previous.height * tan(t)
                        pivot = previous.boardMaxX + gap
                    }
                    result.append(.init(item: entry.item, index: entry.index, pose: pose,
                                        boxX: pivot, boxSize: CGSize(width: w, height: h),
                                        boardMinX: pivot, boardMaxX: pivot + w * cos(t), height: h * cos(t), pivotX: pivot))
                case .leanRight:
                    // 右倾：右下角着地，右侧靠在后一个物体上（后一个物体按它摆放）。
                    let left: CGFloat
                    if let previous, previous.pose == .leanRight, previous.item.isSlab {
                        let pivot = previous.pivotX + w / cos(t)
                        left = pivot - w * cos(t)
                    } else {
                        left = (previous.map { $0.boardMaxX + spacing } ?? 0)
                    }
                    let pivot = left + w * cos(t)
                    result.append(.init(item: entry.item, index: entry.index, pose: pose,
                                        boxX: pivot - w, boxSize: CGSize(width: w, height: h),
                                        boardMinX: left, boardMaxX: pivot, height: h * cos(t), pivotX: pivot))
                }
            }
        }
        return result
    }

    /// 竖直物体（竖立的书、平躺的书、文件夹、摆件）放在 previous 后面时的左边位置。
    private func leftEdgeAfter(_ previous: BookshelfShelfPlacement, objectHeight: CGFloat) -> CGFloat {
        let t = Self.leanRadians
        if previous.pose == .leanRight, previous.item.isSlab {
            // 前一本右倾的书靠在这个物体上。
            let h = previous.boxSize.height
            let gap = h * cos(t) <= objectHeight ? h * sin(t) : objectHeight * tan(t)
            return previous.pivotX + gap
        }
        return previous.boardMaxX + spacing
    }

    private func rows(_ items: [BookshelfShelfItem], perched: [String: [(ShelfOrnament, CGSize)]]) -> [[BookshelfShelfPlacement]] {
        let perchedIDs = Set(perched.values.flatMap { $0.map { "o:" + $0.0.id } })
        let sequence = items.filter { !perchedIDs.contains($0.id) }
        var result: [[BookshelfShelfPlacement]] = []
        var current: [(item: BookshelfShelfItem, index: Int)] = []
        var currentLayout: [BookshelfShelfPlacement] = []
        for (index, item) in sequence.enumerated() {
            let candidate = current + [(item, index)]
            let candidateLayout = layoutRow(candidate, perched: perched)
            let right = candidateLayout.map(\.boardMaxX).max() ?? 0
            if !current.isEmpty, right > contentWidth {
                result.append(currentLayout)
                current = [(item, index)]
                currentLayout = layoutRow(current, perched: perched)
            } else {
                current = candidate
                currentLayout = candidateLayout
            }
        }
        if !currentLayout.isEmpty { result.append(currentLayout) }
        return result
    }

    // MARK: 视图

    var body: some View {
        let items = allItems
        let perched = perchedOrnaments(in: items)
        let shelfRows = rows(items, perched: perched)
        VStack(alignment: .leading, spacing: rowSpacing) {
            ForEach(shelfRows.indices, id: \.self) { index in
                shelfRow(shelfRows[index], rowIndex: index, rows: shelfRows, perched: perched)
                    .zIndex(shelfRows[index].contains { isRaised($0, perched: perched) } ? 1 : 0)
            }
        }
        .coordinateSpace(name: Self.coordinateSpace)
        .padding(.top, 28)
        .frame(maxWidth: .infinity, minHeight: UIScreen.main.bounds.height * 0.5, alignment: .topLeading)
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { if hasSelection { deselect() } }
        )
        .overlay(alignment: .top) {
            if let toast {
                Text(toast)
                    .font(AppFontStyle.footnote.weight(.medium).themed)
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.75), in: Capsule())
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: books.map(\.bookUrl)) { urls in
            if let selectedURL, !urls.contains(selectedURL) { deselect() }
        }
        .onChange(of: dragGestureActive) { active in
            if !active { finishDrag() }
        }
        .onDisappear {
            selectedURL = nil
            showsPicker = false
            selectedFolderID = nil
            folderPickerID = nil
        }
        .dismissesSheetOnOutsideTap(Binding(
            get: { editingOrnament != nil },
            set: { if !$0 { editingOrnament = nil } }
        ))
        .sheet(item: $editingOrnament) { ornament in
            ShelfOrnamentSettingsSheet(ornamentID: ornament.id)
        }
        .sheet(item: $dressingTarget) { target in
            if target.id.hasPrefix("f:") {
                BookshelfFolderDressSheet(folderID: String(target.id.dropFirst(2)))
            } else if let book = books.first(where: { $0.bookUrl == String(target.id.dropFirst(2)) }) {
                BookshelfSpineDressSheet(book: book, style: style)
            }
        }
    }

    private func isRaised(_ placement: BookshelfShelfPlacement, perched: [String: [(ShelfOrnament, CGSize)]]) -> Bool {
        if placement.id == draggingID || placement.id == "b:" + (selectedURL ?? "")
            || placement.id == "f:" + (selectedFolderID ?? "") { return true }
        if let key = placement.item.poseKey, let list = perched[key] {
            return list.contains { "o:" + $0.0.id == draggingID }
        }
        return false
    }

    private func deselect() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            selectedURL = nil
            showsPicker = false
            folderPickerID = nil
            selectedFolderID = nil
        }
    }

    private var hasSelection: Bool { selectedURL != nil || folderPickerID != nil || selectedFolderID != nil }

    private func shelfRow(_ row: [BookshelfShelfPlacement], rowIndex: Int, rows: [[BookshelfShelfPlacement]],
                          perched: [String: [(ShelfOrnament, CGSize)]]) -> some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { if hasSelection { deselect() } }
                // 每本书 / 每个摆件底下一抹接触阴影，压在台面上。
                ForEach(row) { placement in
                    contactShadow(placement)
                }
                ForEach(row) { placement in
                    placementView(placement, rows: rows)
                        .zIndex(placement.id == draggingID ? 3
                                : (placement.id == "b:" + (selectedURL ?? "") || placement.id == "f:" + (selectedFolderID ?? "") ? 2 : 0))
                    if let key = placement.item.poseKey, let list = perched[key] {
                        ForEach(Array(list.enumerated()), id: \.offset) { position, perch in
                            perchedOrnamentView(perch.0, size: perch.1, on: placement,
                                                x: perchX(list, position: position, on: placement), rows: rows)
                                .zIndex("o:" + perch.0.id == draggingID ? 3 : 1)
                        }
                    }
                }
                if let marker = insertionMarker, marker.row == rowIndex {
                    Capsule()
                        .fill(LinearGradient(colors: [Color.yellow.opacity(0.35), Color.yellow, Color.yellow.opacity(0.35)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 4, height: rowHeight - 20)
                        .shadow(color: Color.yellow.opacity(0.8), radius: 4)
                        .offset(x: marker.x - 2)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        .zIndex(4)
                }
            }
            .frame(width: contentWidth, height: rowHeight, alignment: .bottomLeading)
            // 书画在层板上面：抽出的书往外挪时书底压在层板前沿上，而不是被层板挡住、看起来跑到层板后面。
            .zIndex(1)
            .overlay(alignment: .topLeading) {
                if showsPicker, let placement = row.first(where: { $0.id == "b:" + (selectedURL ?? "") }),
                   let book = placement.item.book {
                    posePicker(key: book.bookUrl, folderID: nil)
                        .offset(x: pickerX(for: placement), y: max(rowHeight - placement.height - 46, -40))
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottom)))
                } else if let folderID = folderPickerID,
                          let placement = row.first(where: { $0.id == "f:" + folderID }) {
                    posePicker(key: BookshelfShelfItem.folderPoseKey(folderID), folderID: folderID)
                        .offset(x: pickerX(for: placement), y: max(rowHeight - placement.height - 46, -40))
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottom)))
                }
            }
            shelfBoard
        }
    }

    @ViewBuilder
    private func contactShadow(_ placement: BookshelfShelfPlacement) -> some View {
        if placement.id != draggingID {
            let footprint: CGFloat = max(placement.boardMaxX - placement.boardMinX, 4)
            Ellipse()
                .fill(Color.black.opacity(0.3))
                .frame(width: footprint * 0.96, height: 6)
                .blur(radius: 2.5)
                .offset(x: placement.boardMinX + footprint * 0.02, y: 2.5)
                .allowsHitTesting(false)
        }
    }

    private func pickerX(for placement: BookshelfShelfPlacement) -> CGFloat {
        let center = (placement.boardMinX + placement.boardMaxX) / 2
        let width = Self.pickerWidth
        return min(max(center - width / 2, -4), contentWidth - width + 4)
    }

    @ViewBuilder
    private func placementView(_ placement: BookshelfShelfPlacement, rows: [[BookshelfShelfPlacement]]) -> some View {
        let isDragging = placement.id == draggingID
        let isTarget = placement.id == dropTargetID
        Group {
            switch placement.item {
            case .ornament(let ornament, let size):
                ornamentView(ornament, size: size, drag: dragGesture(id: placement.id, index: placement.index, rows: rows))
            case .book(let book):
                spine(book, pose: placement.pose, titleOnTrailing: placement.boardMinX < 40,
                      drag: dragGesture(id: placement.id, index: placement.index, rows: rows))
            case .folder(let folder, let inside):
                folderView(folder, books: inside, pose: placement.pose,
                           drag: dragGesture(id: placement.id, index: placement.index, rows: rows))
            }
        }
        .frame(width: placement.boxSize.width, height: placement.boxSize.height, alignment: .bottomLeading)
        .overlay {
            if isTarget {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Color.yellow, lineWidth: 2)
                    .shadow(color: Color.yellow.opacity(0.9), radius: 5)
                    .rotationEffect(.degrees(rotationDegrees(placement.pose)),
                                    anchor: placement.pose == .leanRight ? .bottomTrailing : .bottomLeading)
                    .allowsHitTesting(false)
            }
        }
        .scaleEffect(isDragging ? 1.06 : (isTarget ? 1.04 : 1), anchor: .bottom)
        .shadow(color: .black.opacity(isDragging ? 0.25 : 0), radius: isDragging ? 8 : 0, y: isDragging ? 6 : 0)
        .offset(x: placement.boxX)
        .offset(isDragging ? dragTranslation : .zero)
    }

    private func rotationDegrees(_ pose: BookshelfShelfPose) -> Double {
        switch pose {
        case .leanLeft: -BookshelfSpine.leanAngle
        case .leanRight: BookshelfSpine.leanAngle
        default: 0
        }
    }

    /// 并排放在平躺书上的第 position 个摆件的横向位置：整组在书上居中。
    private func perchX(_ list: [(ShelfOrnament, CGSize)], position: Int, on placement: BookshelfShelfPlacement) -> CGFloat {
        let total = list.reduce(CGFloat(0)) { $0 + $1.1.width } + CGFloat(max(list.count - 1, 0)) * Self.perchGap
        var x = placement.boxX + max((placement.boxSize.width - total) / 2, 0)
        for index in 0..<position { x += list[index].1.width + Self.perchGap }
        return x
    }

    private func perchedOrnamentView(_ ornament: ShelfOrnament, size: CGSize, on placement: BookshelfShelfPlacement,
                                     x: CGFloat, rows: [[BookshelfShelfPlacement]]) -> some View {
        let id = "o:" + ornament.id
        let isDragging = id == draggingID
        return ornamentView(ornament, size: size, drag: dragGesture(id: id, index: placement.index, rows: rows))
            .scaleEffect(isDragging ? 1.06 : 1, anchor: .bottom)
            .shadow(color: .black.opacity(isDragging ? 0.25 : 0), radius: isDragging ? 8 : 0, y: isDragging ? 6 : 0)
            .offset(x: x, y: -placement.boxSize.height)
            .offset(isDragging ? dragTranslation : .zero)
    }

    // MARK: 拖动

    private func dragGesture(id: String, index: Int, rows: [[BookshelfShelfPlacement]]) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpace)))
            .updating($dragGestureActive) { value, state, _ in
                if case .second(true, _) = value { state = true }
            }
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if draggingID == nil {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    BookshelfLongPressGuard.lift()
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        selectedURL = nil
                        showsPicker = false
                        folderPickerID = nil
                        selectedFolderID = nil
                        draggingID = id
                    }
                    insertionIndex = nil
                    insertionMarker = nil
                    dropTargetID = nil
                    dragMoved = false
                }
                if let drag {
                    dragTranslation = drag.translation
                    if !dragMoved, hypot(drag.translation.width, drag.translation.height) > BookshelfDragSession.moveThreshold {
                        dragMoved = true
                    }
                    // 还没真正拖动时不显示插入黄线、不认合并目标：原地松手是「长按」。
                    if dragMoved { updateDropTarget(at: drag.location, rows: rows) }
                }
            }
    }

    /// 根据手指位置决定：插到两件东西之间（黄线），或者落在某本书 / 文件夹上。
    private func updateDropTarget(at location: CGPoint, rows: [[BookshelfShelfPlacement]]) {
        guard let draggingID, !rows.isEmpty else { return }
        let rowIndex = min(max(Int(floor(location.y / rowPitch)), 0), rows.count - 1)
        let row = rows[rowIndex].filter { $0.id != draggingID }
        let draggingBook = draggingID.hasPrefix("b:")
        let draggingOrnament = draggingID.hasPrefix("o:")

        var target: String?
        for placement in row {
            switch placement.item {
            case .book:
                let width = placement.boardMaxX - placement.boardMinX
                if draggingBook {
                    // 手指在一本书中间一半的范围内：两本书装进一个文件夹。
                    let inset = width * 0.25
                    if location.x > placement.boardMinX + inset, location.x < placement.boardMaxX - inset {
                        target = placement.id
                    }
                } else if draggingOrnament, placement.pose == .flat,
                          location.x > placement.boardMinX, location.x < placement.boardMaxX {
                    // 摆件拖到平躺的书上：放在书上面。
                    target = placement.id
                }
            case .folder:
                // 书拖到文件夹上：放进文件夹（两边留一点给插入位置）；摆件拖到平躺的文件夹上：放在上面。
                let inset = min(8, (placement.boardMaxX - placement.boardMinX) * 0.2)
                if draggingBook, location.x > placement.boardMinX + inset, location.x < placement.boardMaxX - inset {
                    target = placement.id
                } else if draggingOrnament, placement.pose == .flat,
                          location.x > placement.boardMinX, location.x < placement.boardMaxX {
                    target = placement.id
                }
            case .ornament:
                break
            }
            if target != nil { break }
        }
        if target != dropTargetID {
            if target != nil { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
            withAnimation(.easeOut(duration: 0.15)) { dropTargetID = target }
        }
        if target != nil {
            insertionIndex = nil
            insertionMarker = nil
            return
        }

        // 插入位置
        let all = rows[rowIndex]
        var index = (all.last?.index ?? 0) + 1
        var markerX = (row.last?.boardMaxX ?? 0) + spacing / 2 + 1
        for (position, placement) in row.enumerated() {
            if location.x < (placement.boardMinX + placement.boardMaxX) / 2 {
                index = placement.index
                let previousMax = position > 0 ? row[position - 1].boardMaxX : placement.boardMinX - spacing
                markerX = max((previousMax + placement.boardMinX) / 2, 1)
                break
            }
        }
        if insertionIndex != index { UISelectionFeedbackGenerator().selectionChanged() }
        insertionIndex = index
        insertionMarker = (rowIndex, min(markerX, contentWidth - 2))
    }

    private func finishDrag() {
        BookshelfLongPressGuard.end()
        guard let draggingID else { return }
        if !dragMoved {
            // 原地长按松手：书弹出整本书的操作面板；文件夹打开文件夹；摆件打开大小调整。
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                self.draggingID = nil
                dragTranslation = .zero
                insertionIndex = nil
                insertionMarker = nil
                dropTargetID = nil
            }
            if draggingID.hasPrefix("b:") {
                let url = String(draggingID.dropFirst(2))
                if let book = books.first(where: { $0.bookUrl == url }) {
                    BookshelfSheetRouter.shared.sheet = .actions(book)
                }
            } else if draggingID.hasPrefix("f:") {
                let id = String(draggingID.dropFirst(2))
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { folderStore.presentedFolderID = id }
            } else if draggingID.hasPrefix("o:") {
                let id = String(draggingID.dropFirst(2))
                editingOrnament = ornamentStore.placed.first { $0.id == id }
            }
            return
        }
        dragMoved = false
        let items = allItems
        let perched = perchedOrnaments(in: items)
        let perchedIDs = Set(perched.values.flatMap { $0.map { "o:" + $0.0.id } })
        let target = dropTargetID
        let insertion = insertionIndex

        if let target {
            if draggingID.hasPrefix("b:") {
                let sourceURL = String(draggingID.dropFirst(2))
                if let source = books.first(where: { $0.bookUrl == sourceURL }) {
                    if target.hasPrefix("b:") {
                        let destinationURL = String(target.dropFirst(2))
                        if destinationURL != sourceURL,
                           let destination = books.first(where: { $0.bookUrl == destinationURL }) {
                            makeFolder(with: source, and: destination)
                        }
                    } else if target.hasPrefix("f:"), let folder = folderStore.folder(id: String(target.dropFirst(2))) {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                            folderStore.add(source.bookUrl, to: folder.id)
                        }
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        showToast("已放入「\(folder.name)」")
                    }
                }
            } else if draggingID.hasPrefix("o:"),
                      let key = items.first(where: { $0.id == target })?.poseKey {
                let ornamentID = String(draggingID.dropFirst(2))
                // 一本平躺的书上可以并排放几个摆件，放不下时提示，不再把原来的摆件挤下去。
                let width = items.compactMap { item -> CGFloat? in
                    if case .ornament(let ornament, let size) = item, ornament.id == ornamentID { return size.width }
                    return nil
                }.first ?? 0
                let room = perchRoom(for: key, items: items, excluding: ornamentID)
                let othersOnIt = perches.contains { $0.key != ornamentID && $0.value == key }
                if width <= room - (othersOnIt ? Self.perchGap : 0) + 0.5 {
                    perches[ornamentID] = key
                    ShelfOrnamentPerches.save(perches)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } else {
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    showToast("这本书上放不下了，可以先调小摆件")
                }
            }
        } else if let insertion {
            // 序列里不含放在平躺书上的摆件；拖动的是它时先从书上拿下来。
            var sequence = items.map(\.id).filter { !perchedIDs.contains($0) || $0 == draggingID }
            if perchedIDs.contains(draggingID) {
                sequence.removeAll { $0 == draggingID }
                perches.removeValue(forKey: String(draggingID.dropFirst(2)))
                ShelfOrnamentPerches.save(perches)
                let to = min(max(insertion, 0), sequence.count)
                sequence.insert(draggingID, at: to)
            } else if let from = sequence.firstIndex(of: draggingID) {
                var to = min(max(insertion, 0), sequence.count)
                if to != from && to != from + 1 {
                    sequence.remove(at: from)
                    if to > from { to -= 1 }
                    sequence.insert(draggingID, at: to)
                }
            }
            // 保留文件夹里那些书原来的位置记录，书拿出文件夹时回到原处附近。
            let ids = sequence + order.filter { !sequence.contains($0) }
            order = ids
            BookshelfShelfOrder.save(ids)
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            self.draggingID = nil
            dragTranslation = .zero
            insertionIndex = nil
            insertionMarker = nil
            dropTargetID = nil
        }
    }

    // MARK: 文件夹

    /// 把两本书装进一个新文件夹（属于当前书架），文件夹放在目标书原来的位置。
    private func makeFolder(with source: Book, and destination: Book) {
        var ids = order.isEmpty ? allItems.map(\.id) : order
        let folder = withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            folderStore.makeFolder(groupID: groupID, bookURLs: [destination.bookUrl, source.bookUrl])
        }
        if let position = ids.firstIndex(of: "b:" + destination.bookUrl) {
            ids.insert("f:" + folder.id, at: position)
        } else {
            ids.append("f:" + folder.id)
        }
        order = ids
        BookshelfShelfOrder.save(ids)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        showToast("已建立「\(folder.name)」")
    }

    @MainActor
    private func showToast(_ text: String) {
        withAnimation(.easeOut(duration: 0.2)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            if toast == text { withAnimation(.easeIn(duration: 0.2)) { toast = nil } }
        }
    }

    // MARK: 单个物件

    private func ornamentView<G: Gesture>(_ ornament: ShelfOrnament, size: CGSize, drag: G) -> some View {
        Group {
            if let image = ornamentStore.image(for: ornament) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Color.clear
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .onTapGesture {
            guard BookshelfLongPressGuard.allowsTap, draggingID == nil else { return }
            if hasSelection { deselect() } else { editingOrnament = ornament }
        }
        .gesture(drag)
        .accessibilityLabel("书架摆件")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("轻点调整大小或移出书架，长按拖动调整位置")
    }

    private func folderView<G: Gesture>(_ folder: BookshelfFolder, books inside: [Book], pose: BookshelfShelfPose,
                                        drag: G) -> some View {
        let size = BookshelfFolderBox.size(count: inside.count, style: style)
        let isSelected = selectedFolderID == folder.id
        let pull: CGFloat = isSelected ? 1 : 0
        let box = BookshelfFolderBox(folder: folder, books: inside, style: style, isSelected: isSelected) {
            withAnimation(.easeOut(duration: 0.18)) {
                selectedURL = nil
                showsPicker = false
                folderPickerID = folderPickerID == folder.id ? nil : folder.id
            }
        }
        // 抽出：书匣顶部朝读者倾出来（绕底边前倾）、稍微放大往前挪，底下一圈投影，和抽书的感觉一致。
        let pulled = box
            .rotation3DEffect(.degrees(Double(-14 * pull)), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.45)
            .scaleEffect(1 + 0.03 * pull, anchor: .bottom)
            .shadow(color: .black.opacity(0.3 * pull), radius: 4 * pull, x: 0, y: 3 * pull)
        return Group {
            switch pose {
            case .upright:
                pulled
            case .flat:
                // 平躺：盒子侧放，长边贴着层板。
                box
                    .frame(width: size.width, height: size.height)
                    .rotationEffect(.degrees(-90))
                    .frame(width: size.height, height: size.width)
                    .scaleEffect(1 + 0.04 * pull, anchor: .bottom)
                    .shadow(color: .black.opacity(0.3 * pull), radius: 4 * pull, x: 0, y: 3 * pull)
                    .offset(y: 3 * pull)
            case .leanLeft:
                pulled.rotationEffect(.degrees(-BookshelfSpine.leanAngle), anchor: .bottomLeading)
            case .leanRight:
                pulled.rotationEffect(.degrees(BookshelfSpine.leanAngle), anchor: .bottomTrailing)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard BookshelfLongPressGuard.allowsTap, draggingID == nil else { return }
            if isSelected {
                // 第二下：打开文件夹。
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    selectedFolderID = nil
                    folderPickerID = nil
                    folderStore.presentedFolderID = folder.id
                }
            } else {
                // 第一下：抽出（别的书、文件夹收回），正中出现旋转按钮。
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) {
                    selectedURL = nil
                    showsPicker = false
                    folderPickerID = nil
                    selectedFolderID = folder.id
                }
            }
        }
        .gesture(drag)
        .accessibilityLabel("文件夹「\(folder.name)」，\(inside.count) 本书，\(pose.title)")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(isSelected ? "再次轻点打开文件夹" : "轻点抽出，再点一下打开；长按拖动调整位置")
    }

    private func spine<G: Gesture>(_ book: Book, pose: BookshelfShelfPose, titleOnTrailing: Bool = false,
                                   drag: G) -> some View {
        let isSelected = book.bookUrl == selectedURL
        return BookshelfSpine(book: book, pose: pose, isSelected: isSelected, style: style.sized(for: book),
                              appearance: designStore.appearance(for: book, coverSpine: style.coverSpine),
                              titleOnTrailing: titleOnTrailing) {
            withAnimation(.easeOut(duration: 0.18)) { showsPicker.toggle() }
        }
            .onTapGesture {
                guard BookshelfLongPressGuard.allowsTap, draggingID == nil else { return }
                if isSelected {
                    onOpen(.read(book))
                } else {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    // 抽书的动作稍慢、几乎不回弹，像手指把书从一排书里勾出来。
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) {
                        selectedURL = book.bookUrl
                        showsPicker = false
                        folderPickerID = nil
                        selectedFolderID = nil
                    }
                }
            }
            .gesture(drag)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(isSelected ? "再次轻点打开阅读" : "轻点抽出，长按拖动调整位置或拖到另一本书上装进文件夹")
    }

    /// 摆放形态选择条：书和文件夹共用（装扮统一在书架设置 →「书架装扮」里管理）。
    private func posePicker(key: String, folderID: String?) -> some View {
        let current = requestedPose(key: key)
        return HStack(spacing: 0) {
            ForEach(Array(BookshelfShelfPose.allCases.enumerated()), id: \.element.rawValue) { index, item in
                if index > 0 {
                    Rectangle().fill(Color.white.opacity(0.25)).frame(width: 0.5, height: 12)
                }
                Button {
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.8)) {
                        if item == .upright { poses.removeValue(forKey: key) }
                        else { poses[key] = item.rawValue }
                        showsPicker = false
                        folderPickerID = nil
                    }
                    BookshelfShelfPose.save(poses)
                } label: {
                    Text(item.title)
                        .font(AppFontStyle.system(size: 11, weight: item == current ? .semibold : .regular).themed)
                        .foregroundStyle(Color.white.opacity(item == current ? 1 : 0.85))
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background(item == current ? Color.white.opacity(0.22) : Color.clear, in: Capsule())
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(item == current ? .isSelected : [])
            }
        }
        .padding(3)
        .frame(width: Self.pickerWidth)
        .background(Color(white: 0.16).opacity(0.92), in: Capsule())
        // 选择条上的空隙（分隔线、边距）也接住轻点，不再漏到下面的书上（漏下去会打开书或收回书）。
        .contentShape(Capsule())
        .onTapGesture {}
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }

    /// 层板的台面往上伸进书底下面（被书和摆件盖住一截），书和摆件就像放在台面上，而不是在层板后面。
    private var shelfBoard: some View {
        let solid = boardStyle == "solid"
        let tuck: CGFloat = solid ? 6 : 1
        return BookshelfBoard(width: contentWidth, height: (solid ? boardHeight : 5) + tuck, solid: solid)
            .frame(height: boardHeight, alignment: .bottom)
            .allowsHitTesting(false)
    }
}

/// 一层书架的层板。立体：上面是往里退去的台面（靠书的里侧更暗，前沿有一道高光），
/// 下面是正面，再往下投一层柔和阴影——书底压在台面上，读起来是「书放在板上」。
/// 平面：一条带接触阴影的薄板。
struct BookshelfBoard: View {
    @Environment(\.colorScheme) private var colorScheme
    let width: CGFloat
    let height: CGFloat
    var solid: Bool = true

    var body: some View {
        let dark = colorScheme == .dark
        Group {
            if solid {
                let top = max((height * 0.55).rounded(), 5)
                VStack(spacing: 0) {
                    // 台面：里侧被书挡住光线更暗，越往外越亮。
                    Rectangle()
                        .fill(LinearGradient(colors: [dark ? Color(white: 0.13) : Color(white: 0.74),
                                                      dark ? Color(white: 0.22) : Color(white: 0.86),
                                                      dark ? Color(white: 0.27) : Color(white: 0.92)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(height: top)
                        .overlay(alignment: .bottom) {
                            // 前沿高光
                            Rectangle().fill(Color.white.opacity(dark ? 0.18 : 0.9)).frame(height: 0.75)
                        }
                    // 正面
                    Rectangle()
                        .fill(LinearGradient(colors: [dark ? Color(white: 0.24) : Color(white: 0.99),
                                                      dark ? Color(white: 0.15) : Color(white: 0.90)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(height: max(height - top, 4))
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(Color.black.opacity(dark ? 0.5 : 0.12)).frame(height: 0.5)
                        }
                }
                .clipShape(RoundedRectangle(cornerRadius: 2.5, style: .continuous))
                .shadow(color: .black.opacity(dark ? 0.5 : 0.16), radius: 7, y: 6)
            } else {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(LinearGradient(colors: [dark ? Color(white: 0.20) : Color(white: 0.80),
                                                  dark ? Color(white: 0.28) : Color(white: 0.90)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(height: max(min(height, 6), 2))
                    .shadow(color: .black.opacity(dark ? 0.35 : 0.10), radius: 2.5, y: 2)
            }
        }
        .frame(width: width, height: height, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

/// 按给定的点画一个多边形（书的顶面、侧面）。
/// 抽出的书露出的两个面：顶面（书页）和右侧面（封面）。
/// 斜二测投影：横向露出 dx、纵向抬高 dy≈0.55·dx；dx 随 `progress` 从 0 长到满，
/// 所以点下去时能看到书「被拉出来、转出侧面」的过程，而不是侧面突然出现。
private struct BookshelfPulledFaces: View, Animatable {
    var progress: CGFloat
    let book: Book
    /// 书自己已经加载好的封面（有就直接用，第一次抽出也不会先闪占位图）。
    let coverImage: UIImage?
    let width: CGFloat
    let height: CGFloat
    let depth: CGFloat
    let pageColor: Color

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let p = min(max(progress, 0), 1)
        let dx = depth * p, dy = depth * 0.7 * p
        let w = width, h = height
        ZStack(alignment: .topLeading) {
            if dx > 0.5 {
                BookshelfFace(points: [CGPoint(x: 0, y: dy), CGPoint(x: dx, y: 0), CGPoint(x: w + dx, y: 0), CGPoint(x: w, y: dy)])
                    .fill(pageColor)
                ForEach(1..<4) { i in
                    let t = CGFloat(i) / 4
                    BookshelfFace(points: [CGPoint(x: dx * t, y: dy * (1 - t)), CGPoint(x: w + dx * t, y: dy * (1 - t))])
                        .stroke(Color.black.opacity(0.07), lineWidth: 0.5)
                }
                Group {
                    if let coverImage {
                        Image(uiImage: coverImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: max(h * 0.7, depth), height: h)
                    } else {
                        BookCoverArtwork(title: book.name, author: book.author, remoteURL: book.displayCoverUrl,
                                         width: max(h * 0.7, depth), height: h)
                    }
                }
                    .frame(width: depth, height: h, alignment: .leading)
                    .clipped()
                    .overlay(LinearGradient(colors: [Color.black.opacity(0.32), Color.black.opacity(0.05)],
                                            startPoint: .leading, endPoint: .trailing))
                    // 先把封面条压到 dx 宽，再错切成往右上方退去的平行四边形。
                    .transformEffect(CGAffineTransform(a: dx / depth, b: -dy / depth, c: 0, d: 1, tx: w, ty: dy))
            }
        }
        .frame(width: w + depth, height: h + depth, alignment: .topLeading)
        // 外框按满深度留位（布局不随动画变），书脊顶边在框里的 y=depth 处；画面下移让它对上 y=dy。
        .offset(y: depth - dy)
    }
}

private struct BookshelfFace: Shape {
    let points: [CGPoint]
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }
}

/// 书脊的排版：宽高由书架设置决定；书名越长字号越小，单列放不下时分两列；作者竖排在底部。
/// 书脊 / 书匣上的纹理：1 竖条纹，2 格纹，3 圆点，4 斜纹布。
/// 水墨装帧底部的远山：几道起伏的山脊，下沿填满。
struct ShelfHillsShape: Shape {
    var flipped = false
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        let peaks: [(CGFloat, CGFloat)] = flipped
            ? [(0, 0.55), (0.3, 0.05), (0.62, 0.6), (0.85, 0.2), (1, 0.45)]
            : [(0, 0.3), (0.22, 0.65), (0.5, 0.0), (0.78, 0.5), (1, 0.15)]
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + peaks[0].1 * h))
        for index in 1..<peaks.count {
            let prev = peaks[index - 1], next = peaks[index]
            let control = CGPoint(x: rect.minX + (prev.0 + next.0) / 2 * w, y: rect.minY + min(prev.1, next.1) * h)
            path.addQuadCurve(to: CGPoint(x: rect.minX + next.0 * w, y: rect.minY + next.1 * h), control: control)
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct ShelfPatternView: View {
    let kind: Int
    let color: Color

    var body: some View {
        Canvas { context, size in
            var path = Path()
            switch kind {
            case 1:
                var x: CGFloat = 1.5
                while x < size.width { path.addRect(CGRect(x: x, y: 0, width: 0.6, height: size.height)); x += 3 }
            case 2:
                var x: CGFloat = 2
                while x < size.width { path.addRect(CGRect(x: x, y: 0, width: 0.5, height: size.height)); x += 5 }
                var y: CGFloat = 2
                while y < size.height { path.addRect(CGRect(x: 0, y: y, width: size.width, height: 0.5)); y += 5 }
            case 3:
                var row = 0
                var y: CGFloat = 2.5
                while y < size.height {
                    var x: CGFloat = row % 2 == 0 ? 2.5 : 5
                    while x < size.width { path.addEllipse(in: CGRect(x: x - 0.6, y: y - 0.6, width: 1.2, height: 1.2)); x += 5 }
                    y += 4.5
                    row += 1
                }
            case 4:
                var start: CGFloat = -size.width
                while start < size.height {
                    path.move(to: CGPoint(x: 0, y: start))
                    path.addLine(to: CGPoint(x: size.width, y: start + size.width))
                    start += 3.5
                }
                context.stroke(path, with: .color(color), lineWidth: 0.5)
                return
            case 5:
                // 横纹：细横线，像布面书的纹理。
                var y: CGFloat = 1.5
                while y < size.height { path.addRect(CGRect(x: 0, y: y, width: size.width, height: 0.5)); y += 3 }
            case 6:
                // 菱格：两组斜线交叉。
                var start: CGFloat = -size.width
                while start < size.height {
                    path.move(to: CGPoint(x: 0, y: start))
                    path.addLine(to: CGPoint(x: size.width, y: start + size.width))
                    path.move(to: CGPoint(x: 0, y: start + size.width))
                    path.addLine(to: CGPoint(x: size.width, y: start))
                    start += 6
                }
                context.stroke(path, with: .color(color), lineWidth: 0.5)
                return
            default:
                return
            }
            context.fill(path, with: .color(color))
        }
        .allowsHitTesting(false)
    }
}

private struct BookshelfSpineLayout {
    /// 每个字占的行高（按字号的倍数）。每个字单独排、固定行高，不受字体行距影响，算出来的一定放得下。
    static let lineFactor: CGFloat = 1.12
    /// 竖排标点只占半格多一点（实体书竖排也是这样），保留标点又不浪费书脊高度。
    static let punctuationFactor: CGFloat = 0.6

    let fontSize: CGFloat
    /// 书名各列（第一列在最右边），每列是一串单字（标点已换成竖排写法）。
    let columns: [[String]]
    let authorColumns: [[String]]
    let authorFontSize: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat

    /// 横排标点 → 竖排标点（Unicode 竖排字形），书名、作者里的标点全部保留。
    private static let verticalForms: [Character: String] = [
        "，": "︐", ",": "︐", "、": "︑", "。": "︒", ".": "︒", "：": "︓", ":": "︓",
        "；": "︔", ";": "︔", "！": "︕", "!": "︕", "？": "︖", "?": "︖",
        "〖": "︗", "〗": "︘", "…": "︙", "‥": "︰", "—": "︱", "–": "︲", "-": "︲", "～": "︴", "~": "︴",
        "（": "︵", "(": "︵", "）": "︶", ")": "︶", "｛": "︷", "{": "︷", "｝": "︸", "}": "︸",
        "〔": "︹", "〕": "︺", "【": "︻", "[": "︻", "】": "︼", "]": "︼",
        "《": "︽", "》": "︾", "〈": "︿", "〉": "﹀", "<": "︿", ">": "﹀",
        "「": "﹁", "」": "﹂", "『": "﹃", "』": "﹄",
        "“": "﹁", "”": "﹂", "‘": "﹃", "’": "﹄", "\"": "﹁", "'": "﹃"
    ]
    private static let compactSet: Set<String> = Set(verticalForms.values).union(["·", "・", "•"])
    /// 不能出现在一列开头的标点（避头）。
    private static let noLineStart: Set<String> = ["︐", "︑", "︒", "︓", "︔", "︕", "︖", "︘", "︶", "︸", "︺", "︼", "︾", "﹀", "﹂", "﹄", "︙", "︰"]

    static func weight(_ ch: String) -> CGFloat { compactSet.contains(ch) ? punctuationFactor : 1 }
    static func isCompact(_ ch: String) -> Bool { compactSet.contains(ch) }

    static func verticalCharacters(_ text: String) -> [String] {
        var result: [String] = []
        for ch in text where !ch.isWhitespace {
            result.append(verticalForms[ch] ?? String(ch))
        }
        return result
    }

    private static func units(_ chars: [String]) -> CGFloat { chars.reduce(0) { $0 + weight($1) } }

    /// 按高度把字均匀分成 count 列；标点不放在列首（挪到上一列末尾）。
    private static func split(_ chars: [String], into count: Int) -> [[String]] {
        guard count > 1, chars.count > 1 else { return [chars] }
        let target = units(chars) / CGFloat(count)
        var result: [[String]] = []
        var current: [String] = []
        var used: CGFloat = 0
        for ch in chars {
            let w = weight(ch)
            let remainingColumns = count - result.count
            if !current.isEmpty, remainingColumns > 1, used + w > target + 0.3, !noLineStart.contains(ch) {
                result.append(current)
                current = []
                used = 0
            }
            current.append(ch)
            used += w
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func font(for columns: [[String]], width: CGFloat, height: CGFloat, maxFont: CGFloat) -> CGFloat {
        let count = CGFloat(max(columns.count, 1))
        let tallest = columns.map { units($0) }.max() ?? 1
        return min((width - (count + 1)) / count, maxFont, height / (max(tallest, 0.6) * lineFactor))
    }

    /// 排版：保证完整显示（含标点）。先在 maxColumns 列内找不小于 minFont 的最大字号
    /// （多一列要大三成以上才换，避免无谓分列）；放不下时把下限放宽到 floorFont，
    /// 再不行才允许多一列；全都放不下（极端长的书名）才截断并补「︙」。
    private static func arrange(_ chars: [String], width: CGFloat, height: CGFloat, maxFont: CGFloat,
                                minFont: CGFloat, floorFont: CGFloat, maxColumns: Int,
                                extraColumns: Int = 0) -> (columns: [[String]], font: CGFloat) {
        guard chars.count > 1 else {
            return ([chars], max(min(width - 2, maxFont, height / lineFactor), 1))
        }
        func candidates(upTo limit: Int) -> [(cols: [[String]], font: CGFloat)] {
            (1...max(min(limit, chars.count), 1)).map { count in
                let cols = split(chars, into: count)
                return (cols, font(for: cols, width: width, height: height, maxFont: maxFont))
            }
        }
        func pick(_ list: [(cols: [[String]], font: CGFloat)], minimum: CGFloat) -> (columns: [[String]], font: CGFloat)? {
            var best: (columns: [[String]], font: CGFloat)?
            for item in list where item.font >= minimum {
                if let current = best {
                    if item.font > current.font * 1.3 { best = (item.cols, item.font) }
                } else {
                    best = (item.cols, item.font)
                }
            }
            return best
        }
        let normal = candidates(upTo: maxColumns)
        if let best = pick(normal, minimum: minFont) { return best }
        if let best = pick(normal, minimum: floorFont) { return best }
        if extraColumns > 0 {
            let wider = candidates(upTo: maxColumns + extraColumns)
            if let best = pick(Array(wider.dropFirst(maxColumns)), minimum: floorFont) { return best }
        }
        // 实在放不下：按下限字号截断，末尾补竖排省略号（完整书名在抽出时的胶囊里看）。
        let fontSize = min(floorFont, maxFont, max(width - 2, 1))
        let count = max(min(maxColumns + extraColumns, Int((width - 1) / (fontSize + 1))), 1)
        let rows = max(height / (fontSize * lineFactor), 1)
        var result: [[String]] = []
        var current: [String] = []
        var used: CGFloat = 0
        var index = 0
        while index < chars.count {
            let w = weight(chars[index])
            if used + w > rows {
                result.append(current)
                current = []
                used = 0
                if result.count == count { break }
            }
            current.append(chars[index])
            used += w
            index += 1
        }
        if index >= chars.count {
            if !current.isEmpty { result.append(current) }
            return (result, fontSize)
        }
        if var last = result.popLast() {
            if !last.isEmpty { last.removeLast() }
            last.append("︙")
            result.append(last)
        }
        return (result, fontSize)
    }

    init(title: String, author: String, width: CGFloat, height: CGFloat,
         top customTop: CGFloat? = nil, bottom customBottom: CGFloat? = nil, showsAuthor: Bool = true,
         maxFont: CGFloat = 13, maxColumns: Int = 2) {
        let top = customTop ?? (height * 0.05 + 8)
        let bottom = customBottom ?? (height * 0.05 + 6)
        topInset = top
        bottomInset = bottom
        // 书名完整保留（含标点），标点换成竖排写法、只占半格。
        var chars = Self.verticalCharacters(title)
        if chars.isEmpty { chars = ["未", "命", "名"] }

        // 书名默认最多两列，字号不小于 7；长书名放不下时先把下限放宽到 6，
        // 书脊够宽时再允许第三列，尽量完整显示。作者字号不小于 5.5，且不超过书名。
        let authorChars = showsAuthor && width >= 8 ? Self.verticalCharacters(author) : []
        let authorRoom = min(height * 0.24, max(height - top - bottom, 0) * 0.32)
        let titleMin = min(7, max(width * 0.42, 5))
        let titleFloor = min(6, titleMin)
        let authorMin = min(5.5, max(width * 0.36, 4))
        let extra = width >= 20 ? 1 : 0
        func authorLayout(titleFont: CGFloat, room: CGFloat) -> (columns: [[String]], font: CGFloat, space: CGFloat) {
            guard !authorChars.isEmpty else { return ([], 0, 0) }
            let cap = max(min(8, width * 0.42, max(titleFont * 0.82, authorMin)), authorMin)
            // 作者先试单列，单列放不下才分两列。
            var arranged = Self.arrange(authorChars, width: width, height: room, maxFont: cap,
                                        minFont: authorMin, floorFont: authorMin, maxColumns: 1)
            if arranged.columns.joined().contains("︙") {
                arranged = Self.arrange(authorChars, width: width, height: room, maxFont: cap,
                                        minFont: authorMin, floorFont: authorMin, maxColumns: 2)
            }
            let rows = arranged.columns.map { Self.units($0) }.max() ?? 0
            return (arranged.columns, arranged.font, rows * arranged.font * Self.lineFactor + 6)
        }
        func titleLayout(authorSpace: CGFloat) -> (columns: [[String]], font: CGFloat) {
            let usable = max(height - top - bottom - authorSpace, 16)
            return Self.arrange(chars, width: width, height: usable, maxFont: maxFont,
                                minFont: titleMin, floorFont: titleFloor, maxColumns: maxColumns,
                                extraColumns: extra)
        }
        func truncated(_ fit: (columns: [[String]], font: CGFloat)) -> Bool {
            fit.columns.joined().count != chars.count || (fit.columns.last?.last == "︙" && chars.last != "︙")
        }
        // 第一遍：按作者最多占的位置排书名；第二遍：作者实际用得少，把省下的高度还给书名。
        var titleFit = titleLayout(authorSpace: authorChars.isEmpty ? 0 : authorRoom + 6)
        var authorFit = authorLayout(titleFont: titleFit.font, room: authorRoom)
        let refined = titleLayout(authorSpace: authorFit.space)
        if refined.font > titleFit.font
            || (refined.font == titleFit.font && refined.columns.count < titleFit.columns.count)
            || (truncated(titleFit) && !truncated(refined)) {
            titleFit = refined
        }
        // 书名仍放不下：作者让出一部分高度（改为两列），书名优先完整。
        if truncated(titleFit), !authorChars.isEmpty {
            let squeezed = authorLayout(titleFont: titleFit.font, room: authorRoom * 0.55)
            let retry = titleLayout(authorSpace: squeezed.space)
            if !truncated(retry) {
                titleFit = retry
                authorFit = squeezed
            }
        }
        fontSize = max(titleFit.font, 5)
        columns = titleFit.columns
        self.authorColumns = authorFit.columns
        authorFontSize = authorFit.font
    }
}

/// 从封面里取书脊颜色：缩小封面后按色相分组，取占比最大、颜色最鲜明的一组的平均色。
/// 书脊主色缓存。提取结果同时写入 UserDefaults：冷启动时书脊直接用上次算好的颜色，
/// 不会先显示默认色、等封面加载完再变色（打开 App 时书脊「闪一下」变色）。
@MainActor
final class BookshelfSpineTintCache {
    static let shared = BookshelfSpineTintCache()
    private static let storageKey = "bookshelf.spineTints.v1"
    private static let maxStored = 600
    private var tints: [String: UIColor] = [:]
    private var failed = Set<String>()
    private var stored: [String: String]
    private var saveScheduled = false

    private init() {
        stored = UserDefaults.standard.dictionary(forKey: Self.storageKey) as? [String: String] ?? [:]
    }

    /// data: 封面可能很长，用稳定的 FNV-1a 摘要做键（String.hashValue 每次启动都会变）。
    private static func storageID(_ key: String) -> String {
        guard key.count > 160 else { return key }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return "h:" + String(hash, radix: 16) + ":" + String(key.utf8.count)
    }

    func cached(_ key: String?) -> UIColor? {
        guard let key, !key.isEmpty else { return nil }
        if let tint = tints[key] { return tint }
        guard let text = stored[Self.storageID(key)] else { return nil }
        let parts = text.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        let tint = UIColor(red: parts[0], green: parts[1], blue: parts[2], alpha: 1)
        tints[key] = tint
        return tint
    }

    private func remember(_ tint: UIColor, for key: String) {
        tints[key] = tint
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard tint.getRed(&r, green: &g, blue: &b, alpha: &a) else { return }
        if stored.count >= Self.maxStored { stored.removeAll(keepingCapacity: true) }
        stored[Self.storageID(key)] = String(format: "%.4f,%.4f,%.4f", Double(r), Double(g), Double(b))
        guard !saveScheduled else { return }
        saveScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self else { return }
            self.saveScheduled = false
            UserDefaults.standard.set(self.stored, forKey: Self.storageKey)
        }
    }

    func tint(for urlString: String?) async -> UIColor? {
        guard let urlString, !urlString.isEmpty, !failed.contains(urlString) else { return nil }
        if let tint = cached(urlString) { return tint }
        var image: UIImage?
        if urlString.hasPrefix("data:image/"), let comma = urlString.firstIndex(of: ","),
           let data = Data(base64Encoded: String(urlString[urlString.index(after: comma)...])) {
            image = UIImage(data: data)
        } else if let url = URL(string: urlString) {
            image = await CoverImageCache.shared.image(for: url)
        }
        guard let image, let tint = Self.dominantColor(of: image) else {
            if image != nil { failed.insert(urlString) }
            return nil
        }
        remember(tint, for: urlString)
        return tint
    }

    static func dominantColor(of image: UIImage) -> UIColor? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let side = 16
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let small = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        guard let cgImage = small.cgImage else { return nil }
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var sums = [[Double]](repeating: [0, 0, 0, 0], count: 13)
        for i in 0..<(side * side) {
            let r = Double(pixels[i * 4]) / 255
            let g = Double(pixels[i * 4 + 1]) / 255
            let b = Double(pixels[i * 4 + 2]) / 255
            let maxC = max(r, g, b), minC = min(r, g, b)
            let delta = maxC - minC
            let saturation = maxC == 0 ? 0 : delta / maxC
            let bucket: Int
            if saturation < 0.2 || maxC < 0.12 {
                bucket = 12
            } else {
                var hue: Double
                if maxC == r { hue = (g - b) / delta }
                else if maxC == g { hue = (b - r) / delta + 2 }
                else { hue = (r - g) / delta + 4 }
                hue /= 6
                if hue < 0 { hue += 1 }
                bucket = min(Int(hue * 12), 11)
            }
            // 鲜明的颜色权重更高，书脊更像封面的主色。
            let weight = bucket == 12 ? 0.7 : 0.7 + saturation * 1.2
            sums[bucket][0] += r * weight
            sums[bucket][1] += g * weight
            sums[bucket][2] += b * weight
            sums[bucket][3] += weight
        }
        guard let best = sums.max(by: { $0[3] < $1[3] }), best[3] > 0 else { return nil }
        return UIColor(red: best[0] / best[3], green: best[1] / best[3], blue: best[2] / best[3], alpha: 1)
    }
}

/// 一本书：竖立时书名竖排，平躺时横排；选中时露出书页顶面与侧面，像被抽出来一样。
/// 书脊颜色跟随封面主色；开启「封面书脊」时直接显示封面靠书脊的一条。
private struct BookshelfSpine: View {
    let book: Book
    let pose: BookshelfShelfPose
    let isSelected: Bool
    let style: BookshelfShelfStyle
    /// 抽出时书脊上的旋转按钮（修改摆放形态）；为 nil 时不显示（文件夹里的小书）。
    var onRotate: (() -> Void)?
    @State private var tint: UIColor?
    /// 封面书脊用的封面图：放在书自己身上（之前嵌在封面组件里，平躺、抽出时视图重建，
    /// 图片状态丢了，封面就消失变成纯色）。
    @State private var coverImage: UIImage?

    static let leanAngle: Double = 10
    private static let depth: CGFloat = 8
    /// 竖立的书被抽出时侧面露出的宽度（能看到一部分封面），随书脊宽度变化。
    private var pulledDepth: CGFloat { min(max(style.bookWidth * 0.5, 10), 20) }
    /// 抽出的进度 0…1，用来驱动侧面/顶面「慢慢露出来」以及书往外挪的动画。
    private var pull: CGFloat { isSelected ? 1 : 0 }

    private static let palette: [(CGFloat, CGFloat, CGFloat)] = [
        (0.25, 0.18, 0.12), (0.17, 0.20, 0.27), (0.30, 0.21, 0.13), (0.22, 0.17, 0.14),
        (0.15, 0.17, 0.21), (0.27, 0.19, 0.15)
    ]

    /// 抽出时的书名浮标放在书的右边（书在一层最左边、左边没地方时）。
    var titleOnTrailing = false
    /// 换装：装帧样式与自定义颜色。
    var appearance = BookshelfSpineAppearance()

    init(book: Book, pose: BookshelfShelfPose, isSelected: Bool, style: BookshelfShelfStyle,
         appearance: BookshelfSpineAppearance = BookshelfSpineAppearance(),
         titleOnTrailing: Bool = false, onRotate: (() -> Void)? = nil) {
        self.titleOnTrailing = titleOnTrailing
        self.appearance = appearance
        self.book = book
        self.pose = pose
        self.isSelected = isSelected
        self.style = style
        self.onRotate = onRotate
        _tint = State(initialValue: BookshelfSpineTintCache.shared.cached(book.coverUrl))
        _coverImage = State(initialValue: appearance.design == .cover ? Self.cachedCover(book.coverUrl) : nil)
    }

    /// 只查内存/磁盘缓存（以及 data: 内嵌封面），第一帧就能画出来。
    static func cachedCover(_ urlString: String?) -> UIImage? {
        guard let urlString, !urlString.isEmpty else { return nil }
        if urlString.hasPrefix("data:image/"), let comma = urlString.firstIndex(of: ",") {
            return Data(base64Encoded: String(urlString[urlString.index(after: comma)...])).flatMap(UIImage.init(data:))
        }
        return URL(string: urlString).flatMap { CoverImageCache.shared.cachedImage(for: $0) }
    }

    nonisolated static func seed(_ book: Book) -> Int {
        book.name.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF }
    }

    private var design: BookshelfSpineDesign {
        appearance.design.resolved(for: book, coverSpine: style.coverSpine)
    }

    private var customText: Color? {
        UIColor(shelfHex: appearance.textHex).map { Color($0) }
    }

    private var showsCover: Bool { design == .cover }

    /// 自定义装帧的部件。
    private var parts: ShelfSpineStyle? { design == .custom ? appearance.parts : nil }

    private var accentColor: Color {
        Color(UIColor(shelfHex: parts?.accent) ?? UIColor(red: 0.93, green: 0.91, blue: 0.86, alpha: 1))
    }

    /// 书脊底色：自定义颜色优先；否则取封面主色，太亮时稍微压暗，免得和书架背景混在一起。
    private var baseColor: UIColor {
        if let custom = UIColor(shelfHex: appearance.colorHex) { return custom }
        guard let tint else {
            let c = Self.palette[Self.seed(book) % Self.palette.count]
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard tint.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return tint }
        return UIColor(hue: h, saturation: min(s * 1.05, 1), brightness: min(b, 0.9), alpha: 1)
    }

    private var isLight: Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        baseColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        return 0.299 * r + 0.587 * g + 0.114 * b > 0.62
    }

    private static func luminance(_ color: UIColor) -> CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return 0.299 * r + 0.587 * g + 0.114 * b
    }

    /// 调亮度（倍数），用于封面书脊的渐变底。
    private static func shade(_ color: UIColor, _ factor: CGFloat) -> Color {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return Color(color) }
        return Color(UIColor(hue: h, saturation: s, brightness: min(max(b * factor, 0), 1), alpha: 1))
    }

    private static let cream = Color(red: 0.95, green: 0.91, blue: 0.80)

    private var textColor: Color {
        if design != .cover, let customText { return customText }
        switch design {
        case .cover: return isLight ? Color(white: 0.12) : Color.white.opacity(0.95)
        case .thread, .inkwash, .tripart: return Self.ink
        case .gilded, .ribbed: return Self.gold
        case .framed: return isLight ? Self.ink : Self.cream
        default: return isLight ? Color(white: 0.13) : Color.white.opacity(0.94)
        }
    }

    private static let paper = Color(red: 0.94, green: 0.90, blue: 0.81)
    private static let ink = Color(red: 0.20, green: 0.15, blue: 0.11)
    private static let gold = Color(red: 0.88, green: 0.73, blue: 0.44)
    private static let seal = Color(red: 0.72, green: 0.16, blue: 0.13)

    /// 书脊的底：线装、水墨是宣纸色，烫金、竹节把底色压暗（像皮面），其他用底色。
    private var fillColor: Color {
        switch design {
        case .thread, .inkwash: return Self.paper
        case .gilded, .ribbed:
            var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            baseColor.getHue(&h, saturation: &sat, brightness: &b, alpha: &a)
            return Color(UIColor(hue: h, saturation: min(sat * 1.1, 1), brightness: min(b * 0.62, 0.42), alpha: 1))
        default: return Color(baseColor)
        }
    }

    private var title: String {
        let name = book.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "未命名" : name
    }

    private var pageColor: Color { Color(red: 0.95, green: 0.91, blue: 0.82) }

    private var roundShading: LinearGradient {
        LinearGradient(stops: [
            .init(color: .black.opacity(0.24), location: 0),
            .init(color: .white.opacity(0.16), location: 0.2),
            .init(color: .clear, location: 0.48),
            .init(color: .black.opacity(0.08), location: 0.8),
            .init(color: .black.opacity(0.28), location: 1)
        ], startPoint: .leading, endPoint: .trailing)
    }

    /// 书脊正面：按装帧样式画底色、装饰（色带、标签、线装针脚、印章、烫金线），再排书名和作者。
    private var uprightFront: some View { spineFace(showsTitle: !style.hideTitles) }

    /// 竖立的书脊正面；平躺时把它整个转过来用，花纹、书名作者和竖立时一样。
    private func spineFace(showsTitle: Bool) -> some View {
        let w = style.bookWidth, h = style.bookHeight
        return ZStack(alignment: .topLeading) {
            if showsCover {
                coverArt(width: w, height: h)
            } else {
                fillColor
            }
            decorations(width: w, height: h)
            if showsTitle {
                titleBlock(width: w, height: h)
            }
            // 圆脊明暗与顶端一道细高光，书脊看起来有弧度、有厚度。
            roundShading.opacity(design == .thread || design == .inkwash ? 0.55 : 1)
                .allowsHitTesting(false)
            VStack(spacing: 0) {
                Rectangle().fill(Color.white.opacity(0.22)).frame(height: 0.6)
                Spacer(minLength: 0)
                Rectangle().fill(Color.black.opacity(0.18)).frame(height: 0.6)
            }
            .allowsHitTesting(false)
        }
        .frame(width: w, height: h)
        .clipShape(RoundedRectangle(cornerRadius: min(2, w * 0.08), style: .continuous))
    }

    /// 封面书脊顶部那张小封面的位置。
    private func coverThumbRect(width w: CGFloat, height h: CGFloat) -> CGRect {
        let inset = min(max(w * 0.1, 2), 4)
        let tw = max(w - inset * 2, 4)
        // 长书名时小封面让出高度给书名，保证书名完整显示。
        let titleLength = title.filter { !$0.isWhitespace }.count
        let cap: CGFloat = titleLength > 12 ? 0.16 : (titleLength > 8 ? 0.2 : 0.27)
        let th = min(tw / 0.72, h * cap)
        return CGRect(x: inset, y: inset + 1, width: tw, height: th)
    }

    /// 封面书脊（重新设计，不再模糊）：底色取封面主色做上亮下暗的渐变，
    /// 顶部嵌一张清晰的完整小封面（带细白边和投影，像书脊上的封面贴标），书名作者印在下面的纯色区，
    /// 字号和之前封面书脊一样大，不会和封面上的字叠在一起。
    @ViewBuilder private func coverArt(width w: CGFloat, height h: CGFloat) -> some View {
        let r = coverThumbRect(width: w, height: h)
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Self.shade(baseColor, 1.15), Color(baseColor), Self.shade(baseColor, 0.78)],
                           startPoint: .top, endPoint: .bottom)
            Group {
                if let coverImage {
                    Image(uiImage: coverImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.white.opacity(0.14)
                }
            }
            .frame(width: r.width, height: r.height)
            .clipShape(RoundedRectangle(cornerRadius: 1.5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .strokeBorder(Color.white.opacity(0.45), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.35), radius: 1, y: 0.6)
            .offset(x: r.minX, y: r.minY)
            Rectangle()
                .fill(textColor.opacity(0.35))
                .frame(width: r.width * 0.5, height: 0.6)
                .offset(x: r.minX + r.width * 0.25, y: r.maxY + 3)
        }
        .frame(width: w, height: h, alignment: .topLeading)
        .clipped()
    }

    /// 一道竹节横棱（皮面书脊上凸起的横带）：上亮下暗。
    private func rib(width: CGFloat) -> some View {
        LinearGradient(colors: [Color.white.opacity(0.32), Color.black.opacity(0.05), Color.black.opacity(0.45)],
                       startPoint: .top, endPoint: .bottom)
            .frame(width: width, height: 3.5)
    }

    private func diamond(_ color: Color, size: CGFloat) -> some View {
        Rectangle().fill(color)
            .frame(width: size, height: size)
            .rotationEffect(.degrees(45))
            .frame(width: size * 1.42, height: size * 1.42)
    }

    private func sealView(size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(Self.seal)
            .overlay(RoundedRectangle(cornerRadius: 0.5).strokeBorder(Color.white.opacity(0.7), lineWidth: 0.5).padding(1.2))
            .frame(width: size, height: size)
    }

    /// 各装帧样式的装饰。
    @ViewBuilder private func decorations(width w: CGFloat, height h: CGFloat) -> some View {
        switch design {
        case .classic:
            // 顶部浅色书标 + 底部一枚小圆点（典藏本）。
            let band = max(h * 0.075, 8)
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(Color(red: 0.93, green: 0.91, blue: 0.86))
                    .frame(width: w, height: band)
                    .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.15)).frame(height: 0.5) }
                    .offset(y: h * 0.06)
                Circle()
                    .fill(textColor.opacity(0.75))
                    .frame(width: min(max(w * 0.16, 3), 5), height: min(max(w * 0.16, 3), 5))
                    .offset(y: h * 0.91)
            }
            .frame(width: w, height: h, alignment: .top)
        case .label:
            // 顶部一小条标签、底部小圆点；书签纸贴着书名长短伸缩（在书名区里画）。
            ZStack(alignment: .top) {
                Capsule()
                    .fill(Color.white.opacity(0.8))
                    .frame(width: w * 0.46, height: max(h * 0.035, 4))
                    .offset(y: h * 0.07)
                Circle()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: min(max(w * 0.14, 3), 4.5), height: min(max(w * 0.14, 3), 4.5))
                    .offset(y: h * 0.9)
            }
            .frame(width: w, height: h, alignment: .top)
        case .thread:
            threadDecorations(width: w, height: h)
        case .gilded:
            // 烫金：上下两组金色饰线。
            let gold = Self.gold
            VStack(spacing: 0) {
                VStack(spacing: 2) {
                    Rectangle().fill(gold).frame(height: 1.2)
                    Rectangle().fill(gold.opacity(0.8)).frame(height: 0.5)
                }
                .padding(.top, h * 0.05)
                Spacer(minLength: 0)
                VStack(spacing: 2) {
                    Rectangle().fill(gold.opacity(0.8)).frame(height: 0.5)
                    Rectangle().fill(gold).frame(height: 1.2)
                }
                .padding(.bottom, h * 0.05)
            }
            .frame(width: w, height: h)
        case .tripart:
            tripartDecorations(width: w, height: h)
        case .ribbed:
            ribbedDecorations(width: w, height: h)
        case .inkwash:
            inkwashDecorations(width: w, height: h)
        case .framed:
            framedDecorations(width: w, height: h)
        case .plain:
            EmptyView()
        case .custom:
            customDecorations(width: w, height: h)
        case .cover, .auto:
            EmptyView()
        }
    }

    private func threadDecorations(width w: CGFloat, height h: CGFloat) -> some View {
        // 线装：左侧一条装订布边和白色针脚，上下细双线，底部朱红印章。
        let edge = max(w * 0.15, 2.5)
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Color(baseColor)).frame(width: edge, height: h)
            ForEach(0..<5, id: \.self) { i in
                Rectangle()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: edge + 1.5, height: 0.8)
                    .offset(y: h * (0.1 + CGFloat(i) * 0.2))
            }
            VStack(spacing: 0) {
                VStack(spacing: 1.5) {
                    Rectangle().fill(Self.ink.opacity(0.35)).frame(height: 0.5)
                    Rectangle().fill(Self.ink.opacity(0.35)).frame(height: 0.5)
                }
                .padding(.top, h * 0.045)
                Spacer(minLength: 0)
                sealView(size: min(max(w * 0.38, 5), 10))
                    .padding(.bottom, h * 0.06)
            }
            .padding(.leading, edge + 1)
            .frame(width: w, height: h)
        }
        .frame(width: w, height: h, alignment: .topLeading)
    }

    /// 三段：上下保留底色，中间一条米色书名带（像经典文库本）。
    private func tripartDecorations(width w: CGFloat, height h: CGFloat) -> some View {
        let ring = min(max(w * 0.34, 5), 10)
        return ZStack(alignment: .top) {
            Rectangle()
                .fill(Self.paper)
                .frame(width: w, height: h * 0.78)
                .overlay(alignment: .top) { Rectangle().fill(Color.black.opacity(0.2)).frame(height: 0.6) }
                .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.2)).frame(height: 0.6) }
                .offset(y: h * 0.11)
            Circle()
                .strokeBorder(Color.white.opacity(0.85), lineWidth: 0.8)
                .frame(width: ring, height: ring)
                .offset(y: max(h * 0.055 - ring / 2, 2))
            Capsule()
                .fill(Color.white.opacity(0.75))
                .frame(width: w * 0.4, height: 1.2)
                .offset(y: h * 0.945)
        }
        .frame(width: w, height: h, alignment: .top)
    }

    /// 竹节：皮面书脊上下各两道凸起的横棱，最上、最下一道金线，顶部一枚金色菱形。
    private func ribbedDecorations(width w: CGFloat, height h: CGFloat) -> some View {
        let d = min(max(w * 0.2, 3), 5)
        return ZStack(alignment: .top) {
            Rectangle().fill(Self.gold.opacity(0.85)).frame(width: w, height: 0.6).offset(y: h * 0.03)
            diamond(Self.gold, size: d).offset(y: h * 0.055)
            rib(width: w).offset(y: h * 0.085)
            rib(width: w).offset(y: h * 0.115)
            rib(width: w).offset(y: h * 0.855)
            rib(width: w).offset(y: h * 0.885)
            Rectangle().fill(Self.gold.opacity(0.85)).frame(width: w, height: 0.6).offset(y: h * 0.96)
        }
        .frame(width: w, height: h, alignment: .top)
    }

    /// 水墨：宣纸底，顶部一枚小朱印，底部淡墨晕染 + 远山。
    private func inkwashDecorations(width w: CGFloat, height h: CGFloat) -> some View {
        let wash = isLight ? Self.ink : Color(baseColor)
        let sealSize = min(max(w * 0.3, 4.5), 8)
        return ZStack(alignment: .top) {
            sealView(size: sealSize).offset(y: h * 0.04)
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                ZStack(alignment: .bottom) {
                    LinearGradient(colors: [wash.opacity(0), wash.opacity(0.35)], startPoint: .top, endPoint: .bottom)
                    ShelfHillsShape().fill(wash.opacity(0.55)).frame(height: h * 0.11)
                    ShelfHillsShape(flipped: true).fill(wash.opacity(0.8)).frame(height: h * 0.065)
                }
                .frame(width: w, height: h * 0.2)
            }
            .frame(width: w, height: h)
        }
        .frame(width: w, height: h, alignment: .top)
    }

    /// 双框：通身一粗一细两道框线，顶部、底部各一枚小菱形。
    private func framedDecorations(width w: CGFloat, height h: CGFloat) -> some View {
        let line = textColor
        let d = min(max(w * 0.16, 2.5), 4)
        return ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .strokeBorder(line.opacity(0.85), lineWidth: 0.8)
                .padding(1.5)
            RoundedRectangle(cornerRadius: 0.5, style: .continuous)
                .strokeBorder(line.opacity(0.6), lineWidth: 0.4)
                .padding(3.2)
            diamond(line.opacity(0.85), size: d).offset(y: h * 0.035)
            diamond(line.opacity(0.85), size: d).offset(y: h * 0.965 - d * 1.42)
        }
        .frame(width: w, height: h, alignment: .top)
    }

    /// 自定义装帧：纹理、布边、顶部、底部按部件组合（书名区在书名排版里画，贴着书名伸缩）。
    @ViewBuilder private func customDecorations(width w: CGFloat, height h: CGFloat) -> some View {
        if let p = parts {
            let accent = accentColor
            let edge: CGFloat = (p.edge ?? 0) == 1 ? max(w * 0.15, 2.5) : 0
            let inner = w - edge
            ZStack(alignment: .topLeading) {
                ShelfPatternView(kind: p.texture ?? 0, color: textColor.opacity(0.14))
                    .frame(width: w, height: h)
                if edge > 0 {
                    Rectangle().fill(accent).frame(width: edge, height: h)
                    ForEach(0..<5, id: \.self) { i in
                        Rectangle()
                            .fill(Color.white.opacity(0.85))
                            .frame(width: edge + 1.5, height: 0.8)
                            .offset(y: h * (0.1 + CGFloat(i) * 0.2))
                    }
                }
                customTop(p.top ?? 0, accent: accent, edge: edge, inner: inner, height: h)
                customBottom(p.bottom ?? 0, accent: accent, edge: edge, inner: inner, width: w, height: h)
            }
            .frame(width: w, height: h, alignment: .topLeading)
        }
    }

    private func customDiamondSize(inner: CGFloat) -> CGFloat { min(max(inner * 0.24, 3), 5.5) }

    @ViewBuilder private func customTop(_ kind: Int, accent: Color, edge: CGFloat, inner: CGFloat, height h: CGFloat) -> some View {
        let band = max(h * 0.075, 8)
        switch kind {
        case 1:
            Rectangle().fill(accent)
                .frame(width: inner, height: band)
                .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.15)).frame(height: 0.5) }
                .offset(x: edge, y: h * 0.06)
        case 2:
            VStack(spacing: 2) {
                Rectangle().fill(accent).frame(height: 1.2)
                Rectangle().fill(accent.opacity(0.8)).frame(height: 0.5)
            }
            .frame(width: inner)
            .offset(x: edge, y: h * 0.05)
        case 3:
            Rectangle().fill(accent).frame(width: inner, height: h * 0.09).offset(x: edge)
        case 4:
            let d = customDiamondSize(inner: inner)
            diamond(accent, size: d).offset(x: edge + (inner - d * 1.42) / 2, y: h * 0.05)
        case 5:
            ZStack(alignment: .topLeading) {
                rib(width: inner).offset(y: h * 0.085)
                rib(width: inner).offset(y: h * 0.115)
            }
            .offset(x: edge)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private func customBottom(_ kind: Int, accent: Color, edge: CGFloat, inner: CGFloat,
                                           width w: CGFloat, height h: CGFloat) -> some View {
        let dot = min(max(w * 0.16, 3), 5)
        let sealSize = min(max(w * 0.38, 5), 10)
        switch kind {
        case 1:
            Circle().fill(accent)
                .frame(width: dot, height: dot)
                .offset(x: edge + (inner - dot) / 2, y: h * 0.91)
        case 2:
            VStack(spacing: 2) {
                Rectangle().fill(accent.opacity(0.8)).frame(height: 0.5)
                Rectangle().fill(accent).frame(height: 1.2)
            }
            .frame(width: inner)
            .offset(x: edge, y: h * 0.95 - 3.7)
        case 3:
            sealView(size: sealSize)
                .offset(x: edge + (inner - sealSize) / 2, y: h * 0.94 - sealSize)
        case 4:
            Rectangle().fill(accent).frame(width: inner, height: h * 0.09).offset(x: edge, y: h * 0.91)
        case 5:
            let d = customDiamondSize(inner: inner)
            diamond(accent, size: d).offset(x: edge + (inner - d * 1.42) / 2, y: h * 0.95 - d * 1.42)
        case 6:
            ZStack(alignment: .topLeading) {
                rib(width: inner).offset(y: h * 0.84)
                rib(width: inner).offset(y: h * 0.87)
            }
            .offset(x: edge)
        default:
            EmptyView()
        }
    }

    /// 书名区：top/bottom 上下留白，leading/width 书名文字所在的范围；
    /// panel 书名底衬（0 无，1 书签纸，2 描边框，3 通栏色带，4 胶囊，5 上下饰线），
    /// 底衬左右比文字多出 padH、上下多出 padV，高度贴着书名的长短。
    private struct TitleMetrics {
        var top: CGFloat
        var bottom: CGFloat
        var leading: CGFloat
        var width: CGFloat
        var color: Color
        var panel: Int = 0
        var panelColor: Color = .clear
        var padH: CGFloat = 0
        var padV: CGFloat = 0
    }

    /// 给书名加底衬：在给定的文字范围（leading/width）上让出底衬的边距。
    private func withPanel(_ m: TitleMetrics, kind: Int, color panelColor: Color, textColor: Color,
                           areaLeading: CGFloat, areaWidth: CGFloat) -> TitleMetrics {
        guard kind != 0 else { return m }
        var result = m
        let padH: CGFloat
        switch kind {
        case 1, 2: padH = max(areaWidth * 0.07, 2)
        case 4: padH = max(areaWidth * 0.1, 2.5)
        default: padH = 0
        }
        let padV: CGFloat = kind == 4 ? max(areaWidth * 0.32, 4) : (kind == 5 ? 5 : 4)
        result.panel = kind
        result.panelColor = panelColor
        result.padH = padH
        result.padV = padV
        result.leading = areaLeading + padH + (kind == 3 ? 0 : 0.5)
        result.width = max(areaWidth - padH * 2 - (kind == 3 ? 0 : 1), 6)
        result.top = m.top + padV
        result.bottom = m.bottom + padV
        result.color = textColor
        return result
    }

    private func contrastText(on color: UIColor) -> Color {
        Self.luminance(color) > 0.6 ? Self.ink : Color.white.opacity(0.95)
    }

    private func titleMetrics(width w: CGFloat, height h: CGFloat) -> TitleMetrics {
        switch design {
        case .cover:
            let r = coverThumbRect(width: w, height: h)
            return TitleMetrics(top: r.maxY + 8, bottom: h * 0.05 + 6, leading: 0, width: w, color: textColor)
        case .classic:
            return TitleMetrics(top: h * 0.06 + max(h * 0.075, 8) + 6, bottom: h * 0.11, leading: 0, width: w, color: textColor)
        case .label:
            let base = TitleMetrics(top: h * 0.11 + 2, bottom: h * 0.1 + 4, leading: 0, width: w, color: textColor)
            return withPanel(base, kind: 1, color: Color(red: 0.96, green: 0.95, blue: 0.92),
                             textColor: customText ?? Self.ink, areaLeading: 0, areaWidth: w)
        case .thread:
            let edge = max(w * 0.15, 2.5)
            return TitleMetrics(top: h * 0.045 + 8, bottom: h * 0.06 + min(max(w * 0.38, 5), 10) + 6,
                                leading: edge + 1, width: w - edge - 1, color: textColor)
        case .gilded:
            return TitleMetrics(top: h * 0.05 + 10, bottom: h * 0.05 + 9, leading: 0, width: w, color: textColor)
        case .tripart:
            return TitleMetrics(top: h * 0.11 + 5, bottom: h * 0.11 + 4, leading: 0, width: w, color: textColor)
        case .ribbed:
            return TitleMetrics(top: h * 0.115 + 3.5 + 4, bottom: h * 0.145 + 4, leading: 0, width: w, color: textColor)
        case .inkwash:
            return TitleMetrics(top: h * 0.04 + min(max(w * 0.3, 4.5), 8) + 6, bottom: h * 0.2 + 2,
                                leading: 0, width: w, color: textColor)
        case .framed:
            return TitleMetrics(top: h * 0.035 + min(max(w * 0.16, 2.5), 4) * 1.42 + 6,
                                bottom: h * 0.035 + min(max(w * 0.16, 2.5), 4) * 1.42 + 5,
                                leading: 3.5, width: w - 7, color: textColor)
        case .custom:
            guard let p = parts else { return TitleMetrics(top: h * 0.05 + 6, bottom: h * 0.05 + 6, leading: 0, width: w, color: textColor) }
            let edge: CGFloat = (p.edge ?? 0) == 1 ? max(w * 0.15, 2.5) + 1 : 0
            let inner = w - edge
            let d = customDiamondSize(inner: inner) * 1.42
            let top: CGFloat
            switch p.top ?? 0 {
            case 1: top = h * 0.06 + max(h * 0.075, 8) + 6
            case 2: top = h * 0.05 + 10
            case 3: top = h * 0.09 + 5
            case 4: top = h * 0.05 + d + 5
            case 5: top = h * 0.115 + 3.5 + 4
            default: top = h * 0.05 + 6
            }
            let bottom: CGFloat
            switch p.bottom ?? 0 {
            case 1: bottom = h * 0.11
            case 2: bottom = h * 0.05 + 9
            case 3: bottom = h * 0.06 + min(max(w * 0.38, 5), 10) + 6
            case 4: bottom = h * 0.09 + 5
            case 5: bottom = h * 0.05 + d + 5
            case 6: bottom = h * 0.16 + 4
            default: bottom = h * 0.05 + 6
            }
            let base = TitleMetrics(top: top, bottom: bottom, leading: edge, width: inner, color: textColor)
            let accentUI = UIColor(shelfHex: p.accent) ?? UIColor(red: 0.93, green: 0.91, blue: 0.86, alpha: 1)
            let kind = p.panel ?? 0
            switch kind {
            case 1:
                return withPanel(base, kind: 1, color: Color(red: 0.96, green: 0.95, blue: 0.92),
                                 textColor: customText ?? Self.ink, areaLeading: edge, areaWidth: inner)
            case 3, 4:
                return withPanel(base, kind: kind, color: Color(accentUI),
                                 textColor: customText ?? contrastText(on: accentUI), areaLeading: edge, areaWidth: inner)
            case 2, 5:
                return withPanel(base, kind: kind, color: Color(accentUI),
                                 textColor: textColor, areaLeading: edge, areaWidth: inner)
            default:
                return base
            }
        default:
            return TitleMetrics(top: h * 0.05 + 6, bottom: h * 0.05 + 6, leading: 0, width: w, color: textColor)
        }
    }

    private var titleUsesSerif: Bool { parts?.serif ?? true }

    /// 书名底衬，铺满给它的大小（宽度固定、高度贴着书名）。
    @ViewBuilder private func panelBackground(_ m: TitleMetrics) -> some View {
        switch m.panel {
        case 1:
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(m.panelColor)
                .shadow(color: .black.opacity(0.18), radius: 0.6, y: 0.4)
        case 2:
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .strokeBorder(m.panelColor, lineWidth: 0.8)
        case 3:
            Rectangle()
                .fill(m.panelColor)
                .overlay(alignment: .top) { Rectangle().fill(Color.black.opacity(0.18)).frame(height: 0.5) }
                .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.18)).frame(height: 0.5) }
        case 4:
            Capsule().fill(m.panelColor)
                .overlay(Capsule().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
        case 5:
            VStack(spacing: 0) {
                VStack(spacing: 1.2) {
                    Rectangle().fill(m.panelColor).frame(height: 0.9)
                    Rectangle().fill(m.panelColor.opacity(0.7)).frame(height: 0.4)
                }
                Spacer(minLength: 0)
                VStack(spacing: 1.2) {
                    Rectangle().fill(m.panelColor.opacity(0.7)).frame(height: 0.4)
                    Rectangle().fill(m.panelColor).frame(height: 0.9)
                }
            }
            .padding(.horizontal, 2)
        default:
            EmptyView()
        }
    }

    private func titleColumns(_ layout: BookshelfSpineLayout) -> some View {
        let lineHeight = layout.fontSize * BookshelfSpineLayout.lineFactor
        return HStack(alignment: .top, spacing: 1) {
            // 竖排从右往左读，第一列放在最右边。
            ForEach(Array(layout.columns.enumerated().reversed()), id: \.offset) { _, column in
                VStack(spacing: 0) {
                    ForEach(Array(column.enumerated()), id: \.offset) { _, ch in
                        Text(ch)
                            .font(AppFontStyle.system(size: layout.fontSize,
                                                      weight: design == .plain ? .medium : .semibold,
                                                      design: titleUsesSerif ? .serif : .default).themed)
                            .frame(height: lineHeight * BookshelfSpineLayout.weight(ch))
                            .fixedSize()
                    }
                }
            }
        }
    }

    private func authorColumns(_ layout: BookshelfSpineLayout) -> some View {
        let authorLine = layout.authorFontSize * BookshelfSpineLayout.lineFactor
        return HStack(alignment: .top, spacing: 1) {
            ForEach(Array(layout.authorColumns.enumerated().reversed()), id: \.offset) { _, column in
                VStack(spacing: 0) {
                    ForEach(Array(column.enumerated()), id: \.offset) { _, ch in
                        Text(ch)
                            .font(AppFontStyle.system(size: layout.authorFontSize, weight: .regular).themed)
                            .frame(height: authorLine * BookshelfSpineLayout.weight(ch))
                            .fixedSize()
                    }
                }
            }
        }
    }

    /// 书名（竖排，放不下时自动分列、保证完整）和作者（底部，同样完整显示）。
    /// 有底衬时底衬宽度固定、高度贴着书名，书名短就短、长就长，不再是固定大小的方框。
    private func titleBlock(width w: CGFloat, height h: CGFloat) -> some View {
        let m = titleMetrics(width: w, height: h)
        // 封面书脊上方被小封面占去一截，书名最多两列且字更大，宁可截断也不排成三列细字。
        let layout = BookshelfSpineLayout(title: title, author: book.author, width: m.width, height: h,
                                          top: m.top, bottom: m.bottom, showsAuthor: true, maxFont: 13,
                                          maxColumns: 2)
        // 作者印在底衬外面的书脊上，用书脊的文字颜色（三段装帧的作者在米色带里，文字色本来就是墨色）。
        let authorColor = textColor
        return VStack(spacing: 0) {
            titleColumns(layout)
                .foregroundStyle(m.color)
                .padding(.vertical, m.padV)
                .frame(width: m.width + m.padH * 2 + (m.panel == 0 || m.panel == 3 ? 0 : 1))
                .background { panelBackground(m) }
                .padding(.top, max(layout.topInset - m.padV, 0))
            Spacer(minLength: 0)
            if !layout.authorColumns.isEmpty {
                authorColumns(layout)
                    .foregroundStyle(authorColor)
                    .opacity(0.75)
                    .padding(.bottom, layout.bottomInset - m.padV)
            }
        }
        .frame(width: m.width, height: h)
        .offset(x: m.leading)
    }

    /// 抽出时露出的顶面（书页）与右侧面（封面）。见 `BookshelfPulledFaces`。
    private var uprightDepthFaces: some View {
        BookshelfPulledFaces(progress: pull, book: book, coverImage: coverImage, width: style.bookWidth,
                             height: style.bookHeight, depth: pulledDepth, pageColor: pageColor)
    }

    /// 平躺：书脊朝外横放，就是把竖立的书脊整个转 90°——底色、花纹、饰带、书名和作者
    /// 都和竖立时一模一样（像现实里把书放倒），不再另排横向书名。
    private var flatFront: some View {
        let w = style.bookHeight, h = style.bookWidth
        return spineFace(showsTitle: !style.hideTitles)
            .rotationEffect(.degrees(-90))
            .frame(width: w, height: h)
    }

    /// 平躺抽出时露出的封面（顶面）与书页（右端）。顶面画真正的封面（之前只是一块底色，看不到封面）：
    /// 封面转 90°（书顶朝左、书脊一侧朝外），压扁成顶面的高度，再错切成往右上退去的平行四边形。
    private var flatDepthFaces: some View {
        let w = style.bookHeight, h = style.bookWidth, d = Self.depth
        let coverWidth = max(w * 0.7, 1)
        return ZStack(alignment: .topLeading) {
            BookshelfFace(points: [CGPoint(x: 0, y: d), CGPoint(x: d, y: 0), CGPoint(x: w + d, y: 0), CGPoint(x: w, y: d)])
                .fill(Color(baseColor).opacity(0.8))
            Group {
                if let coverImage {
                    Image(uiImage: coverImage).resizable().scaledToFill()
                } else {
                    BookCoverArtwork(title: book.name, author: book.author, remoteURL: book.displayCoverUrl,
                                     width: coverWidth, height: w)
                }
            }
            .frame(width: coverWidth, height: w)
            .clipped()
            .rotationEffect(.degrees(-90))
            .frame(width: w, height: coverWidth)
            .overlay(LinearGradient(colors: [Color.black.opacity(0.05), Color.black.opacity(0.22)],
                                    startPoint: .top, endPoint: .bottom))
            .transformEffect(CGAffineTransform(a: 1, b: 0, c: -d / coverWidth, d: d / coverWidth, tx: d, ty: 0))
            BookshelfFace(points: [CGPoint(x: w, y: d), CGPoint(x: w + d, y: 0), CGPoint(x: w + d, y: h), CGPoint(x: w, y: h + d)])
                .fill(pageColor)
        }
        .frame(width: w + d, height: h + d, alignment: .topLeading)
    }

    /// 抽出时的旋转按钮：固定画在书脊正面里（跟着书一起倾斜），
    /// 竖立/倾斜时在书脊顶部往下一点的正中，平躺时在书脊左端的正中，位置不再随姿势乱跑。
    /// 点击区域整块放在书脊之内（之前 34×34 的区域比书脊宽，超出部分被书的点击形状裁掉，
    /// 点不中时轻点落到书上，反而打开了书）；用高优先级手势，不和书本身的轻点抢。
    @ViewBuilder private func rotateButton(hitWidth: CGFloat, hitHeight: CGFloat) -> some View {
        if isSelected, let onRotate {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(AppFontStyle.system(size: 10, weight: .semibold).themed)
                .foregroundStyle(Color.white)
                .frame(width: 22, height: 22)
                .background(Color.black.opacity(0.55), in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.5), lineWidth: 0.5))
                .opacity(style.hideRotateButtons ? 0.011 : 1)
                .frame(width: hitWidth, height: hitHeight)
                .contentShape(Rectangle())
                .highPriorityGesture(TapGesture().onEnded {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onRotate()
                })
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
                .accessibilityElement()
                .accessibilityLabel("修改摆放形态")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { onRotate() }
        }
    }

    /// 抽书（照 cmbok 的样子）：书的背面留在原处，正面朝读者拉出——画面上书脊往左下挪
    /// （书底压到层板前沿上），书顶的书页和右侧的封面随之转出来；
    /// 书脊上方出现旋转按钮，旁边浮出深色胶囊竖排完整书名。收回时原路退回。
    /// 有更新时书脊右上角的小圆点（跟着书一起倾斜 / 放平）。
    @ViewBuilder private var updateDot: some View {
        if book.lastCheckCount > 0 {
            BookshelfUpdateDot(size: min(max(style.bookWidth * 0.26, 6), 9))
                .padding(2.5)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var upright: some View {
        let d = pulledDepth
        return uprightFront
            .overlay(alignment: .topTrailing) { updateDot }
            .overlay(alignment: .bottomLeading) {
                uprightDepthFaces.allowsHitTesting(false)
            }
            .background(alignment: .bottomLeading) {
                if isSelected {
                    Ellipse()
                        .fill(Color.black.opacity(0.28))
                        .frame(width: style.bookWidth + d * 1.3, height: 6)
                        .blur(radius: 2.5)
                        .offset(x: d * 0.1, y: 3)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .top) {
                rotateButton(hitWidth: style.bookWidth, hitHeight: min(36, style.bookHeight * 0.3))
                    .offset(y: max(min(style.bookHeight * 0.1, 20) - 11, 0))
            }
            .overlay(alignment: titleOnTrailing ? .topTrailing : .topLeading) {
                if isSelected, style.showsPulledTitle {
                    titlePill
                        .offset(x: titleOnTrailing ? titlePillWidth + d + 2 : -(titlePillWidth + 2), y: 4)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .scaleEffect(1 + 0.025 * pull, anchor: .bottom)
            .offset(x: -d * 0.6 * pull, y: d * 0.45 * pull)
            .contentShape(Rectangle())
    }

    private var titlePillWidth: CGFloat { 22 }

    /// 抽出时旁边浮出的书名：深色胶囊，竖排白字，太长截断。
    private var titlePill: some View {
        let lineHeight: CGFloat = 14.5
        let capacity = max(Int((style.bookHeight * 0.78 - 14) / lineHeight), 2)
        var chars = Array(title)
        if chars.count > capacity { chars = Array(chars.prefix(capacity - 1)) + ["…"] }
        return VStack(spacing: 0) {
            ForEach(Array(chars.enumerated()), id: \.offset) { _, ch in
                Text(String(ch))
                    .font(.system(size: 12.5, weight: .bold))
                    .frame(height: lineHeight)
            }
        }
        .foregroundStyle(Color.white)
        .frame(width: titlePillWidth)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.78), in: Capsule())
        .fixedSize()
    }

    private var flat: some View {
        flatFront
            .overlay(alignment: .topTrailing) { updateDot }
            .overlay(alignment: .bottomLeading) {
                if isSelected {
                    flatDepthFaces.allowsHitTesting(false)
                }
            }
            .overlay(alignment: .leading) {
                rotateButton(hitWidth: min(36, style.bookHeight * 0.3), hitHeight: style.bookWidth)
            }
            .scaleEffect(1 + 0.04 * pull, anchor: .bottom)
            .offset(y: 4 * pull)
            .contentShape(Rectangle())
    }

    var body: some View {
        Group {
            switch pose {
            case .upright:
                upright
            case .flat:
                flat
            case .leanLeft:
                // 左下角着地，向左靠在相邻的书上（位置由书架按支撑关系算好）。
                upright
                    .rotationEffect(.degrees(-Self.leanAngle), anchor: .bottomLeading)
            case .leanRight:
                upright
                    .rotationEffect(.degrees(Self.leanAngle), anchor: .bottomTrailing)
            }
        }
        .shadow(color: .black.opacity(isSelected ? 0.28 : 0.14), radius: isSelected ? 3 : 1,
                x: isSelected ? 1.5 : 0.6, y: isSelected ? 1.5 : 0.6)
        // 封面图不管是不是封面书脊都提前加载：抽出时侧面 / 平躺时顶面要露出封面，
        // 之前等抽出那一刻才开始加载，第一次点开看到的是占位图。
        .task(id: book.coverUrl ?? "") {
            if coverImage == nil {
                if let cached = Self.cachedCover(book.coverUrl) {
                    coverImage = cached
                } else if let text = book.coverUrl, let url = URL(string: text),
                          let loaded = await CoverImageCache.shared.image(for: url) {
                    withAnimation(.easeOut(duration: 0.2)) { coverImage = loaded }
                }
            }
            if tint == nil, let loaded = await BookshelfSpineTintCache.shared.tint(for: book.coverUrl) {
                withAnimation(.easeOut(duration: 0.25)) { tint = loaded }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(book.name)，\(pose.title)")
        .accessibilityAction(named: "修改摆放形态") { if isSelected { onRotate?() } }
    }
}

// MARK: - 文件夹面板

/// 打开的文件夹：盖在整个界面上（包括底部标签栏），背景模糊，书以封面网格排列。
/// 标题可改名；「多选」后可把选中的书移出文件夹；「解散」把书放回书架；长按书拖到面板外移出文件夹。
struct BookshelfFolderOverlay: View {
    @ObservedObject private var store = BookshelfFolderStore.shared

    var body: some View {
        ZStack {
            if let id = store.presentedFolderID, let folder = store.folder(id: id) {
                BookshelfFolderPanel(folder: folder)
                    .id(folder.id)
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: store.presentedFolderID)
    }
}

private struct BookshelfFolderPanel: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var library: BookLibraryModel
    @ObservedObject private var store = BookshelfFolderStore.shared
    let folder: BookshelfFolder

    @State private var appeared = false
    @State private var selecting = false
    @State private var selected = Set<String>()
    @State private var renaming = false
    @State private var draft = ""
    @State private var renameError: String?
    @State private var draggingURL: String?
    @State private var dragLocation: CGPoint = .zero
    @State private var panelFrame: CGRect = .zero

    private static let space = "bookshelf.folder.panel"
    private static let columnSpacing: CGFloat = 14

    /// 文件夹里的书（按放进去的顺序），已经不在书架上的跳过。
    private var books: [Book] {
        let byURL = Dictionary(library.books.map { ($0.bookUrl, $0) }, uniquingKeysWith: { first, _ in first })
        return folder.bookURLs.compactMap { byURL[$0] }
    }

    private var isOutside: Bool {
        draggingURL != nil && !panelFrame.insetBy(dx: -6, dy: -6).contains(dragLocation)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = min(proxy.size.width - 36, 460)
            let columns = width > 400 ? 4 : 3
            let cellWidth = ((width - 40 - CGFloat(columns - 1) * Self.columnSpacing) / CGFloat(columns)).rounded(.down)
            let rows = Int(ceil(Double(max(books.count, 1)) / Double(columns)))
            let gridHeight = CGFloat(rows) * (cellWidth / 0.7 + 34) + CGFloat(max(rows - 1, 0)) * 16
            let height = min(max(gridHeight + 130, 260), proxy.size.height - 140)
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(Color.black.opacity(colorScheme == .dark ? 0.35 : 0.18))
                    .ignoresSafeArea()
                    .onTapGesture { close() }
                panel(width: width, height: height, columns: columns, cellWidth: cellWidth)
                    .frame(width: width, height: height)
                    .background(
                        GeometryReader { panel in
                            Color.clear
                                .onAppear { panelFrame = panel.frame(in: .named(Self.space)) }
                                .onChange(of: panel.frame(in: .named(Self.space))) { panelFrame = $0 }
                        }
                    )
                    .scaleEffect(appeared ? 1 : 0.86)
                    .opacity(appeared ? 1 : 0)
                if let url = draggingURL, let book = books.first(where: { $0.bookUrl == url }) {
                    // 拖动中的书浮在最上层，拖出面板也看得见。
                    BookshelfCover(book: book, width: cellWidth, height: (cellWidth / 0.7).rounded())
                        .scaleEffect(1.08)
                        .shadow(color: .black.opacity(0.3), radius: 10, y: 6)
                        .rotationEffect(.degrees(isOutside ? -6 : 0))
                        .position(x: dragLocation.x, y: dragLocation.y - cellWidth * 0.4)
                        .allowsHitTesting(false)
                        .zIndex(1)
                }
                if renaming {
                    renameDialog
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                        .zIndex(2)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .coordinateSpace(name: Self.space)
        .onAppear {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) { appeared = true }
        }
    }

    private func panel(width: CGFloat, height: CGFloat, columns: Int, cellWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 6)
            ScrollView(showsIndicators: false) {
                grid(columns: columns, cellWidth: cellWidth)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 16)
            }
            footer
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
        }
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(colorScheme == .dark ? Color(white: 0.13).opacity(0.96) : Color.white.opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(isOutside ? ReadingTheme.coral : Color.white.opacity(colorScheme == .dark ? 0.08 : 0.6),
                              lineWidth: isOutside ? 2 : 0.5)
        )
        .shadow(color: .black.opacity(0.2), radius: 28, y: 12)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                draft = folder.name
                renameError = nil
                withAnimation(.easeOut(duration: 0.2)) { renaming = true }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .font(AppFontStyle.system(size: 14).themed)
                        .foregroundStyle(ReadingTheme.accent)
                    Text(folder.name)
                        .font(AppFontStyle.system(size: 17, weight: .semibold).themed)
                        .lineLimit(1)
                    Image(systemName: "pencil")
                        .font(AppFontStyle.system(size: 11, weight: .semibold).themed)
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("文件夹名称 \(folder.name)，轻点修改")
            Text("\(books.count) 本")
                .font(AppFontStyle.caption.themed)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button(selecting ? "完成" : "多选") {
                withAnimation(.easeOut(duration: 0.18)) {
                    selecting.toggle()
                    selected.removeAll()
                }
            }
            .font(AppFontStyle.system(size: 13).themed)
            .foregroundStyle(.primary)
            .frame(minWidth: 40, minHeight: 36)
            Button("解散") { dissolve() }
                .font(AppFontStyle.system(size: 13).themed)
                .foregroundStyle(.primary)
                .frame(minWidth: 40, minHeight: 36)
                .accessibilityHint("把书放回书架并删除这个文件夹")
            Button { close() } label: {
                Image(systemName: "xmark")
                    .font(AppFontStyle.system(size: 13, weight: .semibold).themed)
                    .frame(width: 28, height: 28)
                    .background(Color.secondary.opacity(0.12), in: Circle())
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
        }
        .foregroundStyle(.primary)
    }

    /// 文件夹里的书：封面网格，书名在封面下方。
    private func grid(columns: Int, cellWidth: CGFloat) -> some View {
        let list = books
        let rows = stride(from: 0, to: list.count, by: columns).map { Array(list[$0..<min($0 + columns, list.count)]) }
        return VStack(alignment: .leading, spacing: 16) {
            ForEach(rows.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: Self.columnSpacing) {
                    ForEach(rows[index]) { book in
                        bookCell(book, width: cellWidth)
                            .zIndex(book.bookUrl == draggingURL ? 2 : 0)
                    }
                    Spacer(minLength: 0)
                }
                .zIndex(rows[index].contains { $0.bookUrl == draggingURL } ? 2 : 0)
            }
        }
    }

    private func bookCell(_ book: Book, width: CGFloat) -> some View {
        let isDragging = book.bookUrl == draggingURL
        let isChecked = selected.contains(book.bookUrl)
        return VStack(alignment: .leading, spacing: 6) {
            BookshelfCover(book: book, width: width, height: (width / 0.7).rounded())
                .overlay(alignment: .bottomTrailing) {
                    if selecting {
                        Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                            .font(AppFontStyle.system(size: 18, weight: .semibold).themed)
                            .foregroundStyle(isChecked ? ReadingTheme.accent : Color.white)
                            .background(Circle().fill(isChecked ? Color.white : Color.black.opacity(0.25)))
                            .padding(5)
                            .allowsHitTesting(false)
                    }
                }
            Text(book.name)
                .font(AppFontStyle.caption.weight(.medium).themed)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(width: width, alignment: .leading)
            Text(book.author.isEmpty ? "未知作者" : book.author)
                .font(AppFontStyle.caption2.themed)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: width, alignment: .leading)
        }
        .opacity(isDragging ? 0.25 : (selecting && !isChecked ? 0.7 : 1))
        .contentShape(Rectangle())
        .onTapGesture {
            if selecting {
                if isChecked { selected.remove(book.bookUrl) } else { selected.insert(book.bookUrl) }
            } else {
                guard BookshelfLongPressGuard.allowsTap, draggingURL == nil else { return }
                store.openRequest = .read(book)
                close()
            }
        }
        .gesture(
            LongPressGesture(minimumDuration: 0.35)
                .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space)))
                .onChanged { value in
                    guard case .second(true, let drag) = value else { return }
                    if draggingURL == nil, let drag {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        BookshelfLongPressGuard.lift()
                        dragLocation = drag.location
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { draggingURL = book.bookUrl }
                    }
                    if let drag {
                        let wasOutside = isOutside
                        dragLocation = drag.location
                        if isOutside != wasOutside { UISelectionFeedbackGenerator().selectionChanged() }
                    }
                }
                .onEnded { _ in
                    BookshelfLongPressGuard.end()
                    let remove = isOutside
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                        draggingURL = nil
                    }
                    if remove { removeFromFolder([book.bookUrl]) }
                }
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(selecting ? "轻点选择" : "轻点打开阅读，长按拖到面板外移出文件夹")
    }

    @ViewBuilder
    private var footer: some View {
        if selecting {
            Button {
                removeFromFolder(selected)
            } label: {
                Text(selected.isEmpty ? "选择要移出的书" : "移出文件夹（\(selected.count)）")
                    .font(AppFontStyle.system(size: 14, weight: .semibold).themed)
                    .foregroundStyle(selected.isEmpty ? Color.secondary : Color.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(selected.isEmpty ? Color.secondary.opacity(0.15) : Color(white: 0.15), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(selected.isEmpty)
        } else {
            Text(isOutside ? "松手移出文件夹" : "长按书封拖到面板外 = 移出文件夹")
                .font(AppFontStyle.system(size: 11).themed)
                .foregroundStyle(isOutside ? ReadingTheme.coral : Color.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 20)
        }
    }

    private var renameDialog: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { renaming = false } }
            VStack(alignment: .leading, spacing: 14) {
                Text("文件夹名称")
                    .font(AppFontStyle.system(size: 16, weight: .semibold).themed)
                TextField("输入名称", text: $draft)
                    .font(AppFontStyle.system(size: 15).themed)
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .onChange(of: draft) { value in
                        renameError = nil
                        if value.count > BookshelfFolderStore.nameLimit {
                            draft = String(value.prefix(BookshelfFolderStore.nameLimit))
                        }
                    }
                HStack {
                    if let renameError {
                        Text(renameError)
                            .font(AppFontStyle.system(size: 11).themed)
                            .foregroundStyle(ReadingTheme.coral)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text("\(draft.count)/\(BookshelfFolderStore.nameLimit)")
                        .font(AppFontStyle.system(size: 11).themed)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Spacer()
                    Button("取消") { withAnimation(.easeOut(duration: 0.2)) { renaming = false } }
                        .font(AppFontStyle.system(size: 14).themed)
                        .foregroundStyle(.primary)
                        .frame(width: 64, height: 38)
                    Button {
                        if let error = store.rename(folder.id, to: draft) {
                            renameError = error
                        } else {
                            withAnimation(.easeOut(duration: 0.2)) { renaming = false }
                        }
                    } label: {
                        Text("保存")
                            .font(AppFontStyle.system(size: 14, weight: .semibold).themed)
                            .foregroundStyle(Color.white)
                            .frame(width: 64, height: 38)
                            .background(Color(white: 0.15), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
            .frame(width: 290)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(colorScheme == .dark ? Color(white: 0.16) : Color.white)
            )
            .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
        }
    }

    private func close() {
        withAnimation(.easeIn(duration: 0.16)) { appeared = false }
        let id = folder.id
        let store = self.store
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            if store.presentedFolderID == id { store.presentedFolderID = nil }
        }
    }

    private func removeFromFolder(_ urls: Set<String>) {
        selected.subtract(urls)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            store.remove(urls, from: folder.id)
        }
    }

    private func dissolve() {
        let id = folder.id
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { store.dissolve(id) }
    }
}

// MARK: - 书架设置

/// 书架设置：通用选项（移除时删除本地文件、右侧切换条、书架页视图），再按当前视图显示各自的选项：
/// - 网格：表格列数、隐藏书名/作者、隐藏书架底座、封面样式、书架样式；
/// - 列表：封面样式、书架样式；
/// - 仿真书架：隐藏书名/作者、仿真书大小、封面书脊、隐藏旋转按钮、书架样式。
struct BookshelfShelfSettingsSheet: View {
    @AppStorage("bookshelfLayout") private var bookshelfLayout = "grid3"
    @AppStorage(BookshelfShelfSettings.deleteLocalKey) private var deleteLocal = false
    @AppStorage(BookshelfShelfSettings.sideSwitcherKey) private var sideSwitcher = true
    @AppStorage(BookshelfShelfSettings.hideTitlesKey) private var hideTitles = false
    @AppStorage(BookshelfShelfSettings.hideShelfBaseKey) private var hideShelfBase = true
    @AppStorage(BookshelfShelfSettings.boardStyleKey) private var boardStyle = "solid"
    @AppStorage(BookshelfShelfSettings.bookWidthKey) private var bookWidth = BookshelfShelfSettings.defaultWidth
    @AppStorage(BookshelfShelfSettings.bookHeightKey) private var bookHeight = BookshelfShelfSettings.defaultHeight
    @AppStorage(BookshelfShelfSettings.coverSpineKey) private var coverSpine = false
    @AppStorage(BookshelfShelfSettings.hideRotateKey) private var hideRotateButtons = false
    @AppStorage(BookshelfShelfSettings.pulledTitleKey) private var showsPulledTitle = true
    @AppStorage(BookshelfShelfSettings.variedSizeKey) private var variedSizes = true
    @AppStorage(BookshelfShelfSettings.coverStyleKey) private var coverStyle = "flat"
    @AppStorage(BookshelfShelfSettings.gridShowTitleKey) private var showsGridTitle = true
    @AppStorage(BookshelfShelfSettings.gridShowAuthorKey) private var showsGridAuthor = true
    @State private var showsDress = false
    @State private var dressTab = 0

    private var isGrid: Bool { bookshelfLayout.hasPrefix("grid") }
    private var isShelf: Bool { bookshelfLayout == "shelf" }
    private var isList: Bool { !isGrid && !isShelf }
    private var gridCount: Int { BookshelfShelfSettings.gridCount(bookshelfLayout) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text("书架设置")
                    .font(AppFontStyle.title3.bold().themed)
                    .accessibilityAddTraits(.isHeader)
                toggleRow(title: "移除同时删除本地文件",
                          detail: "从书架移除后，若该书不在其他书架，删除其本地文件（含导入的原文件），不可恢复",
                          isOn: $deleteLocal)
                row(title: "书架页视图", detail: "书架布局：网格封面、行卡列表或实体仿真书架") {
                    HStack(spacing: 4) {
                        layoutChoice("square.grid.2x2.fill", selected: isGrid, label: "网格封面") {
                            if !isGrid { bookshelfLayout = "grid\(BookshelfShelfSettings.lastGridCount)" }
                        }
                        layoutChoice("list.bullet", selected: isList, label: "行卡列表") {
                            bookshelfLayout = "list"
                        }
                        layoutChoice("books.vertical.fill", selected: isShelf, label: "仿真书架") {
                            bookshelfLayout = "shelf"
                        }
                    }
                    .padding(3)
                    .background(Color.secondary.opacity(0.1), in: Capsule())
                }
                if isGrid {
                    row(title: "表格列数", detail: "网格视图每行最少几列；宽屏自动加列") {
                        HStack(spacing: 4) {
                            ForEach(3...5, id: \.self) { count in
                                textChoice("\(count)", selected: gridCount == count, width: 34) {
                                    bookshelfLayout = "grid\(count)"
                                    BookshelfShelfSettings.lastGridCount = count
                                }
                            }
                        }
                        .padding(3)
                        .background(Color.secondary.opacity(0.1), in: Capsule())
                    }
                    toggleRow(title: "显示书名", detail: "网格封面下方显示书名", isOn: $showsGridTitle)
                    toggleRow(title: "显示作者", detail: "网格封面下方显示作者；书名和作者都关掉就是纯封面墙", isOn: $showsGridAuthor)
                    toggleRow(title: "隐藏书架底座", detail: "网格视图不画搁板（含立体板）；板位留白一并收掉", isOn: $hideShelfBase)
                    coverStyleRow
                    boardStyleRow
                } else if isList {
                    coverStyleRow
                } else {
                    toggleRow(title: "隐藏书名/作者", detail: "网格与仿真视图隐藏书名作者与遮罩蒙版（纯净书脊）", isOn: $hideTitles)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("仿真书大小").font(AppFontStyle.headline.themed)
                        Text("调整书高与书宽的基准：每本书在此基础上按字数变厚变薄、高矮错落，文字一并等比缩放")
                            .font(AppFontStyle.caption.themed).foregroundStyle(.secondary)
                        AdjustableSlider(title: "书宽", value: $bookWidth, range: BookshelfShelfSettings.widthRange,
                                         format: { "\(Int($0)) pt" })
                        AdjustableSlider(title: "书高", value: $bookHeight, range: BookshelfShelfSettings.heightRange,
                                         format: { "\(Int($0)) pt" })
                        Button("恢复默认大小") {
                            bookWidth = BookshelfShelfSettings.defaultWidth
                            bookHeight = BookshelfShelfSettings.defaultHeight
                        }
                        .font(AppFontStyle.footnote.themed)
                        .foregroundStyle(ReadingTheme.accent)
                    }
                    row(title: "书架装扮", detail: "书脊装帧与书匣装扮：随机搭配、内置款式与自定义款式") {
                        HStack(spacing: 6) {
                            Button("书脊") { dressTab = 0; showsDress = true }
                            Button("书匣") { dressTab = 1; showsDress = true }
                        }
                        .font(AppFontStyle.subheadline.weight(.medium).themed)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                    }
                    toggleRow(title: "书名浮标", detail: "仿真书架抽出书时，在书旁浮出深色胶囊显示完整书名", isOn: $showsPulledTitle)
                    toggleRow(title: "高矮随字数", detail: "字数越多书越高（以「书高」为最高），厚薄只轻微变化；关闭后所有书一样大", isOn: $variedSizes)
                    toggleRow(title: "封面书脊", detail: "开启后所有有封面的书都显示封面图案（柔化处理，封面上的字不会干扰书名），单本指定的装帧也会被覆盖；关闭则按「书架装扮」搭配", isOn: $coverSpine)
                    toggleRow(title: "隐藏旋转按钮", detail: "仿真视图隐藏书脊与文件夹上的旋转按钮（透明后依旧可点击）", isOn: $hideRotateButtons)
                    boardStyleRow
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 40)
            .animation(.easeOut(duration: 0.2), value: bookshelfLayout)
        }
        .tint(ReadingTheme.ink)
        .sheet(isPresented: $showsDress) { BookshelfDressSettingsSheet(tab: dressTab) }
        .readingSheetCanvas()
        .readingLivePreviewSheet()
        .readingPresentationDragIndicator()
    }

    private var coverStyleRow: some View {
        row(title: "封面样式", detail: "平面：纯封面，无阴影；实体：书脊凹槽、右侧露出书页并带投影") {
            HStack(spacing: 8) {
                BookshelfCoverStyleSample(solid: coverStyle == "solid")
                HStack(spacing: 4) {
                    textChoice("平面", selected: coverStyle != "solid") { coverStyle = "flat" }
                    textChoice("实体", selected: coverStyle == "solid") { coverStyle = "solid" }
                }
                .padding(3)
                .background(Color.secondary.opacity(0.1), in: Capsule())
            }
        }
    }

    private var boardStyleRow: some View {
        row(title: "书架样式", detail: "仅书架页搁板：立体架板带顶面与前立面的厚度感") {
            HStack(spacing: 8) {
                BookshelfBoard(width: 44, height: boardStyle == "solid" ? 12 : 5, solid: boardStyle == "solid")
                    .frame(height: 16)
                HStack(spacing: 4) {
                    textChoice("平面", selected: boardStyle != "solid") { boardStyle = "flat" }
                    textChoice("立体", selected: boardStyle == "solid") { boardStyle = "solid" }
                }
                .padding(3)
                .background(Color.secondary.opacity(0.1), in: Capsule())
            }
        }
    }

    private func row<Accessory: View>(title: String, detail: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(AppFontStyle.headline.themed)
                Text(detail).font(AppFontStyle.caption.themed).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            accessory()
        }
    }

    private func toggleRow(title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(AppFontStyle.headline.themed)
                Text(detail).font(AppFontStyle.caption.themed).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(ReadingTheme.toggleTint)
    }

    private func layoutChoice(_ systemName: String, selected: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(AppFontStyle.system(size: 14, weight: .medium).themed)
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .frame(width: 36, height: 30)
                .background { if selected { ThemeSurface(shape: Capsule()) } }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func textChoice(_ title: String, selected: Bool, width: CGFloat = 44, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(AppFontStyle.system(size: 13, weight: selected ? .semibold : .regular).themed)
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .frame(width: width, height: 30)
                .background { if selected { ThemeSurface(shape: Capsule()) } }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 设置里「封面样式」旁边的小样：一本深色小书，实体时左侧有书脊凹陷。
private struct BookshelfCoverStyleSample: View {
    let solid: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Color(white: 0.16))
            .frame(width: 18, height: 26)
            .overlay {
                Image(systemName: "book.closed.fill")
                    .font(AppFontStyle.system(size: 8).themed)
                    .foregroundStyle(Color.white.opacity(0.85))
            }
            .overlay(alignment: .leading) {
                if solid { BookshelfSolidSpineShade(width: 18) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
            .shadow(color: .black.opacity(solid ? 0.25 : 0), radius: 1.5, x: 1, y: 1.5)
            .accessibilityHidden(true)
    }
}

// MARK: - 书架摆件

/// 仿真书架上的一个摆件。fileName 为 nil 表示内置的青蛙。
struct ShelfOrnament: Codable, Identifiable, Equatable {
    var id: String
    var fileName: String?
    /// 等比缩放后的高度（pt）。
    var size: Double
    var onShelf: Bool
}

/// 保存「我的摆件」：图片存在 Application Support，列表存在 UserDefaults。
@MainActor
final class ShelfOrnamentStore: ObservableObject {
    static let shared = ShelfOrnamentStore()
    static let builtinFrogID = "builtin.frog"
    static let sizeRange: ClosedRange<Double> = 32...120
    private static let defaultsKey = "shelfOrnaments"
    /// 用户删掉的预设摆件，不再自动补回。
    private static let removedBuiltinsKey = "shelfOrnamentsRemovedBuiltins"

    /// 预设摆件：id、图片资源名、默认高度。除青蛙外默认不摆上书架，在「我的摆件」里轻点即可放上。
    static let builtins: [(id: String, asset: String, size: Double)] = [
        (builtinFrogID, "ShelfFrog", 64),
        ("builtin.cat", "ShelfCat", 62),
        ("builtin.owl", "ShelfOwl", 60),
        ("builtin.succulent", "ShelfSucculent", 54),
        ("builtin.globe", "ShelfGlobe", 70),
        ("builtin.hourglass", "ShelfHourglass", 64),
        ("builtin.candle", "ShelfCandle", 40)
    ]

    @Published private(set) var ornaments: [ShelfOrnament]
    private var images: [String: UIImage] = [:]

    private init() {
        var list: [ShelfOrnament]
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([ShelfOrnament].self, from: data) {
            list = saved
        } else {
            list = [ShelfOrnament(id: Self.builtinFrogID, fileName: nil, size: 64, onShelf: true)]
        }
        let removed = Set(UserDefaults.standard.stringArray(forKey: Self.removedBuiltinsKey) ?? [])
        for builtin in Self.builtins where !removed.contains(builtin.id) && !list.contains(where: { $0.id == builtin.id }) {
            list.append(ShelfOrnament(id: builtin.id, fileName: nil, size: builtin.size, onShelf: false))
        }
        ornaments = list
    }

    var placed: [ShelfOrnament] { ornaments.filter(\.onShelf) }

    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado/ShelfOrnaments", isDirectory: true)
    }

    func ornament(id: String) -> ShelfOrnament? { ornaments.first { $0.id == id } }

    func image(for ornament: ShelfOrnament) -> UIImage? {
        if let cached = images[ornament.id] { return cached }
        let image: UIImage?
        if let fileName = ornament.fileName {
            image = UIImage(contentsOfFile: Self.directory.appendingPathComponent(fileName).path)
        } else {
            let asset = Self.builtins.first { $0.id == ornament.id }?.asset ?? "ShelfFrog"
            image = UIImage(named: asset)
        }
        if let image { images[ornament.id] = image }
        return image
    }

    /// 按图片比例算出显示尺寸；过宽的图片再整体缩小到 maxWidth 以内。
    func displaySize(for ornament: ShelfOrnament, maxWidth: CGFloat) -> CGSize {
        var height = CGFloat(ornament.size)
        var aspect: CGFloat = 0.69
        if let image = image(for: ornament), image.size.height > 0 {
            aspect = image.size.width / image.size.height
        }
        var width = height * aspect
        if width > maxWidth, width > 0 {
            height *= maxWidth / width
            width = maxWidth
        }
        return CGSize(width: width.rounded(), height: height.rounded())
    }

    func setSize(_ size: Double, for id: String) {
        guard let index = ornaments.firstIndex(where: { $0.id == id }) else { return }
        ornaments[index].size = min(max(size, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
        save()
    }

    func setOnShelf(_ onShelf: Bool, for id: String) {
        guard let index = ornaments.firstIndex(where: { $0.id == id }) else { return }
        ornaments[index].onShelf = onShelf
        save()
    }

    var hasRemovedBuiltins: Bool {
        !(UserDefaults.standard.stringArray(forKey: Self.removedBuiltinsKey) ?? []).isEmpty
    }

    /// 把删掉的预设摆件放回「我的摆件」（不自动摆上书架）。
    func restoreBuiltins() {
        UserDefaults.standard.removeObject(forKey: Self.removedBuiltinsKey)
        for builtin in Self.builtins where !ornaments.contains(where: { $0.id == builtin.id }) {
            ornaments.append(ShelfOrnament(id: builtin.id, fileName: nil, size: builtin.size, onShelf: false))
        }
        save()
        objectWillChange.send()
    }

    func delete(_ id: String) {
        guard let index = ornaments.firstIndex(where: { $0.id == id }) else { return }
        if let fileName = ornaments[index].fileName {
            try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(fileName))
        }
        images[id] = nil
        if Self.builtins.contains(where: { $0.id == id }) {
            var removed = UserDefaults.standard.stringArray(forKey: Self.removedBuiltinsKey) ?? []
            if !removed.contains(id) { removed.append(id) }
            UserDefaults.standard.set(removed, forKey: Self.removedBuiltinsKey)
        }
        ornaments.remove(at: index)
        save()
    }

    /// 添加一张图片为新摆件，并直接摆到书架上。
    @discardableResult
    func add(imageData data: Data) -> Bool {
        guard let source = UIImage(data: data), source.size.width > 0, source.size.height > 0 else { return false }
        let maxSide: CGFloat = 600
        let scale = min(1, maxSide / max(source.size.width, source.size.height))
        let target = CGSize(width: (source.size.width * scale).rounded(), height: (source.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            source.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let png = image.pngData() else { return false }
        let id = UUID().uuidString
        let fileName = "\(id).png"
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            try png.write(to: Self.directory.appendingPathComponent(fileName), options: .atomic)
        } catch {
            return false
        }
        images[id] = image
        ornaments.append(ShelfOrnament(id: id, fileName: fileName, size: 64, onShelf: true))
        save()
        return true
    }

    private func save() {
        if let data = try? JSONEncoder().encode(ornaments) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// 轻点书架上的摆件弹出：等比大小、移出书架。
private struct ShelfOrnamentSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = ShelfOrnamentStore.shared
    let ornamentID: String
    @State private var size: Double = 64

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Label("摆件设置", systemImage: "leaf")
                    .font(AppFontStyle.headline.themed)
                Spacer()
                Button(role: .destructive) {
                    store.setOnShelf(false, for: ornamentID)
                    dismiss()
                } label: {
                    Label("移出书架", systemImage: "trash")
                        .font(AppFontStyle.subheadline.themed)
                        .foregroundStyle(ReadingTheme.coral)
                }
            }
            AdjustableSlider(title: "等比大小", value: $size, range: ShelfOrnamentStore.sizeRange,
                             format: { "\(Int($0))pt" })
                .tint(ReadingTheme.ink)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .onAppear { size = store.ornament(id: ornamentID)?.size ?? 64 }
        .onChange(of: size) { store.setSize($0, for: ornamentID) }
        .readingLivePreviewSheet()
        .readingSheetCanvas()
        .readingPresentationDragIndicator()
    }
}

/// 换装面板的目标："b:" + 书籍链接，或 "f:" + 文件夹 id。
struct BookshelfDressTarget: Identifiable, Equatable {
    let id: String
}

/// 换装面板里的选择卡片：选中时描边。
private struct BookshelfDressTile<Preview: View>: View {
    let title: String
    let selected: Bool
    var checkmark: Bool? = nil
    let action: () -> Void
    @ViewBuilder let preview: () -> Preview

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                preview()
                    .frame(height: 112, alignment: .bottom)
                    .allowsHitTesting(false)
                Text(title)
                    .font(AppFontStyle.system(size: 12, weight: selected ? .semibold : .regular).themed)
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(selected ? ReadingTheme.groupedCanvas : Color.clear,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? ReadingTheme.ink.opacity(0.45) : Color.clear, lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                if let checkmark {
                    Image(systemName: checkmark ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(checkmark ? ReadingTheme.ink : Color.secondary.opacity(0.6))
                        .padding(5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected || checkmark == true ? .isSelected : [])
    }
}

/// 预览用的样书。
private enum BookshelfDressSample {
    static let book = Book(bookUrl: "preview.sample.book", name: "山河故人", author: "墨卷")
    static let style = BookshelfShelfStyle(bookWidth: 28, bookHeight: 104, hideTitles: false, coverSpine: false,
                                           hideRotateButtons: true, showsPulledTitle: false, variedSizes: false)
}

/// 书匣小样。
private struct BookshelfFolderSkinSample: View {
    let skin: BookshelfFolderSkin
    @ObservedObject private var store = BookshelfSpineDesignStore.shared

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(LinearGradient(colors: [skin.box, skin.dark], startPoint: .top, endPoint: .bottom))
            ShelfPatternView(kind: skin.pattern, color: skin.label.opacity(0.16))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            if skin.border {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(skin.label.opacity(0.75), lineWidth: 0.7)
                    .padding(2)
            }
            switch skin.windowStyle {
            case 1:
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(skin.label.opacity(0.92))
                    .frame(width: 20, height: 56)
                    .overlay(Text("书\n匣").font(.system(size: 8, weight: .semibold, design: .serif)).foregroundStyle(skin.dark))
            case 2:
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(skin.window)
                        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(skin.label.opacity(0.45), lineWidth: 0.6))
                        .frame(height: 34)
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 15)
            default:
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(skin.window)
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(skin.label.opacity(0.45), lineWidth: 0.6))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 15)
            }
            VStack {
                Text(skin.title ?? "文件夹").font(.system(size: 7, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.6)
                Spacer()
                Text(store.folderFooter(for: skin, count: 6))
                    .font(.system(size: 7, weight: .medium, design: skin.monospaced ? .monospaced : .default))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .foregroundStyle(skin.label)
            .padding(.vertical, 3)
            .padding(.horizontal, 3)
        }
        .frame(width: 56, height: 96)
        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
    }
}

private var bookshelfDressColumns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 10), count: 4) }

/// 仿真书架装扮（书架设置里打开）：书脊与书匣两页。
/// 勾选的装帧参与随机，每本书 / 每个书匣自动搭配一套；「我的装帧」可以一直新建，保存后保留。
struct BookshelfDressSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = BookshelfSpineDesignStore.shared
    @State var tab: Int
    @State private var editingSpine: ShelfSpineStyle?
    @State private var editingFolder: ShelfFolderStyle?

    var body: some View {
        ReadingNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Picker("", selection: $tab) {
                        Text("书脊装帧").tag(0)
                        Text("书匣装扮").tag(1)
                    }
                    .pickerStyle(.segmented)
                    if tab == 0 { spinePage } else { folderPage }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .navigationTitle("书架装扮")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .sheet(item: $editingSpine) { style in
            ShelfSpineStyleEditor(style: style) { store.saveStyle($0) }
        }
        .sheet(item: $editingFolder) { style in
            ShelfFolderStyleEditor(style: style) { store.saveFolderStyle($0) }
        }
        .readingPresentationDetents([.large])
        .readingSheetCanvas()
        .readingPresentationDragIndicator()
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(AppFontStyle.caption.themed).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 书脊

    private var spinePage: some View {
        VStack(alignment: .leading, spacing: 14) {
            caption("勾选的装帧会随机分给书架上的每本书（每本书固定一套，不会每次变）。只勾一款就是全部统一。书架设置里打开「封面书脊」时，所有有封面的书改为封面书脊：书脊顶部嵌一张清晰的小封面，底色取封面主色。")
            Text("内置装帧").font(AppFontStyle.headline.themed)
            LazyVGrid(columns: bookshelfDressColumns, spacing: 12) {
                ForEach(BookshelfSpineDesign.concrete) { design in
                    let on = !store.disabledDesigns.contains(design.rawValue)
                    BookshelfDressTile(title: design.title, selected: false, checkmark: on,
                                       action: { store.toggleDesign(design) }) {
                        BookshelfSpine(book: BookshelfDressSample.book, pose: .upright, isSelected: false,
                                       style: BookshelfDressSample.style,
                                       appearance: BookshelfSpineAppearance(design: design,
                                                                            colorHex: BookshelfSpineDesignStore.swatchHex(design.rawValue * 3)))
                    }
                }
            }
            Text("随机颜色").font(AppFontStyle.headline.themed)
            Picker("", selection: $store.colorMode) {
                Text("随机配色").tag("random")
                Text("跟随封面").tag("cover")
            }
            .pickerStyle(.segmented)
            caption("内置装帧的底色：随机配色从色板里随机取；跟随封面取封面的主色。自定义装帧始终用你设好的颜色。")
            HStack {
                Text("我的装帧").font(AppFontStyle.headline.themed)
                Spacer()
                Button {
                    editingSpine = ShelfSpineStyle.template(.classic, id: UUID().uuidString,
                                                            name: "我的装帧 \(store.customStyles.count + 1)")
                } label: {
                    Label("新建", systemImage: "plus").font(AppFontStyle.subheadline.weight(.medium).themed)
                }
            }
            if store.customStyles.isEmpty {
                caption("还没有自定义装帧。点「新建」从模板开始，自由组合顶部饰带、书名区、底部、纹理、布边和颜色，保存后一直保留，并参与随机。")
            } else {
                LazyVGrid(columns: bookshelfDressColumns, spacing: 12) {
                    ForEach(store.customStyles) { style in
                        BookshelfDressTile(title: style.name, selected: false, checkmark: style.enabled,
                                           action: { store.toggleStyle(style.id) }) {
                            BookshelfSpine(book: BookshelfDressSample.book, pose: .upright, isSelected: false,
                                           style: BookshelfDressSample.style,
                                           appearance: style.appearance)
                        }
                        .contextMenu {
                            Button { editingSpine = style } label: { Label("编辑", systemImage: "pencil") }
                            Button(role: .destructive) { store.deleteStyle(style.id) } label: { Label("删除", systemImage: "trash") }
                        }
                    }
                }
                caption("轻点勾选是否参与随机，长按可编辑或删除。")
            }
            if store.hasBookOverrides {
                Button("清除所有单本书的指定装扮") { store.resetAllBooks() }
                    .font(AppFontStyle.footnote.themed)
                    .foregroundStyle(ReadingTheme.coral)
            }
        }
    }

    // MARK: 书匣

    private var folderPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            caption("勾选的装扮会随机分给每个书匣（文件夹），每个书匣固定一套。只勾一款就是全部统一。")
            Text("底部文字").font(AppFontStyle.headline.themed)
            Picker("", selection: $store.folderFooterMode) {
                ForEach(BookshelfSpineDesignStore.folderFooterModes.indices, id: \.self) { index in
                    Text(BookshelfSpineDesignStore.folderFooterModes[index].1)
                        .tag(BookshelfSpineDesignStore.folderFooterModes[index].0)
                }
            }
            .pickerStyle(.segmented)
            if store.folderFooterMode == "custom" {
                TextField("比如：藏书、私人收藏、共#册", text: $store.folderFooterText)
                    .textFieldStyle(.roundedBorder)
                    .font(AppFontStyle.body.themed)
            }
            caption("书匣下边的文字，所有书匣通用（之前显示的是装扮名）。自定义文字里的「#」会自动换成书的本数；自定义书匣里单独填了底部文字的，以它为准。")
            Text("内置装扮").font(AppFontStyle.headline.themed)
            LazyVGrid(columns: bookshelfDressColumns, spacing: 12) {
                ForEach(BookshelfFolderSkin.presets.indices, id: \.self) { index in
                    let skin = BookshelfFolderSkin.presets[index]
                    BookshelfDressTile(title: skin.name, selected: false,
                                       checkmark: !store.disabledFolderPresets.contains(index),
                                       action: { store.togglePreset(index) }) {
                        BookshelfFolderSkinSample(skin: skin)
                    }
                }
            }
            HStack {
                Text("我的装扮").font(AppFontStyle.headline.themed)
                Spacer()
                Button {
                    editingFolder = ShelfFolderStyle(id: UUID().uuidString, name: "我的书匣 \(store.folderStyles.count + 1)",
                                                     box: BookshelfSpineDesignStore.swatchHex(0),
                                                     label: UIColor(red: 0.95, green: 0.86, blue: 0.67, alpha: 1).shelfHex,
                                                     footer: nil, enabled: true, pattern: 0, window: 0, border: false, title: nil)
                } label: {
                    Label("新建", systemImage: "plus").font(AppFontStyle.subheadline.weight(.medium).themed)
                }
            }
            if store.folderStyles.isEmpty {
                caption("还没有自定义书匣。点「新建」设置颜色、纹理、正面样式、边框和上下文字，保存后一直保留，并参与随机。")
            } else {
                LazyVGrid(columns: bookshelfDressColumns, spacing: 12) {
                    ForEach(store.folderStyles) { style in
                        BookshelfDressTile(title: style.name, selected: false, checkmark: style.enabled,
                                           action: { store.toggleFolderStyle(style.id) }) {
                            BookshelfFolderSkinSample(skin: BookshelfFolderSkin.custom(style))
                        }
                        .contextMenu {
                            Button { editingFolder = style } label: { Label("编辑", systemImage: "pencil") }
                            Button(role: .destructive) { store.deleteFolderStyle(style.id) } label: { Label("删除", systemImage: "trash") }
                        }
                    }
                }
                caption("轻点勾选是否参与随机，长按可编辑或删除。")
            }
        }
    }
}

/// 一行分段选择（编辑器里用）。
private struct ShelfPartPicker: View {
    let title: String
    let options: [String]
    @Binding var selection: Int

    var body: some View {
        // 选项多了（书名区 6 种、纹理 7 种），分段控件挤不下，改成可横向滑动的胶囊按钮。
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(AppFontStyle.subheadline.weight(.medium).themed)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(options.indices, id: \.self) { index in
                        let on = index == selection
                        Button {
                            selection = index
                        } label: {
                            Text(options[index])
                                .font(AppFontStyle.system(size: 13, weight: on ? .semibold : .regular).themed)
                                .foregroundStyle(on ? Color.white : Color.primary)
                                .padding(.horizontal, 14)
                                .frame(height: 30)
                                .background(on ? ReadingTheme.accent : ReadingTheme.groupedCanvas, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }
}

/// 颜色一行：色板 + 自定义取色。
private struct ShelfColorRow: View {
    let title: String
    @Binding var hex: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !title.isEmpty {
                Text(title).font(AppFontStyle.subheadline.weight(.medium).themed)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ColorPicker(title, selection: Binding(get: { Color(UIColor(shelfHex: hex) ?? .brown) },
                                                          set: { hex = UIColor($0).shelfHex }),
                                supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 30, height: 30)
                    ForEach(Self.palette, id: \.self) { item in
                        Button { hex = item } label: {
                            Circle().fill(Color(UIColor(shelfHex: item) ?? .brown))
                                .overlay(Circle().strokeBorder(Color.primary.opacity(hex == item ? 0.9 : 0.12),
                                                               lineWidth: hex == item ? 2 : 0.5))
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    @MainActor static var palette: [String] {
        BookshelfSpineDesignStore.swatches.indices.map { BookshelfSpineDesignStore.swatchHex($0) }
            + [UIColor(red: 0.88, green: 0.73, blue: 0.44, alpha: 1).shelfHex,
               UIColor(red: 0.96, green: 0.95, blue: 0.92, alpha: 1).shelfHex,
               UIColor(red: 1, green: 1, blue: 1, alpha: 1).shelfHex,
               UIColor(red: 0.20, green: 0.15, blue: 0.11, alpha: 1).shelfHex]
    }
}

/// 新建 / 编辑一款自定义书脊装帧（简化版）：
/// - 预览固定在顶部，改什么马上看到；
/// - 「风格」一排是带缩略图的模板，点一下套用；
/// - 下面分「样式」「颜色」两页：样式里每个部件都是带小书脊缩略图的选项（看图选，不用猜文字），
///   布边和字体合成一行开关；颜色页只有底色、装饰色、文字颜色三项。
private struct ShelfSpineStyleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var style: ShelfSpineStyle
    @State private var page = 0
    let onSave: (ShelfSpineStyle) -> Void

    private static var defaultAccent: UIColor { UIColor(red: 0.93, green: 0.91, blue: 0.86, alpha: 1) }

    private var previewStyle: BookshelfShelfStyle {
        BookshelfShelfStyle(bookWidth: 40, bookHeight: 150, hideTitles: false, coverSpine: false,
                            hideRotateButtons: true, showsPulledTitle: false, variedSizes: false)
    }

    private var preview: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 22) {
                BookshelfSpine(book: BookshelfDressSample.book, pose: .upright, isSelected: false,
                               style: previewStyle, appearance: style.appearance)
                BookshelfSpine(book: Book(bookUrl: "preview.sample.long", name: "取消你高考，你研发武装直升机？", author: "诺贝尔数学奖"),
                               pose: .upright, isSelected: false, style: previewStyle, appearance: style.appearance)
                BookshelfSpine(book: Book(bookUrl: "preview.sample.mid", name: "北境战尊", author: "无名"),
                               pose: .upright, isSelected: false,
                               style: BookshelfShelfStyle(bookWidth: 34, bookHeight: 130, hideTitles: false, coverSpine: false,
                                                          hideRotateButtons: true, showsPulledTitle: false, variedSizes: false),
                               appearance: style.appearance)
            }
            .allowsHitTesting(false)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.97), Color(white: 0.86)], startPoint: .top, endPoint: .bottom))
                .frame(width: 210, height: 7)
                .shadow(color: .black.opacity(0.12), radius: 3, y: 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    var body: some View {
        ReadingNavigationStack {
            VStack(spacing: 0) {
                preview
                Picker("", selection: $page) {
                    Text("样式").tag(0)
                    Text("颜色").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
                Divider().opacity(0.5)
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if page == 0 { stylePage } else { colorPage }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
            }
            .navigationTitle("自定义装帧")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        var saved = style
                        let name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        saved.name = name.isEmpty ? "我的装帧" : String(name.prefix(8))
                        // 旧版只存了颜色的自定义装帧，编辑保存后也变成部件组合。
                        saved.design = BookshelfSpineDesign.custom.rawValue
                        onSave(saved)
                        dismiss()
                    }
                }
            }
        }
        .readingSheetCanvas()
    }

    // MARK: 样式页

    @ViewBuilder private var stylePage: some View {
        HStack(spacing: 10) {
            Image(systemName: "character.cursor.ibeam").foregroundStyle(.secondary)
            TextField("装帧名称", text: $style.name)
        }
        .font(AppFontStyle.body.themed)
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background { ThemeCardSurface(radius: 12) }

        ShelfSpineOptionGallery(title: "风格", subtitle: "套用后可再细调",
                                count: BookshelfSpineDesign.concrete.count,
                                isSelected: { _ in false },
                                label: { BookshelfSpineDesign.concrete[$0].title },
                                sample: { templateStyle(BookshelfSpineDesign.concrete[$0]) },
                                select: { style = templateStyle(BookshelfSpineDesign.concrete[$0]) })

        gallery("顶部", ShelfSpineStyle.topTitles, \.top)
        gallery("书名区", ShelfSpineStyle.panelTitles, \.panel)
        gallery("底部", ShelfSpineStyle.bottomTitles, \.bottom)
        gallery("纹理", ShelfSpineStyle.textureTitles, \.texture)

        VStack(spacing: 0) {
            Toggle(isOn: Binding(get: { (style.edge ?? 0) == 1 }, set: { style.edge = $0 ? 1 : 0 })) {
                Text("线装布边").font(AppFontStyle.subheadline.weight(.medium).themed)
            }
            .tint(ReadingTheme.toggleTint)
            .padding(.vertical, 10)
            Divider()
            HStack {
                Text("书名字体").font(AppFontStyle.subheadline.weight(.medium).themed)
                Spacer()
                Picker("书名字体", selection: Binding(get: { (style.serif ?? true) ? 0 : 1 }, set: { style.serif = $0 == 0 })) {
                    Text("宋体").tag(0)
                    Text("黑体").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 130)
            }
            .padding(.vertical, 8)
        }
        .padding(.horizontal, 14)
        .background { ThemeCardSurface(radius: 12) }
    }

    private func templateStyle(_ design: BookshelfSpineDesign) -> ShelfSpineStyle {
        ShelfSpineStyle.template(design, id: style.id, name: style.name)
    }

    private func gallery(_ title: String, _ options: [String], _ keyPath: WritableKeyPath<ShelfSpineStyle, Int?>) -> some View {
        ShelfSpineOptionGallery(title: title, subtitle: nil, count: options.count,
                                isSelected: { (style[keyPath: keyPath] ?? 0) == $0 },
                                label: { options[$0] },
                                sample: { index in
                                    var sample = style
                                    sample[keyPath: keyPath] = index
                                    return sample
                                },
                                select: { style[keyPath: keyPath] = $0 })
    }

    // MARK: 颜色页

    @ViewBuilder private var colorPage: some View {
        ShelfColorRow(title: "底色", hex: $style.color)
        ShelfColorRow(title: "装饰色",
                      hex: Binding(get: { style.accent ?? Self.defaultAccent.shelfHex },
                                   set: { style.accent = $0 }))
        Text("饰带、饰线、圆点、布边和书名底衬都用装饰色。")
            .font(AppFontStyle.footnote.themed)
            .foregroundStyle(.secondary)
            .padding(.top, -12)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("文字颜色").font(AppFontStyle.subheadline.weight(.medium).themed)
                Spacer()
                Picker("文字颜色", selection: Binding(get: { style.text == nil ? 0 : 1 },
                                                     set: { style.text = $0 == 0 ? nil : (style.text ?? UIColor.white.shelfHex) })) {
                    Text("自动").tag(0)
                    Text("自选").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 130)
            }
            if style.text != nil {
                ShelfColorRow(title: "", hex: Binding(get: { style.text ?? UIColor.white.shelfHex },
                                                      set: { style.text = $0 }))
            } else {
                Text("自动按底色选深色或浅色，保证看得清。")
                    .font(AppFontStyle.footnote.themed)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// 自定义装帧的一组选项：每个选项是一本小书脊缩略图 + 名字，选中的有描边，横向滑动。
private struct ShelfSpineOptionGallery: View {
    let title: String
    let subtitle: String?
    let count: Int
    let isSelected: (Int) -> Bool
    let label: (Int) -> String
    let sample: (Int) -> ShelfSpineStyle
    let select: (Int) -> Void

    private static var thumbStyle: BookshelfShelfStyle {
        BookshelfShelfStyle(bookWidth: 24, bookHeight: 86, hideTitles: false, coverSpine: false,
                            hideRotateButtons: true, showsPulledTitle: false, variedSizes: false)
    }
    private static var thumbBook: Book { Book(bookUrl: "preview.sample.thumb", name: "山河", author: "") }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(AppFontStyle.subheadline.weight(.semibold).themed)
                if let subtitle {
                    Text(subtitle).font(AppFontStyle.caption.themed).foregroundStyle(.secondary)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(0..<count, id: \.self) { index in
                        let on = isSelected(index)
                        Button {
                            UISelectionFeedbackGenerator().selectionChanged()
                            withAnimation(.easeOut(duration: 0.15)) { select(index) }
                        } label: {
                            VStack(spacing: 6) {
                                BookshelfSpine(book: Self.thumbBook, pose: .upright, isSelected: false,
                                               style: Self.thumbStyle, appearance: sample(index).appearance)
                                    .allowsHitTesting(false)
                                    .frame(width: 52, height: 92)
                                    .background(ReadingTheme.groupedCanvas, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(on ? ReadingTheme.accent : Color.clear, lineWidth: 2))
                                Text(label(index))
                                    .font(AppFontStyle.system(size: 11, weight: on ? .semibold : .regular).themed)
                                    .foregroundStyle(on ? ReadingTheme.accent : Color.secondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 56)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(title)：\(label(index))")
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

/// 新建 / 编辑一款自定义书匣装扮。
private struct ShelfFolderStyleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var style: ShelfFolderStyle
    let onSave: (ShelfFolderStyle) -> Void

    var body: some View {
        ReadingNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Spacer()
                        BookshelfFolderSkinSample(skin: BookshelfFolderSkin.custom(style))
                            .scaleEffect(1.4)
                            .frame(width: 80, height: 140)
                        Spacer()
                    }
                    TextField("名称", text: $style.name)
                        .padding(12)
                        .background { ThemeCardSurface(radius: 12) }
                    ShelfPartPicker(title: "正面", options: ShelfFolderStyle.windowTitles,
                                    selection: Binding(get: { style.window ?? 0 }, set: { style.window = $0 }))
                    ShelfPartPicker(title: "纹理", options: ShelfSpineStyle.textureTitles,
                                    selection: Binding(get: { style.pattern ?? 0 }, set: { style.pattern = $0 }))
                    Toggle(isOn: Binding(get: { style.border ?? false }, set: { style.border = $0 })) {
                        Text("细边框").font(AppFontStyle.subheadline.weight(.medium).themed)
                    }
                    .tint(ReadingTheme.toggleTint)
                    ShelfColorRow(title: "书匣颜色", hex: $style.box)
                    ShelfColorRow(title: "文字与边框颜色", hex: $style.label)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("顶部文字").font(AppFontStyle.subheadline.weight(.medium).themed)
                        TextField("留空显示文件夹名", text: Binding(get: { style.title ?? "" },
                                                              set: { style.title = $0.isEmpty ? nil : String($0.prefix(10)) }))
                            .padding(12)
                            .background { ThemeCardSurface(radius: 12) }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("底部标签").font(AppFontStyle.subheadline.weight(.medium).themed)
                        TextField("留空跟随「书匣装扮」里的底部文字，# 代表本数", text: Binding(get: { style.footer ?? "" },
                                                                    set: { style.footer = $0.isEmpty ? nil : String($0.prefix(16)) }))
                            .padding(12)
                            .background { ThemeCardSurface(radius: 12) }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .navigationTitle("自定义书匣")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        var saved = style
                        let name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        saved.name = name.isEmpty ? "我的书匣" : String(name.prefix(8))
                        onSave(saved)
                        dismiss()
                    }
                }
            }
        }
        .readingSheetCanvas()
    }
}

/// 单本书换装：默认「随机」（跟随书架装扮）；也可以指定内置装帧（再选颜色）或「我的装帧」。
private struct BookshelfSpineDressSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = BookshelfSpineDesignStore.shared
    let book: Book
    let style: BookshelfShelfStyle
    @State private var showsManager = false

    private var choice: String { store.choice(for: book.bookUrl) }

    private var previewStyle: BookshelfShelfStyle {
        var copy = BookshelfDressSample.style
        copy.coverSpine = style.coverSpine
        return copy
    }

    var body: some View {
        ReadingNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    LazyVGrid(columns: bookshelfDressColumns, spacing: 12) {
                        BookshelfDressTile(title: "随机", selected: choice.isEmpty,
                                           action: { store.setChoice("", for: book.bookUrl) }) {
                            BookshelfSpine(book: book, pose: .upright, isSelected: false, style: previewStyle,
                                           appearance: randomPreview)
                        }
                        ForEach(BookshelfSpineDesign.concrete) { design in
                            BookshelfDressTile(title: design.title, selected: choice == "d:\(design.rawValue)",
                                               action: { store.setChoice("d:\(design.rawValue)", for: book.bookUrl) }) {
                                BookshelfSpine(book: book, pose: .upright, isSelected: false, style: previewStyle,
                                               appearance: BookshelfSpineAppearance(design: design, colorHex: previewColor))
                            }
                        }
                        ForEach(store.customStyles) { custom in
                            BookshelfDressTile(title: custom.name, selected: choice == "c:" + custom.id,
                                               action: { store.setChoice("c:" + custom.id, for: book.bookUrl) }) {
                                BookshelfSpine(book: book, pose: .upright, isSelected: false, style: previewStyle,
                                               appearance: custom.appearance)
                            }
                        }
                    }
                    if choice.hasPrefix("d:") || choice.isEmpty {
                        Text("颜色").font(AppFontStyle.headline.themed)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 7), spacing: 10) {
                            colorChip(label: "随机", hex: nil, fill: AnyShapeStyle(AngularGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .red], center: .center)), icon: "shuffle")
                            colorChip(label: "封面色", hex: BookshelfSpineDesignStore.coverColorToken, fill: AnyShapeStyle(Color.gray.opacity(0.35)), icon: "photo")
                            ForEach(BookshelfSpineDesignStore.swatches.indices, id: \.self) { index in
                                let hex = BookshelfSpineDesignStore.swatchHex(index)
                                colorChip(label: BookshelfSpineDesignStore.swatches[index].0, hex: hex,
                                          fill: AnyShapeStyle(Color(UIColor(shelfHex: hex) ?? .brown)), icon: nil)
                            }
                            ColorPicker("自定义颜色", selection: Binding(
                                get: { Color(UIColor(shelfHex: store.ownColor(for: book.bookUrl)) ?? .brown) },
                                set: { store.setColor(UIColor($0).shelfHex, for: book.bookUrl) }
                            ), supportsOpacity: false)
                            .labelsHidden()
                            .frame(width: 32, height: 32)
                        }
                    }
                    HStack {
                        Button("管理书架装扮") { showsManager = true }
                        Spacer()
                        Button("恢复随机") { store.reset(book.bookUrl) }
                            .foregroundStyle(ReadingTheme.coral)
                    }
                    .font(AppFontStyle.footnote.themed)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .navigationTitle("换装 · \(book.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
        .sheet(isPresented: $showsManager) { BookshelfDressSettingsSheet(tab: 0) }
        .readingPresentationDetents([.medium, .large])
        .readingSheetCanvas()
        .readingPresentationDragIndicator()
    }

    private var randomPreview: BookshelfSpineAppearance {
        let current = store.choice(for: book.bookUrl)
        guard !current.isEmpty else { return store.appearance(for: book, coverSpine: style.coverSpine) }
        return BookshelfSpineAppearance(design: .classic, colorHex: previewColor)
    }

    private var previewColor: String? {
        if let own = store.ownColor(for: book.bookUrl) { return own == BookshelfSpineDesignStore.coverColorToken ? nil : own }
        return store.colorMode == "cover" ? nil : BookshelfSpineDesignStore.swatchHex(BookshelfSpineDesignStore.seed(book.bookUrl + "|" + book.name) / 13)
    }

    private func colorChip(label: String, hex: String?, fill: AnyShapeStyle, icon: String?) -> some View {
        let selected = store.ownColor(for: book.bookUrl) == hex
        return Button {
            store.setColor(hex, for: book.bookUrl)
        } label: {
            ZStack {
                Circle().fill(fill)
                if let icon {
                    Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                }
                Circle().strokeBorder(Color.primary.opacity(selected ? 0.9 : 0.12), lineWidth: selected ? 2 : 0.5)
            }
            .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 单个书匣换装：默认「随机」；也可以指定内置或「我的装扮」。
private struct BookshelfFolderDressSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = BookshelfSpineDesignStore.shared
    @ObservedObject private var folders = BookshelfFolderStore.shared
    let folderID: String
    @State private var showsManager = false

    private var folder: BookshelfFolder? { folders.folder(id: folderID) }

    var body: some View {
        ReadingNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let folder {
                        let choice = store.folderChoice(for: folder)
                        LazyVGrid(columns: bookshelfDressColumns, spacing: 12) {
                            BookshelfDressTile(title: "随机", selected: choice.isEmpty,
                                               action: { folders.setSkinID(folderID, skinID: nil) }) {
                                BookshelfFolderSkinSample(skin: randomSkin(folder))
                            }
                            ForEach(BookshelfFolderSkin.presets.indices, id: \.self) { index in
                                BookshelfDressTile(title: BookshelfFolderSkin.presets[index].name, selected: choice == "p:\(index)",
                                                   action: { folders.setSkinID(folderID, skinID: "p:\(index)") }) {
                                    BookshelfFolderSkinSample(skin: BookshelfFolderSkin.presets[index])
                                }
                            }
                            ForEach(store.folderStyles) { custom in
                                BookshelfDressTile(title: custom.name, selected: choice == "c:" + custom.id,
                                                   action: { folders.setSkinID(folderID, skinID: "c:" + custom.id) }) {
                                    BookshelfFolderSkinSample(skin: BookshelfFolderSkin.custom(custom))
                                }
                            }
                        }
                    }
                    Button("管理书架装扮") { showsManager = true }
                        .font(AppFontStyle.footnote.themed)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .navigationTitle("书匣换装")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
        .sheet(isPresented: $showsManager) { BookshelfDressSettingsSheet(tab: 1) }
        .readingPresentationDetents([.medium, .large])
        .readingSheetCanvas()
        .readingPresentationDragIndicator()
    }

    private func randomSkin(_ folder: BookshelfFolder) -> BookshelfFolderSkin {
        var copy = folder
        copy.skinID = nil
        return store.folderSkin(for: copy)
    }
}

/// 书架摆件管理：我的摆件（轻点放上/取下书架，长按删除）与添加新摆件（本地图片多选、网络链接）。
struct ShelfOrnamentManagerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = ShelfOrnamentStore.shared
    @State private var tab = 0
    @State private var addSource = 0
    @State private var linkText = ""
    @State private var showsPhotoPicker = false
    @State private var isDownloading = false
    @State private var message: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("书架摆件").font(AppFontStyle.title3.weight(.semibold).themed)
                Spacer()
                Picker("", selection: $tab) {
                    Text("我的摆件 \(store.ornaments.count)").tag(0)
                    Text("添加新摆件").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 210)
            }
            if tab == 0 { myOrnaments } else { addOrnament }
            if let message {
                Text(message).font(AppFontStyle.footnote.themed).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .sheet(isPresented: $showsPhotoPicker) {
            ShelfOrnamentPhotoPicker { dataList in
                showsPhotoPicker = false
                guard !dataList.isEmpty else { return }
                let added = dataList.filter { store.add(imageData: $0) }.count
                message = added == dataList.count ? "已添加 \(added) 个摆件并放到书架上" : "已添加 \(added) 个，\(dataList.count - added) 张图片无法读取"
                if added > 0 { tab = 0 }
            }
            .ignoresSafeArea()
        }
        .readingPresentationDetents([.medium, .large])
        .readingSheetCanvas()
        .readingPresentationDragIndicator()
    }

    private var myOrnaments: some View {
        ScrollView {
            if store.ornaments.isEmpty {
                Text("还没有摆件，去「添加新摆件」里添加吧")
                    .font(AppFontStyle.subheadline.themed).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.top, 40)
            }
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(store.ornaments) { ornament in
                    Button {
                        store.setOnShelf(!ornament.onShelf, for: ornament.id)
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(ReadingTheme.groupedCanvas)
                            if let image = store.image(for: ornament) {
                                Image(uiImage: image).resizable().scaledToFit().padding(10)
                            }
                            if ornament.onShelf {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(AppFontStyle.system(size: 16).themed)
                                    .foregroundStyle(ReadingTheme.ink, ReadingTheme.canvas)
                                    .padding(6)
                            }
                        }
                        .aspectRatio(1, contentMode: .fit)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            store.setOnShelf(!ornament.onShelf, for: ornament.id)
                        } label: {
                            Label(ornament.onShelf ? "移出书架" : "放到书架",
                                  systemImage: ornament.onShelf ? "tray.and.arrow.up" : "tray.and.arrow.down")
                        }
                        Button(role: .destructive) {
                            store.delete(ornament.id)
                        } label: {
                            Label("删除摆件", systemImage: "trash")
                        }
                    }
                    .accessibilityLabel(ornament.onShelf ? "摆件，已在书架上" : "摆件，未放到书架")
                    .accessibilityHint("轻点放到书架或取下，长按可删除")
                }
            }
            Text("轻点摆件放上或取下书架，长按可删除。在书架上轻点摆件可调整大小，长按后拖动可调整位置。")
                .font(AppFontStyle.caption.themed).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12)
            if store.hasRemovedBuiltins {
                Button("恢复预设摆件") { store.restoreBuiltins() }
                    .font(AppFontStyle.footnote.themed)
                    .foregroundStyle(ReadingTheme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
        }
    }

    private var addOrnament: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("", selection: $addSource) {
                Text("本地图片").tag(0)
                Text("网络链接").tag(1)
            }
            .pickerStyle(.segmented)
            if addSource == 0 {
                Button { showsPhotoPicker = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "photo.badge.plus")
                        Text("点击选取本地图片（支持多选）")
                    }
                    .font(AppFontStyle.subheadline.weight(.medium).themed)
                    .foregroundStyle(ReadingTheme.ink)
                    .frame(maxWidth: .infinity, minHeight: 96)
                    .background { ThemeCardSurface(radius: 16) }
                }
                .buttonStyle(.plain)
                Text("建议使用透明背景的 PNG 图片，摆在书架上更自然。")
                    .font(AppFontStyle.caption.themed).foregroundStyle(.secondary)
            } else {
                TextField("https://…/图片.png", text: $linkText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background { ThemeCardSurface(radius: 12) }
                Button {
                    Task { await addFromLink() }
                } label: {
                    HStack {
                        if isDownloading { ProgressView().controlSize(.small) }
                        Text(isDownloading ? "正在下载…" : "添加")
                    }
                    .font(AppFontStyle.subheadline.weight(.semibold).themed)
                    .foregroundStyle(ReadingTheme.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(ReadingTheme.accentFill, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isDownloading || linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func addFromLink() async {
        let text = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            message = "请输入以 http 或 https 开头的图片链接"
            return
        }
        isDownloading = true
        defer { isDownloading = false }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                message = "下载失败（HTTP \(http.statusCode)）"
                return
            }
            if store.add(imageData: data) {
                message = "已添加并放到书架上"
                linkText = ""
                tab = 0
            } else {
                message = "这个链接不是可用的图片"
            }
        } catch {
            message = "下载失败：\(error.localizedDescription)"
        }
    }
}

/// 系统相册多选。
private struct ShelfOrnamentPhotoPicker: UIViewControllerRepresentable {
    let onFinish: @MainActor ([Data]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 0
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onFinish: @MainActor ([Data]) -> Void
        private var collected: [Int: Data] = [:]
        private var remaining = 0

        init(onFinish: @escaping @MainActor ([Data]) -> Void) {
            self.onFinish = onFinish
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !results.isEmpty else { onFinish([]); return }
            collected = [:]
            remaining = results.count
            for (index, result) in results.enumerated() {
                let provider = result.itemProvider
                let identifier = provider.registeredTypeIdentifiers.first {
                    UTType($0)?.conforms(to: .image) == true
                } ?? UTType.image.identifier
                let handler = Self.makeHandler(index: index, coordinator: self)
                provider.loadDataRepresentation(forTypeIdentifier: identifier, completionHandler: handler)
            }
        }

        // 相册在后台队列回调；用非隔离的静态方法生成回调，再切回主线程。
        nonisolated private static func makeHandler(index: Int, coordinator: Coordinator) -> @Sendable (Data?, (any Error)?) -> Void {
            { data, _ in
                Task { @MainActor in
                    coordinator.received(data, at: index)
                }
            }
        }

        private func received(_ data: Data?, at index: Int) {
            if let data { collected[index] = data }
            remaining -= 1
            if remaining == 0 {
                onFinish(collected.keys.sorted().compactMap { collected[$0] })
            }
        }
    }
}


/// 把书架上每本书的封面登记到它的书源：重启后封面同样带书源请求头，并按 coverDecodeJs 解密。
private struct CoverRegistrySync: View {
    @EnvironmentObject private var library: BookLibraryModel
    @EnvironmentObject private var sourceLibrary: SourceLibraryModel

    private var signature: String {
        "\(library.books.count)|\(sourceLibrary.sources.count)|\(library.books.first?.coverUrl ?? "")"
    }

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: signature) {
                let sources = Dictionary(sourceLibrary.sources.map { ($0.bookSourceUrl, $0) }, uniquingKeysWith: { first, _ in first })
                for book in library.books {
                    guard let source = sources[book.origin] else { continue }
                    CoverRequestRegistry.shared.register(cover: book.coverUrl, source: source)
                    CoverRequestRegistry.shared.register(cover: book.customCoverUrl, source: source)
                }
            }
    }
}

// MARK: - 编辑书籍信息

/// 长按书籍 →「编辑书籍信息」：换封面（相册图片或网址）、改书名作者、改简介、选分组，下面是阅读进度。
struct BookInfoEditView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: BookLibraryModel
    @EnvironmentObject private var sourceLibrary: SourceLibraryModel
    @ObservedObject private var folderStore = BookshelfFolderStore.shared
    let original: Book
    @State private var name: String
    @State private var author: String
    @State private var intro: String
    @State private var coverText: String
    @State private var customCover: String?
    @State private var folderID: String?
    @State private var showsPhotoPicker = false
    @State private var coverMessage: String?
    @State private var coverCandidates: [BookCoverCandidate] = []
    @State private var isSearchingCovers = false
    @State private var coverSearchDone = false
    @State private var coverSearchTask: Task<Void, Never>?

    init(book: Book) {
        original = book
        _name = State(initialValue: book.name)
        _author = State(initialValue: book.author)
        _intro = State(initialValue: book.displayIntro ?? "")
        _customCover = State(initialValue: book.customCoverUrl)
        let current = book.customCoverUrl ?? ""
        _coverText = State(initialValue: current.hasPrefix("data:") ? "" : current)
        _folderID = State(initialValue: BookshelfFolderStore.shared.folders.first { $0.bookURLs.contains(book.bookUrl) }?.id)
    }

    private var shownCover: String? {
        if let customCover, !customCover.isEmpty { return customCover }
        return original.coverUrl
    }

    private var folderOptions: [BookshelfFolder] { folderStore.folders(inGroup: BookGroup.idAll) }

    private var addedDate: String {
        let seconds = original.syncTime > 0 ? original.syncTime : original.durChapterTime
        guard seconds > 0 else { return "—" }
        let date = Date(timeIntervalSince1970: TimeInterval(seconds > 10_000_000_000 ? seconds / 1000 : seconds))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter.string(from: date)
    }

    var body: some View {
        ReadingNavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        BookCoverArtwork(title: name, author: author, remoteURL: shownCover, width: 120, height: 170)
                            .shadow(color: .black.opacity(0.18), radius: 10, y: 6)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }.readingRowBackground()
                Section {
                    coverSearchRow
                } header: {
                    Text("封面搜索")
                } footer: {
                    Text("按书名在已启用的书源里找同一本书的封面，轻点一张即可换上。")
                }.readingRowBackground()
                Section {
                    Button { showsPhotoPicker = true } label: {
                        Label("选择图片", systemImage: "photo")
                    }
                    if customCover?.isEmpty == false {
                        Button(role: .destructive) {
                            customCover = nil
                            coverText = ""
                        } label: {
                            Label("恢复书源封面", systemImage: "arrow.uturn.backward")
                        }
                    }
                } header: {
                    Text("封面")
                } footer: {
                    Text(coverMessage ?? "从相册选一张图片作为封面，只改本机书架上的显示。")
                }.readingRowBackground()
                Section {
                    TextField("粘贴图片网址", text: $coverText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        let value = coverText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard value.hasPrefix("http") || value.hasPrefix("//") else {
                            coverMessage = "请输入以 http 开头的图片网址。"
                            return
                        }
                        customCover = value
                        coverMessage = "已应用，保存后生效。"
                    } label: {
                        Label("应用网址", systemImage: "arrow.down.circle")
                    }
                } footer: {
                    Text("粘贴图片网址后，轻点「应用网址」即可换为封面。")
                }.readingRowBackground()
                Section("基本信息") {
                    LabeledTextRow(title: "书名", text: $name)
                    LabeledTextRow(title: "作者", text: $author)
                    Picker("分组", selection: $folderID) {
                        Text("未分组").tag(String?.none)
                        ForEach(folderOptions) { folder in
                            Text(folder.name).tag(Optional(folder.id))
                        }
                    }
                }.readingRowBackground()
                Section {
                    ZStack(alignment: .topLeading) {
                        if intro.isEmpty {
                            Text("简介").foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 4)
                        }
                        TextEditor(text: $intro)
                            .frame(minHeight: 110)
                            .readingScrollContentBackgroundHidden()
                    }
                } header: {
                    Text("简介")
                } footer: {
                    Text("留空时显示书源提供的简介。")
                }.readingRowBackground()
                Section("阅读进度") {
                    infoRow("当前进度", BookReadingPresentation.hasStarted(original)
                            ? "\(Int((BookReadingPresentation.progress(original) * 100).rounded()))%" : "0%")
                    infoRow("当前章节", BookReadingPresentation.position(original))
                    infoRow("加入时间", addedDate)
                    infoRow("来源", original.origin == "local" ? "本地书籍" : (original.originName.isEmpty ? "网络书籍" : original.originName))
                }.readingRowBackground()
            }
            .readingThemedListBackground()
            .onDisappear { coverSearchTask?.cancel() }
            .navigationTitle("书籍信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("取消")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { save() } label: { Image(systemName: "checkmark") }
                        .accessibilityLabel("保存")
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .readingPhotoPicker(isPresented: $showsPhotoPicker) { data in
                if let dataURL = Self.coverDataURL(from: data) {
                    customCover = dataURL
                    coverText = ""
                    coverMessage = "已选择图片，保存后生效。"
                } else {
                    coverMessage = "这张图片无法读取，换一张试试。"
                }
            } onError: { error in
                coverMessage = error.localizedDescription
            }
        }
    }

    @ViewBuilder private var coverSearchRow: some View {
        if coverCandidates.isEmpty {
            Button { searchCovers() } label: {
                HStack {
                    Label(isSearchingCovers ? "正在搜索封面…" : (coverSearchDone ? "没找到封面，再搜一次" : "搜索封面"),
                          systemImage: "magnifyingglass")
                    Spacer()
                    if isSearchingCovers { ProgressView() }
                }
            }
            .disabled(isSearchingCovers)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(coverCandidates) { candidate in
                        Button {
                            customCover = candidate.url
                            coverText = candidate.url
                            coverMessage = "已选「\(candidate.sourceName)」的封面，保存后生效。"
                        } label: {
                            VStack(spacing: 5) {
                                BookCoverArtwork(title: name, author: author, remoteURL: candidate.url, width: 66, height: 94)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .strokeBorder(ReadingTheme.accent, lineWidth: customCover == candidate.url ? 2.5 : 0)
                                    )
                                Text(candidate.sourceName)
                                    .font(AppFontStyle.system(size: 10).themed)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .frame(width: 70)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if isSearchingCovers {
                        ProgressView().frame(width: 66, height: 94)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// 按书名在启用的书源里搜，同名（作者对得上或没有作者）且带封面的结果收进来，去重。
    private func searchCovers() {
        let keyword = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        coverSearchTask?.cancel()
        coverCandidates = []
        isSearchingCovers = true
        coverSearchDone = false
        let sources = sourceLibrary.sources.filter(\.enabled)
        let byID = Dictionary(sources.map { ($0.bookSourceUrl, $0) }, uniquingKeysWith: { first, _ in first })
        let wantedAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines)
        coverSearchTask = Task {
            var seen = Set<String>()
            if let own = original.coverUrl, !own.isEmpty { seen.insert(own) }
            for await outcome in BookSearchService().searchOutcomes(keyword: keyword, page: 1, sources: sources) {
                if Task.isCancelled { break }
                for book in outcome.books {
                    guard book.name.trimmingCharacters(in: .whitespacesAndNewlines) == keyword,
                          wantedAuthor.isEmpty || book.author.isEmpty || book.author.contains(wantedAuthor) || wantedAuthor.contains(book.author),
                          let cover = book.coverURL?.trimmingCharacters(in: .whitespacesAndNewlines), !cover.isEmpty,
                          seen.insert(cover).inserted else { continue }
                    if let source = byID[outcome.sourceID] {
                        CoverRequestRegistry.shared.register(cover: cover, source: source)
                    }
                    let sourceName = byID[outcome.sourceID]?.bookSourceName ?? book.originName
                    coverCandidates.append(BookCoverCandidate(url: cover, sourceName: sourceName))
                }
                if coverCandidates.count >= 30 { break }
            }
            isSearchingCovers = false
            coverSearchDone = true
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func save() {
        var book = library.books.first { $0.bookUrl == original.bookUrl } ?? original
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        book.name = trimmedName.isEmpty ? book.name : trimmedName
        book.author = author.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedIntro = intro.trimmingCharacters(in: .whitespacesAndNewlines)
        book.customIntro = trimmedIntro.isEmpty || trimmedIntro == (book.intro ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            ? nil : trimmedIntro
        book.customCoverUrl = customCover?.isEmpty == false ? customCover : nil
        let currentFolder = folderStore.folders.first { $0.bookURLs.contains(book.bookUrl) }?.id
        if folderID != currentFolder {
            if let currentFolder { folderStore.remove([book.bookUrl], from: currentFolder) }
            if let folderID { folderStore.add(book.bookUrl, to: folderID) }
        }
        Task {
            await library.replace(oldBookURL: original.bookUrl, with: book)
            dismiss()
        }
    }

    /// 相册图片缩到 600 像素宽、JPEG 压缩后存成 data 地址，书架数据不会被大图撑大。
    static func coverDataURL(from data: Data) -> String? {
        guard let image = UIImage(data: data) else { return nil }
        let scale = min(1, 600 / max(image.size.width, 1))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = resized.jpegData(compressionQuality: 0.82) else { return nil }
        return "data:image/jpeg;base64," + jpeg.base64EncodedString()
    }
}

private struct BookCoverCandidate: Identifiable, Hashable {
    let url: String
    let sourceName: String
    var id: String { url }
}

private struct LabeledTextRow: View {
    let title: String
    @Binding var text: String

    var body: some View {
        HStack {
            Text(title)
            TextField(title, text: $text)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 书架多选

/// 书架多选：「选择」后轻点书勾选，底栏可一次把多本书加入分组（文件夹）、新建分组或移出书架。
@MainActor
final class BookshelfSelection: ObservableObject {
    static let shared = BookshelfSelection()
    @Published var isActive = false
    @Published var urls: Set<String> = []

    func begin(with url: String? = nil) {
        // 先等长按菜单 / 右上角菜单收起再切换，避免菜单收起动画期间部分格子错过这次刷新。
        Task { @MainActor [weak self] in
            self?.urls = url.map { [$0] } ?? []
            self?.isActive = true
        }
    }

    func end() {
        isActive = false
        urls = []
    }

    func toggle(_ url: String) {
        if !urls.insert(url).inserted { urls.remove(url) }
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

/// 多选时盖在书上的勾选圈。
private struct BookshelfSelectionBadge: View {
    let selected: Bool

    var body: some View {
        ZStack {
            // 未选中也要在浅色、深色封面上都看得清：深色半透明底 + 白圈 + 外圈细描边。
            Circle().fill(selected ? ReadingTheme.accentFill : Color.black.opacity(0.5))
            Circle().strokeBorder(Color.white, lineWidth: 2.5)
            Circle().stroke(Color.black.opacity(0.25), lineWidth: 0.75)
            if selected {
                Image(systemName: "checkmark")
                    .font(AppFontStyle.system(size: 11, weight: .bold).themed)
                    .foregroundStyle(ReadingTheme.onAccent)
            }
        }
        .frame(width: 26, height: 26)
        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
        .padding(6)
    }
}

/// 多选底栏：移出书架 · 加入分组 · 移至书架。
private struct BookshelfSelectionBar: View {
    @EnvironmentObject private var library: BookLibraryModel
    @ObservedObject private var selection = BookshelfSelection.shared
    let groupID: Int64
    @State private var showsFolderSheet = false
    @State private var showsRemoveConfirmation = false

    private var selectedBooks: [Book] { library.books.filter { selection.urls.contains($0.bookUrl) } }

    var body: some View {
        HStack(spacing: 12) {
            Button { showsRemoveConfirmation = true } label: {
                Image(systemName: "trash")
                    .font(AppFontStyle.system(size: 16, weight: .medium).themed)
                    .foregroundStyle(selection.urls.isEmpty ? Color.secondary : ReadingTheme.coral)
                    .frame(width: 46, height: 46)
                    .background { ThemeSurface(shape: Circle()) }
            }
            .accessibilityLabel("移出书架")
            Spacer()
            Button { showsFolderSheet = true } label: {
                Label(selection.urls.isEmpty ? "加入分组" : "加入分组（\(selection.urls.count)）", systemImage: "folder.badge.plus")
                    .font(AppFontStyle.subheadline.weight(.semibold).themed)
                    .foregroundStyle(selection.urls.isEmpty ? Color.secondary : ReadingTheme.accent)
                    .padding(.horizontal, 20)
                    .frame(height: 46)
                    .background { ThemeSurface(shape: Capsule()) }
            }
            Spacer()
            Button { selection.end() } label: {
                Text("完成")
                    .font(AppFontStyle.subheadline.weight(.semibold).themed)
                    .foregroundStyle(.primary)
                    .frame(width: 58, height: 46)
                    .background { ThemeSurface(shape: Capsule()) }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
        .sheet(isPresented: $showsFolderSheet) {
            BookshelfAddToFolderSheet(bookURLs: selectedBooks.map(\.bookUrl), groupID: groupID) {
                selection.end()
            }
            .readingPresentationDetents([.medium, .large])
        }
        .confirmationDialog("把选中的 \(selection.urls.count) 本书移出书架？", isPresented: $showsRemoveConfirmation,
                            titleVisibility: .visible) {
            Button("移出书架", role: .destructive) {
                let books = selectedBooks
                selection.end()
                Task { for book in books { await BookshelfRemoval.remove(book, library: library) } }
            }
            Button("取消", role: .cancel) { }
        }
    }
}

/// 加入分组：新建一个分组放进选中的书，或放进已有分组。
private struct BookshelfAddToFolderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var folderStore = BookshelfFolderStore.shared
    let bookURLs: [String]
    let groupID: Int64
    let onDone: () -> Void
    @State private var newName = ""
    @FocusState private var nameFocused: Bool

    private var folders: [BookshelfFolder] { folderStore.folders(inGroup: groupID) }

    var body: some View {
        ReadingNavigationStack {
            List {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "plus").foregroundStyle(ReadingTheme.accent)
                        TextField("新建分组名称", text: $newName)
                            .focused($nameFocused)
                            .submitLabel(.done)
                            .onSubmit(createFolder)
                        if !newName.trimmingCharacters(in: .whitespaces).isEmpty {
                            Button("新建", action: createFolder)
                                .font(AppFontStyle.subheadline.weight(.semibold).themed)
                                .foregroundStyle(ReadingTheme.accent)
                        }
                    }
                } header: {
                    Text("新建分组")
                } footer: {
                    Text(bookURLs.isEmpty ? "先在书架上勾选要加入的书。" : "选中的 \(bookURLs.count) 本书会放进这个分组。")
                }.readingRowBackground()
                if !folders.isEmpty {
                    Section("已有分组") {
                        ForEach(folders) { folder in
                            Button {
                                for url in bookURLs { folderStore.add(url, to: folder.id) }
                                finish()
                            } label: {
                                HStack {
                                    Image(systemName: "folder").foregroundStyle(ReadingTheme.accent)
                                    Text(folder.name).foregroundStyle(.primary)
                                    Spacer()
                                    Text("\(folder.bookURLs.count) 本").foregroundStyle(.secondary)
                                }
                            }
                            .disabled(bookURLs.isEmpty)
                        }
                    }.readingRowBackground()
                }
            }
            .readingThemedListBackground()
            .navigationTitle("加入分组")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
        }
    }

    private func createFolder() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !bookURLs.isEmpty else { return }
        folderStore.makeFolder(groupID: groupID, bookURLs: bookURLs, name: name)
        finish()
    }

    private func finish() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        dismiss()
        onDone()
    }
}



