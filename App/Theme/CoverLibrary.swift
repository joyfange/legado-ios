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

// MARK: - 多选相册

private final class MultiPickerBox: @unchecked Sendable {
    var results: [Int: Data] = [:]
    let lock = NSLock()
    let deliver: ([Data]) -> Void
    init(deliver: @escaping ([Data]) -> Void) { self.deliver = deliver }
}

struct CoverMultiPhotoPicker: UIViewControllerRepresentable {
    let onPick: ([Data]) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 0
        configuration.preferredAssetRepresentationMode = .current
        configuration.selection = .ordered
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: ([Data]) -> Void
        let onCancel: () -> Void
        private var finished = false
        init(onPick: @escaping ([Data]) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !finished else { return }
            finished = true
            guard !results.isEmpty else { onCancel(); return }
            let box = MultiPickerBox(deliver: onPick)
            let group = DispatchGroup()
            for (index, result) in results.enumerated() {
                let provider = result.itemProvider
                let type = provider.registeredTypeIdentifiers.first {
                    UTType($0)?.conforms(to: .image) == true
                } ?? UTType.image.identifier
                group.enter()
                provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                    if let data, !data.isEmpty {
                        box.lock.lock(); box.results[index] = data; box.lock.unlock()
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                box.lock.lock()
                let ordered = box.results.keys.sorted().compactMap { box.results[$0] }
                box.lock.unlock()
                box.deliver(ordered)
            }
        }
    }
}

// MARK: - 管理界面

struct CoverLibraryView: View {
    @ObservedObject private var library = CoverLibraryStore.shared
    @State private var newName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        List {
            Section {
                Button { library.setActive(nil) } label: {
                    choiceRow(title: "不使用图库", detail: "使用主题的默认封面或系统生成封面",
                              selected: library.activeGroupID == nil)
                }
                .buttonStyle(.plain)
                ForEach(library.groups) { group in
                    HStack(spacing: 12) {
                        Button { library.setActive(group.id) } label: {
                            choiceRow(title: group.name,
                                      detail: group.images.isEmpty ? "还没有图片" : "\(group.images.count) 张图片",
                                      selected: library.activeGroupID == group.id,
                                      preview: group.images.prefix(3).map { $0 })
                        }
                        .buttonStyle(.plain)
                        NavigationLink {
                            CoverGroupDetailView(groupID: group.id)
                        } label: {
                            Text("编辑").font(AppFontStyle.subheadline.themed)
                                .foregroundStyle(ReadingTheme.accent)
                        }
                        .fixedSize()
                    }
                }
                .onDelete { offsets in
                    let ids = offsets.map { library.groups[$0].id }
                    for id in ids { library.deleteGroup(id) }
                }
            } header: {
                Text("选择分组")
            } footer: {
                Text("选中分组后，没有封面的书会从这个分组的图片里随机分到一张（同一本书固定同一张）；已有封面的书不受影响。图库对所有主题通用。左滑可删除分组。")
            }
            .readingRowBackground()

            Section("新建分组") {
                HStack(spacing: 10) {
                    TextField("分组名称，如：古风、插画", text: $newName)
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .onSubmit(create)
                    Button("新建", action: create)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .readingRowBackground()
        }
        .listStyle(.insetGrouped)
        .readingThemedListBackground()
        .navigationTitle("封面图库")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func create() {
        guard library.createGroup(named: newName) != nil else { return }
        newName = ""
        nameFocused = false
    }

    private func choiceRow(title: String, detail: String, selected: Bool, preview: [String] = []) -> some View {
        HStack(spacing: 12) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20))
                .foregroundStyle(selected ? ReadingTheme.accent : ReadingTheme.secondaryInk)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(AppFontStyle.body.themed).foregroundStyle(ReadingTheme.ink)
                Text(detail).font(AppFontStyle.caption.themed).foregroundStyle(ReadingTheme.secondaryInk)
            }
            Spacer(minLength: 8)
            HStack(spacing: -10) {
                ForEach(preview, id: \.self) { id in
                    CoverLibraryImage(id: id)
                        .frame(width: 26, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(.white.opacity(0.7), lineWidth: 1))
                }
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

struct CoverGroupDetailView: View {
    let groupID: String
    @ObservedObject private var library = CoverLibraryStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var picking = false
    @State private var selecting = false
    @State private var selection: Set<String> = []
    @State private var confirmDelete = false
    @State private var message: String?

    private var group: CoverGroup? { library.group(groupID) }
    private let columns = [GridItem(.adaptive(minimum: 84, maximum: 120), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let group {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            TextField("分组名称", text: $name)
                                .font(AppFontStyle.body.themed)
                                .submitLabel(.done)
                                .onSubmit { library.rename(groupID, to: name) }
                            if name != group.name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                                Button("保存") { library.rename(groupID, to: name) }
                            }
                        }
                        .padding(.horizontal, 14).frame(minHeight: 46)
                        .background { ThemeSurface(shape: RoundedRectangle(cornerRadius: 14, style: .continuous), isCard: true) }

                        Toggle(isOn: Binding(get: { library.activeGroupID == groupID },
                                             set: { library.setActive($0 ? groupID : nil) })) {
                            Text("用作无封面书籍的默认封面").font(AppFontStyle.body.themed)
                        }
                        .padding(.horizontal, 14).frame(minHeight: 46)
                        .background { ThemeSurface(shape: RoundedRectangle(cornerRadius: 14, style: .continuous), isCard: true) }
                    }

                    HStack(spacing: 10) {
                        Button { picking = true } label: {
                            Label(library.importing ? "正在导入…" : "从相册添加", systemImage: "photo.on.rectangle.angled")
                                .font(AppFontStyle.body.themed)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(library.importing)
                        if !group.images.isEmpty {
                            Button(selecting ? "完成" : "选择") {
                                selecting.toggle()
                                selection = []
                            }
                            .buttonStyle(.bordered)
                            .frame(minHeight: 44)
                        }
                    }

                    if group.images.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "books.vertical").font(.system(size: 34, weight: .light))
                            Text("可以一次从相册选多张图片").font(AppFontStyle.subheadline.themed)
                        }
                        .foregroundStyle(ReadingTheme.secondaryInk)
                        .frame(maxWidth: .infinity, minHeight: 180)
                    } else {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(group.images, id: \.self) { id in
                                thumbnail(id)
                            }
                        }
                        Text("共 \(group.images.count) 张。长按图片可删除；图片已压缩保存，不会改动相册原图。")
                            .font(AppFontStyle.footnote.themed)
                            .foregroundStyle(ReadingTheme.secondaryInk)
                    }

                    Button(role: .destructive) { confirmDelete = true } label: {
                        Text("删除这个分组").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 8)
                }
            }
            .padding(18)
        }
        .readingCanvas()
        .navigationTitle(group?.name ?? "封面分组")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("删除所选") {
                    library.removeImages(selection, from: groupID)
                    selection = []
                    selecting = false
                }
                .disabled(!selecting || selection.isEmpty)
                .opacity(selecting ? 1 : 0)
            }
        }
        .onAppear { name = group?.name ?? "" }
        .sheet(isPresented: $picking) {
            CoverMultiPhotoPicker(onPick: { items in
                picking = false
                Task {
                    let failed = await library.addImages(items, to: groupID)
                    if failed > 0 { message = "有 \(failed) 张图片无法读取，已跳过。" }
                }
            }, onCancel: { picking = false })
            .ignoresSafeArea()
        }
        .confirmationDialog("删除分组“\(group?.name ?? "")”？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除分组和其中的图片", role: .destructive) {
                library.deleteGroup(groupID)
                dismiss()
            }
        }
        .alert("提示", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好") { message = nil }
        } message: { Text(message ?? "") }
    }

    private func thumbnail(_ id: String) -> some View {
        let selected = selection.contains(id)
        return Color.clear
            .aspectRatio(0.72, contentMode: .fit)
            .overlay { CoverLibraryImage(id: id) }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ReadingTheme.separator.opacity(0.4)))
            .overlay(alignment: .topTrailing) {
                if selecting {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(selected ? ReadingTheme.accent : .white)
                        .shadow(radius: 2)
                        .padding(6)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard selecting else { return }
                if selected { selection.remove(id) } else { selection.insert(id) }
            }
            .contextMenu {
                Button(role: .destructive) {
                    library.removeImages([id], from: groupID)
                } label: { Label("删除图片", systemImage: "trash") }
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
