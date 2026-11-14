import SwiftUI
import UniformTypeIdentifiers
import PhotosUI

struct RootTabView: View {
    @EnvironmentObject private var sourceLibrary: SourceLibraryModel
    private enum Tab: Hashable { case bookshelf, explore, statistics, my }
    /// 切换或编辑主题后根视图会整体刷新，记住当前标签，刷新后停留在原处。
    @MainActor private static var lastSelection: Tab?
    @Environment(\.appTheme) private var appTheme
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
        _selection = State(initialValue: Self.lastSelection ?? initial)
    }

    var body: some View {
        TabView(selection: $selection) {
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
                .tabItem { themedTabItem(.shelf) }
                .tag(Tab.bookshelf)

            ReadingNavigationStack { ExploreView() }
                .tabItem { themedTabItem(.discover) }
                .tag(Tab.explore)

            ReadingNavigationStack { ReadingStatisticsView() }
                .tabItem { themedTabItem(.statistics) }
                .tag(Tab.statistics)

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
                .tabItem { themedTabItem(.profile) }
                .tag(Tab.my)
        }
        .readingTabBarBackground()
        .onChange(of: selection) { Self.lastSelection = $0 }
        .overlay { BookshelfFolderOverlay() }
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

    /// 底栏标签：跟随主题的「Tab栏」显示方式（图标和文字 / 仅图标 / 仅文字）与自定义图标。
    @ViewBuilder
    private func themedTabItem(_ tab: LibraryTab) -> some View {
        switch appTheme.customization?.tabStyle ?? .iconsAndText {
        case .iconsAndText:
            ThemeTabIconImage.image(tab: tab, theme: appTheme, size: 25)
            Text(tab.title)
        case .icons:
            ThemeTabIconImage.image(tab: tab, theme: appTheme, size: 25)
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
    @State private var showsLocalImporter = false
    @State private var pendingLocalFiles: [LocalBookImportFile] = []
    @State private var selectedGroupID = BookGroup.idAll
    @State private var showsGroupManager = false
    @State private var showsOrnamentManager = false
    @State private var showsShelfSettings = false
    @AppStorage("bookshelfLayout") private var bookshelfLayout = "grid3"
    @AppStorage(BookshelfShelfSettings.sideSwitcherKey) private var sideSwitcher = true
    @AppStorage(BookshelfShelfSettings.hideShelfBaseKey) private var hideShelfBase = false
    @AppStorage(BookshelfShelfSettings.boardStyleKey) private var boardStyle = "solid"
    @State private var shelfDestination: BookshelfShelfDestination?

    private static let gridSpacing: CGFloat = 16

    private var selectedGroup: BookGroup {
        library.visibleGroups.first(where: { $0.id == selectedGroupID })
            ?? library.visibleGroups.first
            ?? BookGroup(groupId: BookGroup.idAll, groupName: "全部")
    }

    private var displayedBooks: [Book] { library.books(in: selectedGroup) }

    private var recentBook: Book? {
        displayedBooks.filter(BookReadingPresentation.hasStarted)
            .sorted { $0.durChapterTime > $1.durChapterTime }
            .first
    }

    private var showsSideSwitcher: Bool { sideSwitcher && library.visibleGroups.count > 1 }

    /// 书架内容宽度：左右各留 24pt 边距。
    private var contentWidth: CGFloat { max(UIScreen.main.bounds.width - 48, 120) }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ReadingPageHeader(title: "书架", subtitle: "阅读，让时间有了形状") {
                    NavigationLink { SearchView() } label: {
                        ReadingToolbarIcon(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("搜索")
                    if bookshelfLayout == "shelf" {
                        Button { showsOrnamentManager = true } label: {
                            ReadingToolbarIcon(systemName: "leaf")
                        }
                        .accessibilityLabel("书架摆件")
                    }
                    Button { showsShelfSettings = true } label: {
                        ReadingToolbarIcon(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("书架设置")
                    bookshelfMenu
                }
                if library.visibleGroups.count > 1 {
                    bookshelfGroups.padding(.bottom, 24)
                }
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !library.hasLoaded {
                        // 书架还没读完：保持空白，不闪「空书架」占位。
                        Color.clear.frame(height: 1)
                    } else if displayedBooks.isEmpty {
                        EmptyBookshelfHero { showsLocalImporter = true }
                    } else {
                        if let book = recentBook {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("继续阅读")
                                    .font(AppFontStyle.subheadline.weight(.medium).themed)
                                    .foregroundStyle(.secondary)
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
                .padding(.bottom, 32)
            }
        }
        .readingCanvas()
        .overlay(alignment: .trailing) {
            if showsSideSwitcher {
                sideSwitcherBar
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: showsSideSwitcher)
        .navigationBarHidden(true)
        .onReceive(library.$books) { books in
            ReadRecordCoverStore.remember(books)
            if library.hasLoaded {
                folderStore.prune(existing: Set(books.map(\.bookUrl)))
            }
        }
        .onAppear { Task { await migrateLegacyFolders() } }
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
        .sheet(isPresented: $showsShelfSettings) {
            BookshelfShelfSettingsSheet()
        }
        .onReceive(BookshelfFolderStore.shared.$openRequest) { request in
            guard let request else { return }
            BookshelfFolderStore.shared.openRequest = nil
            shelfDestination = request
        }
        .sheet(isPresented: $showsGroupManager) {
            BookshelfManagerSheet()
                .environmentObject(library)
                .readingPresentationDetents([.medium, .large])
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

    private var bookshelfSummary: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text(selectedGroupID == BookGroup.idAll ? "全部书籍" : selectedGroup.groupName)
                    .font(AppFontStyle.title3.bold().themed)
                    .accessibilityAddTraits(.isHeader)
                Text("\(displayedBooks.count)本")
                    .font(AppFontStyle.caption.themed).foregroundStyle(.secondary)
            }
            Spacer()
            layoutSwitcher
        }
        .padding(.bottom, 20)
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
        .background(Color.secondary.opacity(0.10), in: Capsule())
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
        return VStack(alignment: .leading, spacing: hideShelfBase ? 20 : 22) {
            ForEach(rows.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(rows[index]) { entry in
                        gridCell(entry, width: cellWidth)
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
                        BookshelfBoard(width: contentWidth, height: boardHeight, solid: solid)
                            .offset(y: coverHeight)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func gridCell(_ entry: BookshelfEntry, width: CGFloat) -> some View {
        switch entry {
        case .book(let book):
            BookshelfBookLink(book: book, mode: .grid(width), groupID: selectedGroup.groupId)
        case .folder(let folder, let inside):
            Button {
                openFolder(folder)
            } label: {
                BookshelfFolderGridTile(folder: folder, books: inside, width: width)
            }
            .buttonStyle(.plain)
            .modifier(BookshelfDropModifier(targetURL: nil, folderID: folder.id, groupID: selectedGroup.groupId))
            .accessibilityLabel("文件夹「\(folder.name)」，\(inside.count) 本书")
            .accessibilityHint("轻点打开")
        }
    }

    // MARK: 列表

    private var listSection: some View {
        let entries = folderStore.entries(for: displayedBooks, groupID: selectedGroup.groupId)
        let compact = bookshelfLayout == "compact"
        let solid = boardStyle == "solid"
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(entries) { entry in
                switch entry {
                case .book(let book):
                    BookshelfBookLink(book: book, mode: compact ? .compact : .list, groupID: selectedGroup.groupId)
                case .folder(let folder, let inside):
                    Button {
                        openFolder(folder)
                    } label: {
                        BookshelfFolderRow(folder: folder, books: inside, compact: compact)
                    }
                    .buttonStyle(.plain)
                    .modifier(BookshelfDropModifier(targetURL: nil, folderID: folder.id, groupID: selectedGroup.groupId))
                }
                if solid {
                    BookshelfBoard(width: contentWidth, height: 7, solid: true)
                        .padding(.bottom, 6)
                } else if entry.id != entries.last?.id {
                    Rectangle().fill(ReadingTheme.separator).frame(height: 0.5)
                        .padding(.leading, compact ? 54 : 66)
                }
            }
        }
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
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.08), radius: 4, x: -1, y: 1)
        .padding(.trailing, 2)
    }

    private static func verticalLabel(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.prefix(4).map(String.init).joined(separator: "\n")
    }

    @ViewBuilder
    private var bookshelfMenu: some View {
        if library.isCheckingUpdates {
            ProgressView().controlSize(.small).frame(width: 44, height: 44)
        } else {
            Menu {
                Button("更新目录", systemImage: "arrow.clockwise") {
                    Task { await library.checkForUpdates(sources: sources.sources) }
                }
                Button("本地书", systemImage: "plus") { showsLocalImporter = true }
                Button("管理书架", systemImage: "rectangle.3.group") { showsGroupManager = true }
                if bookshelfLayout == "shelf" {
                    Button { showsOrnamentManager = true } label: {
                        Label("书架摆件", systemImage: "leaf")
                    }
                }
                NavigationLink {
                    FileManagementView()
                } label: {
                    Label("文件管理", systemImage: "folder")
                }
            } label: {
                ReadingToolbarIcon(systemName: "ellipsis")
            }
            .accessibilityLabel("更多")
        }
    }

    private var bookshelfGroups: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 24) {
                ForEach(library.visibleGroups) { group in
                    Button(group.groupName) { selectedGroupID = group.id }
                        .font(AppFontStyle.subheadline.weight(selectedGroup.id == group.id ? .semibold : .regular).themed)
                        .foregroundStyle(selectedGroup.id == group.id ? Color.primary : .secondary)
                        .frame(minHeight: 44)
                        .overlay(alignment: .bottom) {
                            if selectedGroup.id == group.id {
                                Rectangle().fill(ReadingTheme.accent).frame(height: 2)
                            }
                        }
                        .accessibilityAddTraits(selectedGroup.id == group.id ? .isSelected : [])
                }
                Button { showsGroupManager = true } label: {
                    Image(systemName: "slider.horizontal.below.rectangle")
                        .font(AppFontStyle.system(size: 14).themed)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 32, minHeight: 44)
                }
                .accessibilityLabel("管理书架")
            }
            .padding(.horizontal, 24)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(ReadingTheme.separator).frame(height: 0.5)
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
}

private struct BookshelfBookLink: View {
    @EnvironmentObject private var library: BookLibraryModel
    @EnvironmentObject private var sources: SourceLibraryModel
    @ObservedObject private var folderStore = BookshelfFolderStore.shared
    let book: Book
    let mode: BookshelfLinkMode
    let groupID: Int64
    @State private var showsGroupSelector = false

    private var source: BookSource? { sources.sources.first { $0.bookSourceUrl == book.origin } }

    var body: some View {
        NavigationLink {
            BookshelfBookDestination(book: book, source: source)
        } label: {
            switch mode {
            case .grid(let width): BookshelfGridItem(book: book, width: width)
            case .list: BookshelfRow(book: book, compact: false)
            case .compact: BookshelfRow(book: book, compact: true)
            }
        }
        .buttonStyle(.plain)
        .onDrag { NSItemProvider(object: book.bookUrl as NSString) }
        .modifier(BookshelfDropModifier(targetURL: book.bookUrl, folderID: nil, groupID: groupID))
        .contextMenu {
            NavigationLink {
                if let source { BookDetailView(book: book, source: source) }
                else { LocalBookDetailView(book: book) }
            } label: {
                Label("书籍信息", systemImage: "info.circle")
            }
            Button("移至书架", systemImage: "rectangle.3.group") { showsGroupSelector = true }
            let folders = folderStore.folders(inGroup: groupID)
            if !folders.isEmpty {
                Menu {
                    ForEach(folders) { folder in
                        Button(folder.name) {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                                folderStore.add(book.bookUrl, to: folder.id)
                            }
                        }
                    }
                } label: {
                    Label("放入文件夹", systemImage: "folder")
                }
            }
            Button("移出书架", systemImage: "trash", role: .destructive) {
                Task { await BookshelfRemoval.remove(book, library: library) }
            }
        }
        .sheet(isPresented: $showsGroupSelector) {
            BookGroupSelectView(book: book).environmentObject(library)
        }
    }
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
    let title: String
    let subtitle: String
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(AppFontStyle.system(size: width < 90 ? 12 : 13, weight: .medium).themed)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(AppFontStyle.system(size: width < 90 ? 10 : 11).themed)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
    }
}

/// 网格封面：封面立在书板上，书名和作者写在书板下方；阅读进度是封面底边的一条细线。
private struct BookshelfGridItem: View {
    let book: Book
    let width: CGFloat
    @AppStorage(BookshelfShelfSettings.hideTitlesKey) private var hideTitles = false
    @AppStorage(BookshelfShelfSettings.hideShelfBaseKey) private var hideShelfBase = false
    @AppStorage(BookshelfShelfSettings.boardStyleKey) private var boardStyle = "solid"

    var body: some View {
        let height = BookshelfGridMetrics.coverHeight(width: width)
        let progress = BookReadingPresentation.progress(book)
        VStack(alignment: .leading, spacing: 0) {
            BookshelfCover(book: book, width: width, height: height)
                .overlay(alignment: .bottom) {
                    if progress > 0 {
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(Color.white.opacity(0.35))
                                Rectangle().fill(ReadingTheme.accent)
                                    .frame(width: proxy.size.width * min(max(progress, 0), 1))
                            }
                        }
                        .frame(height: 2.5)
                        .clipShape(RoundedRectangle(cornerRadius: 1, style: .continuous))
                        .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if book.lastCheckCount > 0 {
                        Text("+\(book.lastCheckCount)")
                            .font(.system(size: 9, weight: .bold).monospacedDigit())
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 5)
                            .frame(height: 15)
                            .background(ReadingTheme.coral, in: Capsule())
                            .offset(x: 4, y: -5)
                            .accessibilityLabel("更新 \(book.lastCheckCount) 章")
                    }
                }
                .frame(width: width, height: height)
            if !hideTitles {
                BookshelfGridLabel(title: book.name,
                                   subtitle: book.author.isEmpty ? "未知作者" : book.author,
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
    @AppStorage(BookshelfShelfSettings.hideTitlesKey) private var hideTitles = false
    @AppStorage(BookshelfShelfSettings.hideShelfBaseKey) private var hideShelfBase = false
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
            if !hideTitles {
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
            BookshelfFolderIcon(books: books, width: compact ? 40 : coverWidth, height: compact ? 56 : coverWidth * 1.42)
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
        .padding(.vertical, compact ? 10 : 12)
        .contentShape(Rectangle())
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
                BookCoverArtwork(title: book.name, author: book.author, remoteURL: book.coverUrl, width: 44, height: 62)
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
        .background(ReadingTheme.groupedCanvas, in: RoundedRectangle(cornerRadius: 14))
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

private struct BookGroupSelectView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: BookLibraryModel
    let book: Book
    @State private var selected: Set<Int64>

    init(book: Book) {
        self.book = book
        _selected = State(initialValue: [])
    }

    private var customGroups: [BookGroup] {
        library.groups.filter { $0.groupId > 0 }.sorted { $0.order < $1.order }
    }

    var body: some View {
        ReadingNavigationStack {
            List(customGroups) { group in
                Button {
                    if !selected.insert(group.id).inserted { selected.remove(group.id) }
                } label: {
                    HStack {
                        Text(group.groupName).foregroundStyle(.primary)
                        Spacer()
                        if selected.contains(group.id) { Image(systemName: "checkmark").foregroundStyle(ReadingTheme.accent) }
                    }
                }
            }.readingThemedListBackground()
            .overlay {
                if customGroups.isEmpty {
                    ReadingUnavailableView("没有自定义书架", systemImage: "rectangle.3.group", description: Text("在「管理书架」里新建书架。"))
                }
            }
            .navigationTitle("移至书架")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确定") {
                        Task { await library.setBook(book, groupIDs: selected); dismiss() }
                    }
                }
            }
            .onAppear {
                selected = Set(customGroups.filter { (book.group & $0.groupId) != 0 }.map(\.groupId))
            }
        }
        .interactiveDismissDisabled()
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
        .task { await model.load(book: book, source: source) }
    }
}

/// 打开书籍时、目录还没读完的过渡页：直接用阅读背景，不出现白底和返回栏，
/// 读得快时用户看不到任何过渡；超过半秒才显示一个小的加载圈。
private struct ReaderOpeningPlaceholder: View {
    @AppStorage("readerTheme") private var theme = "wechat"
    @AppStorage("themeMode") private var themeMode = "0"
    @AppStorage("readerUseBackgroundImage") private var useBackgroundImage = false
    @Environment(\.dismiss) private var dismiss
    @State private var showsSpinner = false
    @State private var backgroundImage: UIImage?

    private var style: ReaderStylePreset {
        themeMode == "3" ? .eInk : ReaderStylePreset.resolve(theme)
    }

    init() {
        let defaults = UserDefaults.standard
        let usesImage = defaults.bool(forKey: "readerUseBackgroundImage") && defaults.string(forKey: "themeMode") != "3"
        _backgroundImage = State(initialValue: usesImage ? ReaderBackgroundStore.load() : nil)
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
        .preferredColorScheme(style.id == "night" ? .dark : .light)
        .navigationBarBackButtonHidden(true)
        .readingTabBarHidden()
        .task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            withAnimation(.easeIn(duration: 0.2)) { showsSpinner = true }
        }
    }
}

private struct BookshelfRow: View {
    let book: Book
    var compact = false
    @ScaledMetric(relativeTo: .body) private var coverWidth = 52

    private var readingPosition: String {
        if let title = book.durChapterTitle, !title.isEmpty { return title }
        if book.durChapterIndex > 0 || book.durChapterPos > 0 || book.durChapterTime > 0 {
            return book.totalChapterNum > 0
                ? "第 \(book.durChapterIndex + 1) 章 / 共 \(book.totalChapterNum) 章"
                : "已读至第 \(book.durChapterIndex + 1) 章"
        }
        return "尚未阅读"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            BookshelfCover(
                book: book,
                width: compact ? 40 : coverWidth,
                height: compact ? 56 : coverWidth * 1.42
            )
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(book.name)
                        .font(AppFontStyle.body.weight(.medium).themed)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    if book.lastCheckCount > 0 {
                        Text("+\(book.lastCheckCount)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(ReadingTheme.accent)
                            .fixedSize()
                            .accessibilityLabel("更新 \(book.lastCheckCount) 章")
                    }
                }
                Text(book.author.isEmpty ? "未知作者" : book.author)
                    .font(AppFontStyle.caption.themed).foregroundStyle(.secondary).lineLimit(1)
                if !compact {
                    Text(readingPosition)
                        .font(AppFontStyle.caption.themed)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, compact ? 10 : 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(book.latestChapterTitle.map { "最新章节：\($0)" } ?? "")
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
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
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
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("themeMode") private var themeMode = "0"
    @ScaledMetric(relativeTo: .body) private var rowHeight = 52

    var body: some View {
        GeometryReader { geometry in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    profileHeader(topInset: geometry.safeAreaInsets.top)
                    VStack(alignment: .leading, spacing: 24) {
                        appCard
                        readingSection
                        rulesSection
                        settingSection("文件与存储") {
                            settingLink("文件管理", icon: "folder", showsSeparator: false) {
                                FileManagementView()
                            }
                        }
                        supportSection
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 32)
                }
                .background(alignment: .top) {
                    Image("ProfileHeader")
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.safeAreaInsets.top + 156)
                        .clipped()
                        .overlay {
                            if colorScheme == .dark {
                                Color.black.opacity(0.78)
                            }
                        }
                        .overlay(alignment: .bottom) {
                            LinearGradient(
                                colors: [ProfileTheme.canvas.opacity(0), ProfileTheme.canvas],
                                startPoint: .top, endPoint: .bottom
                            )
                            .frame(height: 44)
                        }
                        .accessibilityHidden(true)
                }
            }
            .ignoresSafeArea(.container, edges: .top)
            .accessibilityIdentifier("profile.scroll")
        }
        .readingCanvas()
        .navigationBarHidden(true)
    }

    private func profileHeader(topInset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("我的")
                .font(AppFontStyle.largeTitle.bold().themed)
                .foregroundStyle(ProfileTheme.ink)
                .accessibilityAddTraits(.isHeader)
            Text("按照你的方式阅读")
                .font(AppFontStyle.subheadline.themed)
                .foregroundStyle(ProfileTheme.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.top, topInset + 42)
        .padding(.bottom, 34)
    }

    private var appCard: some View {
        NavigationLink {
            AboutView()
        } label: {
            HStack(spacing: 16) {
                Image("BrandIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 58, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(AppIdentity.name)
                        .font(AppFontStyle.headline.themed)
                        .foregroundStyle(ProfileTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(AppIdentity.slogan)
                        .font(AppFontStyle.footnote.themed)
                        .foregroundStyle(ProfileTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(AppFontStyle.system(size: 13, weight: .medium).themed)
                    .foregroundStyle(ProfileTheme.ink.opacity(0.75))
                    .frame(width: 26, height: 26)
                    .background(ProfileTheme.detail.opacity(0.10), in: Circle())
                    .accessibilityHidden(true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
            .background {
                // 跟随主题的界面效果 / 卡片背景 / 圆角边框 / 玻璃模式。
                ThemeSurface(shape: RoundedRectangle(cornerRadius: palette.cornerRadius(default: 16), style: .continuous),
                             isCard: true)
            }
            .shadow(color: .black.opacity(palette.cardBackground ? 0.035 : 0), radius: 18, x: 0, y: 8)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("查看关于与版本信息")
        .accessibilityIdentifier("profile.about")
    }

    private var readingSection: some View {
        settingSection("阅读") {
            settingLink("阅读设置", icon: "textformat.size") { ReadingPreferencesView() }
            appearanceEntry
            .accessibilityLabel("外观")
            .accessibilityValue(appearanceTitle)
            .accessibilityIdentifier("profile.appearance")
            settingLink("在线朗读", icon: "waveform") { HttpTTSManagementView() }
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

    /// iOS 17 起打开完整的「外观主题」（主题配色、编辑器、玻璃模式、应用外观）；更早的系统保留原来的外观菜单。
    @ViewBuilder
    private var appearanceEntry: some View {
        if #available(iOS 17.0, *) {
            Button { AppearanceHubPresenter.shared.isPresented = true } label: {
                settingRow("外观主题", icon: "circle.lefthalf.filled",
                           value: AppThemeStore.shared.selectedTheme.name + " · " + appearanceTitle,
                           showsValuePill: true)
            }
            .buttonStyle(.plain)
        } else {
            Menu {
                Picker("外观", selection: $themeMode) {
                    Text("跟随系统").tag("0")
                    Text("浅色").tag("1")
                    Text("深色").tag("2")
                    Text("E-Ink 模式").tag("3")
                }
            } label: {
                settingRow("外观", icon: "circle.lefthalf.filled", value: appearanceTitle, showsValuePill: true)
            }
            .buttonStyle(.plain)
        }
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
            VStack(spacing: 0, content: content)
                .background {
                    ThemeSurface(shape: RoundedRectangle(cornerRadius: palette.cornerRadius(default: 18), style: .continuous),
                                 isCard: true)
                }
                .clipShape(RoundedRectangle(cornerRadius: palette.cornerRadius(default: 18), style: .continuous))
                .shadow(color: .black.opacity(palette.cardBackground ? 0.025 : 0), radius: 20, x: 0, y: 8)
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
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(minHeight: rowHeight)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            if showsSeparator {
                Rectangle()
                    .fill(ProfileTheme.separator)
                    .frame(height: 0.5)
                    .padding(.leading, 62)
                    .padding(.trailing, 18)
                    .accessibilityHidden(true)
            }
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

    var body: some View {
        Group {
            if systemName == "textformat.size" {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("A").font(AppFontStyle.system(size: 24, weight: .light).themed).foregroundStyle(ProfileTheme.ink)
                    Text("A").font(AppFontStyle.system(size: 13, weight: .medium).themed).foregroundStyle(ProfileTheme.detail)
                }
            } else if ["circle.lefthalf.filled", "waveform", "bookmark", "clock", "globe"].contains(systemName) {
                Canvas { context, size in
                    context.scaleBy(x: size.width / 24, y: size.height / 24)
                    draw(in: &context)
                }
                .frame(width: 22, height: 22)
            } else {
                Image(systemName: systemName)
                    .font(AppFontStyle.system(size: 20, weight: .regular).themed)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(ProfileTheme.ink, ProfileTheme.detail)
            }
        }
    }

    private func draw(in context: inout GraphicsContext) {
        let stroke = StrokeStyle(lineWidth: 1.65, lineCap: .round, lineJoin: .round)
        let circle = Path(ellipseIn: CGRect(x: 2.5, y: 2.5, width: 19, height: 19))
        switch systemName {
        case "circle.lefthalf.filled":
            var half = Path()
            half.addArc(center: CGPoint(x: 12, y: 12), radius: 9.5, startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
            half.closeSubpath()
            context.fill(half, with: .color(ProfileTheme.ink))
            context.stroke(circle, with: .color(ProfileTheme.ink), style: stroke)
            var edge = Path()
            edge.addArc(center: CGPoint(x: 12, y: 12), radius: 10.2, startAngle: .degrees(105), endAngle: .degrees(255), clockwise: false)
            context.stroke(edge, with: .color(ProfileTheme.detail), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        case "waveform":
            for (index, height) in [4.0, 12.0, 21.0, 14.0, 5.0].enumerated() {
                let bar = CGRect(x: 2 + Double(index) * 4.4, y: (24 - height) / 2, width: 2.4, height: height)
                context.fill(Path(roundedRect: bar, cornerRadius: 1.2), with: .color(index > 2 ? ProfileTheme.detail : ProfileTheme.ink))
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
            context.stroke(bookmark, with: .color(ProfileTheme.detail), style: stroke)
        case "clock":
            context.stroke(circle, with: .color(ProfileTheme.ink), style: stroke)
            var hands = Path()
            hands.move(to: CGPoint(x: 12, y: 6))
            hands.addLine(to: CGPoint(x: 12, y: 12))
            hands.addLine(to: CGPoint(x: 16, y: 15))
            context.stroke(hands, with: .color(ProfileTheme.detail), style: stroke)
        case "globe":
            let meridian = Path(ellipseIn: CGRect(x: 7.5, y: 2.5, width: 9, height: 19))
            context.stroke(meridian, with: .color(ProfileTheme.detail), style: stroke)
            var parallels = Path()
            for y in [7.0, 17.0] {
                parallels.move(to: CGPoint(x: 4, y: y))
                parallels.addQuadCurve(to: CGPoint(x: 20, y: y), control: CGPoint(x: 12, y: 12))
            }
            context.stroke(parallels, with: .color(ProfileTheme.detail), style: stroke)
            context.stroke(circle, with: .color(ProfileTheme.ink), style: stroke)
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
    static let bookWidthKey = "shelfBookWidth"
    static let bookHeightKey = "shelfBookHeight"
    static let coverSpineKey = "shelfCoverSpine"
    static let hideRotateKey = "shelfHideRotateButtons"
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

    func scaled(_ factor: CGFloat) -> BookshelfShelfStyle {
        var copy = self
        copy.bookWidth = max(6, (bookWidth * factor).rounded())
        copy.bookHeight = max(30, (bookHeight * factor).rounded())
        return copy
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
    /// 仿真书架上的装帧样式：0 典藏（酒红），1 精装（深灰）。
    var style: Int = 0
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
    }
}

/// 实体封面左侧的书脊凹槽与高光。
struct BookshelfSolidSpineShade: View {
    let width: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            LinearGradient(stops: [
                .init(color: .black.opacity(0.30), location: 0),
                .init(color: .white.opacity(0.22), location: 0.35),
                .init(color: .black.opacity(0.25), location: 0.7),
                .init(color: .white.opacity(0.10), location: 1)
            ], startPoint: .leading, endPoint: .trailing)
            .frame(width: max(width * 0.075, 3))
            LinearGradient(colors: [.black.opacity(0.12), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: max(width * 0.06, 2))
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

    var body: some View {
        let solid = coverStyle == "solid"
        BookCoverArtwork(title: book.name, author: book.author, remoteURL: book.coverUrl, width: width, height: height)
            .overlay(alignment: .leading) {
                if solid {
                    BookshelfSolidSpineShade(width: width)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }
            .shadow(color: .black.opacity(solid ? 0.22 : 0.08), radius: solid ? 3 : 1.5, x: solid ? 2 : 0, y: solid ? 3 : 1)
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
                                                     remoteURL: shown[index].coverUrl, width: cellWidth, height: cellHeight)
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

/// 网格、列表里的拖放：把一本书拖到另一本书上建文件夹，拖到文件夹上放进去。
struct BookshelfDropModifier: ViewModifier {
    let targetURL: String?
    let folderID: String?
    let groupID: Int64
    var cornerRadius: CGFloat = 6
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(ReadingTheme.accent, lineWidth: 2)
                    .opacity(targeted ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .scaleEffect(targeted ? 1.04 : 1)
            .animation(.easeOut(duration: 0.15), value: targeted)
            .onDrop(of: [UTType.plainText], isTargeted: $targeted) { providers in
                guard let provider = providers.first else { return false }
                let target = targetURL
                let folder = folderID
                let group = groupID
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    guard let value = object as? NSString else { return }
                    let url = String(value)
                    Task { @MainActor in
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                            BookshelfFolderStore.shared.handleDrop(url, ontoBook: target, folder: folder, groupID: group)
                        }
                    }
                }
                return true
            }
    }
}

/// 仿真书架上的文件夹外观：两种装帧样式；书脊上的小旋转按钮修改摆放形态与样式。
private struct BookshelfFolderBox: View {
    let folder: BookshelfFolder
    let books: [Book]
    let style: BookshelfShelfStyle
    let onRotate: () -> Void

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

    private var colors: (box: Color, dark: Color, label: Color, window: Color) {
        if folder.style == 1 {
            return (Color(red: 0.20, green: 0.21, blue: 0.23), Color(red: 0.11, green: 0.12, blue: 0.13),
                    Color(red: 0.86, green: 0.87, blue: 0.89), Color(red: 0.06, green: 0.06, blue: 0.07))
        }
        return (Color(red: 0.42, green: 0.14, blue: 0.13), Color(red: 0.27, green: 0.08, blue: 0.08),
                Color(red: 0.95, green: 0.86, blue: 0.67), Color(red: 0.16, green: 0.05, blue: 0.05))
    }

    private var footer: String {
        folder.style == 1 ? "PRECISION // \(books.count)V" : "典藏 · \(books.count) 册"
    }

    var body: some View {
        let size = Self.size(count: books.count, style: style)
        let inner = style.scaled(Self.innerScale(style))
        let colors = self.colors
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(LinearGradient(colors: [colors.box, colors.dark], startPoint: .top, endPoint: .bottom))
            // 左侧高光、右侧暗面，做出盒子的厚度。
            HStack(spacing: 0) {
                LinearGradient(colors: [Color.white.opacity(0.18), Color.clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 4)
                Spacer(minLength: 0)
                LinearGradient(colors: [Color.clear, Color.black.opacity(0.35)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 5)
            }
            // 顶部标签：文件夹名
            Text(folder.name)
                .font(AppFontStyle.system(size: 8, weight: .semibold).themed)
                .foregroundStyle(colors.label)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: max(size.width - 32, 12), height: Self.topLabel)
                .offset(x: 5)
            // 窗口：里面立着文件夹里的书
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(colors.window)
                .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .strokeBorder(colors.label.opacity(0.45), lineWidth: 0.6))
                .frame(width: size.width - Self.side * 2, height: size.height - Self.topLabel - Self.bottomLabel)
                .offset(x: Self.side, y: Self.topLabel)
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(books.prefix(Self.maxShown)) { book in
                    BookshelfSpine(book: book, pose: .upright, isSelected: false, style: inner)
                }
            }
            .frame(width: size.width - Self.side * 2 - 2, height: size.height - Self.topLabel - Self.bottomLabel - 2,
                   alignment: .bottomLeading)
            .clipped()
            .offset(x: Self.side + 2, y: Self.topLabel + 1)
            .allowsHitTesting(false)
            // 底部标签
            Text(footer)
                .font(AppFontStyle.system(size: 6.5, weight: .medium, design: folder.style == 1 ? .monospaced : .default).themed)
                .foregroundStyle(colors.label.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(width: size.width - 10, height: Self.bottomLabel)
                .offset(x: 5, y: size.height - Self.bottomLabel)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .overlay(alignment: .topTrailing) {
            // 旋转按钮整块放在文件夹外框之内：之前按钮向外偏移，超出外框的部分
            // 会被外框的点击形状裁掉、被相邻的书盖住，导致大多数时候点不中。
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(AppFontStyle.system(size: 7.5, weight: .bold).themed)
                .foregroundStyle(colors.label)
                .frame(width: 15, height: 15)
                .background(Color.black.opacity(0.4), in: Circle())
                .overlay(Circle().strokeBorder(colors.label.opacity(0.35), lineWidth: 0.5))
                .opacity(style.hideRotateButtons ? 0.011 : 1)
                .padding(.top, 2)
                .padding(.trailing, 2)
                .frame(width: Self.rotateHitWidth, height: Self.rotateHitHeight, alignment: .topTrailing)
                .contentShape(Rectangle())
                .highPriorityGesture(TapGesture().onEnded { onRotate() })
                .accessibilityElement()
                .accessibilityLabel("修改文件夹摆放形态与样式")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { onRotate() }
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
    @AppStorage(BookshelfShelfSettings.boardStyleKey) private var boardStyle = "solid"
    @State private var poses: [String: Int] = BookshelfShelfPose.load()
    /// 文件夹上的旋转按钮打开的摆放形态选择条。
    @State private var folderPickerID: String?
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
            hideRotateButtons: hideRotateButtons
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
        guard !order.isEmpty else { return defaults }
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
        return defaults.enumerated().sorted { lhs, rhs in
            let l = itemRank(lhs.element, offset: lhs.offset)
            let r = itemRank(rhs.element, offset: rhs.offset)
            return l == r ? lhs.offset < rhs.offset : l < r
        }.map(\.element)
    }

    /// 放在平躺书上面的摆件（书 → 摆件）。书不在当前书架或不再平躺时，摆件回到原来的位置。
    private func perchedOrnaments(in items: [BookshelfShelfItem]) -> [String: (ShelfOrnament, CGSize)] {
        var flatBooks = Set<String>()
        for item in items {
            if let key = item.poseKey, requestedPose(key: key) == .flat { flatBooks.insert(key) }
        }
        var result: [String: (ShelfOrnament, CGSize)] = [:]
        for item in items {
            guard case .ornament(let ornament, let size) = item,
                  let url = perches[ornament.id], flatBooks.contains(url), result[url] == nil else { continue }
            result[url] = (ornament, size)
        }
        return result
    }

    /// 按现实中的支撑关系摆一层：倾斜的书一角着地，上端刚好靠在相邻的书、文件夹或摆件上。
    private func layoutRow(_ entries: [(item: BookshelfShelfItem, index: Int)],
                           perched: [String: (ShelfOrnament, CGSize)]) -> [BookshelfShelfPlacement] {
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
                } else {
                    w = style.bookWidth
                    h = style.bookHeight
                }
                let key = entry.item.poseKey ?? ""
                var pose = requestedPose(key: key)
                // 一层最边上的书没有东西可靠：改靠向另一侧；这一层只有它一件时竖立。
                if pose == .leanLeft && position == 0 { pose = entries.count > 1 ? .leanRight : .upright }
                if pose == .leanRight && position == entries.count - 1 { pose = entries.count > 1 ? .leanLeft : .upright }
                switch pose {
                case .upright:
                    let left = previous.map { leftEdgeAfter($0, objectHeight: h) } ?? 0
                    result.append(.init(item: entry.item, index: entry.index, pose: pose,
                                        boxX: left, boxSize: CGSize(width: w, height: h),
                                        boardMinX: left, boardMaxX: left + w, height: h, pivotX: left))
                case .flat:
                    let lying = w + (perched[key]?.1.height ?? 0)
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

    private func rows(_ items: [BookshelfShelfItem], perched: [String: (ShelfOrnament, CGSize)]) -> [[BookshelfShelfPlacement]] {
        let perchedIDs = Set(perched.values.map { "o:" + $0.0.id })
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
        }
        .sheet(item: $editingOrnament) { ornament in
            ShelfOrnamentSettingsSheet(ornamentID: ornament.id)
        }
    }

    private func isRaised(_ placement: BookshelfShelfPlacement, perched: [String: (ShelfOrnament, CGSize)]) -> Bool {
        if placement.id == draggingID || placement.id == "b:" + (selectedURL ?? "") { return true }
        if let key = placement.item.poseKey, let ornament = perched[key]?.0 {
            return "o:" + ornament.id == draggingID
        }
        return false
    }

    private func deselect() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            selectedURL = nil
            showsPicker = false
            folderPickerID = nil
        }
    }

    private var hasSelection: Bool { selectedURL != nil || folderPickerID != nil }

    private func shelfRow(_ row: [BookshelfShelfPlacement], rowIndex: Int, rows: [[BookshelfShelfPlacement]],
                          perched: [String: (ShelfOrnament, CGSize)]) -> some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { if hasSelection { deselect() } }
                ForEach(row) { placement in
                    placementView(placement, rows: rows)
                        .zIndex(placement.id == draggingID ? 3 : (placement.id == "b:" + (selectedURL ?? "") ? 2 : 0))
                    if let key = placement.item.poseKey, let perch = perched[key] {
                        perchedOrnamentView(perch.0, size: perch.1, on: placement, rows: rows)
                            .zIndex("o:" + perch.0.id == draggingID ? 3 : 1)
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

    private func pickerX(for placement: BookshelfShelfPlacement) -> CGFloat {
        let center = (placement.boardMinX + placement.boardMaxX) / 2
        return min(max(center - Self.pickerWidth / 2, -4), contentWidth - Self.pickerWidth + 4)
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
                spine(book, pose: placement.pose, drag: dragGesture(id: placement.id, index: placement.index, rows: rows))
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

    private func perchedOrnamentView(_ ornament: ShelfOrnament, size: CGSize, on placement: BookshelfShelfPlacement,
                                     rows: [[BookshelfShelfPlacement]]) -> some View {
        let id = "o:" + ornament.id
        let isDragging = id == draggingID
        let x = placement.boxX + max((placement.boxSize.width - size.width) / 2, 0)
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
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        selectedURL = nil
                        showsPicker = false
                        folderPickerID = nil
                        draggingID = id
                    }
                    insertionIndex = nil
                    insertionMarker = nil
                    dropTargetID = nil
                }
                if let drag {
                    dragTranslation = drag.translation
                    updateDropTarget(at: drag.location, rows: rows)
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
        guard let draggingID else { return }
        let items = allItems
        let perched = perchedOrnaments(in: items)
        let perchedIDs = Set(perched.values.map { "o:" + $0.0.id })
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
                perches = perches.filter { $0.value != key }
                perches[ornamentID] = key
                ShelfOrnamentPerches.save(perches)
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
        let box = BookshelfFolderBox(folder: folder, books: inside, style: style) {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.easeOut(duration: 0.18)) {
                selectedURL = nil
                showsPicker = false
                folderPickerID = folderPickerID == folder.id ? nil : folder.id
            }
        }
        return Group {
            switch pose {
            case .upright:
                box
            case .flat:
                // 平躺：盒子侧放，长边贴着层板。
                box
                    .frame(width: size.width, height: size.height)
                    .rotationEffect(.degrees(-90))
                    .frame(width: size.height, height: size.width)
            case .leanLeft:
                box.rotationEffect(.degrees(-BookshelfSpine.leanAngle), anchor: .bottomLeading)
            case .leanRight:
                box.rotationEffect(.degrees(BookshelfSpine.leanAngle), anchor: .bottomTrailing)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if hasSelection {
                deselect()
            } else {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    folderStore.presentedFolderID = folder.id
                }
            }
        }
        .gesture(drag)
        .accessibilityLabel("文件夹「\(folder.name)」，\(inside.count) 本书，\(pose.title)")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("轻点打开，长按拖动调整位置")
    }

    private func spine<G: Gesture>(_ book: Book, pose: BookshelfShelfPose, drag: G) -> some View {
        let isSelected = book.bookUrl == selectedURL
        return BookshelfSpine(book: book, pose: pose, isSelected: isSelected, style: style) {
            withAnimation(.easeOut(duration: 0.18)) { showsPicker.toggle() }
        }
            .onTapGesture {
                if isSelected {
                    onOpen(.read(book))
                } else {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                        selectedURL = book.bookUrl
                        showsPicker = false
                        folderPickerID = nil
                    }
                }
            }
            .gesture(drag)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(isSelected ? "再次轻点打开阅读" : "轻点抽出，长按拖动调整位置或拖到另一本书上装进文件夹")
    }

    /// 摆放形态选择条：书和文件夹共用；文件夹多一个「换装」切换装帧样式。
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
            if let folderID {
                Rectangle().fill(Color.white.opacity(0.25)).frame(width: 0.5, height: 12)
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { folderStore.toggleStyle(folderID) }
                } label: {
                    Text("换装")
                        .font(AppFontStyle.system(size: 11).themed)
                        .foregroundStyle(Color.white.opacity(0.85))
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("切换文件夹装帧样式")
            }
        }
        .padding(3)
        .frame(width: folderID == nil ? Self.pickerWidth : Self.pickerWidth + 44)
        .background(Color(white: 0.16).opacity(0.92), in: Capsule())
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }

    private var shelfBoard: some View {
        BookshelfBoard(width: contentWidth, height: boardStyle == "solid" ? boardHeight : 5, solid: boardStyle == "solid")
            .frame(height: boardHeight, alignment: .top)
    }
}

/// 一层书架的层板：立体时为浅色台面 + 正面 + 下方柔和的阴影；平面时只是一条薄板。
struct BookshelfBoard: View {
    @Environment(\.colorScheme) private var colorScheme
    let width: CGFloat
    let height: CGFloat
    var solid: Bool = true

    var body: some View {
        let dark = colorScheme == .dark
        Group {
            if solid {
                VStack(spacing: 0) {
                    // 台面（略带透视的浅色条）
                    Rectangle()
                        .fill(LinearGradient(colors: [dark ? Color(white: 0.30) : Color(white: 0.86),
                                                      dark ? Color(white: 0.24) : Color(white: 0.93)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(height: 3)
                    // 正面
                    Rectangle()
                        .fill(LinearGradient(colors: [dark ? Color(white: 0.22) : Color(white: 0.985),
                                                      dark ? Color(white: 0.16) : Color(white: 0.94)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(height: max(height - 3, 4))
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(Color.black.opacity(dark ? 0.4 : 0.06)).frame(height: 0.5)
                        }
                }
                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                .shadow(color: .black.opacity(dark ? 0.45 : 0.10), radius: 6, y: 5)
            } else {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(dark ? Color(white: 0.26) : Color(white: 0.88))
                    .frame(height: max(min(height, 5), 2))
                    .shadow(color: .black.opacity(dark ? 0.3 : 0.06), radius: 2, y: 1.5)
            }
        }
        .frame(width: width)
        .accessibilityHidden(true)
    }
}

/// 按给定的点画一个多边形（书的顶面、侧面）。
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
private struct BookshelfSpineLayout {
    let fontSize: CGFloat
    let columns: [String]
    let author: String?
    let authorFontSize: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat

    init(title: String, author: String, width: CGFloat, height: CGFloat) {
        let lineFactor: CGFloat = 1.18
        let top = height * 0.05 + 8
        let bottom = height * 0.05 + 6
        topInset = top
        bottomInset = bottom
        var chars = Array(title).filter { !$0.isWhitespace }
        if chars.isEmpty { chars = Array("未命名") }

        // 作者：底部最多占书脊两成高度。
        let authorChars = Array(author).filter { !$0.isWhitespace }
        let authorFont = min(max(width * 0.27, 5), 7.5)
        var authorText: String?
        var authorSpace: CGFloat = 0
        if !authorChars.isEmpty, height >= 100, width >= 14 {
            let capacity = max(Int((height * 0.2) / (authorFont * lineFactor)), 1)
            let shown = authorChars.count > capacity ? Array(authorChars.prefix(max(capacity - 1, 1))) + ["…"] : authorChars
            authorText = shown.map(String.init).joined(separator: "\n")
            authorSpace = CGFloat(shown.count) * authorFont * lineFactor + 6
        }
        self.author = authorText
        authorFontSize = authorFont

        let usable = max(height - top - bottom - authorSpace, 20)
        var columnCount = 1
        var font = min(width * 0.48, 13, usable / (CGFloat(chars.count) * lineFactor))
        if font < max(width * 0.3, 6), width >= 18 {
            // 单列字太小：同样宽度里排两列。
            columnCount = 2
            let perColumn = (chars.count + 1) / 2
            font = min((width - 4) / 2, width * 0.36, usable / (CGFloat(perColumn) * lineFactor))
        }
        var shown = chars
        let minFont: CGFloat = 5
        if font < minFont {
            font = minFont
            let capacity = max(Int(usable / (font * lineFactor)), 1) * columnCount
            if chars.count > capacity { shown = Array(chars.prefix(max(capacity - 1, 1))) + ["…"] }
        }
        let per = (shown.count + columnCount - 1) / columnCount
        var columns: [String] = []
        var index = 0
        while index < shown.count {
            let end = min(index + per, shown.count)
            columns.append(shown[index..<end].map(String.init).joined(separator: "\n"))
            index = end
        }
        fontSize = font
        self.columns = columns
    }
}

/// 从封面里取书脊颜色：缩小封面后按色相分组，取占比最大、颜色最鲜明的一组的平均色。
@MainActor
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

    static let leanAngle: Double = 10
    private static let depth: CGFloat = 8
    /// 竖立的书被抽出时侧面露出的宽度（能看到一部分封面）。
    private static let pulledDepth: CGFloat = 14

    private static let palette: [(CGFloat, CGFloat, CGFloat)] = [
        (0.25, 0.18, 0.12), (0.17, 0.20, 0.27), (0.30, 0.21, 0.13), (0.22, 0.17, 0.14),
        (0.15, 0.17, 0.21), (0.27, 0.19, 0.15)
    ]

    init(book: Book, pose: BookshelfShelfPose, isSelected: Bool, style: BookshelfShelfStyle,
         onRotate: (() -> Void)? = nil) {
        self.book = book
        self.pose = pose
        self.isSelected = isSelected
        self.style = style
        self.onRotate = onRotate
        _tint = State(initialValue: BookshelfSpineTintCache.shared.cached(book.coverUrl))
    }

    static func seed(_ book: Book) -> Int {
        book.name.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF }
    }

    private var layout: BookshelfSpineLayout {
        BookshelfSpineLayout(title: title, author: book.author, width: style.bookWidth, height: style.bookHeight)
    }

    /// 书脊底色：封面主色，太亮时稍微压暗，免得和书架背景混在一起。
    private var baseColor: UIColor {
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

    private var textColor: Color {
        if style.coverSpine { return Color.white }
        return isLight ? Color(white: 0.13) : Color.white.opacity(0.94)
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

    /// 书脊正面：底色 / 封面条、圆脊明暗、上下装饰线、书名和作者。
    private var uprightFront: some View {
        let w = style.bookWidth, h = style.bookHeight
        let layout = self.layout
        return ZStack(alignment: .top) {
            if style.coverSpine {
                BookCoverArtwork(title: book.name, author: book.author, remoteURL: book.coverUrl,
                                 width: max(h * 0.7, w), height: h)
                    .frame(width: w, height: h, alignment: .leading)
                    .clipped()
            } else {
                Color(baseColor)
            }
            roundShading
            if !style.coverSpine {
                spineBands(width: w, height: h)
            }
            if !style.hideTitles {
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 1) {
                        // 竖排从右往左读，第一列放在最右边。
                        ForEach(Array(layout.columns.enumerated().reversed()), id: \.offset) { _, column in
                            Text(column)
                                .font(AppFontStyle.system(size: layout.fontSize, weight: .semibold, design: .serif).themed)
                                .lineSpacing(0)
                                .multilineTextAlignment(.center)
                                .fixedSize()
                        }
                    }
                    .padding(.top, layout.topInset)
                    Spacer(minLength: 0)
                    if let author = layout.author {
                        Text(author)
                            .font(AppFontStyle.system(size: layout.authorFontSize, weight: .regular).themed)
                            .lineSpacing(0)
                            .multilineTextAlignment(.center)
                            .fixedSize()
                            .opacity(0.78)
                            .padding(.bottom, layout.bottomInset)
                    }
                }
                .foregroundStyle(textColor)
                .shadow(color: style.coverSpine ? .black.opacity(0.7) : .clear, radius: 1)
                .frame(width: w, height: h)
            }
        }
        .frame(width: w, height: h)
        .clipShape(RoundedRectangle(cornerRadius: min(2, w * 0.08), style: .continuous))
    }

    private func spineBands(width: CGFloat, height: CGFloat) -> some View {
        let line = textColor.opacity(0.42)
        return VStack(spacing: 0) {
            VStack(spacing: 2) {
                Rectangle().fill(line).frame(height: 0.8)
                Rectangle().fill(line).frame(height: 0.5)
            }
            .padding(.top, height * 0.05)
            Spacer(minLength: 0)
            VStack(spacing: 2) {
                Rectangle().fill(line).frame(height: 0.5)
                Rectangle().fill(line).frame(height: 0.8)
            }
            .padding(.bottom, height * 0.05)
        }
        .frame(width: width, height: height)
    }

    /// 抽出时露出的顶面（书页）与右侧面（封面靠书脊的一条）。
    /// 斜二测投影：横向露出 dx、纵向只抬高 dy = dx/2，顶面很薄，书底与层板齐平，
    /// 看起来是书被抽出站在层板上，而不是整本书被抬到半空。
    private var uprightDepthFaces: some View {
        let w = style.bookWidth, h = style.bookHeight
        let dx = Self.pulledDepth, dy = (Self.pulledDepth * 0.5).rounded()
        return ZStack(alignment: .topLeading) {
            BookshelfFace(points: [CGPoint(x: 0, y: dy), CGPoint(x: dx, y: 0), CGPoint(x: w + dx, y: 0), CGPoint(x: w, y: dy)])
                .fill(pageColor)
            // 书页的几道细线
            ForEach(1..<4) { i in
                let t = CGFloat(i) / 4
                BookshelfFace(points: [CGPoint(x: dx * t, y: dy * (1 - t)), CGPoint(x: w + dx * t, y: dy * (1 - t))])
                    .stroke(Color.black.opacity(0.07), lineWidth: 0.5)
            }
            BookCoverArtwork(title: book.name, author: book.author, remoteURL: book.coverUrl,
                             width: max(h * 0.7, dx), height: h)
                .frame(width: dx, height: h, alignment: .leading)
                .clipped()
                .overlay(LinearGradient(colors: [Color.black.opacity(0.3), Color.black.opacity(0.06)],
                                        startPoint: .leading, endPoint: .trailing))
                .transformEffect(CGAffineTransform(a: 1, b: -dy / dx, c: 0, d: 1, tx: w, ty: dy))
        }
        .frame(width: w + dx, height: h + dy, alignment: .topLeading)
    }

    /// 平躺：书脊朝外横放，书名横排。
    private var flatFront: some View {
        let w = style.bookHeight, h = style.bookWidth
        return ZStack {
            if style.coverSpine {
                BookCoverArtwork(title: book.name, author: book.author, remoteURL: book.coverUrl,
                                 width: max(w * 0.7, h), height: w)
                    .frame(width: h, height: w, alignment: .leading)
                    .clipped()
                    .rotationEffect(.degrees(-90))
                    .frame(width: w, height: h)
            } else {
                Color(baseColor)
            }
            LinearGradient(stops: [
                .init(color: .black.opacity(0.24), location: 0),
                .init(color: .white.opacity(0.14), location: 0.22),
                .init(color: .clear, location: 0.5),
                .init(color: .black.opacity(0.26), location: 1)
            ], startPoint: .top, endPoint: .bottom)
            if !style.hideTitles {
                Text(title)
                    .font(.system(size: min(11, h * 0.45), weight: .semibold, design: .serif))
                    .foregroundStyle(textColor)
                    .shadow(color: style.coverSpine ? .black.opacity(0.7) : .clear, radius: 1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, 8)
            }
        }
        .frame(width: w, height: h)
        .clipShape(RoundedRectangle(cornerRadius: min(2, h * 0.08), style: .continuous))
    }

    /// 平躺抽出时露出的封面（顶面）与书页（右端）。
    private var flatDepthFaces: some View {
        let w = style.bookHeight, h = style.bookWidth, d = Self.depth
        return ZStack(alignment: .topLeading) {
            BookshelfFace(points: [CGPoint(x: 0, y: d), CGPoint(x: d, y: 0), CGPoint(x: w + d, y: 0), CGPoint(x: w, y: d)])
                .fill(Color(baseColor).opacity(0.8))
            BookshelfFace(points: [CGPoint(x: w, y: d), CGPoint(x: w + d, y: 0), CGPoint(x: w + d, y: h), CGPoint(x: w, y: h + d)])
                .fill(pageColor)
        }
        .frame(width: w + d, height: h + d, alignment: .topLeading)
    }

    /// 抽出时的旋转按钮：固定画在书脊正面里（跟着书一起倾斜），
    /// 竖立/倾斜时在书脊顶部往下一点的正中，平躺时在书脊左端的正中，位置不再随姿势乱跑。
    @ViewBuilder private var rotateButton: some View {
        if isSelected, let onRotate {
            Button(action: onRotate) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(AppFontStyle.system(size: 10, weight: .semibold).themed)
                    .foregroundStyle(Color.white)
                    .frame(width: 22, height: 22)
                    .background(Color.black.opacity(0.55), in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.5), lineWidth: 0.5))
                    .opacity(style.hideRotateButtons ? 0.011 : 1)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .transition(.opacity.combined(with: .scale(scale: 0.6)))
            .accessibilityLabel("修改摆放形态")
        }
    }

    private var upright: some View {
        uprightFront
            .overlay(alignment: .bottomLeading) {
                if isSelected {
                    uprightDepthFaces.allowsHitTesting(false)
                }
            }
            .overlay(alignment: .top) {
                rotateButton.offset(y: min(10, style.bookHeight * 0.08) - 6)
            }
            // 抽出：书底仍然压在层板上，只是整本书朝外挪出一点（略放大、露出书顶和封面侧面），
            // 不再绕底边前倾——前倾加透视会让书看起来离开层板、悬在半空。
            .scaleEffect(isSelected ? 1.035 : 1, anchor: .bottom)
            .contentShape(Rectangle())
    }

    private var flat: some View {
        flatFront
            .overlay(alignment: .bottomLeading) {
                if isSelected {
                    flatDepthFaces.allowsHitTesting(false)
                }
            }
            .overlay(alignment: .leading) {
                rotateButton.offset(x: -4)
            }
            .scaleEffect(isSelected ? 1.03 : 1, anchor: .bottom)
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
        .overlay(alignment: .topTrailing) {
            if book.lastCheckCount > 0, pose == .upright {
                Circle().fill(ReadingTheme.coral).frame(width: 6, height: 6).offset(x: 2, y: -2)
                    .allowsHitTesting(false)
            }
        }
        .task(id: book.coverUrl ?? "") {
            guard !style.coverSpine || tint == nil else { return }
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
    @AppStorage(BookshelfShelfSettings.hideShelfBaseKey) private var hideShelfBase = false
    @AppStorage(BookshelfShelfSettings.boardStyleKey) private var boardStyle = "solid"
    @AppStorage(BookshelfShelfSettings.bookWidthKey) private var bookWidth = BookshelfShelfSettings.defaultWidth
    @AppStorage(BookshelfShelfSettings.bookHeightKey) private var bookHeight = BookshelfShelfSettings.defaultHeight
    @AppStorage(BookshelfShelfSettings.coverSpineKey) private var coverSpine = false
    @AppStorage(BookshelfShelfSettings.hideRotateKey) private var hideRotateButtons = false
    @AppStorage(BookshelfShelfSettings.coverStyleKey) private var coverStyle = "flat"

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
                toggleRow(title: "书架右侧切换条",
                          detail: "书架右边竖型控制条：在各个书架之间快速切换；关闭后不再显示",
                          isOn: $sideSwitcher)
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
                    toggleRow(title: "隐藏书名/作者", detail: "网格与仿真视图隐藏封面下方的书名作者（纯净封面与书脊）", isOn: $hideTitles)
                    toggleRow(title: "隐藏书架底座", detail: "网格视图不画搁板（含立体板）；板位留白一并收掉", isOn: $hideShelfBase)
                    coverStyleRow
                    boardStyleRow
                } else if isList {
                    coverStyleRow
                    boardStyleRow
                } else {
                    toggleRow(title: "隐藏书名/作者", detail: "网格与仿真视图隐藏书名作者与遮罩蒙版（纯净书脊）", isOn: $hideTitles)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("仿真书大小").font(AppFontStyle.headline.themed)
                        Text("统一调整书高与书宽，书脊与文件夹文字一并等比缩放")
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
                    toggleRow(title: "封面书脊", detail: "书脊直接显示封面截取图案（关闭后按封面主色装帧）", isOn: $coverSpine)
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
        .readingSheetCanvas()
        .readingLivePreviewSheet()
        .readingPresentationDragIndicator()
    }

    private var coverStyleRow: some View {
        row(title: "封面样式", detail: "仅书架页封面：实体在封面左侧呈现书脊凹陷质感") {
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
                .background(selected ? Color(UIColor.systemBackground) : Color.clear, in: Capsule())
                .shadow(color: .black.opacity(selected ? 0.1 : 0), radius: 2, y: 1)
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
                .background(selected ? Color(UIColor.systemBackground) : Color.clear, in: Capsule())
                .shadow(color: .black.opacity(selected ? 0.1 : 0), radius: 2, y: 1)
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

    @Published private(set) var ornaments: [ShelfOrnament]
    private var images: [String: UIImage] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([ShelfOrnament].self, from: data) {
            ornaments = saved
        } else {
            ornaments = [ShelfOrnament(id: Self.builtinFrogID, fileName: nil, size: 64, onShelf: true)]
        }
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
            image = UIImage(named: "ShelfFrog")
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

    func delete(_ id: String) {
        guard let index = ornaments.firstIndex(where: { $0.id == id }) else { return }
        if let fileName = ornaments[index].fileName {
            try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(fileName))
        }
        images[id] = nil
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
                    .background(ReadingTheme.groupedCanvas, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                    .background(ReadingTheme.groupedCanvas, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
