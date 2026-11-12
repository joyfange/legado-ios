import SwiftUI
import UniformTypeIdentifiers
import PhotosUI

struct RootTabView: View {
    @EnvironmentObject private var sourceLibrary: SourceLibraryModel
    private enum Tab: Hashable { case bookshelf, explore, statistics, my }
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
        _selection = State(initialValue: initial)
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
                .tabItem { Label("书架", systemImage: "book.fill") }
                .tag(Tab.bookshelf)

            ReadingNavigationStack { ExploreView() }
                .tabItem { Label("发现", systemImage: "safari") }
                .tag(Tab.explore)

            ReadingNavigationStack { ReadingStatisticsView() }
                .tabItem { Label("统计", systemImage: "chart.bar") }
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
                .tabItem { Label("我的", systemImage: "person.crop.circle") }
                .tag(Tab.my)
        }
        .readingTabBarBackground()
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
    @EnvironmentObject private var library: BookLibraryModel
    @EnvironmentObject private var sources: SourceLibraryModel
    @State private var showsLocalImporter = false
    @State private var pendingLocalFiles: [LocalBookImportFile] = []
    @State private var selectedGroupID = BookGroup.idAll
    @State private var showsGroupManager = false
    @State private var showsOrnamentManager = false
    @AppStorage("bookshelfLayout") private var bookshelfLayout = "grid3"
    @State private var shelfDestination: BookshelfShelfDestination?

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
                                    .font(.subheadline.weight(.medium))
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
                            BookshelfShelfView(books: displayedBooks) { shelfDestination = $0 }
                        } else if bookshelfLayout.hasPrefix("grid") {
                            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 24) {
                                ForEach(displayedBooks) { book in
                                    BookshelfBookLink(book: book, compact: false, grid: true)
                                }
                            }
                        } else {
                            ForEach(displayedBooks) { book in
                                BookshelfBookLink(book: book, compact: bookshelfLayout == "compact", grid: false)
                                if book.id != displayedBooks.last?.id {
                                    Rectangle().fill(ReadingTheme.separator).frame(height: 0.5)
                                        .padding(.leading, bookshelfLayout == "compact" ? 54 : 66)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
        }
        .background(ReadingTheme.canvas)
        .navigationBarHidden(true)
        .onReceive(library.$books) { ReadRecordCoverStore.remember($0) }
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
        .sheet(isPresented: $showsGroupManager) {
            BookGroupManagerView()
                .environmentObject(library)
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
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("\(displayedBooks.count)本")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 0) {
                Button { bookshelfLayout = "grid3" } label: {
                    Image(systemName: "square.grid.2x2.fill")
                        .foregroundStyle(bookshelfLayout.hasPrefix("grid") ? ReadingTheme.accent : .secondary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("网格布局")
                .accessibilityAddTraits(bookshelfLayout.hasPrefix("grid") ? .isSelected : [])
                Button { bookshelfLayout = "list" } label: {
                    Image(systemName: "list.bullet")
                        .foregroundStyle(isListLayout ? ReadingTheme.accent : .secondary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("列表布局")
                .accessibilityAddTraits(isListLayout ? .isSelected : [])
                Button { bookshelfLayout = "shelf" } label: {
                    Image(systemName: "books.vertical.fill")
                        .foregroundStyle(bookshelfLayout == "shelf" ? ReadingTheme.accent : .secondary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("仿真书架")
                .accessibilityAddTraits(bookshelfLayout == "shelf" ? .isSelected : [])
            }
            .font(.system(size: 18, weight: .medium))
            .buttonStyle(.plain)
        }
        .padding(.bottom, 20)
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
                Button("书架分组", systemImage: "rectangle.3.group") { showsGroupManager = true }
                Menu("书架布局", systemImage: "square.grid.2x2") {
                    layoutButton("列表", value: "list")
                    layoutButton("紧凑列表", value: "compact")
                    ForEach(2...6, id: \.self) { count in
                        layoutButton("\(count) 列宫格", value: "grid\(count)")
                    }
                    layoutButton("仿真书架", value: "shelf")
                }
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
                        .font(.subheadline.weight(selectedGroupID == group.id ? .semibold : .regular))
                        .foregroundStyle(selectedGroupID == group.id ? Color.primary : .secondary)
                        .frame(minHeight: 44)
                        .overlay(alignment: .bottom) {
                            if selectedGroupID == group.id {
                                Rectangle().fill(ReadingTheme.accent).frame(height: 2)
                            }
                        }
                        .accessibilityAddTraits(selectedGroupID == group.id ? .isSelected : [])
                }
            }
            .padding(.horizontal, 24)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(ReadingTheme.separator).frame(height: 0.5)
        }
    }

    private var isListLayout: Bool { bookshelfLayout == "list" || bookshelfLayout == "compact" }

    private var gridColumns: [GridItem] {
        let count = Int(bookshelfLayout.dropFirst(4)) ?? 3
        let maximum = dynamicTypeSize.isAccessibilitySize ? 2 : 6
        return Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: max(2, min(count, maximum)))
    }

    @ViewBuilder
    private func layoutButton(_ title: String, value: String) -> some View {
        Button {
            bookshelfLayout = value
        } label: {
            if bookshelfLayout == value { Label(title, systemImage: "checkmark") }
            else { Text(title) }
        }
    }
}

private struct BookshelfBookLink: View {
    @EnvironmentObject private var library: BookLibraryModel
    @EnvironmentObject private var sources: SourceLibraryModel
    let book: Book
    let compact: Bool
    let grid: Bool
    @State private var showsGroupSelector = false

    private var source: BookSource? { sources.sources.first { $0.bookSourceUrl == book.origin } }

    var body: some View {
        NavigationLink {
            BookshelfBookDestination(book: book, source: source)
        } label: {
            if grid { BookshelfGridItem(book: book) }
            else { BookshelfRow(book: book, compact: compact) }
        }
        .buttonStyle(.plain)
        .contextMenu {
            NavigationLink {
                if let source { BookDetailView(book: book, source: source) }
                else { LocalBookDetailView(book: book) }
            } label: {
                Label("书籍信息", systemImage: "info.circle")
            }
            Button("移至分组", systemImage: "rectangle.3.group") { showsGroupSelector = true }
            Button("移出书架", systemImage: "trash", role: .destructive) {
                Task { await library.remove(bookURL: book.bookUrl) }
            }
        }
        .sheet(isPresented: $showsGroupSelector) {
            BookGroupSelectView(book: book).environmentObject(library)
        }
    }
}

private struct BookshelfGridItem: View {
    let book: Book

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geometry in
                BookCoverArtwork(
                    title: book.name,
                    author: book.author,
                    remoteURL: book.coverUrl,
                    width: geometry.size.width,
                    height: geometry.size.height
                )
            }
            .aspectRatio(0.70, contentMode: .fit)
            .frame(maxWidth: 180)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topTrailing) {
                if book.lastCheckCount > 0 {
                    Circle()
                        .fill(ReadingTheme.coral)
                        .frame(width: 7, height: 7)
                        .overlay { Circle().stroke(ReadingTheme.canvas, lineWidth: 2) }
                        .offset(x: 3, y: -3)
                        .accessibilityLabel("更新 \(book.lastCheckCount) 章")
                }
            }
            Text(book.name)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
                .padding(.top, 10)
            Text(book.author.isEmpty ? "未知作者" : book.author)
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                .padding(.top, 3)
            ReadingProgressLine(value: BookReadingPresentation.progress(book))
                .padding(.top, 12)
            Text(BookReadingPresentation.progressLabel(book))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                .padding(.top, 7)
        }
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
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ReadingTheme.ink)
                    .lineLimit(1)
                Text(BookReadingPresentation.position(book))
                    .font(.caption).foregroundStyle(.secondary)
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
            .font(.caption.weight(.semibold))
            .foregroundStyle(ReadingTheme.onAccent)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(ReadingTheme.accentFill, in: Capsule())
        }
        .padding(12)
        .background(ReadingTheme.groupedCanvas, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct BookGroupManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: BookLibraryModel
    @State private var newName = ""
    @State private var showsCreate = false
    @State private var editingGroup: BookGroup?
    @State private var editingName = ""

    private var customGroups: [BookGroup] {
        library.groups.filter { $0.groupId > 0 }.sorted { $0.order < $1.order }
    }

    var body: some View {
        ReadingNavigationStack {
            List {
                Section {
                    HStack {
                        Text("全部")
                        Spacer()
                        Text("系统分组").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("自定义分组") {
                    ForEach(customGroups) { group in
                        HStack {
                            Toggle(isOn: Binding(
                                get: { group.show },
                                set: { visible in Task { await library.setGroupVisible(group, visible: visible) } }
                            )) {
                                Text(group.groupName)
                            }
                            Button {
                                editingGroup = group
                                editingName = group.groupName
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)
                        }
                        .swipeActions {
                            Button("删除", role: .destructive) {
                                Task { await library.deleteGroup(group) }
                            }
                        }
                    }
                    .onMove { offsets, destination in
                        Task { await library.moveGroups(from: offsets, to: destination) }
                    }
                }
            }
            .overlay {
                if customGroups.isEmpty {
                    ReadingUnavailableView("没有自定义分组", systemImage: "rectangle.3.group", description: Text("点右上角加号新建分组。"))
                }
            }
            .navigationTitle("书架分组")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    EditButton()
                    Button("新建", systemImage: "plus") { newName = ""; showsCreate = true }
                }
            }
            .alert("新建分组", isPresented: $showsCreate) {
                TextField("分组名称", text: $newName)
                Button("取消", role: .cancel) {}
                Button("确定") { Task { await library.createGroup(name: newName) } }
            }
            .alert("编辑分组", isPresented: Binding(
                get: { editingGroup != nil },
                set: { if !$0 { editingGroup = nil } }
            )) {
                TextField("分组名称", text: $editingName)
                Button("取消", role: .cancel) { editingGroup = nil }
                Button("确定") {
                    guard let group = editingGroup else { return }
                    Task { await library.renameGroup(group, name: editingName) }
                    editingGroup = nil
                }
            }
        }
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
            }
            .overlay {
                if customGroups.isEmpty {
                    ReadingUnavailableView("没有自定义分组", systemImage: "rectangle.3.group")
                }
            }
            .navigationTitle("移至分组")
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
                            Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
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
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(ReadingTheme.accent)
                .accessibilityHidden(true)
            VStack(spacing: 10) {
                Text("书架还是空的").font(.title3.weight(.semibold))
                Text("导入本地书，或添加书源后搜索书籍。")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 12) {
                Button("导入本地书", action: onImport)
                    .readingProminentButtonStyle()
                    .controlSize(.large)
                NavigationLink("添加书源") { SourceManagementView() }
                    .font(.subheadline)
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
                        .font(.system(size: 17, weight: .semibold))
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
            BookCoverArtwork(
                title: book.name,
                author: book.author,
                remoteURL: book.coverUrl,
                width: compact ? 40 : coverWidth,
                height: compact ? 56 : coverWidth * 1.42
            )
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(book.name)
                        .font(.body.weight(.medium))
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
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !compact {
                    Text(readingPosition)
                        .font(.caption)
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

struct SearchView: View {
    @EnvironmentObject private var library: SourceLibraryModel
    let fixedSource: BookSource?
    private let initialKeyword: String
    @State private var keyword: String
    @StateObject private var model = SearchViewModel()
    @State private var showsScope = false
    @State private var selectedGroups = Set<String>()
    @State private var selectedSourceID: String?
    @State private var didStartInitialSearch = false
    @State private var searchIsPresented = false
    @AppStorage("precisionSearch") private var precisionSearch = false

    init(fixedSource: BookSource? = nil, initialKeyword: String = "") {
        self.fixedSource = fixedSource
        self.initialKeyword = initialKeyword
        _keyword = State(initialValue: initialKeyword)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
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
        .background(ReadingTheme.canvas)
        .navigationTitle("搜索")
        .readingSearchable(text: $keyword, isPresented: $searchIsPresented, prompt: "书名或作者")
        .readingScrollDismissesKeyboard()
        .onSubmit(of: [.text, .search]) { startSearch() }
        .onDisappear {
            if model.state == .searching || model.isLoadingMore { model.cancel() }
        }
        .onChange(of: keyword) { value in
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model.cancel(reset: true)
            }
        }
        .onChange(of: library.sources.count) { _ in
            guard !didStartInitialSearch,
                  !initialKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !library.sources.isEmpty else { return }
            didStartInitialSearch = true
            startSearch()
        }
        .task {
            await model.loadSearchKeywords()
            if initialKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                searchIsPresented = true
            } else if !library.sources.isEmpty, !didStartInitialSearch {
                didStartInitialSearch = true
                startSearch()
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("精准搜索", isOn: $precisionSearch)
                    Button("分组或书源", systemImage: "scope") { showsScope = true }
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
        .sheet(isPresented: $showsScope) {
            SearchScopeSheet(
                sources: library.sources.filter(\.enabled),
                groups: library.groups,
                selectedGroups: $selectedGroups,
                selectedSourceID: $selectedSourceID
            )
        }
    }

    @ViewBuilder
    private var idleContent: some View {
        discoveryPrompt
        if !model.searchKeywords.isEmpty {
            searchHistoryView
        }
    }

    private var discoveryPrompt: some View {
        Button { searchIsPresented = true } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.body)
                    .foregroundStyle(ReadingTheme.accent)
                VStack(alignment: .leading, spacing: 6) {
                    Text("搜索书名或作者")
                        .font(.headline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text("\(searchableSourceCount) 个书源 · \(scopeDisplay)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 20)
        }
        .buttonStyle(.plain)
    }

    private var initialLoadingView: some View {
        VStack(spacing: 12) {
            ReadingCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.regular)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("正在搜索“\(model.submittedKeyword)”").font(.headline)
                            Text(searchProgressText).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("停止", role: .destructive) { model.cancel() }
                            .font(.subheadline.weight(.medium))
                    }
                    ProgressView(value: searchProgress)
                        .tint(ReadingTheme.accent)
                    Text("结果会在书源返回后立即显示，无需等待全部完成。")
                        .font(.caption).foregroundStyle(.secondary)
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
                        Text("“\(model.submittedKeyword)”").font(.headline).lineLimit(1)
                        Text(model.isShowingCachedResults
                             ? (model.state == .searching ? "已显示缓存结果，正在更新书源" : "已显示缓存结果")
                             : "找到 \(model.books.count) 本，已自动合并重复来源")
                            .font(.caption).foregroundStyle(.secondary)
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
                    Text("正在查找更多结果…").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else if !model.hasMore, model.state == .finished {
                Text("已经到底了")
                    .font(.caption).foregroundStyle(.tertiary)
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
            Button("修改关键词", systemImage: "text.cursor") { searchIsPresented = true }
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
                            Text(diagnostic.message).font(.subheadline)
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
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("搜索历史").font(.headline)
                    Spacer()
                    Button("清空") { Task { await model.clearSearchKeywords() } }.font(.subheadline)
                }
                .padding(.bottom, 8)
                ForEach(model.searchKeywords) { item in
                    Divider().padding(.leading, 28)
                    HStack(spacing: 10) {
                        Button { keyword = item.word; startSearch() } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                                Text(item.word).foregroundStyle(.primary).lineLimit(1)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button {
                            Task { await model.deleteSearchKeyword(item.word) }
                        } label: {
                            Image(systemName: "xmark").font(.caption.bold()).foregroundStyle(.tertiary)
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("删除 \(item.word)")
                    }
                    .padding(.vertical, 7)
                }
            }
        }
    }

    private var scopedSources: [BookSource] {
        if var fixedSource { fixedSource.enabled = true; return [fixedSource] }
        let enabled = library.sources.filter(\.enabled)
        if let selectedSourceID { return enabled.filter { $0.id == selectedSourceID } }
        guard !selectedGroups.isEmpty else { return enabled }
        return enabled.filter { source in selectedGroups.contains(where: source.hasGroup) }
    }

    private var scopeDisplay: String {
        if let fixedSource { return fixedSource.bookSourceName }
        if let selectedSourceID, let source = library.sources.first(where: { $0.id == selectedSourceID }) { return source.bookSourceName }
        return selectedGroups.isEmpty ? "全部书源" : selectedGroups.sorted().joined(separator: ",")
    }

    private func startSearch() {
        let value = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        searchIsPresented = false
        model.search(keyword: value, sources: scopedSources, precision: precisionSearch)
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
                    .font(.system(size: 32))
                    .foregroundStyle(ReadingTheme.accent)
                    .frame(width: 64, height: 64)
                    .background(ReadingTheme.accentSoft.opacity(0.5), in: Circle())
                VStack(spacing: 5) {
                    Text(title).font(.headline).multilineTextAlignment(.center)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                HStack(spacing: 10) { actions }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
    }
}

private struct SearchBookRow: View {
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
                Text(book.name).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                Text(book.author.isEmpty ? "未知作者" : book.author)
                    .font(.caption).foregroundStyle(.secondary)
                if let latest = book.latestChapterTitle, !latest.isEmpty {
                    Text(latest)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(book.origins.count > 1 ? "\(book.origins.count) 个来源" : book.originName)
                        .lineLimit(1)
                    if let wordCount = book.wordCount, !wordCount.isEmpty {
                        Text("·")
                        Text(wordCount).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(ReadingTheme.separator).frame(height: 0.5)
                .padding(.leading, 66)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct SettingsView: View {
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
            .background(ProfileTheme.canvas)
            .ignoresSafeArea(.container, edges: .top)
            .accessibilityIdentifier("profile.scroll")
        }
        .background(ProfileTheme.canvas)
        .navigationBarHidden(true)
    }

    private func profileHeader(topInset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("我的")
                .font(.largeTitle.bold())
                .foregroundStyle(ProfileTheme.ink)
                .accessibilityAddTraits(.isHeader)
            Text("按照你的方式阅读")
                .font(.subheadline)
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
                        .font(.headline)
                        .foregroundStyle(ProfileTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("快速搜书，自由阅读")
                        .font(.footnote)
                        .foregroundStyle(ProfileTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ProfileTheme.ink.opacity(0.75))
                    .frame(width: 26, height: 26)
                    .background(ProfileTheme.detail.opacity(0.10), in: Circle())
                    .accessibilityHidden(true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(
                        colors: [ProfileTheme.surface, ProfileTheme.appCardTint],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(ProfileTheme.surface.opacity(0.9), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(0.035), radius: 18, x: 0, y: 8)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("查看关于与版本信息")
        .accessibilityIdentifier("profile.about")
    }

    private var readingSection: some View {
        settingSection("阅读") {
            settingLink("阅读设置", icon: "textformat.size") { ReadingPreferencesView() }
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
        settingSection("项目与支持") {
            Link(destination: AppIdentity.authorURL) {
                settingRow("开发者 Aminark", icon: "person.crop.circle", isExternal: true)
            }
            .buttonStyle(.plain)
            Link(destination: AppIdentity.projectURL) {
                settingRow("GitHub 项目", icon: "chevron.left.forwardslash.chevron.right", isExternal: true)
            }
            .buttonStyle(.plain)
            settingLink("其他设置", icon: "gearshape") { OtherSettingsView() }
            settingLink("关于", icon: "info.circle", showsSeparator: false) { AboutView() }
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
                .font(.body)
                .foregroundStyle(ProfileTheme.secondary)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0, content: content)
                .background(ProfileTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.025), radius: 20, x: 0, y: 8)
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
                .font(.body)
                .foregroundStyle(ProfileTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let value {
                Text(value)
                    .font(.footnote)
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
                .font(.caption.weight(.medium))
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
    static let canvas = adaptive(0xF8F8F7, dark: 0x141416)
    static let surface = adaptive(0xFFFFFF, dark: 0x232326)
    static let appCardTint = adaptive(0xFBF3EC, dark: 0x302923)
    static let ink = adaptive(0x171817, dark: 0xF3F0EC)
    static let secondary = adaptive(0x898A8C, dark: 0xA5A2A0)
    static let detail = adaptive(0xBA916B, dark: 0xD1AB84)
    static let separator = adaptive(0xEAEAEA, dark: 0x373638)

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
                    Text("A").font(.system(size: 24, weight: .light)).foregroundStyle(ProfileTheme.ink)
                    Text("A").font(.system(size: 13, weight: .medium)).foregroundStyle(ProfileTheme.detail)
                }
            } else if ["circle.lefthalf.filled", "waveform", "bookmark", "clock", "globe"].contains(systemName) {
                Canvas { context, size in
                    context.scaleBy(x: size.width / 24, y: size.height / 24)
                    draw(in: &context)
                }
                .frame(width: 22, height: 22)
            } else {
                Image(systemName: systemName)
                    .font(.system(size: 20, weight: .regular))
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
                    }
                }
            }
        }
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
                .font(.headline).foregroundStyle(ReadingTheme.coral)
            if !bookmark.bookText.isEmpty {
                Text(bookmark.bookText).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
            }
            if !bookmark.content.isEmpty {
                Label(bookmark.content, systemImage: "note.text").font(.caption).lineLimit(2)
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
                Section("原文") { TextEditor(text: $bookText).frame(minHeight: 150) }
                Section("摘要") { TextEditor(text: $content).frame(minHeight: 120) }
                Section {
                    Button("删除书签", role: .destructive) {
                        Task { await activity.removeBookmark(bookmark); dismiss() }
                    }
                }
            }
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
                    }
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
                                    Text(source.bookSourceUrl).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if workingSourceID == source.id { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
            }
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
                ReadingLabeledContent("字号", value: String(format: "%.0f", fontSize))
                Slider(value: $fontSize, in: 5...50, step: 1)
                ReadingLabeledContent("字间距", value: String(format: "%.2f", letterSpacing))
                Slider(value: $letterSpacing, in: -0.5...0.5, step: 0.01)
                ReadingLabeledContent("行间距", value: String(format: "%.0f", lineSpacing))
                Slider(value: $lineSpacing, in: 0...50, step: 1)
                ReadingLabeledContent("段距", value: String(format: "%.1f", paragraphSpacing))
                Slider(value: $paragraphSpacing, in: 0...50, step: 1)
                Picker("字重", selection: $fontWeight) {
                    Text("正常").tag(0)
                    Text("粗体").tag(1)
                    Text("细体").tag(2)
                }
                TextField("段落缩进字符", text: $paragraphIndent)
                Picker("下划线", selection: $underlineMode) {
                    Text("关闭").tag(0)
                    Text("实线").tag(1)
                    Text("虚线").tag(2)
                }
            }
            Section("正文边距") {
                paddingSlider("左边距", value: $paddingLeft)
                paddingSlider("右边距", value: $paddingRight)
                paddingSlider("上边距", value: $paddingTop)
                paddingSlider("下边距", value: $paddingBottom)
            }
            Section("章节标题") {
                Picker("标题模式", selection: $titleMode) {
                    Text("左对齐").tag(0)
                    Text("居中").tag(1)
                    Text("隐藏").tag(2)
                }
                ReadingLabeledContent("字号增量", value: String(format: "%+.0f", titleSize))
                Slider(value: $titleSize, in: -10...30, step: 1)
                ReadingLabeledContent("上间距", value: String(Int(titleTopSpacing)))
                Slider(value: $titleTopSpacing, in: 0...100, step: 1)
                ReadingLabeledContent("下间距", value: String(Int(titleBottomSpacing)))
                Slider(value: $titleBottomSpacing, in: 0...100, step: 1)
            }
            Section("翻页") {
                Picker("翻页模式", selection: $pageAnimation) {
                    Text("覆盖").tag(0)
                    Text("滑动").tag(1)
                    Text("仿真").tag(2)
                    Text("滚动").tag(3)
                    Text("无动画").tag(4)
                }
            }
            Section("屏幕") {
                Toggle("阅读时不自动锁屏", isOn: $keepScreenOn)
                Toggle("阅读时隐藏小横条", isOn: $hideHomeIndicator)
            }
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
            }
            Section("预览") {
                Text("雨落在旧城的瓦檐上，故事从一束灯光开始。")
                    .tracking(letterSpacing * fontSize)
                    .font(.system(size: fontSize, design: .serif))
                    .lineSpacing(lineSpacing)
                    .foregroundStyle(Color(uiColor: ReaderStylePreset.resolve(theme).foreground))
                    .padding(.vertical, 12)
                    .listRowBackground(Color(uiColor: ReaderStylePreset.resolve(theme).background))
            }
        }
        .navigationTitle("阅读设置")
    }

    private func paddingSlider(_ title: String, value: Binding<Double>) -> some View {
        VStack {
            ReadingLabeledContent(title, value: String(Int(value.wrappedValue)))
            Slider(value: value, in: 0...100, step: 1)
        }
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

/// 仿真书架：书脊站在层板上，左边一只青蛙摆件。长按一本书把它抽出来（露出书页顶面），
/// 上方弹出「竖立 / 平躺 / 左倾 / 右倾」；轻点打开书。
private struct BookshelfShelfView: View {
    @Environment(\.colorScheme) private var colorScheme
    let books: [Book]
    let onOpen: (BookshelfShelfDestination) -> Void

    @ObservedObject private var ornamentStore = ShelfOrnamentStore.shared
    @State private var poses: [String: Int] = BookshelfShelfPose.load()
    @State private var selectedURL: String?
    @State private var showsPicker = false
    @State private var editingOrnament: ShelfOrnament?

    private let spacing: CGFloat = 4
    private let rowSpacing: CGFloat = 30
    private static let pickerWidth: CGFloat = 176

    /// 书架内容宽度：书架页左右各留 24pt 边距，宽度在布局前就能确定，避免首帧高度跳动。
    private var contentWidth: CGFloat { max(UIScreen.main.bounds.width - 48, 120) }
    private var rowHeight: CGFloat { BookshelfSpine.maxHeight + 10 }

    /// 第一层左侧摆放的摆件及其尺寸（放不下的不显示）。
    private var placedOrnaments: [PlacedShelfOrnament] {
        var result: [PlacedShelfOrnament] = []
        var used: CGFloat = 0
        for ornament in ornamentStore.placed {
            let size = ornamentStore.displaySize(for: ornament, maxWidth: contentWidth * 0.5)
            guard used + size.width <= contentWidth else { break }
            result.append(PlacedShelfOrnament(ornament: ornament, size: size))
            used += size.width + spacing
        }
        return result
    }

    private var ornamentsWidth: CGFloat {
        placedOrnaments.reduce(0) { $0 + $1.size.width + spacing }
    }

    private func pose(_ book: Book) -> BookshelfShelfPose {
        BookshelfShelfPose(rawValue: poses[book.bookUrl] ?? 0) ?? .upright
    }

    private func footprint(_ book: Book) -> CGFloat {
        BookshelfSpine.footprint(for: book, pose: pose(book)).width
    }

    private func rows(width: CGFloat) -> [[Book]] {
        var result: [[Book]] = []
        var current: [Book] = []
        // 第一层左边放摆件。
        var available = width - ornamentsWidth
        var used: CGFloat = 0
        for book in books {
            let item = footprint(book)
            let needed = current.isEmpty ? item : used + spacing + item
            if needed > available, !current.isEmpty {
                result.append(current)
                current = [book]
                used = item
                available = width
            } else {
                current.append(book)
                used = needed
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    var body: some View {
        let shelfRows = rows(width: contentWidth)
        VStack(alignment: .leading, spacing: rowSpacing) {
            ForEach(shelfRows.indices, id: \.self) { index in
                shelfRow(shelfRows[index], first: index == 0)
                    .zIndex(shelfRows[index].contains { $0.bookUrl == selectedURL } ? 1 : 0)
            }
        }
        .padding(.top, 36)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: books.map(\.bookUrl)) { urls in
            if let selectedURL, !urls.contains(selectedURL) { deselect() }
        }
        .sheet(item: $editingOrnament) { ornament in
            ShelfOrnamentSettingsSheet(ornamentID: ornament.id)
        }
    }

    private func deselect() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            selectedURL = nil
            showsPicker = false
        }
    }

    private func shelfRow(_ row: [Book], first: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: spacing) {
                if first {
                    ForEach(placedOrnaments) { item in
                        ornamentView(item.ornament, size: item.size)
                    }
                }
                ForEach(row) { book in
                    spine(book)
                }
                Spacer(minLength: 0)
            }
            .frame(height: rowHeight, alignment: .bottom)
            .background(
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { if selectedURL != nil { deselect() } }
            )
            .overlay(alignment: .topLeading) {
                if showsPicker, let book = row.first(where: { $0.bookUrl == selectedURL }) {
                    posePicker(for: book)
                        .offset(x: pickerX(for: book, in: row, first: first),
                                y: rowHeight - BookshelfSpine.footprint(for: book, pose: pose(book)).height - 44)
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottom)))
                }
            }
            shelfBoard
        }
    }

    private func pickerX(for book: Book, in row: [Book], first: Bool) -> CGFloat {
        var x: CGFloat = first ? ornamentsWidth : 0
        for item in row {
            if item.bookUrl == book.bookUrl { break }
            x += footprint(item) + spacing
        }
        let target = x + footprint(book) / 2 - Self.pickerWidth / 2
        return min(max(target, -4), contentWidth - Self.pickerWidth + 4)
    }

    private func ornamentView(_ ornament: ShelfOrnament, size: CGSize) -> some View {
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
            if selectedURL != nil { deselect() } else { editingOrnament = ornament }
        }
        .accessibilityLabel("书架摆件")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("轻点调整大小或移出书架")
    }

    private func spine(_ book: Book) -> some View {
        let isSelected = book.bookUrl == selectedURL
        return BookshelfSpine(book: book, pose: pose(book), isSelected: isSelected)
            .onTapGesture {
                if isSelected {
                    withAnimation(.easeOut(duration: 0.18)) { showsPicker.toggle() }
                } else if selectedURL != nil {
                    deselect()
                } else {
                    onOpen(.read(book))
                }
            }
            .onLongPressGesture(minimumDuration: 0.35) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                    selectedURL = book.bookUrl
                }
                withAnimation(.easeOut(duration: 0.2).delay(0.15)) { showsPicker = true }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("轻点打开，长按调整摆放")
    }

    private func posePicker(for book: Book) -> some View {
        let current = pose(book)
        return HStack(spacing: 0) {
            ForEach(Array(BookshelfShelfPose.allCases.enumerated()), id: \.element.rawValue) { index, item in
                if index > 0 {
                    Rectangle().fill(Color.white.opacity(0.25)).frame(width: 0.5, height: 12)
                }
                Button {
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.8)) {
                        if item == .upright { poses.removeValue(forKey: book.bookUrl) }
                        else { poses[book.bookUrl] = item.rawValue }
                        showsPicker = false
                    }
                    BookshelfShelfPose.save(poses)
                } label: {
                    Text(item.title)
                        .font(.system(size: 11, weight: item == current ? .semibold : .regular))
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
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }

    private var shelfBoard: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(colorScheme == .dark ? Color(white: 0.36) : Color(white: 0.80))
                .frame(height: 1.5)
            Rectangle()
                .fill(LinearGradient(colors: [colorScheme == .dark ? Color(white: 0.20) : Color(white: 0.96),
                                              colorScheme == .dark ? Color(white: 0.14) : Color(white: 0.92)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(height: 7)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.08), radius: 4, y: 3)
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

/// 书脊的排版：书脊宽度固定，书名越长字号越小；单列放不下时在同样宽度里分两列小字，
/// 尽量完整显示书名，不把书加厚。
private struct BookshelfSpineLayout {
    static let spineWidth: CGFloat = 26
    let width: CGFloat
    let height: CGFloat
    let fontSize: CGFloat
    let columns: [String]

    static let minHeight: CGFloat = 118
    static let maxHeight: CGFloat = 176
    private static let verticalPadding: CGFloat = 22
    private static let lineFactor: CGFloat = 1.2
    private static let singleColumnMinFont: CGFloat = 7
    private static let doubleColumnMaxFont: CGFloat = 8.5
    private static let doubleColumnMinFont: CGFloat = 5.5

    init(title: String) {
        var chars = Array(title).filter { !$0.isWhitespace }
        if chars.isEmpty { chars = Array("未命名") }
        let usable = Self.maxHeight - Self.verticalPadding
        var columnCount = 1
        var font = min(12, usable / (CGFloat(chars.count) * Self.lineFactor))
        var shown = chars
        if font < Self.singleColumnMinFont {
            // 单列字太小：同样宽度里排两列。
            columnCount = 2
            let perColumn = (chars.count + 1) / 2
            font = min(Self.doubleColumnMaxFont, usable / (CGFloat(perColumn) * Self.lineFactor))
            if font < Self.doubleColumnMinFont {
                // 极长书名（约 48 字以上）：最小字号仍放不下，末尾用省略号。
                font = Self.doubleColumnMinFont
                let capacity = Int(usable / (font * Self.lineFactor)) * 2
                if chars.count > capacity { shown = Array(chars.prefix(max(capacity - 1, 1))) + ["…"] }
            }
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
        width = Self.spineWidth
        let textHeight = CGFloat(per) * font * Self.lineFactor + Self.verticalPadding
        height = min(max(textHeight, Self.minHeight), Self.maxHeight)
    }
}

/// 一本书：竖立时书名竖排，平躺时横排；选中时露出书页顶面与侧面，像被抽出来一样。
private struct BookshelfSpine: View {
    let book: Book
    let pose: BookshelfShelfPose
    let isSelected: Bool

    static let maxHeight: CGFloat = BookshelfSpineLayout.maxHeight
    static let leanAngle: Double = 10
    private static let depth: CGFloat = 8

    private static let palette: [(Double, Double, Double)] = [
        (0.25, 0.18, 0.12), (0.17, 0.20, 0.27), (0.30, 0.21, 0.13), (0.22, 0.17, 0.14),
        (0.15, 0.17, 0.21), (0.27, 0.19, 0.15)
    ]

    static func seed(_ book: Book) -> Int {
        book.name.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF }
    }

    static func layout(for book: Book) -> BookshelfSpineLayout {
        BookshelfSpineLayout(title: book.name.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 在层板上占用的宽高（倾斜、平躺后会变宽）。
    static func footprint(for book: Book, pose: BookshelfShelfPose) -> CGSize {
        let layout = layout(for: book)
        let size = CGSize(width: layout.width, height: layout.height)
        let radians = CGFloat(leanAngle * .pi / 180)
        switch pose {
        case .upright: return size
        case .flat: return CGSize(width: size.height, height: size.width)
        case .leanLeft, .leanRight:
            return CGSize(width: size.width * cos(radians) + size.height * sin(radians) + 2,
                          height: size.width * sin(radians) + size.height * cos(radians))
        }
    }

    private var layout: BookshelfSpineLayout { Self.layout(for: book) }

    private var color: Color {
        let c = Self.palette[Self.seed(book) % Self.palette.count]
        return Color(red: c.0, green: c.1, blue: c.2)
    }

    private var title: String {
        let name = book.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "未命名" : name
    }

    private var pageColor: Color { Color(red: 0.95, green: 0.91, blue: 0.82) }

    /// 竖立书脊（书名竖排，长书名自动缩小字号或分两列）。
    private var uprightFront: some View {
        let layout = self.layout
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(color)
            .overlay(alignment: .top) {
                HStack(alignment: .top, spacing: 1) {
                    // 竖排从右往左读，第一列放在最右边。
                    ForEach(Array(layout.columns.enumerated().reversed()), id: \.offset) { _, column in
                        Text(column)
                            .font(.system(size: layout.fontSize, weight: .medium))
                            .lineSpacing(0)
                            .multilineTextAlignment(.center)
                            .fixedSize()
                    }
                }
                .foregroundStyle(Color.white.opacity(0.93))
                .padding(.top, 11)
            }
            .frame(width: layout.width, height: layout.height)
    }

    /// 抽出时的顶面（书页）与右侧面（封面）。
    private var uprightDepthFaces: some View {
        let w = layout.width, h = layout.height, d = Self.depth
        return ZStack(alignment: .topLeading) {
            BookshelfFace(points: [CGPoint(x: 0, y: d), CGPoint(x: d, y: 0), CGPoint(x: w + d, y: 0), CGPoint(x: w, y: d)])
                .fill(pageColor)
            BookshelfFace(points: [CGPoint(x: w, y: d), CGPoint(x: w + d, y: 0), CGPoint(x: w + d, y: h), CGPoint(x: w, y: h + d)])
                .fill(color.opacity(0.75))
        }
        .frame(width: w + d, height: h + d, alignment: .topLeading)
    }

    /// 平躺：书脊朝外横放，书名横排。
    private var flatFront: some View {
        let layout = self.layout
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(color)
            .overlay {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.93))
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .padding(.horizontal, 6)
            }
            .frame(width: layout.height, height: layout.width)
    }

    /// 平躺抽出时露出的封面（顶面）与书页（右端）。
    private var flatDepthFaces: some View {
        let w = layout.height, h = layout.width, d = Self.depth
        return ZStack(alignment: .topLeading) {
            BookshelfFace(points: [CGPoint(x: 0, y: d), CGPoint(x: d, y: 0), CGPoint(x: w + d, y: 0), CGPoint(x: w, y: d)])
                .fill(color.opacity(0.8))
            BookshelfFace(points: [CGPoint(x: w, y: d), CGPoint(x: w + d, y: 0), CGPoint(x: w + d, y: h), CGPoint(x: w, y: h + d)])
                .fill(pageColor)
        }
        .frame(width: w + d, height: h + d, alignment: .topLeading)
    }

    private var upright: some View {
        uprightFront
            .overlay(alignment: .bottomLeading) {
                if isSelected {
                    uprightDepthFaces.offset(y: 0).allowsHitTesting(false)
                }
            }
    }

    private var flat: some View {
        flatFront
            .overlay(alignment: .bottomLeading) {
                if isSelected {
                    flatDepthFaces.allowsHitTesting(false)
                }
            }
    }

    var body: some View {
        let footprint = Self.footprint(for: book, pose: pose)
        let height = layout.height
        Group {
            switch pose {
            case .upright:
                upright
            case .flat:
                flat
            case .leanLeft:
                upright
                    .rotationEffect(.degrees(-Self.leanAngle), anchor: .bottomLeading)
                    .frame(width: footprint.width, height: height, alignment: .bottomTrailing)
            case .leanRight:
                upright
                    .rotationEffect(.degrees(Self.leanAngle), anchor: .bottomTrailing)
                    .frame(width: footprint.width, height: height, alignment: .bottomLeading)
            }
        }
        .shadow(color: .black.opacity(isSelected ? 0.25 : 0.12), radius: isSelected ? 4 : 1, x: isSelected ? -1 : 0.5, y: isSelected ? 3 : 0.5)
        .offset(x: isSelected ? -2 : 0, y: isSelected ? -3 : 0)
        .overlay(alignment: .topTrailing) {
            if book.lastCheckCount > 0 {
                Circle().fill(ReadingTheme.coral).frame(width: 6, height: 6).offset(x: 2, y: -2)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(book.name)，\(pose.title)")
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

/// 书架第一层上实际显示的摆件和尺寸。
private struct PlacedShelfOrnament: Identifiable {
    let ornament: ShelfOrnament
    let size: CGSize
    var id: String { ornament.id }
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
                    .font(.headline)
                Spacer()
                Button(role: .destructive) {
                    store.setOnShelf(false, for: ornamentID)
                    dismiss()
                } label: {
                    Label("移出书架", systemImage: "trash")
                        .font(.subheadline)
                        .foregroundStyle(ReadingTheme.coral)
                }
            }
            HStack(spacing: 12) {
                Text("等比大小")
                    .font(.subheadline)
                Slider(value: $size, in: ShelfOrnamentStore.sizeRange, step: 1)
                    .tint(ReadingTheme.ink)
                Text("\(Int(size))pt")
                    .font(.subheadline.monospacedDigit())
                    .frame(width: 48, alignment: .trailing)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .onAppear { size = store.ornament(id: ornamentID)?.size ?? 64 }
        .onChange(of: size) { store.setSize($0, for: ornamentID) }
        .readingLivePreviewSheet()
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
                Text("书架摆件").font(.title3.weight(.semibold))
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
                Text(message).font(.footnote).foregroundStyle(.secondary)
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
        .readingPresentationDragIndicator()
    }

    private var myOrnaments: some View {
        ScrollView {
            if store.ornaments.isEmpty {
                Text("还没有摆件，去「添加新摆件」里添加吧")
                    .font(.subheadline).foregroundStyle(.secondary)
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
                                    .font(.system(size: 16))
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
            Text("轻点摆件放上或取下书架，长按可删除。轻点书架上的摆件可调整大小。")
                .font(.caption).foregroundStyle(.secondary)
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
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(ReadingTheme.ink)
                    .frame(maxWidth: .infinity, minHeight: 96)
                    .background(ReadingTheme.groupedCanvas, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                Text("建议使用透明背景的 PNG 图片，摆在书架上更自然。")
                    .font(.caption).foregroundStyle(.secondary)
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
                    .font(.subheadline.weight(.semibold))
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
