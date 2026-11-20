import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - 正则高亮：规则列表

/// 「正则高亮」页：总开关 → 统计 → 内置规则（常用引号，只能开关 / 改样式 / 复制）→ 自定义规则（可增删排序）。
/// 右上角「编辑」排序自定义规则，「⋯」里添加规则、导入 / 导出规则文件、恢复内置默认。
struct ReaderHighlightSettingsView: View {
    @ObservedObject private var store = ReaderHighlightStore.shared
    @ThemePalette private var palette
    @State private var editing: ReaderHighlightEditorTarget?
    @State private var editMode: EditMode = .inactive
    @State private var importing = false
    @State private var exportURL: URL?
    @State private var message: String?
    @State private var confirmsReset = false

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(get: { store.enabled }, set: { store.setEnabled($0) })) {
                    Text("启用正则高亮").font(AppFontStyle.body.themed)
                }
                .tint(palette.accent)
                .accessibilityIdentifier("highlight.enabled")
            } footer: {
                Text(store.enabled ? "开启后才会按下面的规则进行高亮。" : "当前已关闭，下面的规则只做配置，不会参与阅读页匹配。")
            }
            .readingRowBackground()

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 0) {
                        stat("已启用", store.enabledCount)
                        stat("内置", store.builtInRules.count)
                        stat("自定义", store.customRules.count)
                    }
                    Text("常用引号已经内置。平时只需要开关或改颜色；要做特殊高亮时，再新增自定义规则。")
                        .font(AppFontStyle.footnote.themed)
                        .foregroundStyle(palette.secondary)
                    if !store.enabled {
                        Label("全局开关关闭中", systemImage: "exclamationmark.circle")
                            .font(AppFontStyle.footnote.weight(.medium).themed)
                            .foregroundStyle(Color.orange)
                    }
                }
                .padding(.vertical, 4)
            }
            .readingRowBackground()

            Section {
                ForEach(store.builtInRules) { rule in
                    row(rule)
                }
            } header: {
                Text("内置规则")
            } footer: {
                Text("内置规则不能删除。需要改匹配方式时，直接复制一条为自定义规则再改。")
            }
            .readingRowBackground()

            Section {
                ForEach(store.customRules) { rule in
                    row(rule)
                }
                .onDelete { offsets in
                    let ids = offsets.map { store.customRules[$0].id }
                    for id in ids { store.delete(id) }
                }
                .onMove { source, destination in
                    store.moveCustom(from: source, to: destination)
                }
                Button {
                    editing = ReaderHighlightEditorTarget(rule: store.newCustomRule(), isNew: true)
                } label: {
                    Label("添加自定义规则", systemImage: "plus.circle.fill")
                        .font(AppFontStyle.body.themed)
                        .foregroundStyle(palette.accent)
                }
                .disabled(store.customRules.count >= ReaderHighlightStore.maximumCustom)
            } header: {
                Text("自定义规则")
            } footer: {
                Text("自定义规则排在内置规则之后，适合做更具体的覆盖高亮。左滑可删除，点右上角“编辑”可排序。")
            }
            .readingRowBackground()

            if let message {
                Section {
                    Text(message).font(AppFontStyle.footnote.themed).foregroundStyle(palette.secondary)
                }
                .readingRowBackground()
            }
        }
        .readingThemedListBackground()
        .environment(\.editMode, $editMode)
        .navigationTitle("正则高亮")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button(editMode == .active ? "完成" : "编辑") {
                    withAnimation { editMode = editMode == .active ? .inactive : .active }
                }
                .disabled(store.customRules.isEmpty && editMode != .active)
                Menu {
                    Button {
                        editing = ReaderHighlightEditorTarget(rule: store.newCustomRule(), isNew: true)
                    } label: { Label("添加自定义规则", systemImage: "plus") }
                    Button { importing = true } label: { Label("导入规则文件", systemImage: "square.and.arrow.down") }
                    Button { exportRules() } label: { Label("导出自定义规则", systemImage: "square.and.arrow.up") }
                        .disabled(store.customRules.isEmpty)
                    Button(role: .destructive) { confirmsReset = true } label: {
                        Label("恢复内置默认", systemImage: "arrow.counterclockwise")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("更多")
            }
        }
        .sheet(item: $editing) { target in
            ReaderHighlightRuleEditor(target: target) { saved in
                store.save(saved)
                editing = nil
            } onDuplicate: { rule in
                if store.duplicate(rule) != nil { message = "已复制为自定义规则「\(rule.name) 副本」" }
                editing = nil
            } onDelete: { id in
                store.delete(id)
                editing = nil
            } onResetBuiltIn: { id in
                store.resetBuiltIn(id)
                editing = nil
            } onCancel: {
                editing = nil
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let count = try store.importRules(data)
                message = count > 0 ? "已导入 \(count) 条规则" : "文件里没有可用的规则"
            } catch {
                message = "无法导入这个规则文件。"
            }
        }
        .confirmationDialog("恢复内置规则的默认设置？", isPresented: $confirmsReset, titleVisibility: .visible) {
            Button("恢复内置默认", role: .destructive) {
                store.resetAllBuiltIns()
                message = "内置规则已恢复默认"
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("内置规则的开关、颜色和样式恢复默认；自定义规则不受影响。")
        }
        .sheet(isPresented: Binding(get: { exportURL != nil }, set: { if !$0 { exportURL = nil } })) {
            if let exportURL { AppearanceActivityView(items: [exportURL]) }
        }
    }

    private func stat(_ title: String, _ value: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(palette.primary)
            Text(title)
                .font(AppFontStyle.caption.themed)
                .foregroundStyle(palette.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func row(_ rule: ReaderHighlightRule) -> some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { rule.enabled }, set: { store.setRuleEnabled(rule.id, $0) }))
                .labelsHidden()
                .tint(palette.accent)
                .accessibilityLabel("启用\(rule.name)")
            HStack(spacing: 10) {
                Circle()
                    .fill(Color(uiColor: UIColor(readerHex: rule.lightColor) ?? .systemOrange))
                    .frame(width: 12, height: 12)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(rule.name)
                            .font(AppFontStyle.body.themed)
                            .foregroundStyle(palette.primary)
                            .lineLimit(1)
                        if rule.builtIn {
                            Text("内置")
                                .font(AppFontStyle.caption2.weight(.medium).themed)
                                .foregroundStyle(palette.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(palette.accent.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(rule.pattern.isEmpty ? "（未填写正则）" : rule.pattern)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(palette.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
            .onTapGesture { editing = ReaderHighlightEditorTarget(rule: rule, isNew: false) }
            if rule.builtIn {
                Image(systemName: "lock.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondary.opacity(0.7))
                    .accessibilityLabel("内置规则")
            }
            Button {
                editing = ReaderHighlightEditorTarget(rule: rule, isNew: false)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.secondary.opacity(0.7))
                    .frame(width: 20, height: 30)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("编辑\(rule.name)")
        }
        .opacity(store.enabled ? 1 : 0.6)
        .deleteDisabled(rule.builtIn)
        .moveDisabled(rule.builtIn)
    }

    private func exportRules() {
        guard let data = store.exportData() else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("正则高亮规则.json")
        do {
            try data.write(to: url, options: .atomic)
            exportURL = url
        } catch {
            message = "导出失败：\(error.localizedDescription)"
        }
    }
}

struct ReaderHighlightEditorTarget: Identifiable {
    let rule: ReaderHighlightRule
    let isNew: Bool
    var id: String { rule.id }
}

// MARK: - 编辑规则

private struct ReaderHighlightRuleEditor: View {
    enum Tab: Int, CaseIterable {
        case basic, image, padding, css
        var title: String {
            switch self {
            case .basic: "基础"
            case .image: "背景图"
            case .padding: "边距"
            case .css: "CSS"
            }
        }
    }

    let target: ReaderHighlightEditorTarget
    let onSave: (ReaderHighlightRule) -> Void
    let onDuplicate: (ReaderHighlightRule) -> Void
    let onDelete: (String) -> Void
    let onResetBuiltIn: (String) -> Void
    let onCancel: () -> Void

    @ThemePalette private var palette
    @State private var draft: ReaderHighlightRule
    @State private var tab: Tab = .basic
    @State private var sample = "“这是第一句对白。”她轻声说。\n“第二句也应该被匹配。”"
    @State private var previewDark = false
    @State private var imageDark = false
    @State private var picksImage = false
    @State private var imageError: String?
    @State private var createdImages: Set<String> = []
    @State private var confirmsDelete = false

    init(target: ReaderHighlightEditorTarget, onSave: @escaping (ReaderHighlightRule) -> Void,
         onDuplicate: @escaping (ReaderHighlightRule) -> Void, onDelete: @escaping (String) -> Void,
         onResetBuiltIn: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.target = target
        self.onSave = onSave
        self.onDuplicate = onDuplicate
        self.onDelete = onDelete
        self.onResetBuiltIn = onResetBuiltIn
        self.onCancel = onCancel
        _draft = State(initialValue: target.rule)
        if let pair = target.rule.quotePair {
            _sample = State(initialValue: "\(pair.open)这是第一句对白。\(pair.close)她轻声说。\n\(pair.open)第二句也应该被匹配。\(pair.close)")
        }
    }

    private var canSave: Bool {
        draft.regexError == nil && !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ReadingNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    AppearanceSegmentedCard(options: Tab.allCases.map { ($0, $0.title) }, selection: $tab)
                    switch tab {
                    case .basic: basicTab
                    case .image: imageTab
                    case .padding: paddingTab
                    case .css: cssTab
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 48)
            }
            .background { AppThemeCanvas().ignoresSafeArea() }
            .navigationTitle("编辑规则")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        for name in createdImages { ReaderHighlightImageStore.remove(name) }
                        onCancel()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(!canSave)
                }
            }
        }
        .readingPhotoPicker(isPresented: $picksImage) { data in
            do {
                let name = try ReaderHighlightImageStore.save(data)
                createdImages.insert(name)
                if imageDark { draft.darkImage = name } else { draft.lightImage = name }
                imageError = nil
            } catch {
                imageError = error.localizedDescription
            }
        } onError: { error in
            imageError = error.localizedDescription
        }
        .confirmationDialog("删除这条规则？", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { onDelete(draft.id) }
            Button("取消", role: .cancel) {}
        }
    }

    private func save() {
        // 换掉 / 移除的旧图片删掉；本次新导入但没用上的也删掉。
        let used = Set([draft.lightImage, draft.darkImage].compactMap { $0 })
        for name in [target.rule.lightImage, target.rule.darkImage].compactMap({ $0 }) where !used.contains(name) {
            ReaderHighlightImageStore.remove(name)
        }
        for name in createdImages where !used.contains(name) { ReaderHighlightImageStore.remove(name) }
        var value = draft
        value.name = String(value.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30))
        onSave(value)
    }

    // MARK: 基础

    private var basicTab: some View {
        Group {
            AppearanceGroup("匹配模板", prominent: true) {
                AppearanceCard {
                    HStack {
                        Text("名称").font(AppFontStyle.body.themed).foregroundStyle(palette.primary)
                        Spacer(minLength: 12)
                        TextField("规则名称", text: $draft.name)
                            .multilineTextAlignment(.trailing)
                            .disabled(draft.builtIn)
                            .foregroundStyle(draft.builtIn ? palette.secondary : palette.primary)
                    }
                }
                AppearanceCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("正则").font(AppFontStyle.body.themed).foregroundStyle(palette.primary)
                        TextField("例如 “[^“”\\n]*”", text: $draft.pattern)
                            .font(.system(size: 15, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .disabled(draft.builtIn)
                            .foregroundStyle(draft.builtIn ? palette.secondary : palette.primary)
                        if let error = draft.regexError, !draft.builtIn {
                            Text(error).font(AppFontStyle.footnote.themed).foregroundStyle(Color.red)
                        }
                    }
                }
                if draft.builtIn {
                    ReaderSettingsFootnote(text: "内置规则的名称和正则模板固定。想改匹配方式时，复制成自定义规则再编辑。")
                }
            }
            AppearanceGroup("颜色", prominent: true) {
                colorRow("浅色模式", hex: $draft.lightColor)
                colorRow("深色模式", hex: $draft.darkColor)
                ReaderSettingsFootnote(text: "CSS 没写 color 时，命中的文字用这里的颜色。")
            }
            AppearanceGroup("字体", prominent: true) {
                fontMenu
                AppearanceToggleRow(title: "自定义字号", isOn: Binding(
                    get: { draft.fontSize != nil },
                    set: { draft.fontSize = $0 ? (draft.fontSize ?? 20) : nil }
                ))
                if let size = draft.fontSize {
                    AppearanceSliderRow(title: "字号", value: Binding(get: { size }, set: { draft.fontSize = $0 }),
                                        range: 10...40, step: 1) { "\(Int($0)) pt" }
                }
                AppearanceToggleRow(title: "自定义字重", isOn: Binding(
                    get: { draft.fontWeight != nil },
                    set: { draft.fontWeight = $0 ? (draft.fontWeight ?? 6) : nil }
                ))
                if let weight = draft.fontWeight {
                    AppearanceSliderRow(title: "字重", value: Binding(get: { Double(weight) }, set: { draft.fontWeight = Int($0.rounded()) }),
                                        range: 1...9, step: 1) { "\(Int($0) * 100)" }
                }
                ReaderSettingsFootnote(text: "默认跟随阅读字体、字号和字重；选择后只影响正则命中的文字。")
            }
            AppearanceGroup {
                AppearanceToggleRow(title: "匹配不跨段", isOn: $draft.noCrossParagraph)
                ReaderSettingsFootnote(text: "开启后单次匹配跨段时只高亮到段落末尾，避免高亮糊连多段。")
                if draft.quotePair != nil {
                    AppearanceToggleRow(title: "跨页补偿", isOn: $draft.pageCompensation)
                    ReaderSettingsFootnote(text: "引号类对话被分页、分章截断或原文漏了后引号时，从开引号一直高亮到段尾。")
                }
            }
            previewGroup
            actionsGroup
        }
    }

    private var fontMenu: some View {
        Menu {
            Button { draft.fontName = nil } label: {
                Label("跟随阅读字体", systemImage: draft.fontName == nil ? "checkmark" : "textformat")
            }
            ForEach(ReaderHighlighter.fontChoices.indices, id: \.self) { index in
                let choice = ReaderHighlighter.fontChoices[index]
                Button { draft.fontName = choice.id } label: {
                    Label(choice.title, systemImage: draft.fontName == choice.id ? "checkmark" : "textformat")
                }
            }
            ForEach(ReaderHighlighter.importedFonts(), id: \.self) { file in
                Button { draft.fontName = file } label: {
                    Label((file as NSString).deletingPathExtension, systemImage: draft.fontName == file ? "checkmark" : "textformat")
                }
            }
        } label: {
            AppearanceRowLabel(title: "字体", value: ReaderHighlighter.fontTitle(draft.fontName), chevron: true)
        }
        .buttonStyle(.plain)
    }

    private func colorRow(_ title: String, hex: Binding<String>) -> some View {
        AppearanceCard {
            HStack {
                Text(title).font(AppFontStyle.body.themed).foregroundStyle(palette.primary)
                Spacer()
                ColorPicker(title, selection: Binding(
                    get: { Color(uiColor: UIColor(readerHex: hex.wrappedValue) ?? .systemOrange) },
                    set: { hex.wrappedValue = UIColor($0).readerHex }
                ), supportsOpacity: false)
                .labelsHidden()
            }
        }
    }

    private var actionsGroup: some View {
        AppearanceGroup("操作", prominent: true) {
            if draft.builtIn {
                Button { onDuplicate(draft) } label: {
                    AppearanceRowLabel(title: "复制为自定义规则", icon: "doc.on.doc")
                }
                .buttonStyle(.plain)
                Button { onResetBuiltIn(draft.id) } label: {
                    AppearanceRowLabel(title: "恢复此内置规则默认值", icon: "arrow.counterclockwise")
                }
                .buttonStyle(.plain)
            } else if !target.isNew {
                Button { onDuplicate(draft) } label: {
                    AppearanceRowLabel(title: "复制一份规则", icon: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
                Button { confirmsDelete = true } label: {
                    AppearanceCard {
                        Label("删除这条规则", systemImage: "trash")
                            .font(AppFontStyle.body.themed)
                            .foregroundStyle(Color.red)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: 预览

    private var previewGroup: some View {
        AppearanceGroup("试一下", prominent: true) {
            AppearanceCard {
                TextEditor(text: $sample)
                    .font(.system(size: 16))
                    .frame(height: 70)
                    .readingScrollContentBackgroundHidden()
            }
            let result = previewText(dark: previewDark)
            AppearanceCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(result.fallback ? "正则\(draft.pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "为空" : "无效")，按 “…” 示意 \(result.count) 处" : "匹配到 \(result.count) 处")
                            .font(AppFontStyle.footnote.themed)
                            .foregroundStyle(palette.secondary)
                        Spacer()
                        Picker("预览", selection: $previewDark) {
                            Text("浅色").tag(false)
                            Text("深色").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 120)
                    }
                    ReaderHighlightPreview(text: result.text, background: previewColors(dark: previewDark).background)
                        .frame(height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            let warnings = ReaderHighlighter.css(previewDark ? (draft.darkCSS.isEmpty ? draft.lightCSS : draft.darkCSS) : draft.lightCSS).warnings
            if !warnings.isEmpty {
                ReaderSettingsFootnote(text: "已忽略：" + warnings.joined(separator: "；"))
            }
        }
    }

    private func previewColors(dark: Bool) -> (background: UIColor, foreground: UIColor) {
        dark ? (UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1), UIColor(white: 0.8, alpha: 1))
             : (UIColor(red: 0.98, green: 0.97, blue: 0.94, alpha: 1), UIColor(white: 0.12, alpha: 1))
    }

    /// 正则为空或无效时（例如刚新建的规则），预览先按中文双引号对话示意样式，CSS / 颜色 / 背景图改动立刻看得到。
    static let fallbackPreviewPattern = "“[^“”\\n]*”"

    private func previewText(dark: Bool) -> (text: NSAttributedString, count: Int, fallback: Bool) {
        let colors = previewColors(dark: dark)
        let font = UIFont(name: "STSongti-SC-Regular", size: 18) ?? UIFont.systemFont(ofSize: 18)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 6
        let text = NSMutableAttributedString(string: sample, attributes: [
            .font: font, .foregroundColor: colors.foreground, .paragraphStyle: paragraph
        ])
        var rule = draft
        rule.enabled = true
        let fallback = rule.regexError != nil
        if fallback { rule.pattern = Self.fallbackPreviewPattern }
        let count = ReaderHighlighter.apply(rules: [rule], to: text, in: NSRange(location: 0, length: text.length),
                                            foreground: colors.foreground, dark: dark)
        return (text, count, fallback)
    }

    // MARK: 背景图

    private var imageTab: some View {
        Group {
            AppearanceGroup("背景图", prominent: true) {
                AppearanceSegmentedCard(options: [(false, "浅色模式"), (true, "深色模式")], selection: $imageDark)
                let name = imageDark ? draft.darkImage : draft.lightImage
                AppearanceCard {
                    HStack(spacing: 12) {
                        if let image = ReaderHighlightImageStore.image(name) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 64, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        } else {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(palette.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4]))
                                .frame(width: 64, height: 44)
                                .overlay { Image(systemName: "photo").foregroundStyle(palette.secondary) }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(name == nil ? (imageDark && draft.lightImage != nil ? "沿用浅色图片" : "未设置") : "已设置")
                                .font(AppFontStyle.body.themed)
                                .foregroundStyle(palette.primary)
                            Text(imageDark ? "深色阅读主题下使用" : "浅色阅读主题下使用")
                                .font(AppFontStyle.caption.themed)
                                .foregroundStyle(palette.secondary)
                        }
                        Spacer()
                        Menu {
                            Button { picksImage = true } label: { Label("导入图片", systemImage: "photo.on.rectangle") }
                            if name != nil {
                                Button(role: .destructive) {
                                    if imageDark { draft.darkImage = nil } else { draft.lightImage = nil }
                                } label: { Label("移除", systemImage: "trash") }
                            }
                        } label: {
                            Text(name == nil ? "导入图片" : "更换")
                                .font(AppFontStyle.subheadline.weight(.medium).themed)
                                .foregroundStyle(palette.accent)
                        }
                    }
                }
                if let imageError {
                    ReaderSettingsFootnote(text: imageError)
                }
                ReaderSettingsFootnote(text: "图片画在命中文字的后面，盖在 CSS 背景之上，不影响分页；深色模式没设图片时沿用浅色图片。")
            }
            AppearanceGroup("9-Slice 拉伸", prominent: true) {
                AppearanceToggleRow(title: "9-Slice 拉伸", isOn: $draft.sliceEnabled)
                if draft.sliceEnabled {
                    AppearanceSliderRow(title: "上", value: $draft.sliceTop, range: 0...0.49, step: 0.01, format: AppearanceSliderRow.percent)
                    AppearanceSliderRow(title: "左", value: $draft.sliceLeft, range: 0...0.49, step: 0.01, format: AppearanceSliderRow.percent)
                    AppearanceSliderRow(title: "下", value: $draft.sliceBottom, range: 0...0.49, step: 0.01, format: AppearanceSliderRow.percent)
                    AppearanceSliderRow(title: "右", value: $draft.sliceRight, range: 0...0.49, step: 0.01, format: AppearanceSliderRow.percent)
                }
                if let image = ReaderHighlightImageStore.image(imageDark ? (draft.darkImage ?? draft.lightImage) : draft.lightImage) {
                    AppearanceCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("拉伸预览").font(AppFontStyle.footnote.themed).foregroundStyle(palette.secondary)
                            slicedPreview(image)
                                .frame(height: 40)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                ReaderSettingsFootnote(text: "开启后图片四边按比例保留、只拉伸中间，命中文字很长时边角不变形；关闭时整张图拉伸铺满。")
            }
            previewGroup
        }
    }

    @ViewBuilder
    private func slicedPreview(_ image: UIImage) -> some View {
        if draft.sliceEnabled {
            let size = image.size
            Image(uiImage: image)
                .resizable(capInsets: EdgeInsets(top: size.height * draft.sliceTop, leading: size.width * draft.sliceLeft,
                                                 bottom: size.height * draft.sliceBottom, trailing: size.width * draft.sliceRight),
                           resizingMode: .stretch)
        } else {
            Image(uiImage: image).resizable()
        }
    }

    // MARK: 边距

    private var paddingTab: some View {
        Group {
            AppearanceGroup("文字边距", prominent: true) {
                AppearanceSliderRow(title: "左右", value: $draft.paddingHorizontal, range: 0...12, step: 0.5) { String(format: "%.1f pt", $0) }
                AppearanceSliderRow(title: "上下", value: $draft.paddingVertical, range: 0...8, step: 0.5) { String(format: "%.1f pt", $0) }
                ReaderSettingsFootnote(text: "高亮背景（CSS 背景或背景图）比文字向外多出的距离；只改变背景外观，不影响分页。")
            }
            previewGroup
        }
    }

    // MARK: CSS

    private var cssTab: some View {
        Group {
            AppearanceGroup("CSS 预设", prominent: true) {
                ForEach(ReaderHighlightCSSPreset.all) { preset in
                    Button {
                        draft.lightCSS = preset.light
                        draft.darkCSS = preset.dark
                    } label: {
                        AppearanceCard {
                            HStack(spacing: 12) {
                                Image(systemName: preset.icon)
                                    .font(.system(size: 19))
                                    .foregroundStyle(palette.accent)
                                    .frame(width: 26)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preset.title).font(AppFontStyle.body.themed).foregroundStyle(palette.primary)
                                    Text(preset.subtitle).font(AppFontStyle.caption.themed).foregroundStyle(palette.secondary)
                                }
                                Spacer(minLength: 4)
                                if draft.lightCSS == preset.light && draft.darkCSS == preset.dark {
                                    Image(systemName: "checkmark").foregroundStyle(palette.accent)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                ReaderSettingsFootnote(text: "点选后会覆盖浅色 CSS 和深色 CSS。颜色选择器保留，仍作为 CSS 没写 color 时的 fallback。")
            }
            AppearanceGroup("高级 CSS", prominent: true) {
                cssEditor("浅色 CSS", text: $draft.lightCSS)
                cssEditor("深色 CSS", text: $draft.darkCSS)
                ReaderSettingsFootnote(text: Self.cssHelp)
            }
            previewGroup
        }
    }

    private func cssEditor(_ title: String, text: Binding<String>) -> some View {
        AppearanceCard {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(AppFontStyle.subheadline.themed).foregroundStyle(palette.secondary)
                TextEditor(text: text)
                    .font(.system(size: 15, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .frame(minHeight: 96)
                    .readingScrollContentBackgroundHidden()
            }
        }
    }

    private static let cssHelp = """
    支持声明列表或单个 block：color:#f60; / mark { color:#f60; }
    支持属性：color、background、background-color、border-radius、text-decoration、text-decoration-line、text-decoration-style、text-decoration-color。
    颜色写法：#RGB、#RGBA、#RRGGBB、#RRGGBBAA、rgb()、rgba()、transparent、currentColor。
    渐变写法：linear-gradient(90deg, #fff, #f60)；color 可做文字渐变，background/background-color 可做背景渐变。
    圆角写法：border-radius:999px 可得到椭圆背景；仅改变高亮背景外观，不影响分页。
    装饰写法：underline、line-through、none、solid、double、dotted、dashed、wavy；其它属性会忽略并在预览里提示。
    深色 CSS 留空时沿用浅色 CSS。
    """
}

// MARK: - 预览视图

/// 用正文同一个排版器画预览，圆角 / 渐变 / 背景图 / 波浪线和阅读页一模一样。
struct ReaderHighlightPreview: UIViewRepresentable {
    let text: NSAttributedString
    let background: UIColor

    func makeUIView(context: Context) -> ReaderHighlightPreviewCanvas { ReaderHighlightPreviewCanvas() }

    func updateUIView(_ view: ReaderHighlightPreviewCanvas, context: Context) {
        view.backgroundColor = background
        view.text = text
    }
}

final class ReaderHighlightPreviewCanvas: UIView {
    private let storage = NSTextStorage()
    private let manager = ReaderHighlightLayoutManager()
    private let container = NSTextContainer(size: .zero)

    var text: NSAttributedString = NSAttributedString() {
        didSet {
            storage.setAttributedString(text)
            setNeedsDisplay()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentMode = .redraw
        isOpaque = false
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = CGSize(width: max(bounds.width - 24, 1), height: .greatestFiniteMagnitude)
        if container.size != size {
            container.size = size
            setNeedsDisplay()
        }
    }

    override func draw(_ rect: CGRect) {
        let range = manager.glyphRange(for: container)
        let origin = CGPoint(x: 12, y: 12)
        manager.drawBackground(forGlyphRange: range, at: origin)
        manager.drawGlyphs(forGlyphRange: range, at: origin)
    }
}
