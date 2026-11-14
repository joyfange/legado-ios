import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SourceManagementView: View {
    @EnvironmentObject private var library: SourceLibraryModel
    @State private var showsImporter = false
    @State private var pickedImportFiles: [SourceImportFile] = []
    @State private var importPickerHasDismissed = true
    @State private var showsNewSource = false
    @State private var showsQRImporter = false
    @State private var showsTextImporter = false
    @State private var showsGroupManager = false
    @State private var showsBatchGroups = false
    @State private var batchSourceIDs = Set<String>()
    @State private var groupManagerFocusesNew = false
    @State private var selectedGroup: String?
    @State private var searchText = ""
    @State private var isSelecting = false
    @State private var selectedSourceIDs = Set<String>()
    @AppStorage("bookSourceSort") private var sortMode = "manual"
    @AppStorage("bookSourceSortDescending") private var sortDescending = false

    private var filteredSources: [BookSource] {
        let filtered = library.sources.filter { source in
            let matchesGroup: Bool
            if let selectedGroup {
                matchesGroup = selectedGroup.isEmpty ? source.groups.isEmpty : source.hasGroup(selectedGroup)
            } else {
                matchesGroup = true
            }
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            return matchesGroup && (query.isEmpty
                || source.bookSourceName.localizedCaseInsensitiveContains(query)
                || source.bookSourceUrl.localizedCaseInsensitiveContains(query)
                || source.groups.contains(where: { $0.localizedCaseInsensitiveContains(query) }))
        }
        guard sortMode != "manual" else { return filtered }
        return filtered.sorted { lhs, rhs in
            sortDescending ? isOrdered(rhs, before: lhs) : isOrdered(lhs, before: rhs)
        }
    }

    private func isOrdered(_ lhs: BookSource, before rhs: BookSource) -> Bool {
        switch sortMode {
        case "weight":
            return lhs.weight == rhs.weight ? lhs.bookSourceName.localizedStandardCompare(rhs.bookSourceName) == .orderedAscending : lhs.weight < rhs.weight
        case "name": return lhs.bookSourceName.localizedStandardCompare(rhs.bookSourceName) == .orderedAscending
        case "url": return lhs.bookSourceUrl.localizedStandardCompare(rhs.bookSourceUrl) == .orderedAscending
        case "update": return lhs.lastUpdateTime == rhs.lastUpdateTime ? lhs.bookSourceName < rhs.bookSourceName : lhs.lastUpdateTime > rhs.lastUpdateTime
        case "respond": return lhs.respondTime == rhs.respondTime ? lhs.bookSourceName < rhs.bookSourceName : lhs.respondTime < rhs.respondTime
        case "enabled": return lhs.enabled == rhs.enabled ? lhs.bookSourceName < rhs.bookSourceName : lhs.enabled && !rhs.enabled
        default: return lhs.customOrder < rhs.customOrder
        }
    }

    var body: some View {
        Group {
            if library.sources.isEmpty, !library.isWorking {
                ReadingUnavailableView {
                    Label("还没有书源", systemImage: "network")
                } description: {
                    Text("新建书源，或从文件、链接、JSON、二维码导入。")
                } actions: {
                    Button("导入书源", action: presentFileImporter)
                        .readingProminentButtonStyle()
                }
            } else {
                List {
                    Section {
                        groupBar
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                            .listRowBackground(Color.clear)
                    }.readingRowBackground()
                    Section {
                        ForEach(filteredSources) { source in
                            if isSelecting {
                                Button {
                                    if !selectedSourceIDs.insert(source.id).inserted { selectedSourceIDs.remove(source.id) }
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: selectedSourceIDs.contains(source.id) ? "checkmark.circle.fill" : "circle")
                                            .font(AppFontStyle.title3.themed)
                                            .foregroundStyle(selectedSourceIDs.contains(source.id) ? ReadingTheme.accent : .secondary)
                                        SourceRow(source: source, showsToggle: false) { _ in }
                                    }
                                }
                                .buttonStyle(.plain)
                            } else {
                                NavigationLink {
                                    SourceDetailView(source: source)
                                } label: {
                                    SourceRow(source: source) { enabled in
                                        Task { await library.setEnabled(enabled, for: source.id) }
                                    }
                                }
                                .contextMenu {
                                    Menu {
                                        ForEach(library.groups, id: \.self) { group in
                                            Button {
                                                Task { await library.moveSources([source.id], toGroup: group) }
                                            } label: {
                                                Label(group, systemImage: source.hasGroup(group) ? "checkmark" : "folder")
                                            }
                                        }
                                        Button {
                                            batchSourceIDs = [source.id]
                                            showsBatchGroups = true
                                        } label: { Label("新建分组…", systemImage: "folder.badge.plus") }
                                        if !source.groups.isEmpty {
                                            Button(role: .destructive) {
                                                Task { await library.moveSources([source.id], toGroup: nil) }
                                            } label: { Label("移出分组", systemImage: "folder.badge.minus") }
                                        }
                                    } label: {
                                        Label("移到分组", systemImage: "folder")
                                    }
                                    NavigationLink {
                                        SearchView(fixedSource: source)
                                    } label: {
                                        Label("搜索", systemImage: "magnifyingglass")
                                    }
                                    Button(source.enabledExplore ? "停用发现" : "启用发现", systemImage: "safari") {
                                        Task { await library.setExploreEnabled(!source.enabledExplore, for: source.id) }
                                    }
                                    Button("删除", systemImage: "trash", role: .destructive) {
                                        Task { await library.remove(sourceIDs: [source.id]) }
                                    }
                                }
                            }
                        }
                        .onDelete { offsets in
                            let ids = Set(offsets.compactMap { filteredSources.indices.contains($0) ? filteredSources[$0].id : nil })
                            Task { await library.remove(sourceIDs: ids) }
                        }
                    } header: {
                        Text("\(filteredSources.count) 个书源")
                    } footer: {
                        Text("共 \(library.sources.count) 个书源，\(library.sources.filter(\.enabled).count) 个已启用")
                    }.readingRowBackground()
                }.readingThemedListBackground()
                .listStyle(.insetGrouped)
                .readingScrollContentBackgroundHidden()
                .background(ReadingTheme.groupedCanvas)
                .overlay {
                    if library.isWorking { ProgressView() }
                }
            }
        }
        .navigationTitle("书源")
        .background(ReadingTheme.groupedCanvas)
        .readingInlineSearch(text: $searchText, prompt: "名称、地址或分组")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(isSelecting ? "完成" : "选择") {
                    isSelecting.toggle()
                    if !isSelecting { selectedSourceIDs.removeAll() }
                }
                .disabled(library.sources.isEmpty)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu("更多", systemImage: "ellipsis.circle") {
                    Button("新建书源", systemImage: "plus") { showsNewSource = true }
                    Button("二维码导入", systemImage: "qrcode.viewfinder") { showsQRImporter = true }
                    Button("从文件导入", systemImage: "doc.badge.plus", action: presentFileImporter)
                    Button("URL 或粘贴 JSON", systemImage: "link.badge.plus") { showsTextImporter = true }
                    Divider()
                    NavigationLink {
                        SourceBatchTestView()
                    } label: {
                        Label("测试书源", systemImage: "checkmark.circle.badge.questionmark")
                    }
                    Button("管理分组", systemImage: "folder.badge.gearshape") {
                        groupManagerFocusesNew = false
                        showsGroupManager = true
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu("排序", systemImage: "arrow.up.arrow.down") {
                    Toggle("倒序", isOn: $sortDescending)
                    Picker("排序方式", selection: $sortMode) {
                        Text("手动排序").tag("manual")
                        Text("自动排序").tag("weight")
                        Text("按名称").tag("name")
                        Text("按网址").tag("url")
                        Text("按更新时间").tag("update")
                        Text("按响应时间").tag("respond")
                        Text("按启用状态").tag("enabled")
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                HStack(spacing: 18) {
                    Button(selectedSourceIDs.count == filteredSources.count ? "取消全选" : "全选") {
                        if selectedSourceIDs.count == filteredSources.count { selectedSourceIDs.removeAll() }
                        else { selectedSourceIDs = Set(filteredSources.map(\.id)) }
                    }
                    Spacer()
                    Button("移到分组", systemImage: "folder") {
                        batchSourceIDs = selectedSourceIDs
                        showsBatchGroups = true
                    }
                        .disabled(selectedSourceIDs.isEmpty)
                    Button("启用", systemImage: "checkmark.circle") {
                        Task { await library.setEnabled(true, for: selectedSourceIDs) }
                    }
                    .disabled(selectedSourceIDs.isEmpty)
                    Button("停用", systemImage: "pause.circle") {
                        Task { await library.setEnabled(false, for: selectedSourceIDs) }
                    }
                    .disabled(selectedSourceIDs.isEmpty)
                }
                .font(AppFontStyle.subheadline.weight(.semibold).themed)
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(.ultraThinMaterial)
            }
        }
        .sheet(isPresented: $showsNewSource) { SourceEditorView().environmentObject(library) }
        .sheet(isPresented: $showsQRImporter) {
            QRCodeImportView { value in Task { await library.previewInput(value) } }
        }
        .sheet(isPresented: $showsTextImporter) {
            SourceTextImportView()
                .environmentObject(library)
        }
        .sheet(isPresented: $showsGroupManager) {
            SourceGroupManagerView(focusesNewGroup: groupManagerFocusesNew).environmentObject(library)
        }
        .sheet(isPresented: $showsBatchGroups) {
            SourceBatchGroupView(sourceIDs: batchSourceIDs).environmentObject(library)
        }
        .sheet(isPresented: $showsImporter, onDismiss: {
            importPickerHasDismissed = true
            previewPickedFilesWhenReady()
        }) {
            SourceFileImportPicker { files in
                pickedImportFiles = files
                showsImporter = false
                previewPickedFilesWhenReady()
            } onCancel: {
                showsImporter = false
            }
        }
    }

    /// 分组栏：全部 / 未分组 / 各分组（隐藏的分组不显示），末尾是新建与管理入口。
    private var groupBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                groupChip("全部", count: library.sources.count, selected: selectedGroup == nil) { selectedGroup = nil }
                let ungrouped = library.sources.filter { $0.groups.isEmpty }.count
                if ungrouped > 0 || selectedGroup == "" {
                    groupChip("未分组", count: ungrouped, selected: selectedGroup == "") { selectedGroup = "" }
                }
                ForEach(library.visibleGroups, id: \.self) { group in
                    groupChip(group, count: library.sourceCount(inGroup: group), selected: selectedGroup == group) {
                        selectedGroup = group
                    }
                }
                Button {
                    groupManagerFocusesNew = true
                    showsGroupManager = true
                } label: {
                    Image(systemName: "plus")
                        .font(AppFontStyle.footnote.weight(.semibold).themed)
                        .frame(width: 34, height: 34)
                        .modifier(ShelfGlass(shape: Capsule(), isCard: true))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("新建分组")
                .accessibilityIdentifier("sources.group.new")
                Button {
                    groupManagerFocusesNew = false
                    showsGroupManager = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(AppFontStyle.footnote.weight(.semibold).themed)
                        .frame(width: 34, height: 34)
                        .modifier(ShelfGlass(shape: Capsule(), isCard: true))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("管理分组")
                .accessibilityIdentifier("sources.group.manage")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
        }
        .onChange(of: library.visibleGroups) { groups in
            if let selectedGroup, !selectedGroup.isEmpty, !groups.contains(selectedGroup) { self.selectedGroup = nil }
        }
    }

    private func groupChip(_ title: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).lineLimit(1)
                Text("\(count)").foregroundStyle(selected ? ReadingTheme.onAccent.opacity(0.8) : .secondary)
            }
            .font(AppFontStyle.footnote.weight(selected ? .semibold : .regular).themed)
            .foregroundStyle(selected ? ReadingTheme.onAccent : ReadingTheme.ink)
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background {
                if selected {
                    Capsule().fill(ReadingTheme.accent)
                } else {
                    ThemeSurface(shape: Capsule(), isCard: true)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func presentFileImporter() {
        pickedImportFiles = []
        importPickerHasDismissed = false
        showsImporter = true
    }

    private func previewPickedFilesWhenReady() {
        // Import-copy mode can dismiss before returning URLs. Other providers
        // return URLs first, so wait for both events instead of assuming order.
        guard importPickerHasDismissed, !pickedImportFiles.isEmpty else { return }
        let files = pickedImportFiles
        pickedImportFiles = []
        Task { await library.previewPickedFiles(files) }
    }
}

private struct SourceFileImportPicker: UIViewControllerRepresentable {
    let onPick: @MainActor ([SourceImportFile]) -> Void
    let onCancel: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // Ask the provider to import copies, including JSON files whose provider
        // does not support opening documents in place. Multi-select gives Files
        // an explicit confirmation action for the selected files.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let parent: SourceFileImportPicker

        init(parent: SourceFileImportPicker) { self.parent = parent }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            // Hold the picker grants before dismissing, until the model has
            // finished its coordinated background reads.
            parent.onPick(urls.map { SourceImportFile(url: $0) })
        }
    }
}

private struct SourceTextImportView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: SourceLibraryModel
    @State private var mode = 0
    @State private var value = ""

    var body: some View {
        ReadingNavigationStack {
            Form {
                Picker("导入方式", selection: $mode) {
                    Text("URL").tag(0)
                    Text("粘贴 JSON").tag(1)
                }
                .pickerStyle(.segmented)

                Section(mode == 0 ? "书源 URL" : "书源 JSON") {
                    if mode == 0 {
                        TextField("https://example.com/sources.json", text: $value)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                    } else {
                        SyntaxCodeEditor(text: $value, language: .json)
                            .frame(minHeight: 220)
                    }
                }.readingRowBackground()
                Section {
                    Text("导入前可预览并选择书源。地址相同的书源将被替换。")
                        .font(AppFontStyle.footnote.themed).foregroundStyle(.secondary)
                }.readingRowBackground()
            }.readingThemedListBackground()
            .navigationTitle("导入书源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") {
                        let input = value
                        let selectedMode = mode
                        dismiss()
                        Task {
                            try? await Task.sleep(nanoseconds: 350_000_000)
                            if selectedMode == 0 { await library.previewRemoteURL(input) }
                            else { await library.previewText(input) }
                        }
                    }
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct SourceRow: View {
    let source: BookSource
    var showsToggle = true
    let onEnabledChanged: @MainActor @Sendable (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: source.enabled ? "network" : "network.slash")
                .font(AppFontStyle.system(size: 20).themed)
                .frame(width: 28)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(source.bookSourceName)
                    .font(AppFontStyle.body.themed)
                    .foregroundStyle(source.enabled ? Color.primary : .secondary)
                Text(source.groups.isEmpty ? (URL(string: source.bookSourceUrl)?.host ?? source.bookSourceUrl) : source.groups.joined(separator: " · "))
                    .font(AppFontStyle.caption.themed)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if showsToggle {
                Toggle("启用", isOn: Binding(
                    get: { source.enabled },
                    set: { enabled in
                        Task { @MainActor in onEnabledChanged(enabled) }
                    }
                ))
                .labelsHidden()
                .tint(.green)
                .accessibilityLabel("启用\(source.bookSourceName)")
            }
        }
        .padding(.vertical, 5)
    }
}

private struct SourceGroupManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: SourceLibraryModel
    @State private var newGroup = ""
    @State private var renaming: String?
    @State private var renamedValue = ""
    @State private var pendingDelete: String?
    @FocusState private var newGroupFocused: Bool
    var focusesNewGroup = false

    var body: some View {
        ReadingNavigationStack {
            List {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "folder.badge.plus").foregroundStyle(ReadingTheme.accent)
                            .accessibilityHidden(true)
                        TextField("新分组名称，例如：书旗", text: $newGroup)
                            .focused($newGroupFocused)
                            .submitLabel(.done)
                            .onSubmit(create)
                        Button("创建", action: create)
                            .disabled(BookSource.parseGroups(newGroup).isEmpty)
                            .accessibilityIdentifier("sourceGroups.create")
                    }
                } header: {
                    Text("新建分组")
                } footer: {
                    Text("可以建立多个分组。创建后点进分组添加书源，或在书源列表长按书源选择「移到分组」。")
                }.readingRowBackground()
                Section {
                    if library.groups.isEmpty {
                        Text("还没有分组").foregroundStyle(.secondary)
                    }
                    ForEach(library.groups, id: \.self) { group in
                        HStack(spacing: 10) {
                            NavigationLink {
                                SourceGroupContentsView(group: group)
                            } label: {
                                HStack {
                                    Label(group, systemImage: library.hiddenGroups.contains(group) ? "folder" : "folder.fill")
                                        .foregroundStyle(library.hiddenGroups.contains(group) ? Color.secondary : Color.primary)
                                    Spacer()
                                    Text("\(library.sourceCount(inGroup: group)) 个书源")
                                        .font(AppFontStyle.footnote.themed)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Button {
                                library.setGroupHidden(group, hidden: !library.hiddenGroups.contains(group))
                            } label: {
                                Image(systemName: library.hiddenGroups.contains(group) ? "eye.slash" : "eye")
                                    .foregroundStyle(library.hiddenGroups.contains(group) ? Color.secondary : ReadingTheme.accent)
                                    .frame(width: 30, height: 30)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(library.hiddenGroups.contains(group) ? "显示\(group)分组" : "隐藏\(group)分组")
                            Menu {
                                Button {
                                    renaming = group
                                    renamedValue = group
                                } label: { Label("重命名", systemImage: "pencil") }
                                Button(role: .destructive) {
                                    pendingDelete = group
                                } label: { Label("删除分组", systemImage: "trash") }
                            } label: {
                                Image(systemName: "ellipsis.circle").frame(width: 30, height: 30)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("\(group)分组操作")
                        }
                    }
                } header: {
                    Text("已有分组")
                } footer: {
                    Text("点眼睛图标隐藏或显示分组：隐藏的分组不出现在书源页分组栏和搜索范围里，书源本身不受影响。")
                }.readingRowBackground()
            }.readingThemedListBackground()
            .listStyle(.insetGrouped)
            .navigationTitle("书源分组")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task {
                guard focusesNewGroup else { return }
                try? await Task.sleep(nanoseconds: 500_000_000)
                newGroupFocused = true
            }
            .alert("重命名分组", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("分组名称", text: $renamedValue)
                Button("取消", role: .cancel) { renaming = nil }
                Button("保存") {
                    if let old = renaming { Task { await library.renameGroup(old, to: renamedValue) } }
                    renaming = nil
                }
            }
            .alert("删除分组？", isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )) {
                Button("取消", role: .cancel) { pendingDelete = nil }
                Button("删除", role: .destructive) {
                    if let group = pendingDelete { Task { await library.deleteGroup(group) } }
                    pendingDelete = nil
                }
            } message: {
                Text("分组里的书源会变为未分组，书源本身不会删除。")
            }
        }
    }

    private func create() {
        let value = newGroup
        guard !BookSource.parseGroups(value).isEmpty else { return }
        newGroup = ""
        library.createGroup(value)
    }
}

private struct SourceGroupContentsView: View {
    @EnvironmentObject private var library: SourceLibraryModel
    let group: String
    @State private var showsPicker = false

    private var sources: [BookSource] {
        library.sources.filter { $0.hasGroup(group) }
    }

    var body: some View {
        List {
            Section {
                ForEach(sources) { source in
                    SourceRow(source: source) { enabled in
                        Task { await library.setEnabled(enabled, for: source.id) }
                    }
                    .swipeActions {
                        Button("移出") {
                            Task { await library.moveSources([source.id], toGroup: nil) }
                        }
                        .tint(.orange)
                    }
                }
                if sources.isEmpty {
                    Text("该分组暂无书源，点右上角「添加书源」把书源移进来。")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("\(sources.count) 个书源")
            } footer: {
                if !sources.isEmpty { Text("左滑书源可移出该分组。") }
            }.readingRowBackground()
        }.readingThemedListBackground()
        .listStyle(.insetGrouped)
        .readingScrollContentBackgroundHidden()
        .background(ReadingTheme.groupedCanvas)
        .navigationTitle(group)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showsPicker = true } label: {
                    Label("添加书源", systemImage: "plus")
                }
                .accessibilityIdentifier("sourceGroups.addSources")
            }
        }
        .sheet(isPresented: $showsPicker) {
            SourceGroupMemberPicker(group: group).environmentObject(library)
        }
    }
}

/// 多选书源放进某个分组。
private struct SourceGroupMemberPicker: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: SourceLibraryModel
    let group: String
    @State private var selected = Set<String>()
    @State private var query = ""

    private var candidates: [BookSource] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return library.sources.filter { source in
            !source.hasGroup(group) && (text.isEmpty
                || source.bookSourceName.localizedCaseInsensitiveContains(text)
                || source.bookSourceUrl.localizedCaseInsensitiveContains(text))
        }
    }

    var body: some View {
        ReadingNavigationStack {
            List {
                Section {
                    ForEach(candidates) { source in
                        Button {
                            if !selected.insert(source.id).inserted { selected.remove(source.id) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selected.contains(source.id) ? "checkmark.circle.fill" : "circle")
                                    .font(AppFontStyle.title3.themed)
                                    .foregroundStyle(selected.contains(source.id) ? ReadingTheme.accent : .secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(source.bookSourceName).foregroundStyle(.primary)
                                    Text(source.groups.first.map { "当前分组：\($0)" } ?? "未分组")
                                        .font(AppFontStyle.caption.themed).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if candidates.isEmpty {
                        Text("没有可添加的书源").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("选择要移到「\(group)」的书源")
                } footer: {
                    Text("每个书源只属于一个分组，已在其他分组的书源会移到这里。")
                }.readingRowBackground()
            }.readingThemedListBackground()
            .listStyle(.insetGrouped)
            .readingInlineSearch(text: $query, prompt: "筛选书源")
            .navigationTitle("添加书源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加 \(selected.count)") {
                        let ids = selected
                        Task {
                            await library.moveSources(ids, toGroup: group)
                            dismiss()
                        }
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
    }
}

/// 把选中的书源移到一个分组（或新建分组再移入）。
private struct SourceBatchGroupView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: SourceLibraryModel
    let sourceIDs: Set<String>
    @State private var customGroup = ""

    var body: some View {
        ReadingNavigationStack {
            List {
                Section {
                    HStack {
                        TextField("新分组名称", text: $customGroup)
                            .submitLabel(.done)
                            .onSubmit(moveToNewGroup)
                        Button("新建并移入", action: moveToNewGroup)
                            .disabled(BookSource.parseGroups(customGroup).isEmpty)
                    }
                } header: {
                    Text("已选择 \(sourceIDs.count) 个书源")
                }.readingRowBackground()
                Section("移到现有分组") {
                    if library.groups.isEmpty {
                        Text("还没有分组，可在上方新建。").foregroundStyle(.secondary)
                    }
                    ForEach(library.groups, id: \.self) { group in
                        Button {
                            move(to: group)
                        } label: {
                            HStack {
                                Label(group, systemImage: "folder")
                                Spacer()
                                Text("\(library.sourceCount(inGroup: group))")
                                    .font(AppFontStyle.footnote.themed).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.readingRowBackground()
                Section {
                    Button(role: .destructive) { move(to: nil) } label: {
                        Label("移出分组（设为未分组）", systemImage: "folder.badge.minus")
                    }
                }.readingRowBackground()
            }.readingThemedListBackground()
            .listStyle(.insetGrouped)
            .navigationTitle("移到分组")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }

    private func moveToNewGroup() {
        guard !BookSource.parseGroups(customGroup).isEmpty else { return }
        move(to: customGroup)
    }

    private func move(to group: String?) {
        let ids = sourceIDs
        Task {
            await library.moveSources(ids, toGroup: group)
            dismiss()
        }
    }
}

private struct SourceDetailView: View {
    @EnvironmentObject private var library: SourceLibraryModel
    let source: BookSource
    @State private var showsEditor = false
    @State private var editedSourceID: String?
    private var current: BookSource { library.sources.first { $0.id == (editedSourceID ?? source.id) } ?? source }

    var body: some View {
        List {
            Section("基本信息") {
                ReadingLabeledContent("名称", value: current.bookSourceName)
                ReadingLabeledContent("地址", value: current.bookSourceUrl)
                ReadingLabeledContent("分组", value: current.bookSourceGroup ?? "未分组")
                ReadingLabeledContent("类型", value: String(current.bookSourceType))
            }.readingRowBackground()
            Section("能力") {
                CapabilityRow(title: "搜索", available: current.searchUrl?.isEmpty == false)
                CapabilityRow(title: "发现", available: current.exploreUrl?.isEmpty == false)
                CapabilityRow(title: "详情", available: current.ruleBookInfo != nil)
                CapabilityRow(title: "目录", available: current.ruleToc != nil)
                CapabilityRow(title: "正文", available: current.ruleContent != nil)
            }.readingRowBackground()
            Section("状态") {
                Toggle("启用书源", isOn: Binding(
                    get: { library.sources.first(where: { $0.id == current.id })?.enabled ?? current.enabled },
                    set: { value in Task { await library.setEnabled(value, for: current.id) } }
                ))
                Toggle("启用发现", isOn: Binding(
                    get: { library.sources.first(where: { $0.id == current.id })?.enabledExplore ?? current.enabledExplore },
                    set: { value in Task { await library.setExploreEnabled(value, for: current.id) } }
                ))
            }.readingRowBackground()
            Section("兼容检查") {
                NavigationLink {
                    SearchView(fixedSource: current)
                } label: {
                    Label("搜索此书源", systemImage: "magnifyingglass")
                }
                NavigationLink {
                    SourceDebugView(source: current)
                } label: {
                    Label("运行端到端调试", systemImage: "stethoscope")
                }
                Text("使用你输入的关键词，逐步验证搜索、详情、目录和正文规则。")
                    .font(AppFontStyle.footnote.themed).foregroundStyle(.secondary)
            }.readingRowBackground()
            if current.loginUrl?.isEmpty == false {
                Section("账户") {
                    NavigationLink {
                        SourceLoginView(source: current)
                    } label: {
                        Label("登录此书源", systemImage: "person.badge.key.fill")
                    }
                    Text("登录 Cookie 与阅读请求共享；若书源提供检测脚本，会在页面载入后自动验证。")
                        .font(AppFontStyle.footnote.themed).foregroundStyle(.secondary)
                }.readingRowBackground()
            }
            if let comment = current.bookSourceComment, !comment.isEmpty {
                Section("说明") { Text(comment) }.readingRowBackground()
            }
        }.readingThemedListBackground()
        .navigationTitle(current.bookSourceName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("编辑") { showsEditor = true }
            }
        }
        .sheet(isPresented: $showsEditor) {
            SourceEditorView(source: current) { editedSourceID = $0.id }.environmentObject(library)
        }
    }
}

struct SourceImportReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: SourceLibraryModel
    let pending: SourceLibraryModel.PendingImport
    @State private var selectedIDs: Set<String>
    @State private var importError: String?
    @State private var isImporting = false
    @State private var keepOriginalName = false
    @State private var keepOriginalGroup = false
    @State private var keepOriginalEnabled = false
    @State private var showComments = false
    @State private var customGroup = ""
    @State private var addCustomGroup = true

    init(pending: SourceLibraryModel.PendingImport) {
        self.pending = pending
        _selectedIDs = State(initialValue: Set(pending.items.filter { $0.existing == nil || $0.state == "更新" }.map(\.id)))
    }

    var body: some View {
        ReadingNavigationStack {
            List {
                Section {
                    HStack(spacing: 10) {
                        importCountCard(
                            title: "有效",
                            count: pending.validCount,
                            color: .green,
                            systemImage: "checkmark.circle.fill"
                        )
                        importCountCard(
                            title: "失效",
                            count: pending.invalidCount,
                            color: .red,
                            systemImage: "xmark.circle.fill"
                        )
                        importCountCard(
                            title: "总计",
                            count: pending.totalCount,
                            color: .secondary,
                            systemImage: "doc.text.fill"
                        )
                    }
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))

                    Label("仅有效书源可被选择和导入", systemImage: "checkmark.shield.fill")
                        .font(AppFontStyle.footnote.themed)
                        .foregroundStyle(.secondary)
                }.readingRowBackground()

                if !pending.items.isEmpty {
                    Section {
                        TextField("放入分组（留空则用书源自带分组的第一个词）", text: $customGroup)
                        Toggle("保留原名称", isOn: $keepOriginalName)
                        Toggle("保留原分组", isOn: $keepOriginalGroup)
                        Toggle("保留原启用状态", isOn: $keepOriginalEnabled)
                        Toggle("显示书源备注", isOn: $showComments)
                    } header: {
                        Text("导入设置")
                    } footer: {
                        Text("书源自带多个分组标签时（如「书旗,小说,APP」），只建立第一个分组「书旗」。")
                    }.readingRowBackground()
                }

                Section("有效书源（\(pending.validCount)）") {
                    ForEach(pending.items) { item in
                        Button {
                            if !selectedIDs.insert(item.id).inserted { selectedIDs.remove(item.id) }
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: selectedIDs.contains(item.id) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(selectedIDs.contains(item.id) ? ReadingTheme.accent : .secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.source.bookSourceName).foregroundStyle(.primary)
                                    HStack {
                                        Text(item.state)
                                            .font(AppFontStyle.caption.bold().themed)
                                            .foregroundStyle(item.state == "新增" ? .green : item.state == "更新" ? .orange : .secondary)
                                        Text(item.source.bookSourceUrl)
                                            .font(AppFontStyle.caption.themed).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    if showComments, let comment = item.source.bookSourceComment, !comment.isEmpty {
                                        Text(comment).font(AppFontStyle.caption.themed).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }.readingRowBackground()

                if !pending.invalidItems.isEmpty {
                    Section("失效书源（\(pending.invalidCount)）") {
                        ForEach(pending.invalidItems) { item in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.source.bookSourceName.isEmpty ? "未命名书源" : item.source.bookSourceName)
                                        .foregroundStyle(.primary)
                                    if !item.source.bookSourceUrl.isEmpty {
                                        Text(item.source.bookSourceUrl)
                                            .font(AppFontStyle.caption.themed)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Text(item.issues.map(\.message).joined(separator: "；"))
                                        .font(AppFontStyle.caption.themed)
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                    }.readingRowBackground()
                }
            }.readingThemedListBackground()
            .navigationTitle("书源导入预检")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        library.cancelPendingImport()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("选择") {
                        Button("全选") { selectedIDs = Set(pending.items.map(\.id)) }
                        Button("取消全选") { selectedIDs.removeAll() }
                        Button("仅选择新增") {
                            selectedIDs = Set(pending.items.filter { $0.existing == nil }.map(\.id))
                        }
                        Button("仅选择更新") {
                            selectedIDs = Set(pending.items.filter { $0.existing != nil }.map(\.id))
                        }
                    }
                    .disabled(pending.items.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") {
                        let ids = selectedIDs
                        isImporting = true
                        Task {
                            await library.commitPendingImport(
                                selectedIDs: ids,
                                keepOriginalName: keepOriginalName,
                                keepOriginalGroup: keepOriginalGroup,
                                keepOriginalEnabled: keepOriginalEnabled,
                                customGroup: customGroup.isEmpty ? nil : customGroup,
                                addCustomGroup: addCustomGroup
                            )
                            isImporting = false
                            if library.pendingImport == nil { dismiss() }
                            else {
                                let message = library.notice?.detail ?? "保存失败，请重试"
                                library.notice = nil
                                importError = message
                            }
                        }
                    }
                    .disabled(selectedIDs.isEmpty || isImporting)
                }
            }
        }
        .interactiveDismissDisabled()
        .alert("导入保存失败", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(importError ?? "") }
    }

    private func importCountCard(
        title: String,
        count: Int,
        color: Color,
        systemImage: String
    ) -> some View {
        VStack(spacing: 5) {
            Label(title, systemImage: systemImage)
                .font(AppFontStyle.caption.weight(.semibold).themed)
                .foregroundStyle(color)
            Text("\(count)")
                .font(AppFontStyle.title2.bold().themed)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct CapabilityRow: View {
    let title: String
    let available: Bool

    var body: some View {
        ReadingLabeledContent(title) {
            Image(systemName: available ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(available ? .green : .secondary)
                .accessibilityLabel(available ? "已配置" : "未配置")
        }
    }
}
