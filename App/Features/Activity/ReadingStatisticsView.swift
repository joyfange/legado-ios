import SwiftUI
#if SWIFT_PACKAGE
import LegadoCore
#endif

// MARK: - 统计页（版式参考 joyfange/bookon：今日目标环 / 连续阅读热力图 / 今年在读 / 趋势图 / 常读书籍）

enum ReadingStatsRange: String, CaseIterable, Identifiable {
    case week, month
    var id: String { rawValue }
    var days: Int { self == .week ? 7 : 30 }
    var title: String { self == .week ? "近 7 天" : "近 30 天" }
}

/// 从阅读记录（每本书每天的阅读毫秒数）汇总出统计页需要的全部数字。纯计算，不改数据。
struct ReadingStatsDigest {
    let calendar: Calendar
    let today: Date
    /// 每天（当天 0 点）的阅读毫秒数。
    let daily: [Date: Int64]
    /// 每天读过的书。
    let booksByDay: [Date: Set<String>]
    let totalReadTime: Int64
    let bookCount: Int

    init(records: [ReadRecord], now: Date = Date(), calendar: Calendar = .current) {
        self.calendar = calendar
        today = calendar.startOfDay(for: now)
        var daily: [Date: Int64] = [:]
        var books: [Date: Set<String>] = [:]
        for record in records {
            for (key, value) in record.dailyReadTimes where value > 0 {
                guard let day = Self.date(fromKey: key, calendar: calendar) else { continue }
                daily[day, default: 0] += value
                if !record.bookName.isEmpty { books[day, default: []].insert(record.bookName) }
            }
        }
        self.daily = daily
        booksByDay = books
        totalReadTime = records.reduce(0) { $0 + max($1.readTime, 0) }
        bookCount = Set(records.lazy.map(\.bookName).filter { !$0.isEmpty }).count
    }

    static func date(fromKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
            .map { calendar.startOfDay(for: $0) }
    }

    func readTime(on day: Date) -> Int64 { daily[calendar.startOfDay(for: day)] ?? 0 }
    var todayReadTime: Int64 { readTime(on: today) }

    private func shift(_ date: Date, by days: Int) -> Date {
        calendar.date(byAdding: .day, value: days, to: date) ?? date
    }

    /// 当前连续：今天没读时保留到昨天为止。
    var currentStreak: Int {
        var cursor: Date? = readTime(on: today) > 0 ? today : (readTime(on: shift(today, by: -1)) > 0 ? shift(today, by: -1) : nil)
        var count = 0
        while let day = cursor, readTime(on: day) > 0 {
            count += 1
            cursor = shift(day, by: -1)
        }
        return count
    }

    var longestStreak: Int {
        let days = daily.filter { $0.value > 0 }.keys.sorted()
        var best = 0, run = 0
        var previous: Date?
        for day in days {
            if let previous, calendar.dateComponents([.day], from: previous, to: day).day == 1 {
                run += 1
            } else {
                run = 1
            }
            best = max(best, run)
            previous = day
        }
        return best
    }

    /// 最近 n 天（含今天），从早到晚。
    func days(_ count: Int) -> [(date: Date, time: Int64)] {
        (0..<max(count, 1)).reversed().map { offset in
            let day = shift(today, by: -offset)
            return (date: day, time: readTime(on: day))
        }
    }

    /// 热力图：weeks 列，每列周一到周日；未来的日子为 -1。
    func heatmap(weeks: Int, goalMinutes: Int) -> [[Int]] {
        let weekday = calendar.component(.weekday, from: today) // 1 = 周日
        let mondayOffset = (weekday + 5) % 7
        let thisMonday = shift(today, by: -mondayOffset)
        let goal = Double(max(goalMinutes, 1)) * 60_000
        return (0..<weeks).map { column in
            let monday = shift(thisMonday, by: -7 * (weeks - 1 - column))
            return (0..<7).map { row in
                let day = shift(monday, by: row)
                if day > today { return -1 }
                let value = Double(readTime(on: day))
                guard value > 0 else { return 0 }
                let ratio = value / goal
                if ratio < 0.25 { return 1 }
                if ratio < 0.6 { return 2 }
                if ratio < 1 { return 3 }
                return 4
            }
        }
    }

    var todayRow: Int { (calendar.component(.weekday, from: today) + 5) % 7 }

    /// 今年每月读过的书（本数）与今年读过的书总数。
    func yearlyBooks() -> (monthly: [Int], total: Int) {
        let year = calendar.component(.year, from: today)
        var months = Array(repeating: Set<String>(), count: 12)
        var all = Set<String>()
        for (day, names) in booksByDay where calendar.component(.year, from: day) == year {
            let month = calendar.component(.month, from: day) - 1
            guard months.indices.contains(month) else { continue }
            months[month].formUnion(names)
            all.formUnion(names)
        }
        return (months.map(\.count), all.count)
    }

    /// 某段时间里读得最多的书。
    func topBooks(records: [ReadRecord], days count: Int, limit: Int = 3) -> [(name: String, time: Int64)] {
        let start = shift(today, by: -(count - 1))
        var totals: [String: Int64] = [:]
        for record in records where !record.bookName.isEmpty {
            for (key, value) in record.dailyReadTimes where value > 0 {
                guard let day = Self.date(fromKey: key, calendar: calendar), day >= start, day <= today else { continue }
                totals[record.bookName, default: 0] += value
            }
        }
        return totals.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit).map { (name: $0.key, time: $0.value) }
    }
}

struct ReadingStatisticsView: View {
    @EnvironmentObject private var activity: ReadingActivityModel
    @ThemePalette private var palette
    @AppStorage("stats.dailyGoalMinutes") private var dailyGoal = 30
    @State private var range: ReadingStatsRange = .week
    @State private var showStreakInfo = false

    private static let goalChoices = [10, 15, 20, 30, 45, 60, 90, 120]

    var body: some View {
        let digest = ReadingStatsDigest(records: activity.readRecords)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(digest)
                    .padding(.top, 14)
                sectionTitle("阅读目标")
                dailyCard(digest)
                streakCard(digest).padding(.top, 14)
                yearlyCard(digest).padding(.top, 14)
                sectionTitle("阅读趋势")
                trendCard(digest)
                topBooksCard(digest).padding(.top, 14)
                historyLink.padding(.top, 14)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 44)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .readingCanvas()
        .foregroundStyle(ReadingTheme.ink)
        .navigationBarHidden(true)
        .alert("连续阅读", isPresented: $showStreakInfo) {
            Button("好", role: .cancel) {}
        } message: {
            Text("一天里读过正文就算连续。今天还没读时，记录会保留到昨天为止。热力图颜色越深，离每日目标越近。")
        }
    }

    // MARK: 版式

    private func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        AppFontStyle.system(size: size, weight: weight).themed
    }

    private func header(_ digest: ReadingStatsDigest) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Self.weekdayName(digest.today, calendar: digest.calendar))
                .font(font(15, .medium))
                .foregroundStyle(ReadingTheme.secondaryInk)
            Text("\(digest.calendar.component(.month, from: digest.today))月\(digest.calendar.component(.day, from: digest.today))日")
                .font(font(34, .bold))
            Text(digest.todayReadTime < 30_000 ? "今天还没开始读" : "今天已读 \(Self.minutesText(digest.todayReadTime))")
                .font(font(17))
                .foregroundStyle(ReadingTheme.secondaryInk)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(font(20, .bold))
            .padding(.top, 30)
            .padding(.bottom, 12)
            .accessibilityAddTraits(.isHeader)
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ThemeSurface(shape: RoundedRectangle(cornerRadius: palette.cornerRadius(default: 26), style: .continuous),
                             isCard: true)
            }
    }

    private var dotsLabel: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(ReadingTheme.secondaryInk)
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
    }

    // MARK: 今日阅读

    private func dailyCard(_ digest: ReadingStatsDigest) -> some View {
        let today = digest.todayReadTime
        let goal = Double(max(dailyGoal, 1)) * 60_000
        let progress = min(Double(today) / goal, 1)
        let week = digest.days(7).reduce(0) { $0 + $1.time }
        return card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Text("今日阅读").font(font(17, .semibold))
                    Spacer(minLength: 0)
                    Menu {
                        Picker("每日目标", selection: $dailyGoal) {
                            ForEach(Self.goalChoices, id: \.self) { value in
                                Text("\(value) 分钟").tag(value)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("目标 \(dailyGoal) 分钟").font(font(14))
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(ReadingTheme.secondaryInk)
                        .frame(minHeight: 32)
                    }
                    .accessibilityLabel("调整每日目标")
                }
                HStack(alignment: .center, spacing: 18) {
                    ReadingGoalRing(progress: progress)
                        .frame(width: 104, height: 104)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(Self.clockText(today))
                            .font(font(38, .bold).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        HStack(spacing: 22) {
                            miniStat(icon: "flame", title: "本周", value: Self.minutesText(week))
                            miniStat(icon: "books.vertical", title: "累计", value: Self.minutesText(digest.totalReadTime))
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("statistics.todayCard")
    }

    private func miniStat(icon: String, title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 13, weight: .medium))
                Text(title).font(font(14))
            }
            .foregroundStyle(ReadingTheme.secondaryInk)
            Text(value)
                .font(font(14, .semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: 连续阅读

    private func streakCard(_ digest: ReadingStatsDigest) -> some View {
        card {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("连续阅读").font(font(17, .semibold))
                    Spacer(minLength: 0)
                    Button { showStreakInfo = true } label: { dotsLabel }
                        .buttonStyle(.plain)
                        .accessibilityLabel("连续阅读怎么算")
                }
                HStack(alignment: .top, spacing: 12) {
                    bigNumber(title: "当前连续", value: "\(digest.currentStreak)", unit: "天")
                    bigNumber(title: "最长纪录", value: "\(digest.longestStreak)", unit: "天")
                    bigNumber(title: "读过", value: "\(digest.bookCount)", unit: "本")
                }
                ReadingHeatmap(levels: digest.heatmap(weeks: 18, goalMinutes: dailyGoal), todayRow: digest.todayRow)
                HStack(spacing: 0) {
                    Text("近 18 周").font(font(12)).foregroundStyle(ReadingTheme.secondaryInk)
                    Spacer(minLength: 8)
                    ReadingHeatmapLegend()
                }
            }
        }
    }

    private func bigNumber(title: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(font(13)).foregroundStyle(ReadingTheme.secondaryInk)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(font(30, .bold).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(unit).font(font(13)).foregroundStyle(ReadingTheme.secondaryInk)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: 今年在读

    private func yearlyCard(_ digest: ReadingStatsDigest) -> some View {
        let yearly = digest.yearlyBooks()
        return card {
            VStack(alignment: .leading, spacing: 14) {
                Text("今年在读").font(font(17, .semibold))
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("\(yearly.total)").font(font(38, .bold).monospacedDigit())
                    Text("本书").font(font(17)).foregroundStyle(ReadingTheme.secondaryInk)
                }
                ReadingYearlyBars(counts: yearly.monthly,
                                  currentMonth: digest.calendar.component(.month, from: digest.today) - 1)
                    .frame(height: 110)
                Text("每月读过（打开阅读过正文）的书本数，同一本书在不同月份分别计算。")
                    .font(font(13))
                    .foregroundStyle(ReadingTheme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 趋势

    private func trendCard(_ digest: ReadingStatsDigest) -> some View {
        let days = digest.days(range.days)
        let total = days.reduce(0) { $0 + $1.time }
        let average = total / Int64(max(range.days, 1))
        return card {
            VStack(alignment: .leading, spacing: 16) {
                ReadingStatsRangePicker(range: $range)
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("日均").font(font(13)).foregroundStyle(ReadingTheme.secondaryInk)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("\(Int((Double(average) / 60_000).rounded()))")
                                .font(font(32, .bold).monospacedDigit())
                            Text("分钟").font(font(13)).foregroundStyle(ReadingTheme.secondaryInk)
                        }
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("合计").font(font(13)).foregroundStyle(ReadingTheme.secondaryInk)
                        Text(Self.minutesText(total)).font(font(17, .bold).monospacedDigit())
                    }
                }
                ReadingTrendChart(days: days.map { (date: $0.date, minutes: Double($0.time) / 60_000) },
                                  goalMinutes: dailyGoal, range: range)
                    .frame(height: 160)
                    .animation(.easeInOut(duration: 0.25), value: range)
                HStack(spacing: 16) {
                    legend(color: ReadingTheme.accent, title: "阅读时长")
                    legend(color: ReadingTheme.secondaryInk.opacity(0.5), title: "虚线：每日目标")
                }
            }
        }
    }

    private func legend(color: Color, title: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).font(font(12)).foregroundStyle(ReadingTheme.secondaryInk)
        }
    }

    // MARK: 常读

    @ViewBuilder
    private func topBooksCard(_ digest: ReadingStatsDigest) -> some View {
        let books = digest.topBooks(records: activity.readRecords, days: range.days)
        if !books.isEmpty {
            let maximum = max(books.first?.time ?? 1, 1)
            card {
                VStack(alignment: .leading, spacing: 14) {
                    Text("\(range.title)常读").font(font(17, .semibold))
                    ForEach(Array(books.enumerated()), id: \.offset) { index, book in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 10) {
                                Text("\(index + 1)")
                                    .font(font(13, .bold).monospacedDigit())
                                    .foregroundStyle(index == 0 ? ReadingTheme.onAccent : ReadingTheme.secondaryInk)
                                    .frame(width: 22, height: 22)
                                    .background(Circle().fill(index == 0 ? ReadingTheme.accent : ReadingTheme.separator))
                                Text(book.name).font(font(15, .medium)).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(Self.minutesText(book.time))
                                    .font(font(13).monospacedDigit())
                                    .foregroundStyle(ReadingTheme.secondaryInk)
                            }
                            GeometryReader { geometry in
                                Capsule().fill(ReadingTheme.separator.opacity(0.6))
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(ReadingTheme.accent.opacity(index == 0 ? 1 : 0.55))
                                            .frame(width: max(6, geometry.size.width * CGFloat(book.time) / CGFloat(maximum)))
                                    }
                            }
                            .frame(height: 5)
                            .padding(.leading, 32)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private var historyLink: some View {
        NavigationLink {
            ReadingHistoryView()
        } label: {
            card {
                HStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 19, weight: .medium))
                    Text("阅读记录").font(font(16, .medium))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ReadingTheme.secondaryInk)
                }
                .foregroundStyle(ReadingTheme.accent)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: 文本

    static func weekdayName(_ date: Date, calendar: Calendar) -> String {
        let symbols = ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"]
        return symbols[min(max(calendar.component(.weekday, from: date) - 1, 0), 6)]
    }

    static func minutesText(_ milliseconds: Int64) -> String {
        let minutes = Int((Double(max(milliseconds, 0)) / 60_000).rounded())
        if minutes < 60 { return "\(minutes) 分钟" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) 小时" : "\(hours) 小时 \(rest) 分"
    }

    static func clockText(_ milliseconds: Int64) -> String {
        let total = Int(max(milliseconds, 0) / 60_000)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - 目标环

struct ReadingGoalRing: View {
    let progress: Double

    var body: some View {
        let value = min(max(progress, 0), 1)
        ZStack {
            Circle()
                .inset(by: 6)
                .stroke(ReadingTheme.accent.opacity(0.14), lineWidth: 11)
            Circle()
                .inset(by: 6)
                .trim(from: 0, to: max(0.0001, value))
                .stroke(
                    AngularGradient(gradient: Gradient(colors: [ReadingTheme.accent.opacity(0.55), ReadingTheme.accent]),
                                    center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * max(value, 0.01))),
                    style: StrokeStyle(lineWidth: 11, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .opacity(value > 0.001 ? 1 : 0)
            VStack(spacing: 0) {
                Text("\(Int((value * 100).rounded()))%")
                    .font(AppFontStyle.system(size: 18, weight: .bold).themed.monospacedDigit())
                Text(value >= 1 ? "已达成" : "目标")
                    .font(AppFontStyle.system(size: 11).themed)
                    .foregroundStyle(ReadingTheme.secondaryInk)
            }
        }
        .animation(.easeOut(duration: 0.4), value: value)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("今日目标完成 \(Int((value * 100).rounded()))%")
    }
}

// MARK: - 热力图

struct ReadingHeatmap: View {
    let levels: [[Int]]
    let todayRow: Int

    var body: some View {
        HStack(spacing: 3.5) {
            ForEach(levels.indices, id: \.self) { column in
                VStack(spacing: 3.5) {
                    ForEach(levels[column].indices, id: \.self) { row in
                        let level = levels[column][row]
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Self.fill(level))
                            .aspectRatio(1, contentMode: .fit)
                            .overlay {
                                if column == levels.count - 1, row == todayRow {
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .strokeBorder(ReadingTheme.accent, lineWidth: 1.5)
                                }
                            }
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("近 18 周阅读记录")
    }

    static func fill(_ level: Int) -> Color {
        switch level {
        case ..<0: return .clear
        case 0: return ReadingTheme.accent.opacity(0.08)
        case 1: return ReadingTheme.accent.opacity(0.3)
        case 2: return ReadingTheme.accent.opacity(0.55)
        case 3: return ReadingTheme.accent.opacity(0.8)
        default: return ReadingTheme.accent
        }
    }
}

struct ReadingHeatmapLegend: View {
    var body: some View {
        HStack(spacing: 4) {
            Text("少").font(AppFontStyle.system(size: 12).themed).foregroundStyle(ReadingTheme.secondaryInk)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(ReadingHeatmap.fill(level))
                    .frame(width: 10, height: 10)
            }
            Text("多").font(AppFontStyle.system(size: 12).themed).foregroundStyle(ReadingTheme.secondaryInk)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - 今年每月柱状图

struct ReadingYearlyBars: View {
    let counts: [Int]
    let currentMonth: Int

    var body: some View {
        let maximum = max(counts.max() ?? 0, 1)
        GeometryReader { geometry in
            let labelHeight: CGFloat = 16
            let area = max(geometry.size.height - labelHeight - 6, 1)
            let slot = geometry.size.width / 12
            let barWidth = min(20, slot * 0.6)
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(0..<12, id: \.self) { index in
                    let value = counts.indices.contains(index) ? counts[index] : 0
                    VStack(spacing: 6) {
                        Spacer(minLength: 0)
                        if value > 0 {
                            Text("\(value)")
                                .font(AppFontStyle.system(size: 10, weight: .semibold).themed.monospacedDigit())
                                .foregroundStyle(ReadingTheme.secondaryInk)
                        }
                        RoundedRectangle(cornerRadius: min(barWidth / 2, 6), style: .continuous)
                            .fill(index > currentMonth ? ReadingTheme.separator.opacity(0.5)
                                  : (value > 0 ? ReadingTheme.accent.opacity(index == currentMonth ? 1 : 0.6)
                                     : ReadingTheme.accent.opacity(0.1)))
                            .frame(width: barWidth,
                                   height: value > 0 ? max(6, (area - 16) * CGFloat(value) / CGFloat(maximum)) : 4)
                        Text("\(index + 1)")
                            .font(AppFontStyle.system(size: 10).themed)
                            .foregroundStyle(index == currentMonth ? ReadingTheme.accent : ReadingTheme.secondaryInk)
                            .frame(height: labelHeight)
                    }
                    .frame(width: slot)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("今年每月读过的书")
    }
}

// MARK: - 趋势图

struct ReadingTrendChart: View {
    let days: [(date: Date, minutes: Double)]
    let goalMinutes: Int
    let range: ReadingStatsRange

    private var axis: (maximum: Double, step: Double) {
        let peak = days.map { $0.minutes }.max() ?? 0
        let need = max(peak, Double(goalMinutes) * 1.25, 8)
        let step = max(ceil(need / 4 / 5) * 5, 5)
        return (step * 4, step)
    }

    var body: some View {
        let axis = axis
        GeometryReader { geometry in
            let labelWidth: CGFloat = 30
            let plotWidth = max(geometry.size.width - labelWidth, 1)
            let plotHeight = max(geometry.size.height - 22, 1)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 0) {
                    plot(width: plotWidth, height: plotHeight, maximum: axis.maximum)
                        .frame(width: plotWidth, height: plotHeight)
                    ZStack(alignment: .topTrailing) {
                        ForEach(0...4, id: \.self) { index in
                            let value = axis.maximum - axis.step * Double(index)
                            Text("\(Int(value))")
                                .font(AppFontStyle.system(size: 10).themed.monospacedDigit())
                                .foregroundStyle(ReadingTheme.secondaryInk)
                                .frame(width: labelWidth, height: 12, alignment: .trailing)
                                .offset(y: y(value, height: plotHeight, maximum: axis.maximum) - 6)
                        }
                    }
                    .frame(width: labelWidth, height: plotHeight, alignment: .topTrailing)
                }
                dayLabels(width: plotWidth)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(range.title)每日阅读时长")
    }

    private func y(_ minutes: Double, height: CGFloat, maximum: Double) -> CGFloat {
        height - CGFloat(min(max(minutes / maximum, 0), 1)) * height
    }

    private func plot(width: CGFloat, height: CGFloat, maximum: Double) -> some View {
        let slot = width / CGFloat(max(days.count, 1))
        let barWidth: CGFloat = range == .week ? min(22, slot * 0.46) : max(3, slot * 0.55)
        let goalY = y(Double(goalMinutes), height: height, maximum: maximum)
        return ZStack(alignment: .topLeading) {
            ForEach(0...4, id: \.self) { step in
                Rectangle()
                    .fill(ReadingTheme.separator.opacity(0.6))
                    .frame(width: width, height: 0.5)
                    .offset(y: height * CGFloat(step) / 4)
            }
            Path { path in
                path.move(to: CGPoint(x: 0, y: goalY))
                path.addLine(to: CGPoint(x: width, y: goalY))
            }
            .stroke(ReadingTheme.secondaryInk.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(days.indices, id: \.self) { index in
                    let minutes = days[index].minutes
                    let isLast = index == days.count - 1
                    let barHeight = minutes > 0 ? max(3, CGFloat(min(minutes / maximum, 1)) * height) : 2
                    RoundedRectangle(cornerRadius: min(barWidth / 2, 5), style: .continuous)
                        .fill(minutes <= 0 ? ReadingTheme.separator
                              : (minutes >= Double(goalMinutes) || isLast ? ReadingTheme.accent : ReadingTheme.accent.opacity(0.5)))
                        .frame(width: barWidth, height: barHeight)
                        .frame(width: slot, height: height, alignment: .bottom)
                }
            }
            .frame(width: width, height: height, alignment: .bottomLeading)
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }

    private func dayLabels(width: CGFloat) -> some View {
        let slot = width / CGFloat(max(days.count, 1))
        let calendar = Calendar.current
        return ZStack(alignment: .topLeading) {
            ForEach(days.indices, id: \.self) { index in
                if days.count <= 7 || index % 5 == 0 || index == days.count - 1 {
                    Text(label(index, calendar: calendar))
                        .font(AppFontStyle.system(size: 11).themed)
                        .foregroundStyle(index == days.count - 1 ? ReadingTheme.accent : ReadingTheme.secondaryInk)
                        .fixedSize()
                        .position(x: slot * (CGFloat(index) + 0.5), y: 8)
                }
            }
        }
        .frame(width: width, height: 16, alignment: .topLeading)
    }

    private func label(_ index: Int, calendar: Calendar) -> String {
        let date = days[index].date
        if days.count <= 7 {
            if index == days.count - 1 { return "今天" }
            let symbols = ["日", "一", "二", "三", "四", "五", "六"]
            return symbols[(calendar.component(.weekday, from: date) - 1 + 7) % 7]
        }
        return "\(calendar.component(.month, from: date)).\(calendar.component(.day, from: date))"
    }
}

struct ReadingStatsRangePicker: View {
    @Binding var range: ReadingStatsRange
    @Namespace private var animation

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ReadingStatsRange.allCases) { item in
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { range = item }
                } label: {
                    Text(item.title)
                        .font(AppFontStyle.system(size: 15, weight: range == item ? .semibold : .regular).themed)
                        .foregroundStyle(range == item ? ReadingTheme.ink : ReadingTheme.secondaryInk)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background {
                            if range == item {
                                Capsule()
                                    .fill(ReadingTheme.surface)
                                    .matchedGeometryEffect(id: "stats.range", in: animation)
                                    .shadow(color: .black.opacity(0.08), radius: 3, x: 0, y: 1)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(range == item ? .isSelected : [])
            }
        }
        .padding(3)
        .background { Capsule().fill(ReadingTheme.ink.opacity(0.06)) }
    }
}
