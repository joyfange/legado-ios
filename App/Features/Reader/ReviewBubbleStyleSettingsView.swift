import SwiftUI
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// 段评相关的显示偏好（不影响气泡绘制，单独存）。
enum BubblePreferences {
    /// 段评 / 插图页（Browser）默认全屏；关闭时半屏弹出、可上划展开。
    static let browserFullScreenKey = "reviewBrowserFullScreen"
    /// Browser 里从左边缘右滑：有上一页就后退，没有就关闭。
    static let edgeBackKey = "reviewBrowserEdgeBack"
    /// 轻点段评气泡时的触感反馈。
    static let hapticsKey = "reviewBubbleHaptics"

    static var hapticsEnabled: Bool { UserDefaults.standard.object(forKey: hapticsKey) as? Bool ?? true }
}

// MARK: - 气泡设置

/// 阅读设置 › 主题 › 气泡设置：气泡样式、显示偏好、管理、整体大小、文字大小、交互。
struct BubbleStyleSettingsView: View {
    @ObservedObject private var store = BubbleStyleStore.shared
    @ThemePalette private var palette
    @AppStorage(BubblePreferences.browserFullScreenKey) private var browserFullScreen = false
    @AppStorage(BubblePreferences.edgeBackKey) private var edgeBack = true
    @AppStorage(BubblePreferences.hapticsKey) private var haptics = true
    @State private var editing: BubbleEditorTarget?
    @State private var importing = false
    @State private var exportURL: URL?
    @State private var message: String?
    @State private var deleting: BubbleStyle?
    /// 拖动滑块时先改这里，松手再保存（样式里可能带图片，避免每一帧都写存档）。
    @State private var scaleDraft: Double?
    @State private var numberScaleDraft: Double?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                AppearanceGroup("气泡样式", prominent: true) { stylesCard }
                AppearanceGroup("显示偏好", prominent: true) {
                    AppearanceToggleRow(title: "优先使用自带气泡", isOn: Binding(
                        get: { store.preferSource },
                        set: { value in perform { try store.setPreferSource(value) } }
                    ))
                    AppearanceSegmentedCard(title: "Browser 默认显示", options: [(false, "半屏"), (true, "全屏")], selection: $browserFullScreen)
                    AppearanceToggleRow(title: "边缘返回", isOn: $edgeBack)
                }
                AppearanceGroup("管理", prominent: true) {
                    managementRow("新建样式", icon: "plus.circle") {
                        var style = BubbleStyle()
                        style.format = ""
                        editing = BubbleEditorTarget(style: style, isNew: true)
                    }
                    .accessibilityIdentifier("bubble.new")
                    managementRow("导入样式", icon: "square.and.arrow.down") { importing = true }
                    managementRow("导出当前样式", icon: "square.and.arrow.up") { exportCurrent() }
                    if let message {
                        ReaderSettingsFootnote(text: message)
                    }
                }
                AppearanceGroup("整体大小", prominent: true) {
                    sliderCard("当前样式大小", value: scaleDraft ?? store.currentScale, range: BubbleStyleStore.scaleRange,
                               text: { String(format: "%.2f×", $0) }) { value, done in
                        scaleDraft = value
                        if done { perform { try store.setCurrentScale(value) }; scaleDraft = nil }
                    }
                    ReaderSettingsFootnote(text: "这里做当前样式的整体大小微调：宽高比仍在样式编辑器里设置。")
                }
                AppearanceGroup("文字大小", prominent: true) {
                    sliderCard("数字字号比例", value: numberScaleDraft ?? store.numberScale, range: BubbleStyleStore.numberScaleRange,
                               text: { "\(Int(($0 * 100).rounded()))%" }) { value, done in
                        numberScaleDraft = value
                        if done { perform { try store.setNumberScale(value) }; numberScaleDraft = nil }
                    }
                }
                AppearanceGroup("交互", prominent: true) {
                    AppearanceToggleRow(title: "触感反馈", isOn: $haptics)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 48)
        }
        .background { AppThemeCanvas().ignoresSafeArea() }
        .navigationTitle("气泡设置")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { target in
            BubbleStyleEditor(store: store, draft: target.style, isNew: target.isNew)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                guard data.count <= 20_000_000 else { throw CocoaError(.fileReadTooLarge) }
                let count = try store.importStyles(data)
                message = "已导入 \(count) 个样式，并使用「\(store.selectedName)」"
            } catch {
                message = "导入失败：\(error.localizedDescription)"
            }
        }
        .sheet(isPresented: Binding(get: { exportURL != nil }, set: { if !$0 { exportURL = nil } })) {
            if let exportURL { AppearanceActivityView(items: [exportURL]) }
        }
        .alert("删除这个气泡样式？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除", role: .destructive) {
                if let deleting { perform { try store.delete(deleting.id) } }
                deleting = nil
            }
        } message: { Text("删除正在使用的样式后会恢复内置「气泡」。") }
    }

    // MARK: 气泡样式

    private var stylesCard: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(BubbleTemplate.all) { template in
                    let id = BubbleTemplate.builtinID(template.id)
                    styleTile(id: id, name: template.name, style: BubbleStyleStore.builtinStyle(template))
                }
                ForEach(store.styles) { style in
                    styleTile(id: style.id, name: style.name, style: style)
                        .contextMenu {
                            Button { editing = BubbleEditorTarget(style: style, isNew: false) } label: { Label("编辑", systemImage: "pencil") }
                            Button(role: .destructive) { deleting = style } label: { Label("删除", systemImage: "trash") }
                        }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { ThemeCardSurface(radius: 14) }
    }

    private func styleTile(id: String, name: String, style: BubbleStyle) -> some View {
        let selected = store.effectiveSelectedID == id
        var preview = style
        preview.scale = 1
        preview.aspect = min(max(style.aspect, 0.8), 1.25)
        let image = BubbleStyleRenderer.image(style: preview, label: "99", fontSize: 25, color: UIColor(palette.primary),
                                              numberScale: store.numberScale)
        return Button {
            if BubblePreferences.hapticsEnabled { UISelectionFeedbackGenerator().selectionChanged() }
            perform { try store.select(id) }
        } label: {
            VStack(spacing: 3) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 44, height: 32)
                Text(name)
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? palette.accent : palette.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: 62, height: 62)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(selected ? palette.accent.opacity(0.13) : palette.secondary.opacity(0.09))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(selected ? palette.accent : Color.clear, lineWidth: 1.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: 组件

    private func managementRow(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            AppearanceCard {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .font(.system(size: 18))
                        .foregroundStyle(palette.primary)
                        .frame(width: 24)
                    Text(title).font(AppFontStyle.body.themed).foregroundStyle(palette.primary)
                    Spacer(minLength: 0)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func sliderCard(_ title: String, value: Double, range: ClosedRange<Double>, text: @escaping (Double) -> String,
                            onChange: @escaping (Double, Bool) -> Void) -> some View {
        AppearanceCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(AppFontStyle.body.themed).foregroundStyle(palette.primary)
                    Spacer()
                    Text(text(value)).font(AppFontStyle.subheadline.themed.monospacedDigit()).foregroundStyle(palette.secondary)
                }
                BubbleSlider(value: value, range: range, onChange: onChange)
            }
        }
    }

    private func exportCurrent() {
        guard let data = store.exportCurrentData() else { message = "导出失败"; return }
        let name = store.selectedName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bubble-export-" + UUID().uuidString)
        let url = folder.appendingPathComponent("\(name).json")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            exportURL = url
            message = nil
        } catch {
            message = "导出失败：\(error.localizedDescription)"
        }
    }

    private func perform(_ work: () throws -> Void) {
        do { try work() } catch { message = error.localizedDescription }
    }
}

/// 拖动时实时回调，松手时再回调一次（done = true）。
private struct BubbleSlider: View {
    @ThemePalette private var palette
    let value: Double
    let range: ClosedRange<Double>
    let onChange: (Double, Bool) -> Void
    @State private var current: Double?

    var body: some View {
        Slider(value: Binding(get: { current ?? value }, set: { current = $0; onChange($0, false) }), in: range) { editing in
            if !editing, let current {
                onChange(current, true)
                self.current = nil
            }
        }
        .tint(palette.accent)
    }
}

struct BubbleEditorTarget: Identifiable {
    let style: BubbleStyle
    let isNew: Bool
    var id: String { style.id }
}

// MARK: - 新建 / 编辑气泡

struct BubbleStyleEditor: View {
    @ObservedObject var store: BubbleStyleStore
    @State var draft: BubbleStyle
    let isNew: Bool
    @Environment(\.dismiss) private var dismiss
    @ThemePalette private var palette
    @State private var picksImage = false
    @State private var error: String?
    @State private var copiedToken = false

    private var warning: String? { BubbleStyleStore.validate(draft) }
    private var missingImage: Bool { draft.mode == "image" && draft.imageData == nil }

    private var customColor: Binding<Color> {
        Binding(get: { Color(uiColor: BubbleStyleRenderer.hex(draft.colorHex)) }, set: { value in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            if UIColor(value).getRed(&r, green: &g, blue: &b, alpha: &a) {
                // ColorPicker 可能给出扩展 sRGB（<0 或 >1），夹紧后才是合法的 #RRGGBB。
                func channel(_ v: CGFloat) -> Int { Int((min(max(v.isFinite ? v : 0, 0), 1) * 255).rounded()) }
                draft.colorHex = String(format: "#%02X%02X%02X", channel(r), channel(g), channel(b))
            }
        })
    }

    var body: some View {
        ReadingNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    summaryCard
                    section("样式名称") {
                        fieldCard {
                            TextField("自定义气泡", text: $draft.name)
                                .font(AppFontStyle.body.themed)
                                .accessibilityIdentifier("bubble.name")
                        }
                    }
                    section("创建方式") { modeCard }
                    switch draft.mode {
                    case "svg": section("SVG 代码") { svgCard }
                    case "image": section("背景图片") { imageCard }
                    default: section("模板") { templateCard }
                    }
                    section("文字与数字") { textCard }
                    section("尺寸") { sizeCard }
                    if missingImage {
                        warningCard("请先选择一张 PNG 或透明背景图片。")
                    } else if let warning, draft.mode != "svg" {
                        warningCard(warning)
                    }
                    if let error {
                        warningCard(error)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 48)
            }
            .background { AppThemeCanvas().ignoresSafeArea() }
            .navigationTitle(isNew ? "新建气泡" : "编辑气泡")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(warning != nil)
                        .accessibilityIdentifier("bubble.save")
                }
            }
        }
        .readingPhotoPicker(isPresented: $picksImage) { data in
            importImage(data)
        } onError: { error in
            self.error = error.localizedDescription
        }
        .onChange(of: draft.mode) { mode in
            // 切到 SVG 时先填入当前模板，直接在上面改。
            if mode == "svg", draft.svg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft.svg = BubbleTemplate.find(draft.template).svg
            }
        }
    }

    // MARK: 预览卡片

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(palette.secondary.opacity(0.1))
                    if missingImage || (draft.mode == "svg" && BubbleSVG.validate(draft.svg) != nil) {
                        Text("暂无预览").font(.system(size: 12)).foregroundStyle(palette.secondary)
                    } else {
                        Image(uiImage: previewImage)
                            .accessibilityLabel("气泡实时预览，评论数 42")
                            .accessibilityIdentifier("bubble.preview")
                    }
                }
                .frame(width: 104, height: 78)
                VStack(alignment: .leading, spacing: 5) {
                    Text(draft.name.isEmpty ? "自定义气泡" : draft.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(palette.primary)
                        .lineLimit(1)
                    Text("\(draft.modeTitle) · 宽高比 \(String(format: "%.2f", draft.aspect))× · 显示 \(draft.showNumber ? draft.label("42") : "无")")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.secondary)
                        .lineLimit(1)
                    if draft.followText {
                        HStack(spacing: 14) {
                            Text("格式")
                            Text("文字颜色跟随正文")
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(palette.secondary)
                    } else {
                        HStack(spacing: 6) {
                            Circle().fill(Color(uiColor: BubbleStyleRenderer.hex(draft.colorHex))).frame(width: 8, height: 8)
                            Text("使用自定义文字颜色")
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(palette.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            if missingImage {
                Label("请先选择一张 PNG 或透明背景图片。", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.orange)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { ThemeCardSurface(radius: 16) }
    }

    /// 预览按实际的整体大小 / 宽高比绘制，放不下时整体缩小。
    private var previewImage: UIImage {
        let base = CGSize(width: 109.0 / 3 / 23 * draft.scale * draft.aspect, height: 85.0 / 3 / 23 * draft.scale)
        let fontSize = min(34, 92 / max(base.width, 0.01), 68 / max(base.height, 0.01))
        return BubbleStyleRenderer.image(style: draft, label: "42", fontSize: CGFloat(fontSize), color: UIColor(palette.primary),
                                         numberScale: store.numberScale)
    }

    // MARK: 创建方式

    private var modeCard: some View {
        fieldCard {
            VStack(alignment: .leading, spacing: 12) {
                Picker("创建方式", selection: $draft.mode) {
                    Text("模板").tag("template")
                    Text("SVG").tag("svg")
                    Text("图片").tag("image")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Divider()
                Text(modeHelp)
                    .font(.system(size: 13))
                    .foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var modeHelp: String {
        switch draft.mode {
        case "svg": "适合粘贴或手改 SVG，支持 __TEXT__ 占位符跟随文字颜色设置。"
        case "image": "把 PNG 包进 SVG 背景里，适合已有素材图。"
        default: "直接选模板最省事，后续再微调文字颜色和尺寸。"
        }
    }

    private var templateCard: some View {
        fieldCard {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10, alignment: .top), GridItem(.flexible(), spacing: 10, alignment: .top)],
                      alignment: .leading, spacing: 10) {
                ForEach(BubbleTemplate.all) { template in
                    let selected = draft.template == template.id
                    Button { draft.template = template.id } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 10) {
                                Image(systemName: template.icon)
                                    .font(.system(size: 18))
                                    .foregroundStyle(palette.primary)
                                Text(template.name)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(palette.primary)
                            }
                            Text(template.detail)
                                .font(.system(size: 12))
                                .foregroundStyle(palette.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(selected ? palette.accent.opacity(0.13) : Color.clear)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(selected ? palette.accent : Color.clear, lineWidth: 1.5)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    private var svgCard: some View {
        fieldCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("填入当前模板") { draft.svg = BubbleTemplate.find(draft.template).svg }
                        .font(.system(size: 13))
                        .foregroundStyle(palette.primary)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = "__TEXT__"
                        copiedToken = true
                    } label: {
                        Text(copiedToken ? "已复制 __TEXT__" : "TEXT").font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(palette.primary)
                    .accessibilityLabel("复制 __TEXT__ 占位符")
                }
                .buttonStyle(.plain)
                TextEditor(text: $draft.svg)
                    .font(.system(size: 13, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .frame(minHeight: 190)
                    .padding(4)
                    .readingScrollContentBackgroundHidden()
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(palette.secondary.opacity(0.2), lineWidth: 0.75)
                    }
                    .accessibilityIdentifier("bubble.svg")
                Text("在描边或填充里使用 TEXT，会跟随“文字颜色”设置；默认跟随正文颜色。")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let svgError = BubbleSVG.validate(draft.svg) {
                    Text(svgError).font(.system(size: 12)).foregroundStyle(Color.red)
                }
            }
        }
    }

    private var imageCard: some View {
        fieldCard {
            VStack(alignment: .leading, spacing: 10) {
                Button { picksImage = true } label: {
                    HStack(spacing: 10) {
                        if let data = draft.imageData, let image = UIImage(data: data) {
                            Image(uiImage: image).resizable().scaledToFit().frame(width: 30, height: 24)
                        } else {
                            Image(systemName: "photo.on.rectangle").font(.system(size: 19))
                        }
                        Text(draft.imageData == nil ? "从相册选择背景图" : "更换背景图")
                            .font(.system(size: 16, weight: .medium))
                    }
                    .foregroundStyle(palette.primary)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text("图片会自动缩小后嵌进 SVG。建议用透明 PNG，避免正文里显得过重。")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 文字与数字 / 尺寸

    private var textCard: some View {
        fieldCard {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $draft.showNumber) {
                    Text("显示评论数字").font(AppFontStyle.body.themed).foregroundStyle(palette.primary)
                }
                .tint(palette.accent)
                Divider()
                TextField("显示格式，可用 {n} 代表评论数", text: $draft.format)
                    .font(AppFontStyle.body.themed)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .accessibilityIdentifier("bubble.format")
                Divider()
                Picker("文字颜色", selection: $draft.followText) {
                    Text("跟随正文").tag(true)
                    Text("自定义").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if !draft.followText {
                    Divider()
                    HStack {
                        Text("自定义颜色").font(AppFontStyle.body.themed).foregroundStyle(palette.primary)
                        Spacer()
                        ColorPicker("自定义颜色", selection: customColor, supportsOpacity: false).labelsHidden()
                    }
                }
            }
        }
    }

    private var sizeCard: some View {
        fieldCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("整体大小").font(AppFontStyle.body.themed).foregroundStyle(palette.primary)
                    Spacer()
                    Text(String(format: "%.2f×", draft.scale)).font(AppFontStyle.subheadline.themed.monospacedDigit()).foregroundStyle(palette.secondary)
                }
                Slider(value: $draft.scale, in: BubbleStyleStore.scaleRange, step: 0.05).tint(palette.accent)
                    .accessibilityIdentifier("bubble.scale")
                HStack {
                    Text("宽高比").font(AppFontStyle.body.themed).foregroundStyle(palette.primary)
                    Spacer()
                    Text(String(format: "%.2f×", draft.aspect)).font(AppFontStyle.subheadline.themed.monospacedDigit()).foregroundStyle(palette.secondary)
                }
                Slider(value: $draft.aspect, in: BubbleStyleStore.aspectRange, step: 0.05).tint(palette.accent)
                Text("整体大小会等比例缩放宽高；宽高比只微调左右比例。")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 组件

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(palette.primary)
                .padding(.horizontal, 6)
            content()
        }
    }

    private func fieldCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { ThemeCardSurface(radius: 16) }
    }

    private func warningCard(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 14))
            .foregroundStyle(Color.orange)
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { ThemeCardSurface(radius: 16) }
    }

    private func importImage(_ data: Data) {
        guard data.count <= 20_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 512,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary),
              let png = UIImage(cgImage: image).pngData(), png.count <= 2_000_000 else {
            error = "图片无效或超过大小限制，请选择其他图片"
            return
        }
        draft.imageData = png
        error = nil
    }

    private func save() {
        do {
            var value = draft
            value.name = String(value.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
            try store.save(value)
            try store.select(value.id)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
