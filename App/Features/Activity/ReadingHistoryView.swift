import SwiftUI

struct ReadingHistoryView: View {
    @EnvironmentObject private var activity: ReadingActivityModel
    @EnvironmentObject private var books: BookLibraryModel
    @EnvironmentObject private var sources: SourceLibraryModel
    @AppStorage("enableReadRecord") private var enableReadRecord = true
    @AppStorage("readRecordSort") private var sortMode = 0
    @State private var searchText = ""
    @State private var confirmsClear = false
    @State private var pendingDelete: ReadRecordSummary?

    private var displayedRecords: [ReadRecordSummary] {
        activity.summaries(searchKey: searchText, sortMode: sortMode)
    }

    var body: some View {
        Group {
            if activity.summaries.isEmpty {
                ReadingUnavailableView(
                    "还没有阅读记录",
                    systemImage: "clock.arrow.circlepath",
                    description: Text(enableReadRecord ? "翻页后会按设备累计阅读时长。" : "阅读记录当前已关闭。")
                )
            } else {
                List {
                    Section {
                        ReadingLabeledContent("累计阅读", value: duration(activity.summaries.reduce(0) { $0 + $1.readTime }))
                        ReadingLabeledContent("读过", value: "\(activity.summaries.count) 本")
                    }.readingRowBackground()
                    if displayedRecords.isEmpty {
                        ReadingUnavailableView.search(text: searchText)
                    } else {
                        ForEach(displayedRecords) { record in
                            NavigationLink {
                                destination(for: record)
                            } label: {
                                HStack(spacing: 13) {
                                    // 书在书架上用书架封面；已移出书架时用之前记下的封面。
                                    let shelfBook = books.books.first(where: { $0.name == record.bookName })
                                    let savedCover = ReadRecordCoverStore.cover(for: record.bookName)
                                    BookCoverArtwork(
                                        title: record.bookName,
                                        author: shelfBook?.author ?? savedCover?.author ?? "",
                                        remoteURL: shelfBook?.coverUrl ?? savedCover?.url,
                                        width: 38,
                                        height: 54
                                    )
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(record.bookName).font(AppFontStyle.headline.themed)
                                        Text(duration(record.readTime))
                                            .font(AppFontStyle.caption.themed).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(date(record.lastRead)).font(AppFontStyle.caption.themed).foregroundStyle(.tertiary)
                                }
                            }
                            .swipeActions {
                                Button("删除", role: .destructive) { pendingDelete = record }
                            }
                        }
                    }
                }.readingThemedListBackground()
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("阅读记录")
        .readingInlineSearch(text: $searchText, prompt: "搜索")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("阅读记录选项", systemImage: "ellipsis.circle") {
                    Toggle("记录阅读时长", isOn: $enableReadRecord)
                    Section("排序") {
                        sortButton("书名", value: 0)
                        sortButton("阅读时长", value: 1)
                        sortButton("最后阅读", value: 2)
                    }.readingRowBackground()
                    if !activity.summaries.isEmpty {
                        Button("清空", systemImage: "trash", role: .destructive) { confirmsClear = true }
                    }
                }
            }
        }
        .alert("清空阅读记录", isPresented: $confirmsClear) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { Task { await activity.clearHistory() } }
        } message: {
            Text("确定删除全部阅读记录吗？")
        }
        .alert("删除阅读记录", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                guard let record = pendingDelete else { return }
                pendingDelete = nil
                Task { await activity.removeHistory(bookName: record.bookName) }
            }
        } message: {
            Text("确定删除“\(pendingDelete?.bookName ?? "")”的阅读记录吗？")
        }
    }

    @ViewBuilder private func destination(for record: ReadRecordSummary) -> some View {
        if let book = books.books.first(where: { $0.name == record.bookName }) {
            BookshelfReadView(
                book: book,
                source: sources.sources.first(where: { $0.bookSourceUrl == book.origin })
            )
        } else {
            SearchView(initialKeyword: record.bookName)
        }
    }

    @ViewBuilder private func sortButton(_ title: String, value: Int) -> some View {
        Button {
            sortMode = value
        } label: {
            if sortMode == value { Label(title, systemImage: "checkmark") }
            else { Text(title) }
        }
    }

    private func duration(_ milliseconds: Int64) -> String {
        let value = max(milliseconds, 0)
        let days = value / 86_400_000
        let hours = value % 86_400_000 / 3_600_000
        let minutes = value % 3_600_000 / 60_000
        let seconds = value % 60_000 / 1_000
        var result = ""
        if days > 0 { result += "\(days)天" }
        if hours > 0 { result += "\(hours)小时" }
        if minutes > 0 { result += "\(minutes)分钟" }
        if seconds > 0 { result += "\(seconds)秒" }
        return result.isEmpty ? "0秒" : result
    }

    private func date(_ milliseconds: Int64) -> String {
        let formatter = DateFormatter()
        guard milliseconds > 0 else { return "" }
        formatter.locale = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000))
    }
}


/// 记住书架上每本书的封面地址（按书名），书移出书架后阅读记录仍能显示原封面。
enum ReadRecordCoverStore {
    private static let key = "readRecordCovers"

    static func cover(for bookName: String) -> (url: String, author: String)? {
        guard let all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: String]],
              let entry = all[bookName], let url = entry["url"], !url.isEmpty else { return nil }
        return (url, entry["author"] ?? "")
    }

    static func remember(_ books: [Book]) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: String]] ?? [:]
        var changed = false
        for book in books {
            guard let url = book.coverUrl, !url.isEmpty else { continue }
            let entry = ["url": url, "author": book.author]
            if all[book.name] != entry {
                all[book.name] = entry
                changed = true
            }
        }
        if changed { UserDefaults.standard.set(all, forKey: key) }
    }
}
