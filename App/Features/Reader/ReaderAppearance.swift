import CoreText
import ImageIO
import SwiftUI
import UIKit
import WebKit
#if SWIFT_PACKAGE
import LegadoCore
#endif

struct ReaderStylePreset: Identifiable {
    let id: String
    let name: String
    let background: UIColor
    let foreground: UIColor
    /// 用户新建的主题自己记录深浅；预设按 id 判断。
    var darkFlag: Bool? = nil

    static let legadoDefaults: [ReaderStylePreset] = [
        .init(id: "wechat", name: "微信读书", background: UIColor(hex: 0xC0EDC6), foreground: UIColor(hex: 0x0B0B0B)),
        .init(id: "preset1", name: "预设1", background: UIColor(hex: 0xFFFFFF), foreground: UIColor(hex: 0x000000)),
        .init(id: "preset2", name: "预设2", background: UIColor(hex: 0xDDC090), foreground: UIColor(hex: 0x3E3422)),
        .init(id: "preset3", name: "预设3", background: UIColor(hex: 0xC2D8AA), foreground: UIColor(hex: 0x596C44)),
        .init(id: "preset4", name: "预设4", background: UIColor(hex: 0xDBB8E2), foreground: UIColor(hex: 0x68516C)),
        .init(id: "preset5", name: "预设5", background: UIColor(hex: 0xABCEE0), foreground: UIColor(hex: 0x3D4C54)),
        .init(id: "warmWhite", name: "暖白", background: UIColor(hex: 0xFAF6EE), foreground: UIColor(hex: 0x37322B)),
        .init(id: "parchment", name: "羊皮纸", background: UIColor(hex: 0xF1E4C6), foreground: UIColor(hex: 0x4A3A22)),
        .init(id: "night", name: "夜间", background: UIColor(hex: 0x000000), foreground: UIColor(hex: 0xADADAD)),
        .init(id: "deepBlue", name: "深蓝", background: UIColor(hex: 0x111B2A), foreground: UIColor(hex: 0xA9B8CB)),
        .init(id: "inkGreen", name: "墨绿", background: UIColor(hex: 0x0F2018), foreground: UIColor(hex: 0xA8C4B2))
    ]

    /// 深色阅读主题（夜间、深蓝、墨绿、自定义深色）：阅读页的系统控件随之用深色外观。
    static let darkIDs: Set<String> = ["night", "deepBlue", "inkGreen", customDarkID]
    var isDark: Bool { darkFlag ?? Self.darkIDs.contains(id) }
    /// 某个主题 id 是否是深色主题（含用户新建的深色主题）。
    static func isDarkID(_ id: String) -> Bool {
        darkIDs.contains(id) || ReaderThemeLibrary.userTheme(id)?.dark == true
    }
    /// 内置预设（已套用用户改过的颜色）。
    static var lightPresets: [ReaderStylePreset] { legadoDefaults.filter { !$0.isDark }.map { resolve($0.id) } }
    static var darkPresets: [ReaderStylePreset] { legadoDefaults.filter(\.isDark).map { resolve($0.id) } }
    static let eInk = ReaderStylePreset(
        id: "eink",
        name: "E-Ink",
        background: UIColor(hex: 0xFFFFFF),
        foreground: UIColor(hex: 0x000000)
    )

    static func resolve(_ id: String) -> ReaderStylePreset {
        let migratedID = switch id {
        case "dark": "night"
        case "light": "preset1"
        case "paper": "preset2"
        default: id
        }
        if migratedID == customID { return custom() }
        if migratedID == customDarkID { return customDark() }
        if let entry = ReaderThemeLibrary.userTheme(migratedID) {
            return ReaderStylePreset(
                id: entry.id,
                name: entry.name,
                background: UIColor(readerHex: entry.backgroundHex) ?? (entry.dark ? .black : .white),
                foreground: UIColor(readerHex: entry.foregroundHex) ?? (entry.dark ? .lightGray : .black),
                darkFlag: entry.dark
            )
        }
        let base = legadoDefaults.first(where: { $0.id == migratedID }) ?? legadoDefaults[0]
        // 预设可以在阅读设置里直接改颜色（不再跳到「自定义」）。
        if let override = ReaderThemeLibrary.presetOverride(base.id) {
            return ReaderStylePreset(
                id: base.id,
                name: base.name,
                background: override.backgroundHex.flatMap { UIColor(readerHex: $0) } ?? base.background,
                foreground: override.foregroundHex.flatMap { UIColor(readerHex: $0) } ?? base.foreground
            )
        }
        return base
    }

    /// 内置预设的原始颜色（不含用户的修改）。
    static func original(_ id: String) -> ReaderStylePreset? {
        legadoDefaults.first { $0.id == id }
    }

    /// 外观主题「绑定阅读主题」开启时，阅读背景与文字跟随应用主题（亮 / 深色各自一套）；未开启返回 nil。
    /// 明暗取「显示模式」，跟随系统时读窗口场景的系统外观（不受阅读页自己设置的明暗影响）。
    @MainActor
    static func boundToAppTheme(themeMode: String) -> ReaderStylePreset? {
        let theme = AppThemeStore.shared.selectedTheme
        guard theme.customization?.bindReaderTheme == true else { return nil }
        let dark: Bool
        switch themeMode {
        case "2": dark = true
        case "1", "3": dark = false
        default:
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            dark = (scene?.traitCollection.userInterfaceStyle ?? .light) == .dark
        }
        let swatch = theme.swatches(for: dark ? .dark : .light)
        let ink = swatch.resolvedInk(style: theme.backgroundStyle)
        let background = AppThemeColor.mix(swatch.background, swatch.backgroundEnd, fraction: 0.5)
        return ReaderStylePreset(
            id: dark ? "night" : "appTheme",
            name: "跟随外观",
            background: UIColor(readerHex: background) ?? (dark ? .black : .white),
            foreground: UIColor(readerHex: ink.primary) ?? (dark ? .white : .black)
        )
    }

    static let customID = "custom"
    static let customBackgroundKey = "readerCustomBackgroundHex"
    static let customForegroundKey = "readerCustomForegroundHex"
    static let defaultCustomBackground = "F5EFDF"
    static let defaultCustomForeground = "2E2A24"

    /// User-defined background and text colours ("自定义").
    static func custom(defaults: UserDefaults = .standard) -> ReaderStylePreset {
        let background = UIColor(readerHex: defaults.string(forKey: customBackgroundKey) ?? "")
            ?? UIColor(readerHex: defaultCustomBackground)!
        let foreground = UIColor(readerHex: defaults.string(forKey: customForegroundKey) ?? "")
            ?? UIColor(readerHex: defaultCustomForeground)!
        return ReaderStylePreset(id: customID, name: "自定义", background: background, foreground: foreground)
    }

    // MARK: 自定义深色主题

    static let customDarkID = "customDark"
    static let customDarkBackgroundKey = "readerCustomDarkBackgroundHex"
    static let customDarkForegroundKey = "readerCustomDarkForegroundHex"
    static let defaultCustomDarkBackground = "1C1B19"
    static let defaultCustomDarkForeground = "B9B2A6"

    /// 深色一侧的「自定义」：与浅色的自定义各存一套文字 / 背景颜色和背景图。
    static func customDark(defaults: UserDefaults = .standard) -> ReaderStylePreset {
        let background = UIColor(readerHex: defaults.string(forKey: customDarkBackgroundKey) ?? "")
            ?? UIColor(readerHex: defaultCustomDarkBackground)!
        let foreground = UIColor(readerHex: defaults.string(forKey: customDarkForegroundKey) ?? "")
            ?? UIColor(readerHex: defaultCustomDarkForeground)!
        return ReaderStylePreset(id: customDarkID, name: "自定义", background: background, foreground: foreground)
    }

    /// 自定义主题（浅色 / 深色）对应的存储。
    static func customKeys(dark: Bool) -> (background: String, foreground: String, useImage: String) {
        dark ? (customDarkBackgroundKey, customDarkForegroundKey, ReaderCustomThemeImage.darkUseKey)
             : (customBackgroundKey, customForegroundKey, ReaderCustomThemeImage.lightUseKey)
    }

    static func custom(dark: Bool, defaults: UserDefaults = .standard) -> ReaderStylePreset {
        dark ? customDark(defaults: defaults) : custom(defaults: defaults)
    }

    var isCustom: Bool { id == Self.customID || id == Self.customDarkID }
}


/// 阅读主题色块的个性化：
/// - 内置预设可以直接改文字 / 背景颜色、加背景图（改的是预设自己，不会跳到「自定义」）；
/// - 用户可以新建任意多个浅色 / 深色主题，新建后出现在对应一排；
/// - 每个色块都可以隐藏，在「管理主题」里随时显示回来。
enum ReaderThemeLibrary {
    struct PresetOverride: Codable, Equatable {
        var backgroundHex: String?
        var foregroundHex: String?
        var usesImage: Bool = false
    }

    struct UserTheme: Codable, Equatable, Identifiable {
        var id: String
        var name: String
        var dark: Bool
        var backgroundHex: String
        var foregroundHex: String
        var usesImage: Bool = false
    }

    static let overridesKey = "readerPresetOverrides"
    static let userThemesKey = "readerUserThemes"
    static let hiddenKey = "readerHiddenThemes"
    static let userPrefix = "user-"

    private static var defaults: UserDefaults { .standard }

    // MARK: 存取

    static func presetOverrides() -> [String: PresetOverride] {
        guard let data = defaults.data(forKey: overridesKey),
              let value = try? JSONDecoder().decode([String: PresetOverride].self, from: data) else { return [:] }
        return value
    }

    static func presetOverride(_ id: String) -> PresetOverride? { presetOverrides()[id] }

    static func setPresetOverride(_ id: String, _ value: PresetOverride?) {
        var all = presetOverrides()
        all[id] = value
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: overridesKey) }
    }

    static func userThemes() -> [UserTheme] {
        guard let data = defaults.data(forKey: userThemesKey),
              let value = try? JSONDecoder().decode([UserTheme].self, from: data) else { return [] }
        return value
    }

    static func userThemes(dark: Bool) -> [UserTheme] { userThemes().filter { $0.dark == dark } }

    static func userTheme(_ id: String) -> UserTheme? {
        guard id.hasPrefix(userPrefix) else { return nil }
        return userThemes().first { $0.id == id }
    }

    static func saveUserTheme(_ theme: UserTheme) {
        var all = userThemes()
        if let index = all.firstIndex(where: { $0.id == theme.id }) { all[index] = theme } else { all.append(theme) }
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: userThemesKey) }
    }

    static func deleteUserTheme(_ id: String) {
        let all = userThemes().filter { $0.id != id }
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: userThemesKey) }
        try? FileManager.default.removeItem(at: imageURL(id))
    }

    static func newUserThemeID() -> String { userPrefix + UUID().uuidString.lowercased() }

    // MARK: 隐藏

    /// 隐藏的色块 id（逗号分隔，便于设置页用 @AppStorage 跟随刷新）。
    static func hiddenIDs() -> Set<String> {
        Set((defaults.string(forKey: hiddenKey) ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }

    static func isHidden(_ id: String) -> Bool { hiddenIDs().contains(id) }

    static func setHidden(_ id: String, _ hidden: Bool) {
        var ids = hiddenIDs()
        if hidden { ids.insert(id) } else { ids.remove(id) }
        defaults.set(ids.sorted().joined(separator: ","), forKey: hiddenKey)
    }

    /// 旧版「自定义」主题（浅色 / 深色）是否用过：用过才作为一个色块显示。
    static func legacyCustomUsed(dark: Bool) -> Bool {
        let keys = ReaderStylePreset.customKeys(dark: dark)
        let id = dark ? ReaderStylePreset.customDarkID : ReaderStylePreset.customID
        return defaults.object(forKey: keys.background) != nil
            || defaults.bool(forKey: keys.useImage)
            || defaults.string(forKey: "readerTheme") == id
    }

    /// 一侧（浅色 / 深色）全部色块：内置预设、用过的旧版「自定义」、用户新建的主题。
    static func allThemes(dark: Bool) -> [ReaderStylePreset] {
        var items = dark ? ReaderStylePreset.darkPresets : ReaderStylePreset.lightPresets
        if legacyCustomUsed(dark: dark) { items.append(ReaderStylePreset.custom(dark: dark)) }
        items += userThemes(dark: dark).map { ReaderStylePreset.resolve($0.id) }
        return items
    }

    /// 一侧要显示的色块（去掉用户隐藏的；当前选中的即使被隐藏也照常显示，免得找不到）。
    static func visibleThemes(dark: Bool, selected: Set<String> = []) -> [ReaderStylePreset] {
        let hidden = hiddenIDs()
        return allThemes(dark: dark).filter { !hidden.contains($0.id) || selected.contains($0.id) }
    }

    // MARK: 颜色与背景图（预设、旧版「自定义」、用户主题统一处理）

    static func imageURL(_ id: String) -> URL {
        if id == ReaderStylePreset.customID { return ReaderBackgroundStore.url }
        if id == ReaderStylePreset.customDarkID { return ReaderCustomThemeImage.darkURL }
        let safe = id.replacingOccurrences(of: "/", with: "_")
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado/reader-theme-\(safe).jpg")
    }

    static func usesImage(_ id: String) -> Bool {
        if id == ReaderStylePreset.customID { return ReaderCustomThemeImage.usesImage(dark: false) }
        if id == ReaderStylePreset.customDarkID { return ReaderCustomThemeImage.usesImage(dark: true) }
        if let theme = userTheme(id) { return theme.usesImage }
        return presetOverride(id)?.usesImage ?? false
    }

    static func hasImage(_ id: String) -> Bool { FileManager.default.fileExists(atPath: imageURL(id).path) }

    /// 写入某个主题的颜色 / 背景图开关；nil 表示不改。
    static func update(_ id: String, background: String? = nil, foreground: String? = nil, usesImage: Bool? = nil) {
        if id == ReaderStylePreset.customID || id == ReaderStylePreset.customDarkID {
            let keys = ReaderStylePreset.customKeys(dark: id == ReaderStylePreset.customDarkID)
            if let background, UIColor(readerHex: background) != nil { defaults.set(background, forKey: keys.background) }
            if let foreground, UIColor(readerHex: foreground) != nil { defaults.set(foreground, forKey: keys.foreground) }
            if let usesImage { defaults.set(usesImage, forKey: keys.useImage) }
            return
        }
        if var theme = userTheme(id) {
            if let background, UIColor(readerHex: background) != nil { theme.backgroundHex = background }
            if let foreground, UIColor(readerHex: foreground) != nil { theme.foregroundHex = foreground }
            if let usesImage { theme.usesImage = usesImage }
            saveUserTheme(theme)
            return
        }
        guard ReaderStylePreset.original(id) != nil else { return }
        var value = presetOverride(id) ?? PresetOverride()
        if let background, UIColor(readerHex: background) != nil { value.backgroundHex = background }
        if let foreground, UIColor(readerHex: foreground) != nil { value.foregroundHex = foreground }
        if let usesImage { value.usesImage = usesImage }
        setPresetOverride(id, value)
    }

    /// 预设恢复成原来的颜色、去掉背景图。
    static func resetPreset(_ id: String) {
        setPresetOverride(id, nil)
        try? FileManager.default.removeItem(at: imageURL(id))
    }

    static func isModifiedPreset(_ id: String) -> Bool { presetOverride(id) != nil }

    /// 这个主题当前要铺的背景图文件（没开或没有图时为 nil）。
    static func activeImageURL(for id: String) -> URL? {
        guard usesImage(id) else { return nil }
        let url = imageURL(id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    nonisolated(unsafe) private static let cache = NSCache<NSString, UIImage>()

    /// 带缓存地读背景图（阅读页每次刷新都会问，避免反复解码）。revision 变化时重读。
    static func image(for id: String, revision: Int) -> UIImage? {
        guard let url = activeImageURL(for: id) else { return nil }
        let key = "\(id)#\(revision)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = ReaderBackgroundStore.load(from: url) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    /// 读背景图（不走缓存），用于设置页的色块和预览。
    static func previewImage(_ id: String) -> UIImage? {
        guard hasImage(id) else { return nil }
        return ReaderBackgroundStore.load(from: imageURL(id))
    }
}

/// 自定义主题的背景图：浅色沿用原来的阅读背景图文件（旧版本选过的背景图不丢），深色单独一张。
enum ReaderCustomThemeImage {
    static let lightUseKey = "readerCustomUseImage"
    static let darkUseKey = "readerCustomDarkUseImage"

    static var darkURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado/reader-background-dark.jpg")
    }

    static func url(dark: Bool) -> URL { dark ? darkURL : ReaderBackgroundStore.url }

    static func load(dark: Bool) -> UIImage? { ReaderBackgroundStore.load(from: url(dark: dark)) }

    static func usesImage(dark: Bool, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: dark ? darkUseKey : lightUseKey)
    }

    /// 旧版「使用背景图」开关（任何主题上都铺同一张图）并入当前一侧的自定义主题：
    /// 颜色抄当前主题、图片沿用原图，阅读页看起来完全不变；之后背景图只跟着自定义主题走。
    static func migrateLegacyBackground(current style: ReaderStylePreset, defaults: UserDefaults = .standard) {
        guard defaults.bool(forKey: "readerUseBackgroundImage") else { return }
        defaults.set(false, forKey: "readerUseBackgroundImage")
        guard FileManager.default.fileExists(atPath: ReaderBackgroundStore.url.path) else { return }
        let dark = style.isDark
        let keys = ReaderStylePreset.customKeys(dark: dark)
        if !style.isCustom {
            defaults.set(style.background.readerHex, forKey: keys.background)
            defaults.set(style.foreground.readerHex, forKey: keys.foreground)
        }
        if dark {
            try? FileManager.default.removeItem(at: darkURL)
            try? FileManager.default.copyItem(at: ReaderBackgroundStore.url, to: darkURL)
        }
        defaults.set(true, forKey: keys.useImage)
        let id = dark ? ReaderStylePreset.customDarkID : ReaderStylePreset.customID
        defaults.set(id, forKey: dark ? "readerDarkTheme" : "readerPreviousDayTheme")
        defaults.set(id, forKey: "readerTheme")
    }

    /// 阅读页当前该用的背景图：旧版「使用背景图」开关（任何主题都铺图）优先，
    /// 否则只有选中自定义主题且它设了背景图时才用。
    static func activeImageSide(for style: ReaderStylePreset, defaults: UserDefaults = .standard) -> Bool? {
        if defaults.bool(forKey: "readerUseBackgroundImage") { return false }
        if style.id == ReaderStylePreset.customID, usesImage(dark: false, defaults: defaults) { return false }
        if style.id == ReaderStylePreset.customDarkID, usesImage(dark: true, defaults: defaults) { return true }
        return nil
    }

    /// 阅读页当前该铺的背景图文件：旧版全局开关优先，否则看当前主题（预设、自定义、新建主题）自己的背景图。
    static func activeImageURL(for style: ReaderStylePreset, defaults: UserDefaults = .standard) -> URL? {
        if defaults.bool(forKey: "readerUseBackgroundImage") { return ReaderBackgroundStore.url }
        return ReaderThemeLibrary.activeImageURL(for: style.id)
    }
}

extension UIColor {
    /// Parses "RRGGBB" or "#RRGGBB"; returns nil for anything else.
    convenience init?(readerHex: String) {
        var text = readerHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(hex: value)
    }

    /// "RRGGBB" in sRGB, alpha ignored.
    var readerHex: String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        let resolved = resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return "" }
        func channel(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X", channel(red), channel(green), channel(blue))
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: 1
        )
    }
}

enum ReaderBackgroundStore {
    static let maximumPixelSize = 2560

    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado/reader-background.jpg")
    }

    static func load(from source: URL = url) -> UIImage? {
        guard let data = try? Data(contentsOf: source, options: .mappedIfSafe) else { return nil }
        return try? downsample(data)
    }

    static func save(_ data: Data, to target: URL = url) throws -> UIImage {
        let image = try downsample(data)
        guard let encoded = image.jpegData(compressionQuality: 0.9) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded.write(to: target, options: .atomic)
        return image
    }

    private static func downsample(_ data: Data) throws -> UIImage {
        // Decode only the size used by the reader, including backgrounds saved
        // by older versions. Full-resolution camera photos can exhaust memory.
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
              ] as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return UIImage(cgImage: image)
    }

    static func remove() { try? FileManager.default.removeItem(at: url) }
}

enum ReaderFontStore {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado/fonts", isDirectory: true)
    }

    static func install(from source: URL) throws -> String {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: source)
        guard let provider = CGDataProvider(data: data as CFData),
              font(provider: provider, size: 20, weight: 0) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(source.lastPathComponent)
        if target != source {
            try data.write(to: target, options: .atomic)
        }
        return target.path
    }

    static func font(at path: String, size: CGFloat, weight: Int) -> UIFont? {
        guard !path.isEmpty,
              let provider = CGDataProvider(url: URL(fileURLWithPath: path) as CFURL) else { return nil }
        return font(provider: provider, size: size, weight: weight)
    }

    private static func font(provider: CGDataProvider, size: CGFloat, weight: Int) -> UIFont? {
        guard let graphicsFont = CGFont(provider) else { return nil }
        CTFontManagerRegisterGraphicsFont(graphicsFont, nil)
        guard let postScriptName = graphicsFont.postScriptName else { return nil }
        let name = postScriptName as String
        guard let base = UIFont(name: name, size: size) else { return nil }
        if weight == 1,
           let descriptor = base.fontDescriptor.withSymbolicTraits(.traitBold) {
            return UIFont(descriptor: descriptor, size: size)
        }
        if weight == 2 {
            let descriptor = base.fontDescriptor.addingAttributes([
                .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.light.rawValue]
            ])
            return UIFont(descriptor: descriptor, size: size)
        }
        return base
    }
}

/// Header/footer row. Short items (time, page, progress) keep their natural
/// width so a long chapter title can use the rest of the row instead of
/// being squeezed into a third of it and cut off with "…".
struct ReaderTipRowLayout: View {
    let left: String
    let middle: String
    let right: String

    var body: some View {
        if middle.isEmpty {
            HStack(spacing: 8) {
                if left.count >= right.count {
                    flexible(left, alignment: .leading)
                    if !right.isEmpty { Text(right).lineLimit(1).fixedSize() }
                } else {
                    if !left.isEmpty { Text(left).lineLimit(1).fixedSize() }
                    flexible(right, alignment: .trailing)
                }
            }
        } else {
            HStack(spacing: 8) {
                flexible(left, alignment: .leading)
                Text(middle).lineLimit(1).minimumScaleFactor(0.7)
                    .layoutPriority(1)
                flexible(right, alignment: .trailing)
            }
        }
    }

    private func flexible(_ text: String, alignment: Alignment) -> some View {
        Text(text)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: alignment)
    }
}

extension NSAttributedString.Key {
    /// A tappable link inside chapter text (段评气泡 or an illustration).
    static let readerLink = NSAttributedString.Key("legado.readerLink")
}

/// Renders the `<img src="…">` markers chapter text can carry. Paragraph
/// review counts (段评, `dp:12`, `bubble://paragraph?num=12`, or a review
/// image with `{"type":"cmt"…}` options) become a small count bubble at the
/// end of the paragraph; other images become an "插图" chip instead of raw
/// HTML. The marker keeps its length (its other characters are drawn at
/// near-zero size) so saved reading positions stay valid.
enum ReaderInlineMarkup {
    struct Bubble: Equatable {
        var text: String
        var color: UIColor?
        var emphasis: Bool
        var url: URL?
        /// 书源自带的气泡图片（「优先使用自带气泡」开启时代替气泡样式）。
        var imageURL: URL? = nil
    }

    enum Item: Equatable {
        case bubble(Bubble)
        case image(URL?)
    }

    private static let reviewTypes: Set<String> = [
        "qd", "fqpl", "fanqie", "cmt", "comment", "comments", "review", "reviews", "paragraph", "duanping", "dp"
    ]

    static let tagExpression = try? NSRegularExpression(pattern: #"<img\s+src\s*=\s*"([^"]*)"\s*/?>"#, options: [.caseInsensitive])

    static func containsMarkup(_ text: String) -> Bool {
        text.range(of: "<img", options: .caseInsensitive) != nil
    }

    static func unescape(_ value: String) -> String {
        value.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#34;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static func parse(src rawSource: String) -> Item {
        let source = unescape(rawSource).trimmingCharacters(in: .whitespacesAndNewlines)
        // dp:12  or  dp:12,{"status":"emphasis","displayColor":"#FF0000"}
        if source.lowercased().hasPrefix("dp:") {
            let body = String(source.dropFirst(3))
            let (head, options) = splitOptions(body)
            return .bubble(.init(
                text: displayCount(options["displayText"] as? String ?? head),
                color: (options["displayColor"] as? String).flatMap { UIColor(readerHex: $0) },
                emphasis: (options["status"] as? String) == "emphasis",
                url: nil
            ))
        }
        // bubble://paragraph?num=12&status=emphasis&displayColor=%23FF0000
        if source.lowercased().hasPrefix("bubble://"), let components = URLComponents(string: source) {
            let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
            return .bubble(.init(
                text: displayCount(query["displayText"] ?? query["num"] ?? ""),
                color: query["displayColor"].flatMap { UIColor(readerHex: $0) },
                emphasis: query["status"] == "emphasis",
                url: query["url"].flatMap { URL(string: $0) } ?? query["js"].flatMap(scriptURL)
            ))
        }
        let (head, options) = splitOptions(source)
        let url = URL(string: head)
        if !options.isEmpty {
            let type = (options["type"] as? String ?? "").lowercased()
            let style = (options["style"] as? String ?? "").uppercased()
            let click = (options["click"] as? String ?? "") + (options["pclick"] as? String ?? "")
            let isReview = reviewTypes.contains(type)
                || click.contains("showCmt(") || click.contains("showComment(") || click.contains("paragraph")
                || (style == "TEXT" && !type.isEmpty)
            if isReview {
                let count = (options["num"] as? String) ?? (options["num"] as? Int).map(String.init)
                    ?? (options["text"] as? String) ?? ""
                let link = (options["url"] as? String).flatMap { URL(string: $0) }
                    ?? (click.contains("showBrowser") ? url : nil)
                return .bubble(.init(
                    text: displayCount(count),
                    color: (options["displayColor"] as? String).flatMap { UIColor(readerHex: $0) },
                    emphasis: (options["status"] as? String) == "emphasis",
                    url: link.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil },
                    imageURL: url.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
                ))
            }
        }
        return .image(url.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil })
    }

    static let scriptScheme = "legado-review-js"

    /// A source click callback (`showCmt(...)`) carried as a tappable link;
    /// the reader runs it with the book source to find the review page.
    static func scriptURL(_ script: String) -> URL? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard !script.isEmpty, let encoded = script.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "\(scriptScheme)://run?code=\(encoded)")
    }

    static func script(from url: URL) -> String? {
        guard url.scheme == scriptScheme else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "code" }?.value
    }

    private static func splitOptions(_ value: String) -> (String, [String: Any]) {
        guard let comma = value.range(of: ",{") else { return (value, [:]) }
        let head = String(value[..<comma.lowerBound])
        let json = String(value[value.index(after: comma.lowerBound)...])
        let options = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        return (head, options)
    }

    private static func displayCount(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "段评" }
        if let number = Int(trimmed), number >= 1000 {
            return number >= 10000 ? String(format: "%.1fw", Double(number) / 10000) : "\(number / 1000)k+"
        }
        return trimmed
    }

    /// Replaces each marker inside `range` without changing the text length.
    static func decorate(_ text: NSMutableAttributedString, in range: NSRange, font: UIFont, foreground: UIColor, accent: UIColor, showsBubbles: Bool = true, bubbleStyle: Int = 0, bubbleAccent: Bool = false, customBubbleRevision: Int = 0) {
        guard range.length > 0 else { return }
        styleCommentCards(text, in: range, font: font, foreground: foreground, accent: accent)
        guard let expression = tagExpression,
              containsMarkup((text.string as NSString).substring(with: range)) else { return }
        let matches = expression.matches(in: text.string, range: range)
        for match in matches where match.range.length > 1 && match.numberOfRanges > 1 {
            let source = (text.string as NSString).substring(with: match.range(at: 1))
            let item = parse(src: source)
            let image: UIImage
            var link: URL?
            switch item {
            case .bubble where !showsBubbles:
                text.addAttributes([.font: UIFont.systemFont(ofSize: 0.01), .foregroundColor: UIColor.clear, .kern: 0], range: match.range)
                text.removeAttribute(.underlineStyle, range: match.range)
                continue
            case .bubble(let bubble):
                // 气泡形状与数字格式跟随「段评气泡」样式；颜色优先用书源给的 displayColor，
                // 其次强调状态用强调色，否则跟随正文（自定义样式可改为固定颜色）。
                image = CommentBubble.image(label: bubble.text, fontSize: font.pointSize, color: bubble.color ?? (bubble.emphasis ? accent : foreground),
                                            sourceImageURL: bubble.imageURL)
                link = bubble.url
            case .image(let url):
                image = bubbleImage(text: "插图", font: font, color: foreground, style: 0)
                link = url
            }
            let attachment = NSTextAttachment()
            attachment.image = image
            let capHeight = font.capHeight
            if case .bubble = item {
                let bounds = CommentBubble.attachmentBounds(fontSize: font.pointSize)
                // 用与设备像素无关的排版尺寸：UIGraphicsImageRenderer 会把画布向上取整到整像素（@2x 时 36.33pt → 36.5pt）。
                attachment.bounds = CGRect(x: 0, y: bounds.minY, width: bounds.width, height: bounds.height)
            } else {
                attachment.bounds = CGRect(x: 0, y: (capHeight - image.size.height) / 2, width: image.size.width, height: image.size.height)
            }
            let existing = text.attributes(at: match.range.location, effectiveRange: nil)
            let replacement = NSMutableAttributedString(attachment: attachment)
            var attributes = existing
            attributes[.attachment] = attachment
            attributes.removeValue(forKey: .underlineStyle)
            replacement.setAttributes(attributes, range: NSRange(location: 0, length: replacement.length))
            text.replaceCharacters(in: NSRange(location: match.range.location, length: 1), with: replacement)
            let hidden = NSRange(location: match.range.location + 1, length: match.range.length - 1)
            text.addAttributes([
                .font: UIFont.systemFont(ofSize: 0.01),
                .foregroundColor: UIColor.clear,
                .kern: 0
            ], range: hidden)
            text.removeAttribute(.underlineStyle, range: hidden)
            if let link { text.addAttribute(.readerLink, value: link, range: match.range) }
        }
    }

    /// 0 描边胶囊（默认）· 1 实心糖果 · 2 方角标签 · 3 对话气泡 · 4 自定义图片
    static let bubbleStyleNames = ["描边胶囊", "实心糖果", "方角标签", "对话气泡", "自定义图片"]

    private static let cardExpression = try? NSRegularExpression(
        pattern: "(?m)^【(?:热评|神评论|精选评论|精彩评论|本章说|本章讨论|本书讨论|本章评论|本书评论)[^】\\n]*】[^\\n]*"
    )

    /// 热评 / 本章说 卡片：标签用强调色加粗，正文缩小、浅色衬底，与正文区分开。
    static func styleCommentCards(_ text: NSMutableAttributedString, in range: NSRange, font: UIFont, foreground: UIColor, accent: UIColor) {
        let substring = (text.string as NSString).substring(with: range)
        guard substring.contains("【"), let expression = cardExpression else { return }
        let small = font.withSize(max(11, font.pointSize * 0.86))
        for match in expression.matches(in: text.string, range: range) {
            text.addAttributes([
                .font: small,
                .foregroundColor: foreground.withAlphaComponent(0.75),
                .backgroundColor: foreground.withAlphaComponent(0.06)
            ], range: match.range)
            let line = (text.string as NSString).substring(with: match.range)
            if let close = line.firstIndex(of: "】") {
                let labelLength = (String(line[...close]) as NSString).length
                text.addAttributes([
                    .font: UIFont.systemFont(ofSize: small.pointSize, weight: .bold),
                    .foregroundColor: accent
                ], range: NSRange(location: match.range.location, length: labelLength))
            }
        }
    }

    /// 用户导入的自定义气泡底图（PNG / JPEG），保存在 UserDefaults。
    static let customBubbleImageKey = "reviewBubbleCustomImage"
    nonisolated(unsafe) private static var customImageRevision = -1
    nonisolated(unsafe) private static var customImage: UIImage?

    static func customBubbleImage(revision: Int) -> UIImage? {
        if revision != customImageRevision {
            customImageRevision = revision
            customImage = UserDefaults.standard.data(forKey: customBubbleImageKey).flatMap { UIImage(data: $0) }
            imageCache.removeAllObjects()
        }
        return customImage
    }

    /// 缩到 96 像素高再存，避免大图拖慢排版。
    static func normalizedBubbleImageData(_ data: Data) -> Data? {
        guard data.count <= 10_000_000, let image = UIImage(data: data), image.size.height > 0 else { return nil }
        let height: CGFloat = 96
        let width = min(max(image.size.width * height / image.size.height, 24), 384)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return resized.pngData()
    }

    nonisolated(unsafe) private static let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        return cache
    }()

    static func bubbleImage(text: String, font: UIFont, color: UIColor, style: Int = 0) -> UIImage {
        let key = "\(text)|\(font.pointSize)|\(color.readerHex)|\(style)" as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        let image = renderBubble(text: text, font: font, color: color, style: style)
        imageCache.setObject(image, forKey: key)
        return image
    }

    private static func renderCustomBubble(text: String, font: UIFont, color: UIColor, image: UIImage) -> UIImage {
        let labelFont = UIFont.systemFont(ofSize: max(9, font.pointSize * 0.55), weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: color]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let height = ceil(labelFont.lineHeight + 6)
        let imageWidth = image.size.width * height / max(image.size.height, 1)
        let width = ceil(max(imageWidth, textSize.width + 10)) + 4
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { _ in
            let box = CGRect(x: 4, y: 0, width: width - 4, height: height)
            image.draw(in: box)
            (text as NSString).draw(
                at: CGPoint(x: box.midX - textSize.width / 2, y: (height - textSize.height) / 2),
                withAttributes: attributes
            )
        }
    }

    private static func renderBubble(text: String, font: UIFont, color: UIColor, style: Int) -> UIImage {
        let labelFont = UIFont.systemFont(ofSize: max(9, font.pointSize * 0.58), weight: .semibold)
        if style == 4, let custom = customImage {
            return renderCustomBubble(text: text, font: font, color: color, image: custom)
        }
        let textColor = style == 1 ? UIColor.white : color
        let attributes: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: textColor]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let height = ceil(labelFont.lineHeight + 4)
        let tail: CGFloat = style == 3 ? 4 : 0
        let size = CGSize(width: ceil(max(textSize.width + 12, height + 4)) + 4, height: height + tail)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let bubble = CGRect(x: 4, y: 0, width: size.width - 4, height: height)
            let path: UIBezierPath
            switch style {
            case 2: path = UIBezierPath(roundedRect: bubble, cornerRadius: 3)
            case 3:
                path = UIBezierPath(roundedRect: bubble, cornerRadius: height / 2)
                let tip = UIBezierPath()
                tip.move(to: CGPoint(x: bubble.minX + 5, y: bubble.maxY - 2))
                tip.addLine(to: CGPoint(x: bubble.minX + 3, y: size.height))
                tip.addLine(to: CGPoint(x: bubble.minX + 11, y: bubble.maxY - 1))
                tip.close()
                path.append(tip)
            default: path = UIBezierPath(roundedRect: bubble, cornerRadius: height / 2)
            }
            if style == 1 {
                color.withAlphaComponent(0.85).setFill()
                path.fill()
            } else {
                color.withAlphaComponent(0.12).setFill()
                path.fill()
                color.withAlphaComponent(0.55).setStroke()
                path.lineWidth = 0.8
                path.stroke()
            }
            (text as NSString).draw(
                at: CGPoint(x: bubble.midX - textSize.width / 2, y: (height - textSize.height) / 2),
                withAttributes: attributes
            )
        }
    }
}

struct ReaderReviewPage: Identifiable {
    var url: URL?
    var html: String?
    var bridge: (@MainActor (String) async -> String)?
    /// 书源回调：先弹出半屏显示“正在加载”，在后台执行脚本拿到页面。
    var loader: (@MainActor () async -> JavaScriptRuleEvaluator.ClickResolution)?
    let id = UUID()

    init(url: URL?, html: String? = nil, bridge: (@MainActor (String) async -> String)? = nil,
         loader: (@MainActor () async -> JavaScriptRuleEvaluator.ClickResolution)? = nil) {
        self.url = url
        self.html = html
        self.bridge = bridge
        self.loader = loader
    }
}

/// 段评 / 插图页：点一下立即半屏弹出，可上划展开到全屏；书源回调在里面加载，
/// 失败时就地显示原因和重试。
struct ReaderReviewSheet: View {
    let page: ReaderReviewPage
    @AppStorage(BubblePreferences.browserFullScreenKey) private var fullScreen = false
    @AppStorage(BubblePreferences.edgeBackKey) private var edgeBack = true
    @Environment(\.dismiss) private var dismiss
    @State private var resolved: (url: URL, html: String?)?
    @State private var error: String?
    @State private var attempt = 0

    var body: some View {
        Group {
            if let resolved {
                ReaderReviewWebView(url: resolved.url, html: resolved.html, bridge: page.bridge,
                                    edgeBack: edgeBack, onEdgeDismiss: { dismiss() })
                    .ignoresSafeArea(edges: .bottom)
            } else if let error {
                VStack(spacing: 14) {
                    Image(systemName: "text.bubble").font(.largeTitle).foregroundStyle(.secondary)
                    Text("段评加载失败").font(.headline)
                    Text(error).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("重试") { self.error = nil; attempt += 1 }.buttonStyle(.borderedProminent)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("正在加载段评…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // 气泡设置 › Browser 默认显示：半屏（可上划展开）或直接全屏。
        .readingPresentationDetents(fullScreen ? [.large] : [.medium, .large])
        .task(id: attempt) { await load() }
    }

    private func load() async {
        guard resolved == nil else { return }
        if let loader = page.loader {
            let result = await loader()
            if let html = result.html {
                resolved = (result.url.flatMap(URL.init(string:)) ?? URL(string: "about:blank")!, html)
            } else if let target = result.url.flatMap(URL.init(string:)) {
                resolved = (target, nil)
            } else {
                error = result.error ?? "书源没有给出段评内容"
            }
        } else if let url = page.url {
            resolved = (url, page.html)
        } else {
            error = "没有段评地址"
        }
    }
}

private struct ReaderReviewWebView: UIViewRepresentable {
    let url: URL
    var html: String?
    var bridge: (@MainActor (String) async -> String)?
    /// 边缘返回：左边缘右滑有上一页时后退，没有时关闭段评页。
    var edgeBack = true
    var onEdgeDismiss: (() -> Void)? = nil

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        if bridge != nil {
            // 安卓 showBrowser 页面用 window.run / qmRun 回调书源 JS，返回 Promise。
            let controller = configuration.userContentController
            controller.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "legadoRun")
            controller.addUserScript(WKUserScript(source: """
                (function(){
                  function run(code){ return window.webkit.messageHandlers.legadoRun.postMessage(String(code)); }
                  window.run = run; window.qmRun = run; window.qmLocalCommentPage = true;
                })();
                """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        }
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.customUserAgent = ApplicationSettingsStore.shared.settings.effectiveUserAgent
        web.allowsBackForwardNavigationGestures = edgeBack
        web.navigationDelegate = context.coordinator
        let edge = UIScreenEdgePanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.edgePanned(_:)))
        edge.edges = .left
        edge.isEnabled = edgeBack
        edge.delegate = context.coordinator
        web.addGestureRecognizer(edge)
        context.coordinator.edgePan = edge
        context.coordinator.onEdgeDismiss = onEdgeDismiss
        if let html {
            web.loadHTMLString(html, baseURL: url)
        } else {
            web.load(URLRequest(url: url))
        }
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        uiView.allowsBackForwardNavigationGestures = edgeBack
        context.coordinator.edgePan?.isEnabled = edgeBack
        context.coordinator.onEdgeDismiss = onEdgeDismiss
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    func makeCoordinator() -> Coordinator { Coordinator(host: url.host, bridge: bridge) }

    /// 不少段评接口的证书已过期，书源阅读里会直接空白。只对段评页自己的域名、
    /// 且仅在“证书过期”这一个错误时放行；其他证书问题照常拦下。
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandlerWithReply, UIGestureRecognizerDelegate {
        let host: String?
        let bridge: (@MainActor (String) async -> String)?
        weak var edgePan: UIScreenEdgePanGestureRecognizer?
        var onEdgeDismiss: (() -> Void)?
        init(host: String?, bridge: (@MainActor (String) async -> String)? = nil) {
            self.host = host
            self.bridge = bridge
        }

        /// 已经退到第一页时，左边缘右滑关闭段评页（能后退时交给网页自己的返回手势）。
        @objc func edgePanned(_ gesture: UIScreenEdgePanGestureRecognizer) {
            guard gesture.state == .ended, let web = gesture.view as? WKWebView, !web.canGoBack else { return }
            if gesture.translation(in: web).x > 60 { onEdgeDismiss?() }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === edgePan, let web = gestureRecognizer.view as? WKWebView else { return true }
            return !web.canGoBack
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            gestureRecognizer === edgePan
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage,
            replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
        ) {
            guard let bridge, let code = message.body as? String else {
                replyHandler(nil, "阅读端没有注入 run 桥接")
                return
            }
            Task { @MainActor in
                replyHandler(await bridge(code), nil)
            }
        }

        func webView(
            _ webView: WKWebView,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            let space = challenge.protectionSpace
            guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = space.serverTrust, let host, Self.sameSite(space.host, host) else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            var error: CFError?
            if SecTrustEvaluateWithError(trust, &error) {
                completionHandler(.performDefaultHandling, nil)
            } else if let error, CFErrorGetCode(error) == Int(errSecCertificateExpired) {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }

        nonisolated static func sameSite(_ a: String, _ b: String) -> Bool {
            func root(_ h: String) -> String { h.lowercased().split(separator: ".").suffix(2).joined(separator: ".") }
            return root(a) == root(b)
        }
    }
}
