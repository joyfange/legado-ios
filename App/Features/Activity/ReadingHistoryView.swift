import SwiftUI

struct ReadingHistoryView: View {
    @EnvironmentObject private var activity: ReadingActivityModel
    @EnvironmentObject private var books: BookLibraryModel
    @EnvironmentObject private var sources: SourceLibraryModel
    @ThemePalette private var palette
    @AppStorage("enableReadRecord") private var enableReadRecord = true
    @AppStorage("readRecordSort") private var sortMode = 0
    @State private var searchText = ""
    @State private var confirmsClear = false
    @State private var pendingDelete: ReadRecordSummary?

    var body: some View {
        // 每次刷新只汇总一次（之前一屏里重复汇总、每行都线性查书架、读一次 UserDefaults、新建日期格式器）。
        let summaries = activity.summaries
        Group {
            if summaries.isEmpty {
                ReadingUnavailableView(
                    "还没有阅读记录",
                    systemImage: "clock.arrow.circlepath",
                    description: Text(enableReadRecord ? "翻页后会按设备累计阅读时长。" : "阅读记录当前已关闭。")
                )
            } else {
                recordList(summaries: summaries)
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
                    if !summaries.isEmpty {
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

    // MARK: 列表

    /// 顶部一张汇总卡片，下面按日期（最后阅读排序时）或按排序方式分组；每条记录一张独立的圆角卡片
    /// （与「外观主题」的行同一种卡片底，跟随系统 / 透明 / 毛玻璃三种界面效果）。
    private func recordList(summaries: [ReadRecordSummary]) -> some View {
        let displayed = activity.summaries(searchKey: searchText, sortMode: sortMode)
        let shelf = Dictionary(books.books.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let savedCovers = ReadRecordCoverStore.all()
        let sourceByURL = Dictionary(sources.sources.map { ($0.bookSourceUrl, $0) }, uniquingKeysWith: { first, _ in first })
        let groups = ReadingHistoryGrouping.groups(displayed, sortMode: sortMode)
        return List {
            summaryCard(summaries)
                .historyRow(top: 10, bottom: 6)
            if displayed.isEmpty {
                ReadingUnavailableView.search(text: searchText)
                    .historyRow(top: 24, bottom: 0)
            } else {
                ForEach(groups) { group in
                    groupHeader(group)
                        .historyRow(top: 18, bottom: 4)
                    ForEach(group.records) { record in
                        let book = shelf[record.bookName]
                        recordRow(record, book: book, source: book.flatMap { sourceByURL[$0.origin] },
                                  saved: savedCovers[record.bookName], showsDay: group.kind != .day)
                            .historyRow(top: 4, bottom: 4)
                            .swipeActions {
                                Button("删除", role: .destructive) { pendingDelete = record }
                            }
                    }
                }
            }
            Color.clear.frame(height: 12).historyRow(top: 0, bottom: 0)
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 1)
        .readingThemedListBackground()
    }

    private func summaryCard(_ summaries: [ReadRecordSummary]) -> some View {
        let total = summaries.reduce(Int64(0)) { $0 + max($1.readTime, 0) }
        return AppearanceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 0) {
                    summaryStat(icon: "clock", title: "累计阅读", parts: ReadingHistoryFormat.durationParts(total))
                    Rectangle()
                        .fill(palette.border.opacity(0.5))
                        .frame(width: 0.5, height: 44)
                        .padding(.horizontal, 14)
                        .padding(.top, 4)
                    summaryStat(icon: "books.vertical", title: "读过", parts: [("\(summaries.count)", "本")])
                }
                if !enableReadRecord {
                    Label("记录阅读时长已关闭", systemImage: "pause.circle")
                        .font(AppFontStyle.caption.themed)
                        .foregroundStyle(palette.secondary)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func summaryStat(icon: String, title: String, parts: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                Text(title).font(AppFontStyle.footnote.themed)
            }
            .foregroundStyle(palette.secondary)
            parts.reduce(Text("")) { (text: Text, part: (String, String)) -> Text in
                text
                    + Text(part.0).font(AppFontStyle.system(size: 30, weight: .bold).themed.monospacedDigit())
                        .foregroundColor(palette.primary)
                    + Text(part.1).font(AppFontStyle.system(size: 14, weight: .medium).themed)
                        .foregroundColor(palette.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func groupHeader(_ group: ReadingHistoryGroup) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(group.title)
                .font(AppFontStyle.subheadline.weight(.semibold).themed)
                .foregroundStyle(palette.primary)
            Spacer(minLength: 8)
            Text("\(group.records.count) 本")
                .font(AppFontStyle.footnote.themed)
                .foregroundStyle(palette.secondary)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func recordRow(_ record: ReadRecordSummary, book: Book?, source: BookSource?,
                           saved: (url: String, author: String)?, showsDay: Bool) -> some View {
        ZStack {
            // 隐藏的链接负责点按进入（不显示系统的箭头，箭头画在卡片里）；目标页点进去时才创建。
            NavigationLink {
                ExploreLazyView { Self.destination(for: record, book: book, source: source) }
            } label: {
                EmptyView()
            }
            .opacity(0)
            AppearanceCard {
                HStack(spacing: 14) {
                    // 书在书架上用书架封面；已移出书架时用之前记下的封面。
                    BookCoverArtwork(
                        title: record.bookName,
                        author: book?.author ?? saved?.author ?? "",
                        remoteURL: book?.displayCoverUrl ?? saved?.url,
                        width: 50,
                        height: 70,
                        cornerRadius: 6
                    )
                    VStack(alignment: .leading, spacing: 7) {
                        Text(record.bookName)
                            .font(AppFontStyle.headline.themed)
                            .foregroundStyle(palette.primary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            HStack(spacing: 3) {
                                Image(systemName: "clock").font(.system(size: 10, weight: .semibold))
                                Text(ReadingHistoryFormat.duration(record.readTime))
                                    .font(AppFontStyle.caption.themed.monospacedDigit())
                            }
                            .foregroundStyle(palette.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(palette.accent.opacity(0.12), in: Capsule())
                            Text(ReadingHistoryFormat.time(record.lastRead, includesDay: showsDay))
                                .font(AppFontStyle.caption.themed.monospacedDigit())
                                .foregroundStyle(palette.secondary)
                                .lineLimit(1)
                        }
                        if let book, BookReadingPresentation.hasStarted(book), book.totalChapterNum > 0 {
                            let progress = BookReadingPresentation.progress(book)
                            HStack(spacing: 8) {
                                ReadingProgressLine(value: progress)
                                    .frame(maxWidth: 150)
                                Text("已读 \(Int((progress * 100).rounded()))%")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(palette.secondary)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.secondary.opacity(0.7))
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// 书在书架上就打开阅读，否则按书名搜索（与之前相同）；书和书源在列表刷新时就查好，目标页点进去时才创建。
    @ViewBuilder private static func destination(for record: ReadRecordSummary, book: Book?, source: BookSource?) -> some View {
        if let book {
            BookshelfReadView(book: book, source: source)
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
}

private extension View {
    /// 阅读记录列表里的一行：去掉系统行底和分隔线，四周留白由卡片自己决定。
    func historyRow(top: CGFloat, bottom: CGFloat) -> some View {
        listRowInsets(EdgeInsets(top: top, leading: 16, bottom: bottom, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

/// 阅读记录分组：按「最后阅读」排序时按日期分（今天 / 昨天 / 日期），其它排序保持原有顺序放在一组里。
struct ReadingHistoryGroup: Identifiable {
    enum Kind { case day, all }
    let id: String
    let title: String
    let kind: Kind
    var records: [ReadRecordSummary]
}

enum ReadingHistoryGrouping {
    static func groups(_ records: [ReadRecordSummary], sortMode: Int,
                       now: Date = Date(), calendar: Calendar = .current) -> [ReadingHistoryGroup] {
        guard !records.isEmpty else { return [] }
        guard sortMode == 2 else {
            let title = sortMode == 1 ? "按阅读时长" : "按书名"
            return [ReadingHistoryGroup(id: "all", title: title, kind: .all, records: records)]
        }
        let today = calendar.startOfDay(for: now)
        var result: [ReadingHistoryGroup] = []
        for record in records {
            let key: String
            let title: String
            if record.lastRead > 0 {
                let day = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(record.lastRead) / 1_000))
                key = String(Int(day.timeIntervalSince1970))
                title = ReadingHistoryFormat.dayTitle(day, today: today, calendar: calendar)
            } else {
                key = "unknown"
                title = "更早"
            }
            if let last = result.indices.last, result[last].id == key {
                result[last].records.append(record)
            } else {
                result.append(ReadingHistoryGroup(id: key, title: title, kind: .day, records: [record]))
            }
        }
        return result
    }
}

enum ReadingHistoryFormat {
    nonisolated(unsafe) private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
    nonisolated(unsafe) private static let monthDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEEE"
        return formatter
    }()
    nonisolated(unsafe) private static let fullDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter
    }()
    nonisolated(unsafe) private static let shortDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()
    nonisolated(unsafe) private static let numericDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func dayTitle(_ day: Date, today: Date, calendar: Calendar) -> String {
        if day == today { return "今天" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), day == yesterday { return "昨天" }
        if calendar.component(.year, from: day) == calendar.component(.year, from: today) {
            return monthDay.string(from: day)
        }
        return fullDay.string(from: day)
    }

    /// 记录行里的时间：按日期分组时只显示几点；不分组时带上是哪天。
    static func time(_ milliseconds: Int64, includesDay: Bool,
                     now: Date = Date(), calendar: Calendar = .current) -> String {
        guard milliseconds > 0 else { return "" }
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        guard includesDay else { return clock.string(from: date) }
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        if day == today { return "今天 " + clock.string(from: date) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), day == yesterday {
            return "昨天 " + clock.string(from: date)
        }
        if calendar.component(.year, from: day) == calendar.component(.year, from: today) {
            return shortDate.string(from: date)
        }
        return numericDate.string(from: date)
    }

    static func duration(_ milliseconds: Int64) -> String {
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

    /// 汇总卡片的大数字：数字和单位分开排版（1 小时 3 分钟 / 12 分钟 9 秒 / 40 秒）。
    static func durationParts(_ milliseconds: Int64) -> [(String, String)] {
        let total = max(milliseconds, 0) / 1_000
        let hours = total / 3_600
        let minutes = total % 3_600 / 60
        let seconds = total % 60
        if hours > 0 {
            return minutes > 0 ? [("\(hours)", "小时"), ("\(minutes)", "分钟")] : [("\(hours)", "小时")]
        }
        if minutes > 0 {
            return seconds > 0 ? [("\(minutes)", "分钟"), ("\(seconds)", "秒")] : [("\(minutes)", "分钟")]
        }
        return [("\(seconds)", "秒")]
    }
}


/// 记住书架上每本书的封面地址（按书名），书移出书架后阅读记录仍能显示原封面。
enum ReadRecordCoverStore {
    private static let key = "readRecordCovers"

    /// 一次读出全部（阅读记录列表每次刷新只读一次 UserDefaults）。
    static func all() -> [String: (url: String, author: String)] {
        guard let all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: String]] else { return [:] }
        var result: [String: (url: String, author: String)] = [:]
        for (name, entry) in all {
            guard let url = entry["url"], !url.isEmpty else { continue }
            result[name] = (url, entry["author"] ?? "")
        }
        return result
    }

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
