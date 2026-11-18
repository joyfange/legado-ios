import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - 外观主题（即时生效版）
//
// 参照用户提供的参考应用：「外观主题」是一个设置页，里面每一项改完立即生效，没有「新建主题 → 编辑 → 保存」流程。
// 页面里所有改动先作用在一份草稿上（页面本身马上按草稿渲染：背景、玻璃、卡片都实时变化），
// 关闭外观主题页时一次性保存并应用到整个应用；这样拖动滑块时不会反复重建整个应用，不卡。

@MainActor
final class AppearanceLiveModel: ObservableObject {
    static let shared = AppearanceLiveModel()
    @Published private(set) var draft: AppTheme
    @Published var message: String?
    private var dirty = false
    private var store: AppThemeStore { AppThemeStore.shared }

    private init() {
        draft = Self.editable(AppThemeStore.shared.selectedTheme)
    }

    /// 内置主题不能直接改：第一次修改时自动生成一份「我的外观」。
    private static func editable(_ theme: AppTheme) -> AppTheme {
        guard theme.isBuiltIn else { return theme }
        var value = theme
        value.id = UUID().uuidString.lowercased()
        value.name = String((theme.name + " · 我的外观").prefix(40))
        return value
    }

    var settings: ThemeCustomization { draft.customization ?? ThemeCustomization() }

    func resync() {
        draft = Self.editable(store.selectedTheme)
        dirty = false
    }

    func edit(_ change: (inout AppTheme) -> Void) {
        var value = draft
        if value.customization == nil { value.customization = ThemeCustomization() }
        change(&value)
        guard value != draft else { return }
        draft = value
        dirty = true
    }

    func custom(_ change: (inout ThemeCustomization) -> Void) {
        edit { theme in
            var value = theme.customization ?? ThemeCustomization()
            change(&value)
            theme.customization = value
        }
    }

    /// 保存并应用到整个应用。
    func commit() {
        guard dirty else { return }
        do {
            try store.saveLive(draft)
            dirty = false
        } catch {
            message = error.localizedDescription
        }
    }

    func switchTheme(to id: String) {
        commit()
        do { try store.apply(id: id) } catch { message = error.localizedDescription }
        resync()
    }

    func resetToDefault() {
        dirty = false
        do { try store.apply(id: AppTheme.defaultID) } catch { message = error.localizedDescription }
        resync()
    }

    func importTheme(from url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 256_000 else { throw CocoaError(.fileReadTooLarge) }
            var theme = try JSONDecoder().decode(AppTheme.self, from: data)
            theme.id = UUID().uuidString.lowercased()
            if theme.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { theme.name = "导入的主题" }
            // 其它设备上的图片不会随主题文件一起过来，清掉无效的图片引用。
            if var custom = theme.customization {
                let existing: (String?) -> String? = { id in
                    guard let id, ThemeAssetStore.shared.image(for: id) != nil else { return nil }
                    return id
                }
                custom.pageBackgroundImage = existing(custom.pageBackgroundImage)
                custom.darkPageBackgroundImage = existing(custom.darkPageBackgroundImage)
                custom.launchImage = existing(custom.launchImage)
                custom.darkLaunchImage = existing(custom.darkLaunchImage)
                custom.defaultCoverImage = existing(custom.defaultCoverImage)
                let icons = (custom.tabIcons ?? [:]).filter { !ThemeAssetStore.isValidID($0.value) }
                custom.tabIcons = icons.isEmpty ? nil : icons
                theme.customization = custom
            }
            commit()
            try store.saveLive(theme)
            resync()
            message = "已导入并使用“\(theme.name)”"
        } catch {
            message = "无法导入这个主题文件。"
        }
    }

    func exportURL() -> URL? {
        guard let data = try? JSONEncoder().encode(draft) else { return nil }
        let name = draft.name.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).json")
        do { try data.write(to: url, options: .atomic); return url } catch { return nil }
    }
}

/// 外观主题页的容器：草稿作为主题环境注入，页面实时按草稿渲染；关闭时保存。
struct AppearanceSettingsRoot: View {
    @ObservedObject private var model = AppearanceLiveModel.shared
    let close: () -> Void

    init(close: @escaping () -> Void) {
        self.close = close
    }

    var body: some View {
        ReadingNavigationStack {
            AppearanceSettingsView(close: {
                model.commit()
                close()
            })
        }
        .environment(\.appTheme, model.draft)
        .onAppear { model.resync() }
        .onDisappear { model.commit() }
    }
}

// MARK: - 首页

struct AppearanceSettingsView: View {
    @ObservedObject private var model = AppearanceLiveModel.shared
    @ObservedObject private var fonts = ReadingFontManager.shared
    @ThemePalette private var palette
    let close: () -> Void
    @State private var importing = false
    @State private var confirmReset = false
    @State private var exportURL: URL?

    private var settings: ThemeCustomization { model.settings }

    var body: some View {
        AppearancePage(title: "外观主题") {
            AppearanceGroup {
                link("主题切换", icon: "paintpalette", value: model.draft.name) { AppearanceThemeSwitchPage() }
            }
            AppearanceGroup {
                link("Tab 栏", icon: "rectangle.bottomthird.inset.filled",
                     value: settings.tabStyle == .icons ? "仅图标" : (settings.tabStyle == .text ? "仅文字" : "图标与文字")) {
                    AppearanceTabBarPage()
                }
                link("书架", icon: "books.vertical",
                     value: "\(settings.shelfColumns) 列 · \(Int(settings.coverWidth.rounded())) pt") { AppearanceShelfPage() }
                link("默认封面", icon: "book.closed",
                     value: settings.defaultCoverImage == nil ? "系统默认" : (settings.forceDefaultCover ? "强制使用" : "已设置")) {
                    AppearanceCoverPage()
                }
                link("启动图", icon: "photo.on.rectangle",
                     value: settings.launchImage == nil && settings.darkLaunchImage == nil ? "关" : "开") { AppearanceLaunchPage() }
            }
            AppearanceGroup {
                link("颜色与字体", icon: "paintbrush", value: ThemeEditorFonts.name(settings.fontPostScriptName, manager: fonts)) {
                    AppearanceColorsPage()
                }
                link("页面背景", icon: "photo", value: settings.hasPageBackground ? "图片"
                     : (model.draft.backgroundStyle == .gradient ? "渐变" : "纯色")) { AppearanceBackgroundPage() }
                link("界面效果", icon: "circle.lefthalf.filled", value: effectTitle) { AppearanceEffectPage() }
                link("卡片背景", icon: "rectangle.on.rectangle", value: settings.customCard ? "开启" : "关闭") {
                    AppearanceCardPage()
                }
            }
            AppearanceGroup {
                Button {
                    model.commit()
                    exportURL = model.exportURL()
                } label: { AppearanceRowLabel(title: "导出主题", icon: "square.and.arrow.up") }
                .buttonStyle(.plain)
                Button { importing = true } label: { AppearanceRowLabel(title: "导入主题", icon: "square.and.arrow.down") }
                    .buttonStyle(.plain)
                Button { confirmReset = true } label: { AppearanceRowLabel(title: "重置为默认", icon: "arrow.counterclockwise") }
                    .buttonStyle(.plain)
            }
            if let message = model.message {
                Text(message)
                    .font(AppFontStyle.footnote.themed)
                    .foregroundStyle(palette.secondary)
                    .padding(.horizontal, 6)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: close) {
                    Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                }
                .accessibilityLabel("返回")
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result { model.importTheme(from: url) }
        }
        .confirmationDialog("恢复为经典黑白主题？", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("重置为默认", role: .destructive) { model.resetToDefault() }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: Binding(get: { exportURL != nil }, set: { if !$0 { exportURL = nil } })) {
            if let exportURL { AppearanceActivityView(items: [exportURL]) }
        }
    }

    private var effectTitle: String {
        switch palette.interfaceEffect ?? .frosted {
        case .transparent: return "透明"
        case .frosted: return "毛玻璃"
        case .opaque: return "系统"
        }
    }

    private func link<D: View>(_ title: String, icon: String, value: String, @ViewBuilder destination: @escaping () -> D) -> some View {
        SwiftUI.NavigationLink {
            destination()
        } label: {
            AppearanceRowLabel(title: title, icon: icon, value: value, chevron: true)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 通用组件

struct AppearancePage<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) { content }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 48)
        }
        .background { AppThemeCanvas().ignoresSafeArea() }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 一组设置：每一项是一张独立的小卡片，组内间距小、组之间间距大（和参考应用一致）。
struct AppearanceGroup<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: Content
    @ThemePalette private var palette

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                Text(title).font(AppFontStyle.footnote.weight(.medium).themed)
                    .foregroundStyle(palette.secondary).padding(.leading, 6)
            }
            content
        }
    }
}

struct AppearanceCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .background { ThemeCardSurface(radius: 14) }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct AppearanceRowLabel: View {
    @ThemePalette private var palette
    let title: String
    var icon: String? = nil
    var value: String? = nil
    var chevron = false

    var body: some View {
        AppearanceCard {
            HStack(spacing: 12) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(palette.accent)
                        .frame(width: 24)
                }
                Text(title).font(AppFontStyle.body.themed).foregroundStyle(palette.primary)
                Spacer(minLength: 8)
                if let value {
                    Text(value).font(AppFontStyle.footnote.themed).foregroundStyle(palette.secondary).lineLimit(1)
                }
                if chevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.secondary.opacity(0.7))
                }
            }
        }
    }
}

struct AppearanceToggleRow: View {
    @ThemePalette private var palette
    let title: String
    @Binding var isOn: Bool
    var disabled = false

    var body: some View {
        AppearanceCard {
            Toggle(isOn: $isOn) {
                Text(title).font(AppFontStyle.body.themed).foregroundStyle(palette.primary)
            }
            .tint(palette.accent)
            .disabled(disabled)
        }
    }
}

struct AppearanceSliderRow: View {
    @ThemePalette private var palette
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    let format: (Double) -> String

    var body: some View {
        AppearanceCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(AppFontStyle.body.themed).foregroundStyle(palette.primary)
                    Spacer()
                    Text(format(value)).font(AppFontStyle.footnote.themed.monospacedDigit()).foregroundStyle(palette.secondary)
                }
                if let step {
                    Slider(value: $value, in: range, step: step).tint(palette.accent)
                } else {
                    Slider(value: $value, in: range).tint(palette.accent)
                }
            }
        }
    }

    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
}

struct AppearanceColorRow: View {
    @ThemePalette private var palette
    @Environment(\.colorScheme) private var scheme
    let title: String
    let hex: String
    let onChange: (String) -> Void

    var body: some View {
        AppearanceCard {
            HStack {
                Text(title).font(AppFontStyle.body.themed).foregroundStyle(palette.primary)
                Spacer()
                ColorPicker(title, selection: Binding(
                    get: { AppThemeColor.color(hex) },
                    set: { onChange(AppThemeColor.hex($0, scheme: scheme)) }
                ), supportsOpacity: false)
                .labelsHidden()
            }
        }
    }
}

/// 图片项：右侧「选择」菜单（从相册导入 / 从文件导入 / 移除），和参考应用一致。
struct AppearanceImageRow: View {
    @ThemePalette private var palette
    let title: String
    let imageID: String?
    var icon = false
    let onChange: (String?) -> Void
    @State private var photoPicker = false
    @State private var filePicker = false
    @State private var failure: String?

    var body: some View {
        AppearanceCard {
            HStack(spacing: 10) {
                Text(title).font(AppFontStyle.body.themed).foregroundStyle(palette.primary)
                Spacer()
                if let imageID, let image = ThemeAssetStore.shared.image(for: imageID) {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                Menu {
                    Button { photoPicker = true } label: { Label("从相册导入", systemImage: "photo.on.rectangle") }
                    Button { filePicker = true } label: { Label("从文件导入", systemImage: "folder") }
                    if imageID != nil {
                        Button(role: .destructive) { onChange(nil) } label: { Label("移除", systemImage: "trash") }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(imageID == nil ? "选择" : "更换")
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    }
                    .font(AppFontStyle.footnote.weight(.medium).themed)
                    .foregroundStyle(palette.accent)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(palette.accent.opacity(0.12), in: Capsule())
                }
            }
        }
        .sheet(isPresented: $photoPicker) {
            ThemePhotoPicker(onPick: { data in
                photoPicker = false
                store(data)
            }, onCancel: { photoPicker = false }, onFailure: { message in
                photoPicker = false
                failure = message
            })
            .ignoresSafeArea()
        }
        .sheet(isPresented: $filePicker) {
            ThemeImagePicker(onPick: { url in
                filePicker = false
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) { store(data) } else { failure = "无法读取这张图片。" }
            }, onCancel: { filePicker = false })
            .ignoresSafeArea()
        }
        .alert("图片导入失败", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func store(_ data: Data) {
        do {
            let id = icon ? try ThemeAssetStore.shared.importIconData(data) : try ThemeAssetStore.shared.importData(data)
            // 先解码进缓存，回到页面第一帧就能显示。
            _ = ThemeAssetStore.shared.image(for: id)
            onChange(id)
        } catch {
            failure = error.localizedDescription
        }
    }
}

struct AppearanceSegmented<Value: Hashable>: View {
    @ThemePalette private var palette
    let options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let selected = option.0 == selection
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { selection = option.0 }
                } label: {
                    Text(option.1)
                        .font(AppFontStyle.subheadline.weight(selected ? .semibold : .regular).themed)
                        .foregroundStyle(selected ? palette.onAccent : palette.primary)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background(selected ? palette.accent : Color.clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background { ThemeSurface(shape: Capsule()) }
    }
}

struct AppearanceActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - 主题切换

struct AppearanceThemeSwitchPage: View {
    @ObservedObject private var model = AppearanceLiveModel.shared
    @ObservedObject private var store = AppThemeStore.shared
    @ThemePalette private var palette

    var body: some View {
        AppearancePage(title: "主题切换") {
            AppearanceGroup("内置主题") {
                ForEach(AppTheme.templates) { theme in row(theme) }
            }
            if !store.customThemes.isEmpty {
                AppearanceGroup("我的主题") {
                    ForEach(store.customThemes) { theme in row(theme) }
                }
            }
        }
    }

    private func row(_ theme: AppTheme) -> some View {
        Button { model.switchTheme(to: theme.id) } label: {
            AppearanceCard {
                HStack(spacing: 12) {
                    HStack(spacing: -6) {
                        Circle().fill(AppThemeColor.color(theme.light.background)).frame(width: 22, height: 22)
                        Circle().fill(AppThemeColor.color(theme.light.accent)).frame(width: 22, height: 22)
                    }
                    .overlay(Capsule().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
                    Text(theme.name).font(AppFontStyle.body.themed).foregroundStyle(palette.primary)
                    Spacer()
                    if store.selectedID == theme.id {
                        Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(palette.accent)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tab 栏

struct AppearanceTabBarPage: View {
    @ObservedObject private var model = AppearanceLiveModel.shared
    @ThemePalette private var palette

    var body: some View {
        AppearancePage(title: "Tab 栏") {
            AppearanceGroup {
                AppearanceToggleRow(title: "显示标签文字", isOn: Binding(
                    get: { model.settings.tabStyle != .icons },
                    set: { on in model.custom { $0.tabStyle = on ? .iconsAndText : .icons } }
                ))
            }
            AppearanceGroup("图标") {
                ForEach(LibraryTab.displayOrder, id: \.rawValue) { tab in
                    iconRow(tab)
                }
            }
        }
    }

    private func iconRow(_ tab: LibraryTab) -> some View {
        let current = model.settings.tabIcons?[tab.key]
        return HStack(spacing: 0) {
            ThemeTabIconImage(tab: tab, theme: model.draft, size: 20)
                .foregroundStyle(palette.accent)
                .frame(width: 36)
            AppearanceImageRow(title: tab.title, imageID: current.flatMap { ThemeAssetStore.isValidID($0) ? $0 : nil },
                               icon: true) { id in
                model.custom { custom in
                    var icons = custom.tabIcons ?? [:]
                    icons[tab.key] = id
                    custom.tabIcons = icons.isEmpty ? nil : icons
                }
            }
        }
    }
}

// MARK: - 书架

struct AppearanceShelfPage: View {
    @ObservedObject private var model = AppearanceLiveModel.shared
    @ThemePalette private var palette
    @AppStorage(BookshelfShelfSettings.gridShowTitleKey) private var showsTitle = true
    @AppStorage(BookshelfShelfSettings.gridShowAuthorKey) private var showsAuthor = true
    @AppStorage(BookshelfShelfSettings.hideShelfBaseKey) private var hideShelfBase = true

    var body: some View {
        AppearancePage(title: "书架") {
            AppearanceGroup("列数") {
                AppearanceSegmented(options: (2...6).map { ($0, "\($0) 列") }, selection: Binding(
                    get: { model.settings.shelfColumns },
                    set: { value in model.custom { $0.shelfColumns = value } }
                ))
            }
            AppearanceGroup {
                AppearanceSliderRow(title: "卡片大小", value: Binding(
                    get: { model.settings.coverWidth },
                    set: { value in model.custom { $0.coverWidth = value.rounded() } }
                ), range: ThemeCustomization.coverWidthRange, step: 2) { "\(Int($0)) pt" }
                AppearanceToggleRow(title: "显示书名", isOn: $showsTitle)
                AppearanceToggleRow(title: "显示作者", isOn: $showsAuthor)
                AppearanceToggleRow(title: "显示书架层板", isOn: Binding(get: { !hideShelfBase }, set: { hideShelfBase = !$0 }))
            }
        }
    }
}

// MARK: - 默认封面

struct AppearanceCoverPage: View {
    @ObservedObject private var model = AppearanceLiveModel.shared
    @ThemePalette private var palette

    var body: some View {
        AppearancePage(title: "默认封面") {
            AppearanceGroup {
                AppearanceToggleRow(title: "强制使用默认封面", isOn: Binding(
                    get: { model.settings.forceDefaultCover },
                    set: { on in model.custom { $0.forceDefaultCover = on } }
                ), disabled: model.settings.defaultCoverImage == nil)
                AppearanceImageRow(title: "默认封面", imageID: model.settings.defaultCoverImage) { id in
                    model.custom {
                        $0.defaultCoverImage = id
                        if id == nil { $0.forceDefaultCover = false }
                    }
                }
            }
            Text(model.settings.defaultCoverImage == nil ? "暂无封面，点上方「选择」添加。没有封面的书会使用这张图。"
                 : "没有封面的书使用这张图；打开「强制使用」后所有书都用它。")
                .font(AppFontStyle.footnote.themed).foregroundStyle(palette.secondary).padding(.horizontal, 6)
        }
    }
}

// MARK: - 启动图

struct AppearanceLaunchPage: View {
    @ObservedObject private var model = AppearanceLiveModel.shared
    @ThemePalette private var palette

    private var hasImage: Bool { model.settings.launchImage != nil || model.settings.darkLaunchImage != nil }

    var body: some View {
        AppearancePage(title: "启动图") {
            AppearanceGroup {
                AppearanceToggleRow(title: "启用启动图", isOn: Binding(
                    get: { hasImage },
                    set: { on in if !on { model.custom { $0.launchImage = nil; $0.darkLaunchImage = nil } } }
                ), disabled: !hasImage)
            }
            AppearanceGroup {
                AppearanceImageRow(title: "亮色启动图", imageID: model.settings.launchImage) { id in
                    model.custom { $0.launchImage = id }
                }
                AppearanceImageRow(title: "深色启动图", imageID: model.settings.darkLaunchImage) { id in
                    model.custom { $0.darkLaunchImage = id }
                }
            }
            Text("未设置深色启动图时，深色模式使用亮色启动图。下次打开应用时生效。")
                .font(AppFontStyle.footnote.themed).foregroundStyle(palette.secondary).padding(.horizontal, 6)
        }
    }
}

// MARK: - 颜色与字体

struct AppearanceColorsPage: View {
    @ObservedObject private var model = AppearanceLiveModel.shared
    @ObservedObject private var fonts = ReadingFontManager.shared
    @ThemePalette private var palette

    private var theme: AppTheme { model.draft }

    var body: some View {
        AppearancePage(title: "颜色与字体") {
            AppearanceGroup("强调色") {
                AppearanceColorRow(title: "亮色强调色", hex: theme.light.accent) { hex in
                    model.edit {
                        let linked = $0.dark.accent == $0.light.accent
                        $0.light.accent = hex
                        if linked { $0.dark.accent = hex }
                    }
                }
                AppearanceToggleRow(title: "单独设置深色强调色", isOn: Binding(
                    get: { theme.dark.accent != theme.light.accent },
                    set: { on in model.edit { if !on { $0.dark.accent = $0.light.accent } else if $0.dark.accent == $0.light.accent {
                        $0.dark.accent = AppThemeColor.mix($0.light.accent, "FFFFFF", fraction: 0.35) } } }
                ))
                if theme.dark.accent != theme.light.accent {
                    AppearanceColorRow(title: "深色强调色", hex: theme.dark.accent) { hex in model.edit { $0.dark.accent = hex } }
                }
            }
            AppearanceGroup("文字") {
                AppearanceColorRow(title: "亮色主文字", hex: ink(dark: false).primary) { hex in model.edit { $0.light.primaryText = hex } }
                AppearanceColorRow(title: "亮色次级文字", hex: ink(dark: false).secondary) { hex in model.edit { $0.light.secondaryText = hex } }
                AppearanceColorRow(title: "深色主文字", hex: ink(dark: true).primary) { hex in model.edit { $0.dark.primaryText = hex } }
                AppearanceColorRow(title: "深色次级文字", hex: ink(dark: true).secondary) { hex in model.edit { $0.dark.secondaryText = hex } }
            }
            AppearanceGroup("字体") {
                Menu {
                    Button("系统默认") { model.custom { $0.fontPostScriptName = "" } }
                    ForEach(ThemeEditorFonts.choices(fonts)) { choice in
                        Button(choice.name) { model.custom { $0.fontPostScriptName = choice.id } }
                    }
                } label: {
                    AppearanceRowLabel(title: "字体", value: ThemeEditorFonts.name(model.settings.fontPostScriptName, manager: fonts),
                                       chevron: true)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func ink(dark: Bool) -> (primary: String, secondary: String, selection: String) {
        (dark ? theme.dark : theme.light).resolvedInk(style: theme.backgroundStyle)
    }
}

// MARK: - 页面背景

struct AppearanceBackgroundPage: View {
    @ObservedObject private var model = AppearanceLiveModel.shared
    @ThemePalette private var palette

    private var theme: AppTheme { model.draft }

    var body: some View {
        AppearancePage(title: "页面背景") {
            AppearanceGroup("颜色") {
                AppearanceColorRow(title: "亮色主色调", hex: theme.light.background) { hex in edit { $0.light.background = hex } }
                AppearanceColorRow(title: "亮色辅色调", hex: theme.light.backgroundEnd) { hex in edit { $0.light.backgroundEnd = hex } }
                AppearanceColorRow(title: "深色主色调", hex: theme.dark.background) { hex in edit { $0.dark.background = hex } }
                AppearanceColorRow(title: "深色辅色调", hex: theme.dark.backgroundEnd) { hex in edit { $0.dark.backgroundEnd = hex } }
            }
            AppearanceGroup("背景图") {
                AppearanceImageRow(title: "亮色背景图", imageID: model.settings.pageBackgroundImage) { id in
                    model.custom { $0.pageBackgroundImage = id }
                }
                AppearanceImageRow(title: "深色背景图", imageID: model.settings.darkPageBackgroundImage) { id in
                    model.custom { $0.darkPageBackgroundImage = id }
                }
                if model.settings.hasPageBackground {
                    AppearanceSliderRow(title: "不透明度", value: Binding(
                        get: { model.settings.backgroundImageOpacity },
                        set: { value in model.custom { $0.backgroundImageOpacity = value } }
                    ), range: 0...1, format: AppearanceSliderRow.percent)
                }
            }
            AppearanceGroup("背景预览") {
                ZStack {
                    AppThemeCanvas()
                    VStack(spacing: 4) {
                        Text("背景预览").font(AppFontStyle.subheadline.weight(.semibold).themed)
                        Text(model.settings.hasPageBackground ? "图片背景" : (theme.backgroundStyle == .gradient ? "渐变背景" : "纯色背景"))
                            .font(AppFontStyle.caption.themed)
                    }
                    .foregroundStyle(palette.primary)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background { ThemeCardSurface(radius: 12) }
                }
                .frame(height: 170)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(palette.border.opacity(0.4), lineWidth: 0.5))
            }
            Text("主色调与辅色调不同时为上下渐变；设置背景图后，四个页面与设置页都显示这张图。")
                .font(AppFontStyle.footnote.themed).foregroundStyle(palette.secondary).padding(.horizontal, 6)
        }
    }

    private func edit(_ change: @escaping (inout AppTheme) -> Void) {
        model.edit { theme in
            change(&theme)
            theme.backgroundStyle = theme.light.background != theme.light.backgroundEnd
                || theme.dark.background != theme.dark.backgroundEnd ? .gradient : .solid
        }
    }
}

// MARK: - 界面效果

struct AppearanceEffectPage: View {
    @ObservedObject private var model = AppearanceLiveModel.shared
    @ThemePalette private var palette
    @AppStorage(AppGlassMode.storageKey) private var glassEnabled = true

    private var effect: ThemeInterfaceEffect { model.settings.effect }

    var body: some View {
        AppearancePage(title: "界面效果") {
            AppearanceGroup {
                AppearanceToggleRow(title: "透明模式", isOn: Binding(
                    get: { effect == .transparent },
                    set: { on in model.custom { $0.effect = on ? .transparent : .opaque; $0.cardBackground = true } }
                ))
                if effect == .transparent { opacityRow }
                AppearanceToggleRow(title: "毛玻璃", isOn: Binding(
                    get: { effect == .frosted && glassEnabled },
                    set: { on in
                        if on { glassEnabled = true }
                        model.custom { $0.effect = on ? .frosted : .opaque; $0.cardBackground = true }
                    }
                ))
                if effect == .frosted && glassEnabled { opacityRow }
            }
            AppearanceGroup {
                AppearanceSliderRow(title: "光晕强度", value: Binding(
                    get: { model.settings.glowIntensity },
                    set: { value in model.custom { $0.glowIntensity = value } }
                ), range: 0...1, format: AppearanceSliderRow.percent)
            }
            Text("两个都关闭时使用系统实色卡片。不透明度越低，背景（图片）透出得越多。")
                .font(AppFontStyle.footnote.themed).foregroundStyle(palette.secondary).padding(.horizontal, 6)
        }
    }

    private var opacityRow: some View {
        AppearanceSliderRow(title: "不透明度", value: Binding(
            get: { model.settings.surfaceOpacity },
            set: { value in model.custom { $0.surfaceOpacity = value } }
        ), range: 0...1, format: AppearanceSliderRow.percent)
    }
}

// MARK: - 卡片背景

struct AppearanceCardPage: View {
    @ObservedObject private var model = AppearanceLiveModel.shared
    @ThemePalette private var palette
    @State private var dark = false

    private var swatch: AppThemeSwatches { dark ? model.draft.dark : model.draft.light }

    var body: some View {
        AppearancePage(title: "卡片背景") {
            AppearanceGroup {
                AppearanceToggleRow(title: "启用卡片背景", isOn: Binding(
                    get: { model.settings.customCard },
                    set: { on in model.custom { $0.customCard = on } }
                ))
            }
            AppearanceSegmented(options: [(false, "浅色模式"), (true, "深色模式")], selection: $dark)
            AppearanceGroup {
                AppearanceColorRow(title: "背景颜色", hex: swatch.surface) { hex in editSwatch { $0.surface = hex } }
                AppearanceSliderRow(title: "背景透明度", value: Binding(
                    get: { model.settings.cardOpacity },
                    set: { value in model.custom { $0.cardOpacity = value } }
                ), range: 0...1, format: AppearanceSliderRow.percent)
                AppearanceColorRow(title: "边框颜色", hex: swatch.border ?? AppThemeColor.mix(swatch.surface, "000000", fraction: 0.2)) { hex in
                    editSwatch { $0.border = hex }
                }
                AppearanceSliderRow(title: "边框透明度", value: Binding(
                    get: { model.settings.cardBorderOpacity },
                    set: { value in model.custom { $0.cardBorderOpacity = value } }
                ), range: 0...1, format: AppearanceSliderRow.percent)
                AppearanceSliderRow(title: "边框大小", value: Binding(
                    get: { model.settings.cardBorderWidth },
                    set: { value in model.custom { $0.cardBorderWidth = value } }
                ), range: 0...4, step: 0.1) { String(format: "%.1f pt", $0) }
                AppearanceSliderRow(title: "卡片圆角", value: Binding(
                    get: { swatch.cardRadius ?? AppTheme.defaultCardRadius },
                    set: { value in editSwatch { $0.cardRadius = value.rounded() } }
                ), range: AppTheme.cardRadiusRange, step: 1) { "\(Int($0)) pt" }
            }
            AppearanceGroup("卡片预览") {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(palette.accent.opacity(0.8))
                        .frame(width: 40, height: 56)
                        .overlay(Image(systemName: "book.closed.fill").foregroundStyle(palette.onAccent))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("书架列表卡片").font(AppFontStyle.subheadline.weight(.semibold).themed).foregroundStyle(palette.primary)
                        Text("最近阅读 · 第十二章").font(AppFontStyle.caption.themed).foregroundStyle(palette.secondary)
                    }
                    Spacer()
                }
                .padding(14)
                .background { ThemeCardSurface(radius: 14) }
            }
            Text(model.settings.customCard ? "卡片按这里的颜色、透明度和边框绘制。" : "关闭时卡片跟随「界面效果」（透明 / 毛玻璃 / 系统）。")
                .font(AppFontStyle.footnote.themed).foregroundStyle(palette.secondary).padding(.horizontal, 6)
        }
    }

    private func editSwatch(_ change: @escaping (inout AppThemeSwatches) -> Void) {
        let isDark = dark
        model.edit { theme in
            if isDark { change(&theme.dark) } else { change(&theme.light) }
        }
    }
}
