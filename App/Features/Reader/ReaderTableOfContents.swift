import SwiftUI
import LegadoCore

/// One row of the table of contents, computed once per chapter list so the
/// sheet never walks the whole chapter array while rendering a row.
struct ReaderTOCEntry: Identifiable, Equatable, Sendable {
    let id: String
    /// Position in `ReaderViewModel.chapters`.
    let index: Int
    /// 1-based number among readable (non-volume) chapters; 0 for volumes.
    let number: Int
    let title: String
    let isVolume: Bool

    static func build(from chapters: [BookChapter]) -> [ReaderTOCEntry] {
        var result: [ReaderTOCEntry] = []
        result.reserveCapacity(chapters.count)
        var readable = 0
        for (offset, chapter) in chapters.enumerated() {
            if !chapter.isVolume { readable += 1 }
            result.append(ReaderTOCEntry(
                id: "\(offset)\u{0}\(chapter.url)",
                index: offset,
                number: chapter.isVolume ? 0 : readable,
                title: chapter.title,
                isVolume: chapter.isVolume
            ))
        }
        return result
    }
}

/// Cheap fingerprint of a chapter list, used to decide when the cached
/// entries must be rebuilt without comparing thousands of chapters.
struct ReaderTOCKey: Equatable {
    let count: Int
    let first: String
    let last: String

    init(_ chapters: [BookChapter]) {
        count = chapters.count
        first = chapters.first.map { $0.url + $0.title } ?? ""
        last = chapters.last.map { $0.url + $0.title } ?? ""
    }
}

/// The reader's table of contents. It is a separate view with its own state so
/// that typing, sorting and locating only re-render this sheet, never the
/// reader behind it, and every row is an equatable view that SwiftUI can skip.
struct ReaderTableOfContentsView: View {
    let bookName: String
    let chapters: [BookChapter]
    let currentIndex: Int
    let progress: Double
    @Binding var descending: Bool
    let onClose: () -> Void
    let onSelect: (Int) -> Void

    @State private var entries: [ReaderTOCEntry] = []
    @State private var visible: [ReaderTOCEntry] = []
    @State private var search = ""
    @State private var readableCount = 0
    @State private var builtKey: ReaderTOCKey?

    private var currentEntryID: String? {
        entries.indices.contains(currentIndex) ? entries[currentIndex].id : nil
    }

    var body: some View {
        ReadingNavigationStack {
            ScrollViewReader { proxy in
                List {
                    Section {
                        ForEach(visible) { entry in
                            if entry.isVolume {
                                ReaderTOCRow(entry: entry, isCurrent: false, progress: 0)
                                    .equatable()
                                    .listRowBackground(ReadingTheme.accent.opacity(0.07))
                            } else {
                                let isCurrent = entry.index == currentIndex
                                Button {
                                    onSelect(entry.index)
                                } label: {
                                    ReaderTOCRow(entry: entry, isCurrent: isCurrent, progress: isCurrent ? progress : 0)
                                        .equatable()
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(isCurrent ? ReadingTheme.accent.opacity(0.08) : Color.clear)
                            }
                        }
                    } header: {
                        header
                    }
                }
                .listStyle(.insetGrouped)
                .navigationTitle("目录")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $search, prompt: "搜索章节")
                .onAppear {
                    rebuildIfNeeded()
                    scroll(proxy, animated: false, delay: 0.05)
                }
                .onChange(of: ReaderTOCKey(chapters)) { _ in
                    rebuildIfNeeded()
                }
                .onChange(of: descending) { _ in
                    refilter()
                    scroll(proxy, animated: false, delay: 0)
                }
                .onChange(of: search) { value in
                    refilter()
                    if value.isEmpty { scroll(proxy, animated: false, delay: 0) }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭", action: onClose) }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(descending ? "正序" : "倒序", systemImage: "arrow.up.arrow.down") {
                            descending.toggle()
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("定位当前章节", systemImage: "scope") {
                            if !search.isEmpty { search = "" }
                            scroll(proxy, animated: true, delay: 0)
                        }
                        .accessibilityIdentifier("reader.toc.locate")
                    }
                    ToolbarItem(placement: .bottomBar) {
                        if !search.isEmpty {
                            Button("清除搜索", systemImage: "xmark.circle") { search = "" }
                                .accessibilityIdentifier("reader.toc.clearSearch")
                        }
                    }
                }
            }
        }
        .readingPresentationDetents([.medium, .large])
        .readingPresentationDragIndicator()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(bookName).font(.headline).lineLimit(1)
                Spacer()
                Text("\(readableCount) 章")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: progress)
                .tint(ReadingTheme.accent)
            Text("第 \(currentNumber) 章 · \(Int(progress * 100))%")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .textCase(nil)
        .padding(.vertical, 4)
    }

    private var currentNumber: Int {
        entries.indices.contains(currentIndex) ? max(entries[currentIndex].number, 1) : max(currentIndex + 1, 1)
    }

    private func rebuildIfNeeded() {
        let key = ReaderTOCKey(chapters)
        guard key != builtKey else {
            if visible.isEmpty, !entries.isEmpty { refilter() }
            return
        }
        builtKey = key
        entries = ReaderTOCEntry.build(from: chapters)
        readableCount = entries.reduce(0) { $0 + ($1.isVolume ? 0 : 1) }
        refilter()
    }

    private func refilter() {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty ? entries : entries.filter {
            $0.title.localizedCaseInsensitiveContains(query) || (!$0.isVolume && "\($0.number)" == query)
        }
        visible = descending ? Array(filtered.reversed()) : filtered
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool, delay: Double) {
        guard let id = currentEntryID else { return }
        let action = {
            if animated {
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
            } else {
                proxy.scrollTo(id, anchor: .center)
            }
        }
        if delay <= 0 {
            // One run-loop hop so the list has applied the new ordering.
            DispatchQueue.main.async(execute: action)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        }
    }
}

private struct ReaderTOCRow: View, Equatable {
    let entry: ReaderTOCEntry
    let isCurrent: Bool
    let progress: Double

    var body: some View {
        if entry.isVolume {
            HStack(spacing: 10) {
                Image(systemName: "books.vertical.fill")
                Text(entry.title).font(.headline)
                Spacer()
            }
            .foregroundStyle(ReadingTheme.accent)
            .padding(.vertical, 4)
        } else {
            HStack(spacing: 12) {
                Text(entry.number > 0 ? "\(entry.number)" : "—")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isCurrent ? ReadingTheme.accent : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(width: 38, alignment: .trailing)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if isCurrent {
                        HStack(spacing: 6) {
                            Text("正在阅读")
                            ProgressView(value: progress)
                                .tint(ReadingTheme.accent)
                        }
                        .font(.caption2)
                        .foregroundStyle(ReadingTheme.accent)
                    }
                }
                Spacer(minLength: 8)
                if isCurrent {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(ReadingTheme.accent)
                }
            }
            .padding(.vertical, 4)
        }
    }
}
