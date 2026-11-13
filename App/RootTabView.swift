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
    @State private var showsShelfSettings = false
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
                            BookshelfShelfView(books: displayedBooks, showsFolders: selectedGroup.groupId <= 0) {
                                shelfDestination = $0
                            }
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
        .sheet(isPresented: $showsShelfSettings) {
            BookshelfShelfSettingsSheet()
        }
        .onReceive(BookshelfFolderStore.shared.$openRequest) { request in
            guard let request else { return }
            BookshelfFolderStore.shared.openRequest = nil
            shelfDestination = request
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
                Button("书架设置", systemImage: "slider.horizontal.3") { showsShelfSettings = true }
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
    @AppStorage(BookshelfShelfSettings.hideTitlesKey) private var hideTitles = false
    @AppStorage(BookshelfShelfSettings.coverStyleKey) private var coverStyle = "flat"

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
                .overlay(alignment: .leading) {
                    if coverStyle == "solid" {
                        // 实体封面：左侧书脊的凹槽与高光。
                        HStack(spacing: 0) {
                            LinearGradient(stops: [
                                .init(color: .black.opacity(0.30), location: 0),
                                .init(color: .white.opacity(0.22), location: 0.35),
                                .init(color: .black.opacity(0.25), location: 0.7),
                                .init(color: .white.opacity(0.10), location: 1)
                            ], startPoint: .leading, endPoint: .trailing)
                            .frame(width: max(geometry.size.width * 0.075, 5))
                            LinearGradient(colors: [.black.opacity(0.12), .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: max(geometry.size.width * 0.06, 4))
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .allowsHitTesting(false)
                    }
                }
                .shadow(color: .black.opacity(coverStyle == "solid" ? 0.22 : 0), radius: 3, x: 2, y: 3)
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
            if !hideTitles {
                Text(book.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .padding(.top, 10)
                Text(book.author.isEmpty ? "未知作者" : book.author)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.top, 3)
            }
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
                AdjustableSlider(title: "字号增量", value: $titleSize, range: -10...30, format: { String(format: "%+.0f", $0) })
                AdjustableSlider(title: "上间距", value: $titleTopSpacing, range: 0...100, format: { String(Int($0)) })
                AdjustableSlider(title: "下间距", value: $titleBottomSpacing, range: 0...100, format: { String(Int($0)) })
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
    static let widthRange: ClosedRange<Double> = 16...44
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

// MARK: - 书盒（文件夹）

/// 在仿真书架上显示成「书盒」的分组：把一本书拖到另一本书上时创建。
/// 分组本身仍是普通的书架分组，可在顶部分组栏查看；这里只记录哪些分组以书盒形式摆在书架上，以及书盒样式。
@MainActor
final class BookshelfFolderStore: ObservableObject {
    static let shared = BookshelfFolderStore()
    private static let idsKey = "bookshelfFolderGroups"
    private static let stylesKey = "bookshelfFolderStyles"
    static let nameLimit = 20

    @Published private(set) var folderIDs: [Int64]
    @Published private(set) var styles: [String: Int]
    /// 正在打开的书盒（面板）。
    @Published var presentedFolderID: Int64?
    /// 在书盒面板里点了某本书：交给书架页打开。
    @Published var openRequest: BookshelfShelfDestination?

    private init() {
        folderIDs = (UserDefaults.standard.array(forKey: Self.idsKey) as? [NSNumber])?.map(\.int64Value) ?? []
        styles = UserDefaults.standard.dictionary(forKey: Self.stylesKey) as? [String: Int] ?? [:]
    }

    func contains(_ id: Int64) -> Bool { folderIDs.contains(id) }

    func add(_ id: Int64) {
        guard id > 0, !folderIDs.contains(id) else { return }
        folderIDs.append(id)
        save()
    }

    func remove(_ id: Int64) {
        folderIDs.removeAll { $0 == id }
        styles[String(id)] = nil
        if presentedFolderID == id { presentedFolderID = nil }
        save()
    }

    func style(for id: Int64) -> Int { styles[String(id)] ?? 0 }

    func toggleStyle(_ id: Int64) {
        styles[String(id)] = style(for: id) == 0 ? 1 : 0
        save()
    }

    /// 书架上以书盒显示的分组（分组被删除的不算）。
    func folders(in groups: [BookGroup]) -> [BookGroup] {
        groups.filter { $0.groupId > 0 && folderIDs.contains($0.groupId) }
            .sorted { $0.order == $1.order ? $0.groupId < $1.groupId : $0.order < $1.order }
    }

    private func save() {
        UserDefaults.standard.set(folderIDs.map { NSNumber(value: $0) }, forKey: Self.idsKey)
        UserDefaults.standard.set(styles, forKey: Self.stylesKey)
    }
}

/// 书盒外观：两种装帧样式，书盒上的小旋转按钮切换。
private struct BookshelfFolderBox: View {
    let group: BookGroup
    let books: [Book]
    let style: BookshelfShelfStyle
    let boxStyle: Int
    let onToggleStyle: () -> Void

    static let topLabel: CGFloat = 17
    static let bottomLabel: CGFloat = 15
    static let side: CGFloat = 5
    static let maxShown = 6

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
        if boxStyle == 1 {
            return (Color(red: 0.20, green: 0.21, blue: 0.23), Color(red: 0.11, green: 0.12, blue: 0.13),
                    Color(red: 0.86, green: 0.87, blue: 0.89), Color(red: 0.06, green: 0.06, blue: 0.07))
        }
        return (Color(red: 0.42, green: 0.14, blue: 0.13), Color(red: 0.27, green: 0.08, blue: 0.08),
                Color(red: 0.95, green: 0.86, blue: 0.67), Color(red: 0.16, green: 0.05, blue: 0.05))
    }

    private var footer: String {
        boxStyle == 1 ? "PRECISION // \(books.count)V" : "典藏 · \(books.count) 册"
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
            // 顶部标签：书盒名
            Text(group.groupName)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(colors.label)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: size.width - 22, height: Self.topLabel)
                .offset(x: 6)
            // 书盒的窗口：里面立着分组里的书
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
                .font(.system(size: 6.5, weight: .medium, design: boxStyle == 1 ? .monospaced : .default))
                .foregroundStyle(colors.label.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(width: size.width - 10, height: Self.bottomLabel)
                .offset(x: 5, y: size.height - Self.bottomLabel)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .overlay(alignment: .topTrailing) {
            Button(action: onToggleStyle) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 6.5, weight: .bold))
                    .foregroundStyle(colors.label)
                    .frame(width: 13, height: 13)
                    .background(Color.black.opacity(0.35), in: Circle())
                    .opacity(style.hideRotateButtons ? 0.011 : 1)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .offset(x: 9, y: -9)
            .accessibilityLabel("切换书盒样式")
        }
        .shadow(color: .black.opacity(0.22), radius: 2, x: 1, y: 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }
}

/// 仿真书架上的一个位置：摆件、书或书盒。
private enum BookshelfShelfItem {
    case ornament(ShelfOrnament, CGSize)
    case book(Book)
    case folder(BookGroup, [Book])

    var id: String {
        switch self {
        case .ornament(let ornament, _): "o:" + ornament.id
        case .book(let book): "b:" + book.bookUrl
        case .folder(let group, _): "f:\(group.groupId)"
        }
    }

    var book: Book? {
        if case .book(let book) = self { return book }
        return nil
    }
}

/// 一本书、一个书盒或一个摆件在某一层上的实际摆放位置（按现实中的支撑关系算出来）。
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

/// 用户拖动调整过的书架顺序（摆件、书、书盒混排），按 id 保存。
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
/// - 长按拖动：放在两件东西之间调整位置（黄线）；把书拖到另一本书上松手，两本书装进一个书盒；
///   拖到书盒上松手，书放进这个书盒；把摆件拖到平躺的书上，摆件就放在这本书上面；
/// - 轻点书盒：打开书盒面板（改名、多选移出、解散）；轻点摆件：调整大小或移出书架。
private struct BookshelfShelfView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var library: BookLibraryModel
    let books: [Book]
    /// 是否把书盒里的书收进书盒（查看某个分组时直接平铺）。
    let showsFolders: Bool
    let onOpen: (BookshelfShelfDestination) -> Void

    @ObservedObject private var ornamentStore = ShelfOrnamentStore.shared
    @ObservedObject private var folderStore = BookshelfFolderStore.shared
    @AppStorage(BookshelfShelfSettings.bookWidthKey) private var bookWidth = BookshelfShelfSettings.defaultWidth
    @AppStorage(BookshelfShelfSettings.bookHeightKey) private var bookHeight = BookshelfShelfSettings.defaultHeight
    @AppStorage(BookshelfShelfSettings.hideTitlesKey) private var hideTitles = false
    @AppStorage(BookshelfShelfSettings.coverSpineKey) private var coverSpine = false
    @AppStorage(BookshelfShelfSettings.hideRotateKey) private var hideRotateButtons = false
    @State private var poses: [String: Int] = BookshelfShelfPose.load()
    @State private var order: [String] = BookshelfShelfOrder.load()
    @State private var perches: [String: String] = ShelfOrnamentPerches.load()
    @State private var selectedURL: String?
    @State private var showsPicker = false
    @State private var editingOrnament: ShelfOrnament?
    @State private var draggingID: String?
    @State private var dragTranslation: CGSize = .zero
    @State private var insertionIndex: Int?
    @State private var insertionMarker: (row: Int, x: CGFloat)?
    /// 拖动时手指停在哪件东西上（书 "b:"、书盒 "f:"）：合并、放进书盒或放摆件。
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
        BookshelfShelfPose(rawValue: poses[book.bookUrl] ?? 0) ?? .upright
    }

    // MARK: 顺序与分层

    /// 书盒与其中的书（按书架当前显示的书）。
    private var folderContents: [(group: BookGroup, books: [Book])] {
        guard showsFolders else { return [] }
        var assigned = Set<String>()
        var result: [(BookGroup, [Book])] = []
        for group in folderStore.folders(in: library.groups) {
            let inside = books.filter { ($0.group & group.groupId) != 0 && !assigned.contains($0.bookUrl) }
            guard !inside.isEmpty else { continue }
            inside.forEach { assigned.insert($0.bookUrl) }
            result.append((group, inside))
        }
        return result
    }

    /// 摆件在前、书和书盒在后的默认顺序，再按用户拖动保存的顺序重排；新加入的放在最后。
    /// 书盒没有保存过位置时，排在它里面第一本书原来的位置。
    private var allItems: [BookshelfShelfItem] {
        let folders = folderContents
        let folded = Set(folders.flatMap { $0.books.map(\.bookUrl) })
        let ornaments = ornamentStore.placed.map {
            BookshelfShelfItem.ornament($0, ornamentStore.displaySize(for: $0, maxWidth: contentWidth * 0.5))
        }
        var defaults = ornaments
        var placedFolders = Set<Int64>()
        for book in books {
            if folded.contains(book.bookUrl) {
                if let folder = folders.first(where: { $0.books.contains { $0.bookUrl == book.bookUrl } }),
                   !placedFolders.contains(folder.group.groupId) {
                    placedFolders.insert(folder.group.groupId)
                    defaults.append(.folder(folder.group, folder.books))
                }
            } else {
                defaults.append(.book(book))
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
            if let book = item.book, requestedPose(book) == .flat { flatBooks.insert(book.bookUrl) }
        }
        var result: [String: (ShelfOrnament, CGSize)] = [:]
        for item in items {
            guard case .ornament(let ornament, let size) = item,
                  let url = perches[ornament.id], flatBooks.contains(url), result[url] == nil else { continue }
            result[url] = (ornament, size)
        }
        return result
    }

    /// 按现实中的支撑关系摆一层：倾斜的书一角着地，上端刚好靠在相邻的书、书盒或摆件上。
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
            case .folder(_, let inside):
                let size = BookshelfFolderBox.size(count: inside.count, style: style)
                let left = previous.map { leftEdgeAfter($0, objectHeight: size.height) + 4 } ?? 0
                result.append(.init(item: entry.item, index: entry.index, pose: .upright,
                                    boxX: left, boxSize: size, boardMinX: left, boardMaxX: left + size.width + 4,
                                    height: size.height, pivotX: left))
            case .book(let book):
                let w = style.bookWidth, h = style.bookHeight
                var pose = requestedPose(book)
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
                    let lying = w + (perched[book.bookUrl]?.1.height ?? 0)
                    let left = previous.map { leftEdgeAfter($0, objectHeight: w) } ?? 0
                    result.append(.init(item: entry.item, index: entry.index, pose: pose,
                                        boxX: left, boxSize: CGSize(width: h, height: w),
                                        boardMinX: left, boardMaxX: left + h, height: lying, pivotX: left))
                case .leanLeft:
                    // 左倾：左下角着地，左侧靠在前一个物体上。
                    guard let previous else { continue }
                    let pivot: CGFloat
                    switch previous.pose {
                    case .leanLeft where previous.item.book != nil:
                        // 同向倾斜，两本书贴在一起。
                        pivot = previous.pivotX + previous.boxSize.width / cos(t)
                    case .leanRight where previous.item.book != nil:
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
                    if let previous, previous.pose == .leanRight, previous.item.book != nil {
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

    /// 竖直物体（竖立的书、平躺的书、书盒、摆件）放在 previous 后面时的左边位置。
    private func leftEdgeAfter(_ previous: BookshelfShelfPlacement, objectHeight: CGFloat) -> CGFloat {
        let t = Self.leanRadians
        if previous.pose == .leanRight, previous.item.book != nil {
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
                .onTapGesture { if selectedURL != nil { deselect() } }
        )
        .overlay(alignment: .top) {
            if let toast {
                Text(toast)
                    .font(.footnote.weight(.medium))
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
        if let book = placement.item.book, let ornament = perched[book.bookUrl]?.0 {
            return "o:" + ornament.id == draggingID
        }
        return false
    }

    private func deselect() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            selectedURL = nil
            showsPicker = false
        }
    }

    private func shelfRow(_ row: [BookshelfShelfPlacement], rowIndex: Int, rows: [[BookshelfShelfPlacement]],
                          perched: [String: (ShelfOrnament, CGSize)]) -> some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { if selectedURL != nil { deselect() } }
                ForEach(row) { placement in
                    placementView(placement, rows: rows)
                        .zIndex(placement.id == draggingID ? 3 : (placement.id == "b:" + (selectedURL ?? "") ? 2 : 0))
                    if let book = placement.item.book, let perch = perched[book.bookUrl] {
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
                    posePicker(for: book)
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
            case .folder(let group, let inside):
                folderView(group, books: inside, drag: dragGesture(id: placement.id, index: placement.index, rows: rows))
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
            .offset(x: x, y: -placement.boxSize.height + (placement.id == "b:" + (selectedURL ?? "") ? -3 : 0))
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

    /// 根据手指位置决定：插到两件东西之间（黄线），或者落在某本书 / 书盒上。
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
                    // 手指在一本书中间一半的范围内：两本书装进一个书盒。
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
                // 书拖到书盒上：放进书盒（两边留一点给插入位置）。
                let inset = min(8, (placement.boardMaxX - placement.boardMinX) * 0.2)
                if draggingBook, location.x > placement.boardMinX + inset, location.x < placement.boardMaxX - inset {
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
                            Task { await makeFolder(with: source, and: destination) }
                        }
                    } else if target.hasPrefix("f:"), let id = Int64(target.dropFirst(2)),
                              let group = library.groups.first(where: { $0.groupId == id }) {
                        Task {
                            await library.setBook(source, in: group, included: true)
                            showToast("已放入「\(group.groupName)」")
                        }
                    }
                }
            } else if draggingID.hasPrefix("o:"), target.hasPrefix("b:") {
                let ornamentID = String(draggingID.dropFirst(2))
                let url = String(target.dropFirst(2))
                perches = perches.filter { $0.value != url }
                perches[ornamentID] = url
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
            // 保留书盒里那些书原来的位置记录，书拿出书盒时回到原处附近。
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

    // MARK: 书盒

    /// 把两本书装进一个新书盒（新建一个书架分组），书盒放在目标书原来的位置。
    @MainActor
    private func makeFolder(with source: Book, and destination: Book) async {
        let names = Set(library.groups.map(\.groupName))
        var name = "文件夹"
        var index = 2
        while names.contains(name) {
            name = "文件夹\(index)"
            index += 1
        }
        await library.createGroup(name: name)
        guard let group = library.groups.first(where: { $0.groupName == name && $0.groupId > 0 }) else { return }
        folderStore.add(group.groupId)
        // 书盒占用目标书的位置。
        var ids = order.isEmpty ? allItems.map(\.id) : order
        if let position = ids.firstIndex(of: "b:" + destination.bookUrl) {
            ids.insert("f:\(group.groupId)", at: position)
        } else {
            ids.append("f:\(group.groupId)")
        }
        order = ids
        BookshelfShelfOrder.save(ids)
        await library.setBook(destination, in: group, included: true)
        if let refreshed = library.books.first(where: { $0.bookUrl == source.bookUrl }) {
            await library.setBook(refreshed, in: group, included: true)
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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
            if selectedURL != nil { deselect() } else { editingOrnament = ornament }
        }
        .gesture(drag)
        .accessibilityLabel("书架摆件")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("轻点调整大小或移出书架，长按拖动调整位置")
    }

    private func folderView<G: Gesture>(_ group: BookGroup, books inside: [Book], drag: G) -> some View {
        BookshelfFolderBox(group: group, books: inside, style: style, boxStyle: folderStore.style(for: group.groupId)) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { folderStore.toggleStyle(group.groupId) }
        }
        .onTapGesture {
            if selectedURL != nil {
                deselect()
            } else {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    folderStore.presentedFolderID = group.groupId
                }
            }
        }
        .gesture(drag)
        .accessibilityLabel("书盒「\(group.groupName)」，\(inside.count) 本书")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("轻点打开，长按拖动调整位置")
    }

    private func spine<G: Gesture>(_ book: Book, pose: BookshelfShelfPose, drag: G) -> some View {
        let isSelected = book.bookUrl == selectedURL
        return BookshelfSpine(book: book, pose: pose, isSelected: isSelected, style: style)
            .overlay(alignment: .top) {
                if isSelected {
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) { showsPicker.toggle() }
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .frame(width: 22, height: 22)
                            .background(Color.black.opacity(0.55), in: Circle())
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.5), lineWidth: 0.5))
                            .opacity(style.hideRotateButtons ? 0.011 : 1)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .offset(x: pose == .flat ? 0 : -2, y: pose == .flat ? -34 : 12)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
                    .accessibilityLabel("修改摆放形态")
                }
            }
            .onTapGesture {
                if isSelected {
                    onOpen(.read(book))
                } else {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                        selectedURL = book.bookUrl
                        showsPicker = false
                    }
                }
            }
            .gesture(drag)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(isSelected ? "再次轻点打开阅读" : "轻点抽出，长按拖动调整位置或拖到另一本书上装进书盒")
    }

    private func posePicker(for book: Book) -> some View {
        let current = requestedPose(book)
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
        BookshelfBoard(width: contentWidth, height: boardHeight)
    }
}

/// 一层书架的层板：浅色台面 + 正面 + 下方柔和的阴影。
private struct BookshelfBoard: View {
    @Environment(\.colorScheme) private var colorScheme
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let dark = colorScheme == .dark
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
        .frame(width: width)
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        .shadow(color: .black.opacity(dark ? 0.45 : 0.10), radius: 6, y: 5)
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
final class BookshelfSpineTintCache {
    static let shared = BookshelfSpineTintCache()
    private var tints: [String: UIColor] = [:]
    private var failed = Set<String>()

    func cached(_ key: String?) -> UIColor? {
        guard let key else { return nil }
        return tints[key]
    }

    func tint(for urlString: String?) async -> UIColor? {
        guard let urlString, !urlString.isEmpty, !failed.contains(urlString) else { return nil }
        if let tint = tints[urlString] { return tint }
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
        tints[urlString] = tint
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
    @State private var tint: UIColor?

    static let leanAngle: Double = 10
    private static let depth: CGFloat = 8
    /// 竖立的书被抽出时侧面露出的宽度（能看到一部分封面）。
    private static let pulledDepth: CGFloat = 16

    private static let palette: [(CGFloat, CGFloat, CGFloat)] = [
        (0.25, 0.18, 0.12), (0.17, 0.20, 0.27), (0.30, 0.21, 0.13), (0.22, 0.17, 0.14),
        (0.15, 0.17, 0.21), (0.27, 0.19, 0.15)
    ]

    init(book: Book, pose: BookshelfShelfPose, isSelected: Bool, style: BookshelfShelfStyle) {
        self.book = book
        self.pose = pose
        self.isSelected = isSelected
        self.style = style
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
                                .font(.system(size: layout.fontSize, weight: .semibold, design: .serif))
                                .lineSpacing(0)
                                .multilineTextAlignment(.center)
                                .fixedSize()
                        }
                    }
                    .padding(.top, layout.topInset)
                    Spacer(minLength: 0)
                    if let author = layout.author {
                        Text(author)
                            .font(.system(size: layout.authorFontSize, weight: .regular))
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

    /// 抽出时露出的顶面（书页）与右侧面：右侧面画的是这本书封面靠书脊的一部分。
    private var uprightDepthFaces: some View {
        let w = style.bookWidth, h = style.bookHeight, d = Self.pulledDepth
        return ZStack(alignment: .topLeading) {
            BookshelfFace(points: [CGPoint(x: 0, y: d), CGPoint(x: d, y: 0), CGPoint(x: w + d, y: 0), CGPoint(x: w, y: d)])
                .fill(pageColor)
            BookshelfFace(points: [CGPoint(x: 2, y: d - 2), CGPoint(x: d - 2, y: 2), CGPoint(x: w + d - 3, y: 2), CGPoint(x: w - 3, y: d - 2)])
                .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
            BookCoverArtwork(title: book.name, author: book.author, remoteURL: book.coverUrl,
                             width: max(h * 0.7, d), height: h)
                .frame(width: d, height: h, alignment: .leading)
                .clipped()
                .overlay(LinearGradient(colors: [Color.black.opacity(0.28), Color.black.opacity(0.05)],
                                        startPoint: .leading, endPoint: .trailing))
                .transformEffect(CGAffineTransform(a: 1, b: -1, c: 0, d: 1, tx: w, ty: d))
        }
        .frame(width: w + d, height: h + d, alignment: .topLeading)
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

    private var upright: some View {
        uprightFront
            .overlay(alignment: .bottomLeading) {
                if isSelected {
                    uprightDepthFaces.allowsHitTesting(false)
                }
            }
            // 抽出时书顶向外倾一点。
            .rotation3DEffect(.degrees(isSelected ? -9 : 0), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.45)
            // 点击区域跟着书一起旋转：倾斜的书点哪里都有反应，不只是靠近底部的一小块。
            .contentShape(Rectangle())
    }

    private var flat: some View {
        flatFront
            .overlay(alignment: .bottomLeading) {
                if isSelected {
                    flatDepthFaces.allowsHitTesting(false)
                }
            }
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
        .shadow(color: .black.opacity(isSelected ? 0.25 : 0.14), radius: isSelected ? 4 : 1, x: isSelected ? -1 : 0.6, y: isSelected ? 3 : 0.6)
        .offset(x: isSelected ? -2 : 0, y: isSelected ? -3 : 0)
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
    }
}

// MARK: - 书盒面板

/// 打开的书盒：盖在整个界面上（包括底部标签栏），背景模糊。
/// 标题可改名；「多选」后可把选中的书移出书盒；「解散」把书放回书架；长按书拖到面板外移出书盒。
struct BookshelfFolderOverlay: View {
    @EnvironmentObject private var library: BookLibraryModel
    @ObservedObject private var store = BookshelfFolderStore.shared

    var body: some View {
        ZStack {
            if let id = store.presentedFolderID,
               let group = library.groups.first(where: { $0.groupId == id }) {
                BookshelfFolderPanel(group: group)
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
    @AppStorage(BookshelfShelfSettings.bookWidthKey) private var bookWidth = BookshelfShelfSettings.defaultWidth
    @AppStorage(BookshelfShelfSettings.bookHeightKey) private var bookHeight = BookshelfShelfSettings.defaultHeight
    @AppStorage(BookshelfShelfSettings.hideTitlesKey) private var hideTitles = false
    @AppStorage(BookshelfShelfSettings.coverSpineKey) private var coverSpine = false
    let group: BookGroup

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

    private var books: [Book] { library.books.filter { ($0.group & group.groupId) != 0 } }

    private var style: BookshelfShelfStyle {
        BookshelfShelfStyle(bookWidth: CGFloat(bookWidth).rounded(), bookHeight: CGFloat(bookHeight).rounded(),
                            hideTitles: hideTitles, coverSpine: coverSpine, hideRotateButtons: true)
    }

    private var isOutside: Bool {
        draggingURL != nil && !panelFrame.insetBy(dx: -6, dy: -6).contains(dragLocation)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = min(proxy.size.width - 28, 520)
            let height = min(max(proxy.size.height * 0.62, 360), proxy.size.height - 120)
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(Color.black.opacity(colorScheme == .dark ? 0.35 : 0.22))
                    .ignoresSafeArea()
                    .onTapGesture { close() }
                panel(width: width, height: height)
                    .frame(width: width, height: height)
                    .background(
                        GeometryReader { panel in
                            Color.clear
                                .onAppear { panelFrame = panel.frame(in: .named(Self.space)) }
                                .onChange(of: panel.frame(in: .named(Self.space))) { panelFrame = $0 }
                        }
                    )
                    .scaleEffect(appeared ? 1 : 0.9)
                    .opacity(appeared ? 1 : 0)
                if let url = draggingURL, let book = books.first(where: { $0.bookUrl == url }) {
                    // 拖动中的书浮在最上层，拖出面板也看得见。
                    BookshelfSpine(book: book, pose: .upright, isSelected: false, style: style)
                        .scaleEffect(1.08)
                        .shadow(color: .black.opacity(0.3), radius: 10, y: 6)
                        .rotationEffect(.degrees(isOutside ? -6 : 0))
                        .position(x: dragLocation.x, y: dragLocation.y - style.bookHeight * 0.3)
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
            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { appeared = true }
        }
        .onChange(of: books.count) { count in
            if count == 0 { dissolve() }
        }
    }

    private func panel(width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)
            ScrollView(showsIndicators: false) {
                shelf(width: width - 32)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 20)
            }
            footer
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
        }
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(colorScheme == .dark ? Color(white: 0.12) : Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(isOutside ? ReadingTheme.coral : Color.clear, lineWidth: 2)
        )
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.system(size: 14))
            Button {
                draft = group.groupName
                renameError = nil
                withAnimation(.easeOut(duration: 0.2)) { renaming = true }
            } label: {
                HStack(spacing: 4) {
                    Text(group.groupName)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("书盒名称 \(group.groupName)，轻点修改")
            Spacer(minLength: 8)
            Button(selecting ? "完成" : "多选") {
                withAnimation(.easeOut(duration: 0.18)) {
                    selecting.toggle()
                    selected.removeAll()
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(.primary)
            .frame(minWidth: 40, minHeight: 36)
            Button("解散") { dissolve() }
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .frame(minWidth: 40, minHeight: 36)
                .accessibilityHint("把书放回书架并删除这个书盒")
            Button { close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
        }
        .foregroundStyle(.primary)
    }

    /// 书盒里的小书架：书竖着排，按宽度换行。
    private func shelf(width: CGFloat) -> some View {
        let style = self.style
        let perRow = max(Int((width + 3) / (style.bookWidth + 3)), 1)
        let list = books
        let rows = stride(from: 0, to: list.count, by: perRow).map { Array(list[$0..<min($0 + perRow, list.count)]) }
        return VStack(alignment: .leading, spacing: 28) {
            ForEach(rows.indices, id: \.self) { index in
                VStack(spacing: 0) {
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(rows[index]) { book in
                            bookCell(book, style: style)
                                .zIndex(book.bookUrl == draggingURL ? 2 : 0)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(width: width, height: style.bookHeight + 12, alignment: .bottomLeading)
                    .zIndex(rows[index].contains { $0.bookUrl == draggingURL } ? 2 : 0)
                    BookshelfBoard(width: width, height: 10)
                }
                .zIndex(rows[index].contains { $0.bookUrl == draggingURL } ? 2 : 0)
            }
        }
    }

    private func bookCell(_ book: Book, style: BookshelfShelfStyle) -> some View {
        let isDragging = book.bookUrl == draggingURL
        let isChecked = selected.contains(book.bookUrl)
        return BookshelfSpine(book: book, pose: .upright, isSelected: false, style: style)
            .overlay(alignment: .bottom) {
                if selecting {
                    Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isChecked ? ReadingTheme.accent : Color.white)
                        .background(Circle().fill(Color.black.opacity(isChecked ? 0 : 0.25)))
                        .padding(.bottom, 6)
                        .allowsHitTesting(false)
                }
            }
            .opacity(isDragging ? 0.25 : (selecting && !isChecked ? 0.75 : 1))
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
                        if remove { Task { await removeFromFolder([book.bookUrl]) } }
                    }
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(selecting ? "轻点选择" : "轻点打开阅读，长按拖到面板外移出书盒")
    }

    @ViewBuilder
    private var footer: some View {
        if selecting {
            Button {
                let urls = selected
                Task { await removeFromFolder(urls) }
            } label: {
                Text(selected.isEmpty ? "选择要移出的书" : "移出书盒（\(selected.count)）")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(selected.isEmpty ? Color.secondary : Color.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(selected.isEmpty ? Color.secondary.opacity(0.15) : Color(white: 0.15), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(selected.isEmpty)
        } else {
            Text(isOutside ? "松手移出书盒" : "长按书封拖到面板外 = 移出书盒")
                .font(.system(size: 11))
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
                Text("书盒名称")
                    .font(.system(size: 16, weight: .semibold))
                TextField("输入名称", text: $draft)
                    .font(.system(size: 15))
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
                            .font(.system(size: 11))
                            .foregroundStyle(ReadingTheme.coral)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text("\(draft.count)/\(BookshelfFolderStore.nameLimit)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Spacer()
                    Button("取消") { withAnimation(.easeOut(duration: 0.2)) { renaming = false } }
                        .font(.system(size: 14))
                        .foregroundStyle(.primary)
                        .frame(width: 64, height: 38)
                    Button {
                        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        withAnimation(.easeOut(duration: 0.2)) { renaming = false }
                        guard !name.isEmpty, name != group.groupName else { return }
                        if library.groups.contains(where: { $0.groupName == name && $0.groupId != group.groupId }) {
                            renameError = "已经有名为「\(name)」的分组了"
                            withAnimation(.easeOut(duration: 0.2)) { renaming = true }
                            return
                        }
                        Task { await library.renameGroup(group, name: name) }
                    } label: {
                        Text("保存")
                            .font(.system(size: 14, weight: .semibold))
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
        let id = group.groupId
        let store = self.store
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            if store.presentedFolderID == id { store.presentedFolderID = nil }
        }
    }

    @MainActor
    private func removeFromFolder(_ urls: Set<String>) async {
        for url in urls {
            if let book = library.books.first(where: { $0.bookUrl == url }) {
                await library.setBook(book, in: group, included: false)
            }
        }
        selected.subtract(urls)
        if books.isEmpty { dissolve() }
    }

    private func dissolve() {
        let group = self.group
        store.remove(group.groupId)
        Task { await library.deleteGroup(group) }
    }
}

// MARK: - 书架设置

/// 书架设置：书架页视图、隐藏书名作者、拟真书大小、封面书脊、隐藏旋转按钮、封面样式。
struct BookshelfShelfSettingsSheet: View {
    @AppStorage("bookshelfLayout") private var bookshelfLayout = "grid3"
    @AppStorage(BookshelfShelfSettings.hideTitlesKey) private var hideTitles = false
    @AppStorage(BookshelfShelfSettings.bookWidthKey) private var bookWidth = BookshelfShelfSettings.defaultWidth
    @AppStorage(BookshelfShelfSettings.bookHeightKey) private var bookHeight = BookshelfShelfSettings.defaultHeight
    @AppStorage(BookshelfShelfSettings.coverSpineKey) private var coverSpine = false
    @AppStorage(BookshelfShelfSettings.hideRotateKey) private var hideRotateButtons = false
    @AppStorage(BookshelfShelfSettings.coverStyleKey) private var coverStyle = "flat"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                row(title: "书架页视图", detail: "书架布局：网格封面、行卡列表或实体仿真书架") {
                    HStack(spacing: 4) {
                        layoutChoice("square.grid.2x2.fill", selected: bookshelfLayout.hasPrefix("grid"), label: "网格") {
                            if !bookshelfLayout.hasPrefix("grid") { bookshelfLayout = "grid3" }
                        }
                        layoutChoice("list.bullet", selected: bookshelfLayout == "list" || bookshelfLayout == "compact", label: "列表") {
                            bookshelfLayout = "list"
                        }
                        layoutChoice("books.vertical.fill", selected: bookshelfLayout == "shelf", label: "仿真书架") {
                            bookshelfLayout = "shelf"
                        }
                    }
                    .padding(3)
                    .background(Color.secondary.opacity(0.1), in: Capsule())
                }
                toggleRow(title: "隐藏书名/作者", detail: "网格与仿真视图隐藏书名作者（纯净书脊）", isOn: $hideTitles)
                VStack(alignment: .leading, spacing: 10) {
                    Text("仿真书大小").font(.headline)
                    Text("统一调整书高与书宽，书脊与书盒文字一并等比缩放")
                        .font(.caption).foregroundStyle(.secondary)
                    AdjustableSlider(title: "书宽", value: $bookWidth, range: BookshelfShelfSettings.widthRange,
                                     format: { "\(Int($0)) pt" })
                    AdjustableSlider(title: "书高", value: $bookHeight, range: BookshelfShelfSettings.heightRange,
                                     format: { "\(Int($0)) pt" })
                    Button("恢复默认大小") {
                        bookWidth = BookshelfShelfSettings.defaultWidth
                        bookHeight = BookshelfShelfSettings.defaultHeight
                    }
                    .font(.footnote)
                    .foregroundStyle(ReadingTheme.accent)
                }
                toggleRow(title: "封面书脊", detail: "书脊直接显示封面截取图案（关闭后按封面主色装帧）", isOn: $coverSpine)
                toggleRow(title: "隐藏旋转按钮", detail: "仿真视图隐藏书脊与书盒上的旋转按钮（透明后依旧可点击）", isOn: $hideRotateButtons)
                row(title: "封面样式", detail: "仅网格书架页封面：实体在封面左侧呈现书脊凹陷质感") {
                    HStack(spacing: 4) {
                        textChoice("平面", selected: coverStyle != "solid") { coverStyle = "flat" }
                        textChoice("实体", selected: coverStyle == "solid") { coverStyle = "solid" }
                    }
                    .padding(3)
                    .background(Color.secondary.opacity(0.1), in: Capsule())
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 40)
        }
        .tint(ReadingTheme.ink)
        .readingLivePreviewSheet()
        .readingPresentationDragIndicator()
    }

    private func row<Accessory: View>(title: String, detail: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            accessory()
        }
    }

    private func toggleRow(title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(ReadingTheme.toggleTint)
    }

    private func layoutChoice(_ systemName: String, selected: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .frame(width: 36, height: 30)
                .background(selected ? Color(UIColor.systemBackground) : Color.clear, in: Capsule())
                .shadow(color: .black.opacity(selected ? 0.1 : 0), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func textChoice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .frame(width: 44, height: 30)
                .background(selected ? Color(UIColor.systemBackground) : Color.clear, in: Capsule())
                .shadow(color: .black.opacity(selected ? 0.1 : 0), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
            Text("轻点摆件放上或取下书架，长按可删除。在书架上轻点摆件可调整大小，长按后拖动可调整位置。")
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
