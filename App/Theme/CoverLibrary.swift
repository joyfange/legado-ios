import SwiftUI
import UIKit
import ImageIO
import PhotosUI
import UniformTypeIdentifiers

// MARK: - 默认封面图库
//
// 用户可以建多个「封面分组」，每组从相册导入任意多张图片；选中一个分组后，
// 没有可用封面的书会从该组里按书名稳定地「随机」分到一张（同一本书每次都是同一张，不会闪烁）。
// 图库对所有主题通用；没选分组时继续使用主题里的单张「默认封面」或系统生成封面。

struct CoverGroup: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var images: [String]
}

/// 图片文件：Documents/CoverLibrary/<uuid>.jpg，导入时缩到最长边 720 像素，书架滚动时解码很轻。
enum CoverLibraryFiles {
    static let maximumPixelSize = 720
    static let maximumInputBytes = 30 * 1024 * 1024

    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CoverLibrary", isDirectory: true)
    }

    static func isValidID(_ id: String) -> Bool {
        id.count == 40 && id.hasSuffix(".jpg")
            && id.dropLast(4).allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    static func url(_ id: String) -> URL? {
        guard isValidID(id) else { return nil }
        return directory.appendingPathComponent(id, isDirectory: false)
    }

    /// 在后台线程调用。返回新图片的 ID。
    static func importData(_ data: Data) -> String? {
        guard !data.isEmpty, data.count <= maximumInputBytes,
              let bitmap = decode(data: data, maxPixel: maximumPixelSize),
              let jpeg = UIImage(cgImage: bitmap).jpegData(compressionQuality: 0.86) else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased() + ".jpg"
        guard let target = url(id) else { return nil }
        do {
            try jpeg.write(to: target, options: [.atomic])
            return id
        } catch {
            return nil
        }
    }

    static func remove(_ id: String) {
        guard let url = url(id) else { return }
        CoverLibraryCache.shared.remove(id)
        try? FileManager.default.removeItem(at: url)
    }

    static func decode(data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ] as CFDictionary)
    }

    /// 在后台线程调用：读文件并解码好，主线程直接显示不再卡顿。
    static func loadImage(_ id: String) -> UIImage? {
        if let cached = CoverLibraryCache.shared.image(id) { return cached }
        guard let url = url(id), let data = try? Data(contentsOf: url),
              let bitmap = decode(data: data, maxPixel: maximumPixelSize) else { return nil }
        let image = UIImage(cgImage: bitmap)
        CoverLibraryCache.shared.insert(image, for: id, cost: bitmap.bytesPerRow * bitmap.height)
        return image
    }
}

final class CoverLibraryCache: @unchecked Sendable {
    static let shared = CoverLibraryCache()
    private let cache = NSCache<NSString, UIImage>()
    init() {
        cache.countLimit = 160
        cache.totalCostLimit = 72 * 1024 * 1024
    }
    func image(_ id: String) -> UIImage? { cache.object(forKey: id as NSString) }
    func insert(_ image: UIImage, for id: String, cost: Int) { cache.setObject(image, forKey: id as NSString, cost: cost) }
    func remove(_ id: String) { cache.removeObject(forKey: id as NSString) }
}

@MainActor
final class CoverLibraryStore: ObservableObject {
    static let shared = CoverLibraryStore()
    private static let storageKey = "coverLibrary.groups.v1"
    private static let activeKey = "coverLibrary.active.v1"

    @Published private(set) var groups: [CoverGroup] = []
    @Published private(set) var activeGroupID: String?
    @Published private(set) var importing = false

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([CoverGroup].self, from: data) {
            groups = decoded
        }
        let active = UserDefaults.standard.string(forKey: Self.activeKey)
        activeGroupID = groups.contains { $0.id == active } ? active : nil
    }

    var activeGroup: CoverGroup? { groups.first { $0.id == activeGroupID } }

    /// 当前用于无封面书籍的图片（选中分组里的图）。
    var activeImages: [String] { activeGroup?.images ?? [] }

    func group(_ id: String) -> CoverGroup? { groups.first { $0.id == id } }

    @discardableResult
    func createGroup(named raw: String) -> CoverGroup? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let group = CoverGroup(id: UUID().uuidString, name: String(name.prefix(30)), images: [])
        groups.append(group)
        if activeGroupID == nil { activeGroupID = group.id }
        persist()
        return group
    }

    func rename(_ id: String, to raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].name = String(name.prefix(30))
        persist()
    }

    func deleteGroup(_ id: String) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        let removed = groups.remove(at: index)
        if activeGroupID == id { activeGroupID = nil }
        persist()
        let images = removed.images
        Task.detached(priority: .utility) { for id in images { CoverLibraryFiles.remove(id) } }
    }

    func setActive(_ id: String?) {
        activeGroupID = id.flatMap { candidate in groups.contains { $0.id == candidate } ? candidate : nil }
        persist()
    }

    func removeImages(_ ids: Set<String>, from groupID: String) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].images.removeAll { ids.contains($0) }
        persist()
        let list = Array(ids)
        Task.detached(priority: .utility) { for id in list { CoverLibraryFiles.remove(id) } }
    }

    /// 导入多张图片（在后台压缩保存），返回失败张数。
    func addImages(_ items: [Data], to groupID: String) async -> Int {
        guard !items.isEmpty else { return 0 }
        importing = true
        defer { importing = false }
        let ids: [String?] = await Task.detached(priority: .userInitiated) {
            items.map { CoverLibraryFiles.importData($0) }
        }.value
        let saved = ids.compactMap { $0 }
        if let index = groups.firstIndex(where: { $0.id == groupID }) {
            groups[index].images.append(contentsOf: saved)
            persist()
        } else {
            Task.detached(priority: .utility) { for id in saved { CoverLibraryFiles.remove(id) } }
        }
        return items.count - saved.count
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(groups) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
        UserDefaults.standard.set(activeGroupID, forKey: Self.activeKey)
    }

    /// 稳定的「随机」分配：同一本书永远得到同一张，不同书尽量分散。
    static func pick(for title: String, author: String, from images: [String]) -> String? {
        guard !images.isEmpty else { return nil }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in (title + "\u{0}" + author).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return images[Int(hash % UInt64(images.count))]
    }
}

/// 异步加载一张图库图片，滚动书架时不阻塞主线程。
struct CoverLibraryImage: View {
    let id: String
    @State private var image: UIImage?

    init(id: String) {
        self.id = id
        _image = State(initialValue: CoverLibraryCache.shared.image(id))
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.clear
            }
        }
        .task(id: id) {
            if let cached = CoverLibraryCache.shared.image(id) {
                if image !== cached { image = cached }
                return
            }
            let target = id
            let loaded = await Task.detached(priority: .userInitiated) { CoverLibraryFiles.loadImage(target) }.value
            if !Task.isCancelled { image = loaded }
        }
    }
}




/// 书籍没有封面时：优先用选中的封面分组，其次用 fallback（主题默认封面或系统生成封面）。
struct CoverLibraryFallback<Fallback: View>: View {
    let title: String
    let author: String
    let width: CGFloat
    let height: CGFloat
    let fallback: Fallback
    @ObservedObject private var library = CoverLibraryStore.shared

    init(title: String, author: String, width: CGFloat, height: CGFloat, @ViewBuilder fallback: () -> Fallback) {
        self.title = title
        self.author = author
        self.width = width
        self.height = height
        self.fallback = fallback()
    }

    var body: some View {
        if let id = CoverLibraryStore.pick(for: title, author: author, from: library.activeImages) {
            ZStack(alignment: .bottomLeading) {
                Color(white: 0.85)
                CoverLibraryImage(id: id)
                    .frame(width: width, height: height)
                    .clipped()
                if width >= 50 {
                    LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .center, endPoint: .bottom)
                    Text(title)
                        .font(.system(size: max(8, width * 0.12), weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.6), radius: 2)
                        .padding(width * 0.08)
                }
            }
            .frame(width: width, height: height)
        } else {
            fallback
        }
    }
}
