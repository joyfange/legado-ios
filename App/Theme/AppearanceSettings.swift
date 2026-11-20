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

    /// 「主题切换」：改所选配色 / 深色主题设置，并把配色写进亮 / 深色色板。
    func colorTheme(_ change: (inout ThemeCustomization) -> Void) {
        edit { theme in
            var value = theme.customization ?? ThemeCustomization()
            change(&value)
            theme.customization = value
            ThemeColorPreset.apply(value, to: &theme)
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
        // 重置为默认＝「系统」玻璃：全局玻璃总开关一并恢复为开启，否则卡片仍是实色。
        UserDefaults.standard.set(true, forKey: AppGlassMode.storageKey)
        do { try store.apply(id: AppTheme.defaultID) } catch { message = error.localizedDescription }
        resync()
    }

    /// 导入主题：支持带图片的主题包（导出主题生成的文件）和只有设置的旧版 JSON。
    func importTheme(from url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 120_000_000 else { throw CocoaError(.fileReadTooLarge) }
            var theme: AppTheme
            var packaged: [String: String] = [:]
            if let package = try? JSONDecoder().decode(ThemeExportPackage.self, from: data), package.format == ThemeExportPackage.formatID {
                theme = package.theme
                packaged = package.assets ?? [:]
            } else {
                theme = try JSONDecoder().decode(AppTheme.self, from: data)
            }
            theme.id = UUID().uuidString.lowercased()
            if theme.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { theme.name = "导入的主题" }
            if var custom = theme.customization {
                // 主题包里的图片重新保存到本机；本机已有的图片沿用；其它找不到的图片引用清掉。
                var mapped: [String: String] = [:]
                for id in custom.assetIDs {
                    if let encoded = packaged[id], let bytes = Data(base64Encoded: encoded) {
                        let newID: String?
                        if id.hasSuffix(".png") {
                            newID = try? ThemeAssetStore.shared.importIconData(bytes)
                        } else {
                            newID = try? ThemeAssetStore.shared.importData(bytes)
                        }
                        if let newID { mapped[id] = newID }
                    } else if ThemeAssetStore.shared.image(for: id) != nil {
                        mapped[id] = id
                    }
                }
                let lookup = mapped
                custom.remapAssets { lookup[$0] }
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

    /// 导出主题：设置 + 所有用到的图片（背景、封面、启动图、Tab 与工具栏图标、卡片背景图）打成一个文件。
    /// 导出的是当前正在使用的主题（先保存页面上未保存的改动）；主题名和文件名用用户看到的名字：
    /// 选了「主题切换」配色时是配色名（如「琥珀金」），而不是内置主题自动生成的「经典黑白 · 我的外观」。
    func exportURL() -> URL? {
        commit()
        var theme = dirty ? draft : store.selectedTheme
        theme.name = Self.displayName(of: theme)
        var assets: [String: String] = [:]
        for id in theme.assetIDs {
            if let data = ThemeAssetStore.shared.data(for: id) { assets[id] = data.base64EncodedString() }
        }
        let package = ThemeExportPackage(format: ThemeExportPackage.formatID, version: 2, theme: theme,
                                         assets: assets.isEmpty ? nil : assets)
        guard let data = try? JSONEncoder().encode(package) else { return nil }
        let name = theme.name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        // 每次导出放进单独的临时目录：同名旧文件不会被分享面板复用。
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("theme-export-" + UUID().uuidString)
        let url = folder.appendingPathComponent("\(name).json")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// 用户看到的主题名：所选配色名（单独设置深色时「亮 · 深」），否则主题名去掉自动加的「· 我的外观」。
    static func displayName(of theme: AppTheme) -> String {
        if let custom = theme.customization, let light = ThemeColorPreset.find(custom.colorThemeID, in: custom) {
            if custom.separateDarkTheme, let dark = ThemeColorPreset.find(custom.darkColorThemeID, in: custom), dark.id != light.id {
                return "\(light.name) · \(dark.name)"
            }
            return light.name
        }
        let name = theme.name.replacingOccurrences(of: " · 我的外观", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? theme.name : name
    }
}

/// 导出的主题文件：主题设置 + 图片（base64）。
struct ThemeExportPackage: Codable {
    static let formatID = "legado.ios.theme"
    var format: String
    var version: Int
    var theme: AppTheme
    var assets: [String: String]?
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
        .environment(\.themePageScope, .settings)
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
    @AppStorage(AppGlassMode.storageKey) private var glassEnabled = true

    private var settings: ThemeCustomization { model.settings }

    var body: some View {
        AppearancePage(title: "外观主题") {
            AppearanceGroup {
                link("主题切换", icon: "moon.circle", value: nil) { AppearanceThemeSwitchPage() }
            }
            AppearanceGroup {
                link("阅读界面", icon: "doc.text", value: settings.readerBarStyle.title) { AppearanceReaderPage() }
                link("Tab 栏", icon: "rectangle.bottomthird.inset.filled",
                     value: settings.tabStyle == .icons ? "仅图标" : (settings.tabStyle == .text ? "仅文字" : "图标与文字")) {
                    AppearanceTabBarPage()
                }
                link("书架", icon: "books.vertical",
                     value: "\(settings.shelfColumns) 列 · \(Int(settings.coverWidth.rounded())) pt") { AppearanceShelfPage() }
                link("默认封面", icon: "book.closed",
                     value: !settings.hasDefaultCover ? "系统默认" : (settings.forceDefaultCover ? "强制使用" : "已设置")) {
                    AppearanceCoverPage()
                }
                link("启动图", icon: "rectangle.portrait.on.rectangle.portrait",
                     value: settings.launchEnabled && (settings.launchImage != nil || settings.darkLaunchImage != nil) ? "开" : "关") {
                    AppearanceLaunchPage()
                }
            }
            AppearanceGroup {
                link("颜色与字体", icon: "paintpalette", value: ThemeEditorFonts.name(settings.fontPostScriptName, manager: fonts)) {
                    AppearanceColorsPage()
                }
                link("页面背景", icon: "photo.on.rectangle", value: backgroundTitle) { AppearanceBackgroundPage() }
                link("界面效果", icon: "circle.lefthalf.filled", value: effectTitle) { AppearanceEffectPage() }
                link("卡片背景", icon: "rectangle.stack", value: settings.customCard ? "开启" : "关闭") {
                    AppearanceCardPage()
                }
            }
            AppearanceGroup {
                Button {
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

    private var backgroundTitle: String {
        let count = ThemePageScope.allCases.filter { settings.pageBackground($0) != nil }.count
        return count == 0 ? "全局默认" : "\(count) 个页面单独设置"
    }

    private var effectTitle: String {
        switch settings.effect {
        case .transparent: return "透明"
        case .frosted: return glassEnabled ? "毛玻璃" : "系统"
        case .opaque: return "系统"
        }
    }

    private func link<D: View>(_ title: String, icon: String, value: String?, @ViewBuilder destination: @escaping () -> D) -> some View {
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
            VStack(alignment: .leading, spacing: 22) { content }
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
    var prominentTitle = false
    @ViewBuilder var content: Content
    @ThemePalette private var palette

    init(_ title: String? = nil, prominent: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.prominentTitle = prominent
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                if prominentTitle {
                    Text(title).font(AppFontStyle.headline.themed)
                        .foregroundStyle(palette.primary).padding(.leading, 4)
                } else {
                    Text(title).font(AppFontStyle.footnote.themed)
                        .foregroundStyle(palette.secondary).padding(.leading, 4)
                }
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
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
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
                        .font(.system(size: 19, weight: .regular))
                        .foregroundStyle(palette.accent)
                        .frame(width: 26)
                }
                Text(title).font(AppFontStyle.body.themed).foregroundStyle(palette.primary)
                Spacer(minLength: 8)
                if let value {
                    Text(value).font(AppFontStyle.subheadline.themed).foregroundStyle(palette.secondary).lineLimit(1)
                }
                if chevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.secondary.opacity(0.7))
                }
            }
        }
    }
}

struct AppearanceTextCard: View {
    @ThemePalette private var palette
    let text: String
    var icon: String? = nil
    var body: some View {
        AppearanceCard {
            HStack(spacing: 10) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 17)).foregroundStyle(palette.secondary)
                }
                Text(text).font(AppFontStyle.subheadline.themed).foregroundStyle(palette.secondary)
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
                    Text(format(value)).font(AppFontStyle.subheadline.themed.monospacedDigit()).foregroundStyle(palette.secondary)
                }
                AppearanceSlider(value: $value, range: range, step: step)
            }
        }
    }

    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
    static func points(_ value: Double) -> String { "\(Int(value.rounded())) pt" }
}

struct AppearanceSlider: View {
    @ThemePalette private var palette
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil

    var body: some View {
        if let step {
            Slider(value: $value, in: range, step: step).tint(palette.accent)
        } else {
            Slider(value: $value, in: range).tint(palette.accent)
        }
    }
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

/// 右侧「值 ⇕」的选择行，点开是系统菜单（当前项打勾），和参考应用一致。
struct AppearancePickerRow<Value: Hashable>: View {
    @ThemePalette private var palette
    let title: String
    let options: [(Value, String)]
    @Binding var selection: Value

    private var currentTitle: String {
        options.first(where: { $0.0 == selection })?.1 ?? ""
    }

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(options.indices, id: \.self) { index in
                    Text(options[index].1).tag(options[index].0)
                }
            }
        } label: {
            AppearanceCard {
                HStack(spacing: 6) {
                    Text(title).font(AppFontStyle.body.themed).foregroundStyle(palette.primary)
                    Spacer(minLength: 8)
                    Text(currentTitle).font(AppFontStyle.body.themed).foregroundStyle(palette.primary).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.accent)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// 卡片里的系统分段控件（灰色轨道、白色选中块）。
struct AppearanceSegmentedCard<Value: Hashable>: View {
    @ThemePalette private var palette
    var title: String? = nil
    let options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        AppearanceCard {
            VStack(alignment: .leading, spacing: 10) {
                if let title {
                    Text(title).font(AppFontStyle.body.themed).foregroundStyle(palette.primary)
                }
                Picker(title ?? "", selection: $selection) {
                    ForEach(options.indices, id: \.self) { index in
                        Text(options[index].1).tag(options[index].0)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }
}

/// 「选择图片 ⌄」小胶囊：菜单里从相册 / 文件导入，已有图片时可移除。
struct AppearanceImageButton: View {
    @ThemePalette private var palette
    var title: String = "选择图片"
    let imageID: String?
    var icon = false
    let onChange: (String?) -> Void
    @State private var photoPicker = false
    @State private var filePicker = false
    @State private var failure: String?

    var body: some View {
        Menu {
            Button { photoPicker = true } label: { Label("从相册导入", systemImage: "photo.on.rectangle") }
            Button { filePicker = true } label: { Label("从文件导入", systemImage: "folder") }
            if imageID != nil {
                Button(role: .destructive) { onChange(nil) } label: { Label("移除", systemImage: "trash") }
            }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .font(AppFontStyle.caption.weight(.medium).themed)
            .foregroundStyle(palette.accent)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(palette.accent.opacity(0.12), in: Capsule())
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

/// 图片项：左侧标题（可带图标），右侧缩略图 +「选择 ⌄」。
struct AppearanceImageRow<Leading: View>: View {
    @ThemePalette private var palette
    let title: String
    var titleColor: Color? = nil
    var buttonTitle = "选择图片"
    let imageID: String?
    var icon = false
    @ViewBuilder var leading: Leading
    let onChange: (String?) -> Void

    var body: some View {
        AppearanceCard {
            HStack(spacing: 10) {
                leading
                Text(title).font(AppFontStyle.body.themed).foregroundStyle(titleColor ?? palette.primary)
                Spacer()
                if let imageID, let image = ThemeAssetStore.shared.image(for: imageID) {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                AppearanceImageButton(title: buttonTitle, imageID: imageID, icon: icon, onChange: onChange)
            }
        }
    }
}

extension AppearanceImageRow where Leading == EmptyView {
    init(title: String, titleColor: Color? = nil, buttonTitle: String = "选择", imageID: String?, icon: Bool = false,
         onChange: @escaping (String?) -> Void) {
        self.init(title: title, titleColor: titleColor, buttonTitle: buttonTitle, imageID: imageID, icon: icon,
                  leading: { EmptyView() }, onChange: onChange)
    }
}

/// 「暂无… / 已设置」说明卡 + 下面一张放「添加…图 ⌄」按钮的卡片（默认封面、启动图）。
struct AppearanceImageSlot: View {
    @ThemePalette private var palette
    let emptyText: String
    let filledText: String
    let addTitle: String
    let imageID: String?
    let onChange: (String?) -> Void

    var body: some View {
        AppearanceCard {
            HStack(spacing: 12) {
                if let imageID, let image = ThemeAssetStore.shared.image(for: imageID) {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: 44, height: 62)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text(filledText).font(AppFontStyle.subheadline.themed).foregroundStyle(palette.primary)
                } else {
                    Text(emptyText).font(AppFontStyle.subheadline.themed).foregroundStyle(palette.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        AppearanceCard {
            AppearanceImageButton(title: imageID == nil ? addTitle : addTitle.replacingOccurrences(of: "添加", with: "更换"),
                                  imageID: imageID, onChange: onChange)
        }
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

/// 参考视频：顶部一张卡片放配色色块（每行 4 个：海洋蓝、落日橙、森林绿、薰衣草、玫瑰粉、琥珀金 +「新建」），
/// 下面是「单独设置深色主题」「绑定阅读主题」两个开关。开启单独设置深色主题后，色块卡片上方出现
/// 「亮色主题 / 深色主题」分段控件（选择正在设置哪一套），两个开关之间多出「跟随系统」。
struct AppearanceThemeSwitchPage: View {
    @ObservedObject private var model = AppearanceLiveModel.shared
    @ThemePalette private var palette
    @AppStorage("themeMode") private var themeMode = "0"
    @State private var editingDark = false
    @State private var editor: ThemeColorPresetDraft?

    private var settings: ThemeCustomization { model.settings }
    private var slotIsDark: Bool { settings.separateDarkTheme && editingDark }
    private var selectedID: String? {
        slotIsDark ? (settings.darkColorThemeID ?? settings.colorThemeID) : settings.colorThemeID
    }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 4)

    var body: some View {
        AppearancePage(title: "主题切换") {
            AppearanceGroup {
                if settings.separateDarkTheme {
                    AppearanceSegmentedCard(options: [(false, "亮色主题"), (true, "深色主题")], selection: Binding(
                        get: { editingDark },
                        set: { dark in
                            editingDark = dark
                            if !settings.darkThemeFollowsSystem { themeMode = dark ? "2" : "1" }
                        }
                    ))
                }
                swatchCard
            }
            AppearanceGroup {
                AppearanceToggleRow(title: "单独设置深色主题", isOn: Binding(
                    get: { settings.separateDarkTheme },
                    set: { on in
                        let forced = !settings.darkThemeFollowsSystem
                        model.colorTheme { value in
                            value.separateDarkTheme = on
                            if on, value.darkColorThemeID == nil { value.darkColorThemeID = value.colorThemeID }
                        }
                        if on {
                            if forced { themeMode = editingDark ? "2" : "1" }
                        } else {
                            editingDark = false
                            if forced, themeMode == "1" || themeMode == "2" { themeMode = "0" }
                        }
                    }
                ))
                if settings.separateDarkTheme {
                    AppearanceToggleRow(title: "跟随系统", isOn: Binding(
                        get: { settings.darkThemeFollowsSystem },
                        set: { on in
                            model.colorTheme { $0.darkThemeFollowsSystem = on }
                            themeMode = on ? "0" : (editingDark ? "2" : "1")
                        }
                    ))
                }
                AppearanceToggleRow(title: "绑定阅读主题", isOn: Binding(
                    get: { settings.bindReaderTheme },
                    set: { on in model.colorTheme { $0.bindReaderTheme = on } }
                ))
            }
        }
        .sheet(item: $editor) { draft in
            ThemeColorPresetEditor(draft: draft) { preset in
                save(preset)
                editor = nil
            } onCancel: {
                editor = nil
            }
            .environment(\.appTheme, model.draft)
            .environment(\.themePageScope, .settings)
        }
    }

    private var swatchCard: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(ThemeColorPreset.all(settings)) { preset in
                tile(preset)
            }
            Button {
                editor = ThemeColorPresetDraft(preset: nil)
            } label: {
                ThemeColorPresetNewTile()
            }
            .buttonStyle(.plain)
            .disabled((settings.customColorThemes?.count ?? 0) >= ThemeColorPreset.maximumCustom)
            .accessibilityLabel("新建主题")
        }
        .padding(.horizontal, 14)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { ThemeCardSurface(radius: 20) }
    }

    @ViewBuilder
    private func tile(_ preset: ThemeColorPreset) -> some View {
        let selected = selectedID == preset.id
        let button = Button { select(preset.id) } label: {
            ThemeColorPresetTile(preset: preset, selected: selected, linked: settings.bindReaderTheme && selected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(preset.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        if preset.isCustom {
            // 自己新建的配色长按可编辑、删除。
            button.contextMenu {
                Button { editor = ThemeColorPresetDraft(preset: preset) } label: {
                    Label("编辑", systemImage: "pencil")
                }
                Button(role: .destructive) { delete(preset.id) } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        } else {
            button
        }
    }

    private func select(_ id: String) {
        let dark = slotIsDark
        model.colorTheme { value in
            if dark {
                value.darkColorThemeID = id
            } else {
                value.colorThemeID = id
                if !value.separateDarkTheme { value.darkColorThemeID = nil }
            }
        }
    }

    private func save(_ preset: ThemeColorPreset) {
        let dark = slotIsDark
        model.colorTheme { value in
            var list = value.customColorThemes ?? []
            if let index = list.firstIndex(where: { $0.id == preset.id }) {
                list[index] = preset
            } else {
                guard list.count < ThemeColorPreset.maximumCustom else { return }
                list.append(preset)
                if dark { value.darkColorThemeID = preset.id } else { value.colorThemeID = preset.id }
            }
            value.customColorThemes = list
        }
    }

    private func delete(_ id: String) {
        model.colorTheme { value in
            let list = (value.customColorThemes ?? []).filter { $0.id != id }
            value.customColorThemes = list.isEmpty ? nil : list
            // 删掉正在用的配色：颜色保留当前效果，只是不再标记选中。
            if value.colorThemeID == id { value.colorThemeID = nil }
            if value.darkColorThemeID == id { value.darkColorThemeID = nil }
        }
    }
}

/// 一个配色色块：浅色渐变底、强调色圆点 + 三条「文字」线，下面是名称；选中时强调色描边，
/// 绑定阅读主题时右上角显示链接角标。
struct ThemeColorPresetTile: View {
    @ThemePalette private var palette
    let preset: ThemeColorPreset
    let selected: Bool
    var linked = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                ThemeColorPresetPreview(preset: preset)
                    .overlay {
                        if selected {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(palette.accent, lineWidth: 2)
                        }
                    }
                if linked {
                    Image(systemName: "link")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 13, height: 13)
                        .background(Circle().fill(palette.accent))
                        .padding(4)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.18), value: linked)
            Text(preset.name)
                .font(.system(size: 11))
                .foregroundStyle(palette.primary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

/// 色块里的迷你预览。
struct ThemeColorPresetPreview: View {
    let preset: ThemeColorPreset

    var body: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(LinearGradient(colors: [AppThemeColor.color(preset.tileStart), AppThemeColor.color(preset.tileEnd)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(alignment: .leading) {
                HStack(spacing: 6) {
                    Circle().fill(AppThemeColor.color(preset.accent)).frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 2.6) {
                        Capsule().fill(Color(white: 0.07)).frame(width: 29, height: 2.6)
                        Capsule().fill(Color(white: 0.33)).frame(width: 22, height: 2.6)
                        Capsule().fill(Color(white: 0.55)).frame(width: 14, height: 2.6)
                    }
                }
                .padding(.leading, 7)
            }
            .frame(height: 39)
            .frame(maxWidth: .infinity)
    }
}

/// 「新建」色块：灰色半透明底 + 强调色「+」。
struct ThemeColorPresetNewTile: View {
    @ThemePalette private var palette
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(scheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.2))
                .overlay {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(palette.accent)
                }
                .frame(height: 39)
                .frame(maxWidth: .infinity)
            Text("新建")
                .font(.system(size: 11))
                .foregroundStyle(palette.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

/// 新建 / 编辑配色的草稿（sheet 用 Identifiable）。
struct ThemeColorPresetDraft: Identifiable {
    let id = UUID()
    let preset: ThemeColorPreset?
}

/// 新建 / 编辑自己的配色：名称、强调色、底色，深色版本自动推算。
struct ThemeColorPresetEditor: View {
    @ThemePalette private var palette
    let draft: ThemeColorPresetDraft
    let onSave: (ThemeColorPreset) -> Void
    let onCancel: () -> Void
    @State private var name: String
    @State private var accent: String
    @State private var background: String

    init(draft: ThemeColorPresetDraft, onSave: @escaping (ThemeColorPreset) -> Void, onCancel: @escaping () -> Void) {
        self.draft = draft
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: draft.preset?.name ?? "我的主题")
        _accent = State(initialValue: draft.preset?.accent ?? "007AFF")
        _background = State(initialValue: draft.preset?.tileStart ?? "DCEBF7")
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var preview: ThemeColorPreset {
        ThemeColorPreset.custom(name: trimmedName.isEmpty ? "我的主题" : String(trimmedName.prefix(20)),
                                accent: accent, background: background, id: draft.preset?.id)
    }

    var body: some View {
        ReadingNavigationStack {
            AppearancePage(title: draft.preset == nil ? "新建主题" : "编辑主题") {
                AppearanceGroup {
                    HStack {
                        Spacer()
                        ThemeColorPresetTile(preset: preview, selected: true)
                            .frame(width: 96)
                        Spacer()
                    }
                    .padding(.vertical, 18)
                    .background { ThemeCardSurface(radius: 22) }
                }
                AppearanceGroup {
                    AppearanceCard {
                        HStack(spacing: 12) {
                            Text("名称").font(AppFontStyle.body.themed).foregroundStyle(palette.primary)
                            TextField("主题名称", text: $name)
                                .multilineTextAlignment(.trailing)
                                .font(AppFontStyle.body.themed)
                                .foregroundStyle(palette.primary)
                        }
                    }
                    AppearanceColorRow(title: "强调色", hex: accent) { accent = $0 }
                    AppearanceColorRow(title: "背景色", hex: background) { background = $0 }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { onSave(preview) }
                        .disabled(trimmedName.isEmpty)
                }
            }
        }
    }
}

// MARK: - 阅读界面

struct AppearanceReaderPage: View {
    @ObservedObject private var model = AppearanceLiveModel.shared
    @ThemePalette private var palette

    var body: some View {
        AppearancePage(title: "阅读界面") {
            AppearanceGroup {
                AppearancePickerRow(title: "底栏样式", options: ThemeReaderBarStyle.allCases.map { ($0, $0.title) },
                                    selection: Binding(
                                        get: { model.settings.readerBarStyle },
                                        set: { value in model.custom { $0.readerBarStyle = value } }
                                    ))
            }
            AppearanceGroup {
                SwiftUI.NavigationLink {
                    AppearanceReaderToolbarPage()
                } label: {
                    AppearanceCard {
                        HStack(spacing: 8) {
                            Text("阅读工具栏图标").font(AppFontStyle.body.themed).foregroundStyle(palette.primary)
                            Spacer(minLength: 8)
                            ForEach(ThemeReaderToolbarItem.allCases) { item in
                                AppearanceToolbarIconPreview(item: item, dark: false, size: 13)
                            }
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(palette.secondary.opacity(0.7))
                                .padding(.leading, 4)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// 工具栏图标预览：选了图片显示图片，否则系统图标（强调色）。
struct AppearanceToolbarIconPreview: View {
    @ObservedObject private var model = AppearanceLiveModel.shared
    @ThemePalette private var palette
    let item: ThemeReaderToolbarItem
    let dark: Bool
    var size: CGFloat = 22

    var body: some View {
        if let id = model.settings.readerToolbarIcons?[item.key(dark: dark)], let image = ThemeAssetStore.shared.image(for: id) {
            Image(uiImage: image).resizable().scaledToFit().frame(width: size + 4, height: size + 4)
        } else {
            Image(systemName: item.symbol)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(palette.accent)
                .frame(minWidth: size + 4)
        }
    }
}

struct AppearanceReaderToolbarPage: View {
    @ObservedObject private var model = AppearanceLiveModel.shared
    @ThemePalette private var palette

    var body: some View {
        AppearancePage(title: "阅读工具栏图标") {
            AppearanceGroup {
                AppearanceCard {
                    HStack {
                        Text("图标大小").font(AppFontStyle.body.themed).foregroundStyle(palette.primary)
                        Spacer()
                        Text(AppearanceSliderRow.points(model.settings.readerToolbarIconSize))
                            .font(AppFontStyle.subheadline.themed.monospacedDigit()).foregroundStyle(palette.secondary)
                    }
                }
                AppearanceCard {
                    AppearanceSlider(value: Binding(
                        get: { model.settings.readerToolbarIconSize },
                        set: { value in model.custom { $0.readerToolbarIconSize = value.rounded() } }
                    ), range: 12...30, step: 1)
                }
                Text("调整阅读工具栏图标的显示大小，默认 17 pt")
                    .font(AppFontStyle.footnote.themed).foregroundStyle(palette.secondary).padding(.horizontal, 6)
            }
            ForEach(ThemeReaderToolbarItem.allCases) { item in
                AppearanceGroup(item.title, prominent: true) {
                    iconRow(item, dark: false)
                    iconRow(item, dark: true)
                }
            }
        }
    }

    private func iconRow(_ item: ThemeReaderToolbarItem, dark: Bool) -> some View {
        AppearanceImageRow(title: dark ? "深色" : "亮色", titleColor: dark ? palette.secondary : palette.primary,
                           buttonTitle: "选择图片", imageID: model.settings.readerToolbarIcons?[item.key(dark: dark)], icon: true,
                           leading: { AppearanceToolbarIconPreview(item: item, dark: dark) }) { id in
            model.custom { custom in
                var icons = custom.readerToolbarIcons ?? [:]
                icons[item.key(dark: dark)] = id
                custom.readerToolbarIcons = icons.isEmpty ? nil : icons
            }
        }
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
                AppearanceToggleRow(title: "经典底栏", isOn: Binding(
                    get: { model.settings.classicTabBar },
                    set: { on in model.custom { $0.classicTabBar = on } }
                ))
            }
            AppearanceGroup {
                AppearanceSliderRow(title: "图标大小", value: Binding(
                    get: { model.settings.tabIconSize },
                    set: { value in model.custom { $0.tabIconSize = value.rounded() } }
                ), range: 16...44, step: 1, format: AppearanceSliderRow.points)
            }
            ForEach(LibraryTab.displayOrder, id: \.rawValue) { tab in
                AppearanceGroup(tab.title) {
                    ForEach(ThemeTabIconState.allCases) { state in
                        iconRow(tab, state: state)
                    }
                }
            }
            // iOS 26 新版底栏：右侧独立的搜索圆钮、下滑收起。
            AppearanceGroup("搜索按钮") {
                AppearanceToggleRow(title: "显示搜索按钮", isOn: Binding(
                    get: { model.settings.showsSearchTab },
                    set: { on in model.custom { $0.showsSearchTab = on } }
                ))
                AppearanceToggleRow(title: "下滑时收起底栏", isOn: Binding(
                    get: { model.settings.tabBarMinimizesOnScroll },
                    set: { on in model.custom { $0.tabBarMinimizesOnScroll = on } }
                ))
                if model.settings.showsSearchTab {
                    ForEach(ThemeTabIconState.allCases) { state in
                        iconRow(.search, state: state)
                    }
                }
            }
        }
    }

    private func iconRow(_ tab: LibraryTab, state: ThemeTabIconState) -> some View {
        let key = tab.key + "." + state.rawValue
        return AppearanceImageRow(title: state.title,
                                  titleColor: state.isSelected ? palette.primary : palette.secondary,
                                  buttonTitle: "选择图片", imageID: model.settings.tabStateIcons?[key], icon: true,
                                  leading: {
                                      ThemeTabIconImage(tab: tab, theme: model.draft, size: 24, state: state)
                                          .font(.system(size: 21))
                                          .foregroundStyle(state.isSelected ? palette.accent : palette.primary)
                                          .frame(width: 30)
                                  }) { id in
            model.custom { custom in
                var icons = custom.tabStateIcons ?? [:]
                icons[key] = id
                custom.tabStateIcons = icons.isEmpty ? nil : icons
            }
        }
    }
}

// MARK: - 书架

struct AppearanceShelfPage: View {
    @ObservedObject private var model = AppearanceLiveModel.shared
    @ThemePalette private var palette

    var body: some View {
        AppearancePage(title: "书架设置") {
            AppearanceGroup {
                AppearancePickerRow(title: "顶部样式", options: ThemeShelfTopStyle.allCases.map { ($0, $0.title) },
                                    selection: Binding(
                                        get: { model.settings.shelfTopStyle },
                                        set: { value in model.custom { $0.shelfTopStyle = value } }
                                    ))
            }
            AppearanceGroup {
                AppearanceSegmentedCard(options: (2...6).map { ($0, "\($0) 列") }, selection: Binding(
                    get: { model.settings.shelfColumns },
                    set: { value in model.custom { $0.shelfColumns = value } }
                ))
            }
            AppearanceGroup {
                AppearanceSliderRow(title: "卡片大小", value: Binding(
                    get: { model.settings.coverWidth },
                    set: { value in model.custom { $0.coverWidth = value.rounded() } }
                ), range: ThemeCustomization.coverWidthRange, step: 2, format: AppearanceSliderRow.points)
            }
            AppearanceGroup {
                AppearanceToggleRow(title: "显示标签", isOn: Binding(
                    get: { model.settings.shelfShowTags },
                    set: { on in model.custom { $0.shelfShowTags = on } }
                ))
                AppearanceSegmentedCard(title: "文字颜色", options: ThemeTagColorStyle.allCases.map { ($0, $0.title) },
                                        selection: Binding(
                                            get: { model.settings.shelfTagColor },
                                            set: { value in model.custom { $0.shelfTagColor = value } }
                                        ))
                if model.settings.shelfTagColor == .custom {
                    AppearanceColorRow(title: "自定义颜色", hex: model.settings.shelfTagCustomColor) { hex in
                        model.custom { $0.shelfTagCustomColor = hex }
                    }
                }
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
                ))
                AppearanceSliderRow(title: "封面圆角", value: Binding(
                    get: { model.settings.coverCornerRadius },
                    set: { value in model.custom { $0.coverCornerRadius = value.rounded() } }
                ), range: 0...20, step: 1, format: AppearanceSliderRow.points)
                AppearanceToggleRow(title: "标签页启用默认封面", isOn: Binding(
                    get: { model.settings.defaultCoverInTabs },
                    set: { on in model.custom { $0.defaultCoverInTabs = on } }
                ))
            }
            AppearanceGroup {
                AppearanceImageSlot(emptyText: "暂无封面，点击下方按钮添加", filledText: "已设置封面",
                                    addTitle: "添加封面图", imageID: model.settings.defaultCoverImage) { id in
                    model.custom {
                        $0.defaultCoverImage = id
                        if id == nil, $0.darkDefaultCoverImage == nil { $0.forceDefaultCover = false }
                    }
                }
            }
            AppearanceGroup {
                AppearanceImageSlot(emptyText: "暂无深色封面，未设置时使用亮色封面", filledText: "已设置深色封面",
                                    addTitle: "添加深色封面图", imageID: model.settings.darkDefaultCoverImage) { id in
                    model.custom { $0.darkDefaultCoverImage = id }
                }
            }
        }
    }
}

// MARK: - 启动图

struct AppearanceLaunchPage: View {
    @ObservedObject private var model = AppearanceLiveModel.shared
    @ThemePalette private var palette

    var body: some View {
        AppearancePage(title: "启动图") {
            AppearanceGroup {
                AppearanceToggleRow(title: "启用启动图", isOn: Binding(
                    get: { model.settings.launchEnabled },
                    set: { on in model.custom { $0.launchEnabled = on } }
                ))
            }
            AppearanceGroup {
                AppearanceImageSlot(emptyText: "暂无启动图，点击下方按钮添加", filledText: "已设置启动图，下次打开应用时显示",
                                    addTitle: "添加启动图", imageID: model.settings.launchImage) { id in
                    model.custom { $0.launchImage = id }
                }
            }
            AppearanceGroup {
                AppearanceImageSlot(emptyText: "暂无深色启动图，未设置时使用浅色启动图", filledText: "已设置深色启动图",
                                    addTitle: "添加深色启动图", imageID: model.settings.darkLaunchImage) { id in
                    model.custom { $0.darkLaunchImage = id }
                }
            }
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
            AppearanceGroup {
                AppearanceColorRow(title: "亮色模式", hex: theme.light.accent) { hex in
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
                    AppearanceColorRow(title: "深色模式", hex: theme.dark.accent) { hex in model.edit { $0.dark.accent = hex } }
                }
            }
            AppearanceGroup {
                AppearanceColorRow(title: "亮色主文字", hex: ink(dark: false).primary) { hex in model.edit { $0.light.primaryText = hex } }
                AppearanceColorRow(title: "亮色次级文字", hex: ink(dark: false).secondary) { hex in model.edit { $0.light.secondaryText = hex } }
                AppearanceColorRow(title: "亮色弱文字", hex: theme.light.resolvedTertiary(style: theme.backgroundStyle)) { hex in
                    model.edit { $0.light.tertiaryText = hex }
                }
                AppearanceColorRow(title: "深色主文字", hex: ink(dark: true).primary) { hex in model.edit { $0.dark.primaryText = hex } }
                AppearanceColorRow(title: "深色次级文字", hex: ink(dark: true).secondary) { hex in model.edit { $0.dark.secondaryText = hex } }
                AppearanceColorRow(title: "深色弱文字", hex: theme.dark.resolvedTertiary(style: theme.backgroundStyle)) { hex in
                    model.edit { $0.dark.tertiaryText = hex }
                }
            }
            AppearanceGroup {
                AppearancePickerRow(title: "字体",
                                    options: [("", "系统默认")] + ThemeEditorFonts.choices(fonts).map { ($0.id, $0.name) },
                                    selection: Binding(
                                        get: { model.settings.fontPostScriptName ?? "" },
                                        set: { value in model.custom { $0.fontPostScriptName = value } }
                                    ))
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
    @Environment(\.colorScheme) private var scheme
    @State private var scope: ThemePageScope = .global

    private var theme: AppTheme { model.draft }
    private var page: ThemePageBackground { model.settings.pageBackgrounds?[scope.rawValue] ?? ThemePageBackground() }

    var body: some View {
        AppearancePage(title: "页面背景") {
            AppearanceGroup {
                AppearancePickerRow(title: "编辑范围", options: ThemePageScope.allCases.map { ($0, $0.title) }, selection: $scope)
            }
            AppearanceGroup {
                AppearanceColorRow(title: "亮色主色调", hex: page.lightBackground ?? theme.light.background) { hex in
                    setColor(hex, page: { $0.lightBackground = hex }, global: { $0.light.background = hex })
                }
                AppearanceColorRow(title: "亮色辅色调", hex: page.lightBackgroundEnd ?? theme.light.backgroundEnd) { hex in
                    setColor(hex, page: { $0.lightBackgroundEnd = hex }, global: { $0.light.backgroundEnd = hex })
                }
                AppearanceColorRow(title: "深色主色调", hex: page.darkBackground ?? theme.dark.background) { hex in
                    setColor(hex, page: { $0.darkBackground = hex }, global: { $0.dark.background = hex })
                }
                AppearanceColorRow(title: "深色辅色调", hex: page.darkBackgroundEnd ?? theme.dark.backgroundEnd) { hex in
                    setColor(hex, page: { $0.darkBackgroundEnd = hex }, global: { $0.dark.backgroundEnd = hex })
                }
            }
            AppearanceGroup {
                AppearanceImageRow(title: "亮色背景图", imageID: scope == .global ? model.settings.pageBackgroundImage : page.lightImage) { id in
                    setImage(id, dark: false)
                }
                AppearanceImageRow(title: "深色背景图", imageID: scope == .global ? model.settings.darkPageBackgroundImage : page.darkImage) { id in
                    setImage(id, dark: true)
                }
                if model.settings.hasPageBackground(scope: scope) {
                    AppearanceSliderRow(title: "不透明度", value: Binding(
                        get: { model.settings.backgroundImageOpacity },
                        set: { value in model.custom { $0.backgroundImageOpacity = value } }
                    ), range: 0...1, format: AppearanceSliderRow.percent)
                }
                if scope != .global, !page.isEmpty {
                    Button {
                        model.custom { custom in
                            var pages = custom.pageBackgrounds ?? [:]
                            pages[scope.rawValue] = nil
                            custom.pageBackgrounds = pages.isEmpty ? nil : pages
                        }
                    } label: {
                        AppearanceRowLabel(title: "恢复为全局默认", icon: "arrow.uturn.backward")
                    }
                    .buttonStyle(.plain)
                }
            }
            preview
        }
    }

    private var preview: some View {
        ZStack {
            AppThemeCanvas()
                .environment(\.themePageScope, scope)
            VStack(spacing: 5) {
                Text("背景预览").font(AppFontStyle.headline.themed).foregroundStyle(palette.primary)
                Text("\(scope.title) · \(scheme == .dark ? "深色模式" : "亮色模式")")
                    .font(AppFontStyle.subheadline.themed).foregroundStyle(palette.secondary)
                Text("弱文字样例").font(AppFontStyle.caption.themed).foregroundStyle(palette.tertiary)
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
            .background { ThemeCardSurface(radius: 14) }
        }
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(palette.border.opacity(0.4), lineWidth: 0.5))
    }

    private func setColor(_ hex: String, page change: @escaping (inout ThemePageBackground) -> Void,
                          global: @escaping (inout AppTheme) -> Void) {
        if scope == .global {
            model.edit { theme in
                global(&theme)
                theme.backgroundStyle = theme.light.background != theme.light.backgroundEnd
                    || theme.dark.background != theme.dark.backgroundEnd ? .gradient : .solid
            }
        } else {
            editPage(change)
        }
    }

    private func setImage(_ id: String?, dark: Bool) {
        if scope == .global {
            model.custom { if dark { $0.darkPageBackgroundImage = id } else { $0.pageBackgroundImage = id } }
        } else {
            editPage { if dark { $0.darkImage = id } else { $0.lightImage = id } }
        }
    }

    private func editPage(_ change: @escaping (inout ThemePageBackground) -> Void) {
        let key = scope.rawValue
        model.custom { custom in
            var pages = custom.pageBackgrounds ?? [:]
            var value = pages[key] ?? ThemePageBackground()
            change(&value)
            pages[key] = value.isEmpty ? nil : value
            custom.pageBackgrounds = pages.isEmpty ? nil : pages
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
                if effect == .transparent {
                    AppearanceSliderRow(title: "不透明度", value: Binding(
                        get: { model.settings.transparentOpacity },
                        set: { value in model.custom { $0.transparentOpacity = value } }
                    ), range: 0...1, format: AppearanceSliderRow.percent)
                }
                AppearanceToggleRow(title: "毛玻璃", isOn: Binding(
                    get: { effect == .frosted && glassEnabled },
                    set: { on in
                        if on { glassEnabled = true }
                        model.custom { $0.effect = on ? .frosted : .opaque; $0.cardBackground = true }
                    }
                ))
                if effect == .frosted && glassEnabled {
                    AppearanceSliderRow(title: "不透明度", value: Binding(
                        get: { model.settings.frostedOpacity },
                        set: { value in model.custom { $0.frostedOpacity = value } }
                    ), range: 0...1, format: AppearanceSliderRow.percent)
                }
                AppearanceToggleRow(title: "阅读半屏卡片跟随外观", isOn: Binding(
                    get: { model.settings.readerPanelFollowsTheme },
                    set: { on in model.custom { $0.readerPanelFollowsTheme = on } }
                ))
                AppearanceToggleRow(title: "进度条跟随外观", isOn: Binding(
                    get: { model.settings.progressBarFollowsTheme },
                    set: { on in model.custom { $0.progressBarFollowsTheme = on } }
                ))
            }
            AppearanceGroup {
                AppearanceSliderRow(title: "光晕强度", value: Binding(
                    get: { model.settings.glowIntensity },
                    set: { value in model.custom { $0.glowIntensity = value } }
                ), range: 0...1, format: AppearanceSliderRow.percent)
            }
        }
    }
}

// MARK: - 卡片背景

struct AppearanceCardPage: View {
    @ObservedObject private var model = AppearanceLiveModel.shared
    @ThemePalette private var palette
    @State private var dark = false

    private var swatch: AppThemeSwatches { dark ? model.draft.dark : model.draft.light }
    private var imageID: String? { dark ? model.settings.darkCardImage : model.settings.cardImage }

    var body: some View {
        AppearancePage(title: "卡片背景") {
            AppearanceGroup {
                AppearanceToggleRow(title: "启用卡片背景", isOn: Binding(
                    get: { model.settings.customCard },
                    set: { on in model.custom { $0.customCard = on } }
                ))
            }
            AppearanceGroup {
                AppearanceSegmentedCard(options: [(false, "浅色模式"), (true, "深色模式")], selection: $dark)
            }
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
                    set: { value in model.custom { $0.cardBorderWidth = (value * 10).rounded() / 10 } }
                ), range: 0...4, step: 0.1) { String(format: "%.1f pt", $0) }
                AppearanceSliderRow(title: "卡片圆角", value: Binding(
                    get: { swatch.cardRadius ?? 14 },
                    set: { value in editSwatch { $0.cardRadius = value.rounded() } }
                ), range: AppTheme.cardRadiusRange, step: 1, format: AppearanceSliderRow.points)
            }
            AppearanceGroup {
                AppearanceCard {
                    HStack(spacing: 12) {
                        if let imageID, let image = ThemeAssetStore.shared.image(for: imageID) {
                            Image(uiImage: image).resizable().scaledToFill()
                                .frame(width: 34, height: 34)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        } else {
                            Image(systemName: "photo").font(.system(size: 20)).foregroundStyle(palette.accent).frame(width: 34)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(dark ? "深色模式" : "浅色模式").font(AppFontStyle.body.themed).foregroundStyle(palette.primary)
                            Text(imageID == nil ? "未设置" : "已设置").font(AppFontStyle.footnote.themed).foregroundStyle(palette.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
                AppearanceCard {
                    AppearanceImageButton(title: imageID == nil ? "导入图片" : "更换图片", imageID: imageID) { id in
                        let isDark = dark
                        model.custom { if isDark { $0.darkCardImage = id } else { $0.cardImage = id } }
                    }
                }
                if imageID != nil {
                    AppearancePickerRow(title: "显示方式", options: ThemeCardImageMode.allCases.map { ($0, $0.title) },
                                        selection: Binding(
                                            get: { model.settings.cardImageMode },
                                            set: { value in model.custom { $0.cardImageMode = value } }
                                        ))
                } else {
                    AppearanceTextCard(text: "先导入图片后可以设置显示方式", icon: "photo.on.rectangle")
                }
            }
            AppearanceGroup {
                VStack(alignment: .leading, spacing: 10) {
                    Text("卡片预览").font(AppFontStyle.footnote.themed).foregroundStyle(palette.secondary)
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(palette.accent.opacity(0.85))
                            .frame(width: 44, height: 60)
                            .overlay(Image(systemName: "book.closed.fill").foregroundStyle(palette.onAccent))
                        VStack(alignment: .leading, spacing: 5) {
                            Text("书架列表卡片").font(AppFontStyle.subheadline.weight(.semibold).themed).foregroundStyle(palette.primary)
                            Text("最近阅读 · 第十二章 夜雨").font(AppFontStyle.caption.themed).foregroundStyle(palette.secondary)
                            HStack(spacing: 5) {
                                BookshelfTagChip(text: "置顶", index: 0)
                                BookshelfTagChip(text: "在线", index: 1)
                            }
                        }
                        Spacer()
                    }
                    .padding(14)
                    .background { ThemeCardSurface(radius: 14) }
                }
                .padding(14)
                .background { ThemeCardSurface(radius: 16) }
            }
        }
    }

    private func editSwatch(_ change: @escaping (inout AppThemeSwatches) -> Void) {
        let isDark = dark
        model.edit { theme in
            if isDark { change(&theme.dark) } else { change(&theme.light) }
        }
    }
}
