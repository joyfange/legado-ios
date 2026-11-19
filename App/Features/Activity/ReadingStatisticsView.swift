import SwiftUI
#if SWIFT_PACKAGE
import LegadoCore
#endif

// MARK: - 统计页（今日目标环 / 趋势与环比 / 阅读日历 / 年度 / 个人纪录 / 书籍排行，全部玻璃卡片）

enum ReadingStatsRange: String, CaseIterable, Identifiable {
    case week, month
    var id: String { rawValue }
    var days: Int { self == .week ? 7 : 30 }
    var title: String { self == .week ? "近 7 天" : "近 30 天" }
}

enum ReadingStatsSettings {
    static let dailyGoalKey = "stats.dailyGoalMinutes"
    static let yearlyGoalKey = "stats.yearlyGoalBooks"
    static let streakMinimumKey = "stats.streakMinimumMinutes"
}

/// 从阅读记录（每本书每天的阅读毫秒数）汇总出统计页需要的全部数字。纯计算，不改数据。
struct ReadingStatsDigest {
    let calendar: Calendar
    let today: Date
    /// 每天（当天 0 点）的阅读毫秒数。
    let daily: [Date: Int64]
    /// 每天每本书的阅读毫秒数。
    let bookTimesByDay: [Date: [String: Int64]]
    let totalReadTime: Int64
    let bookCount: Int
    /// 一天读满这么久才计入连续天数 / 阅读天数（毫秒）。
    let minimumDailyTime: Int64

    init(records: [ReadRecord], now: Date = Date(), calendar: Calendar = .current, minimumDailyMinutes: Int = 0) {
        self.calendar = calendar
        today = calendar.startOfDay(for: now)
        minimumDailyTime = Int64(max(minimumDailyMinutes, 0)) * 60_000
        var daily: [Date: Int64] = [:]
        var books: [Date: [String: Int64]] = [:]
        for record in records {
            for (key, value) in record.dailyReadTimes where value > 0 {
                guard let day = Self.date(fromKey: key, calendar: calendar) else { continue }
                daily[day, default: 0] += value
                if !record.bookName.isEmpty { books[day, default: [:]][record.bookName, default: 0] += value }
            }
        }
        self.daily = daily
        bookTimesByDay = books
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

    /// 这一天是否算「读过」：有阅读时长，且达到连续天数的最低计入时长。
    func isActive(_ day: Date) -> Bool {
        let value = readTime(on: day)
        return value > 0 && value >= minimumDailyTime
    }

    func shift(_ date: Date, by days: Int) -> Date {
        calendar.date(byAdding: .day, value: days, to: date) ?? date
    }

    /// 当前连续：今天没读时保留到昨天为止。
    var currentStreak: Int {
        var cursor: Date? = isActive(today) ? today : (isActive(shift(today, by: -1)) ? shift(today, by: -1) : nil)
        var count = 0
        while let day = cursor, isActive(day) {
            count += 1
            cursor = shift(day, by: -1)
        }
        return count
    }

    var longestStreak: Int {
        let days = daily.keys.filter { isActive($0) }.sorted()
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

    var activeDayCount: Int { daily.keys.filter { isActive($0) }.count }

    /// 读得最久的一天。
    var bestDay: (date: Date, time: Int64)? {
        guard let best = daily.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }),
              best.value > 0 else { return nil }
        return (date: best.key, time: best.value)
    }

    /// 最近 n 天（含今天），从早到晚。
    func days(_ count: Int) -> [(date: Date, time: Int64)] {
        (0..<max(count, 1)).reversed().map { offset in
            let day = shift(today, by: -offset)
            return (date: day, time: readTime(on: day))
        }
    }

    /// 从 start 起 count 天的总时长。
    func total(from start: Date, days count: Int) -> Int64 {
        (0..<max(count, 0)).reduce(0) { $0 + readTime(on: shift(start, by: $1)) }
    }

    func activeDays(from start: Date, days count: Int) -> Int {
        (0..<max(count, 0)).filter { isActive(shift(start, by: $0)) }.count
    }

    /// 从 start 起 count 天里读过的书。
    func books(from start: Date, days count: Int) -> Set<String> {
        var result = Set<String>()
        for offset in 0..<max(count, 0) {
            if let names = bookTimesByDay[shift(start, by: offset)]?.keys { result.formUnion(names) }
        }
        return result
    }

    /// 某天读过的书，按时长从多到少。
    func books(on day: Date) -> [(name: String, time: Int64)] {
        (bookTimesByDay[calendar.startOfDay(for: day)] ?? [:])
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { (name: $0.key, time: $0.value) }
    }

    /// 热力等级：0 没读，1～4 越接近每日目标越深。
    func level(on day: Date, goalMinutes: Int) -> Int {
        let value = Double(readTime(on: day))
        guard value > 0 else { return 0 }
        let ratio = value / (Double(max(goalMinutes, 1)) * 60_000)
        if ratio < 0.25 { return 1 }
        if ratio < 0.6 { return 2 }
        if ratio < 1 { return 3 }
        return 4
    }

    func startOfMonth(_ date: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? calendar.startOfDay(for: date)
    }

    /// 月历格子：周一开头，前面补空位，补齐整周。
    func monthGrid(_ month: Date) -> [Date?] {
        let first = startOfMonth(month)
        let count = calendar.range(of: .day, in: .month, for: first)?.count ?? 30
        let leading = (calendar.component(.weekday, from: first) + 5) % 7
        var cells: [Date?] = Array(repeating: nil, count: leading)
        cells += (0..<count).map { Optional(shift(first, by: $0)) }
        while cells.count % 7 != 0 { cells.append(nil) }
        return cells
    }

    /// 今年每月的阅读时长、今年总时长与今年读过的书。
    func yearly() -> (monthly: [Int64], total: Int64, books: Int) {
        let year = calendar.component(.year, from: today)
        var months = Array(repeating: Int64(0), count: 12)
        var names = Set<String>()
        for (day, value) in daily where calendar.component(.year, from: day) == year {
            let month = calendar.component(.month, from: day) - 1
            guard months.indices.contains(month) else { continue }
            months[month] += value
            if let books = bookTimesByDay[day]?.keys { names.formUnion(books) }
        }
        return (months, months.reduce(0, +), names.count)
    }

    /// 某段时间里读得最多的书。
    func topBooks(days count: Int, limit: Int = 5) -> [(name: String, time: Int64)] {
        let start = shift(today, by: -(count - 1))
        var totals: [String: Int64] = [:]
        for offset in 0..<max(count, 1) {
            for (name, value) in bookTimesByDay[shift(start, by: offset)] ?? [:] {
                totals[name, default: 0] += value
            }
        }
        return totals.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit).map { (name: $0.key, time: $0.value) }
    }
}

struct ReadingStatisticsView: View {
    @EnvironmentObject private var activity: ReadingActivityModel
    @ThemePalette private var palette
    @AppStorage(ReadingStatsSettings.dailyGoalKey) private var dailyGoal = 30
    @AppStorage(ReadingStatsSettings.yearlyGoalKey) private var yearlyGoal = 0
    @AppStorage(ReadingStatsSettings.streakMinimumKey) private var streakMinimum = 1
    @State private var range: ReadingStatsRange = .week
    @State private var displayedMonth: Date?
    @State private var selectedDay: Date?
    @State private var showsSettings = false

    var body: some View {
        let digest = ReadingStatsDigest(records: activity.readRecords, minimumDailyMinutes: streakMinimum)
        // 顶部只留与右上角按钮同一行的紧凑标题，卡片直接从下面开始；上滑后顶部栏铺出页面背景。
        VStack(spacing: 0) {
            ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ReadingLargeTitle(title: "阅读统计")
                    .padding(.bottom, -6)
                todayCard(digest)
                trendCard(digest)
                calendarCard(digest)
                yearlyCard(digest)
                recordsCard(digest)
                topBooksCard(digest)
                historyLink
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 44)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            }
            .readingTopScrollEdgeHidden()
        }
        .readingCanvas()
        .readingLargeTitleBar(title: "阅读统计") {
            Button { showsSettings = true } label: {
                ReadingToolbarIcon(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("统计设置")
            .accessibilityIdentifier("statistics.settings")
        }
        .foregroundStyle(ReadingTheme.ink)
        .navigationBarHidden(true)
        .sheet(isPresented: $showsSettings) {
            ReadingStatsSettingsView()
        }
    }

    // MARK: 版式

    private func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        AppFontStyle.system(size: size, weight: weight).themed
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ThemeSurface(shape: RoundedRectangle(cornerRadius: palette.cornerRadius(default: 24), style: .continuous),
                             isCard: true)
            }
    }

    private func cardTitle(_ text: String, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ReadingTheme.accent)
            Text(text).font(font(17, .semibold))
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// 卡片里的一列数字：数字在上、说明在下。
    private func figure(_ value: String, unit: String = "", title: String, alignment: HorizontalAlignment = .leading) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(font(19, .bold).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.6)
                if !unit.isEmpty {
                    Text(unit).font(font(12)).foregroundStyle(ReadingTheme.secondaryInk)
                }
            }
            Text(title).font(font(12)).foregroundStyle(ReadingTheme.secondaryInk).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
        .accessibilityElement(children: .combine)
    }

    private var softFill: Color { ReadingTheme.ink.opacity(0.05) }

    // MARK: 今日

    private func todayCard(_ digest: ReadingStatsDigest) -> some View {
        let today = digest.todayReadTime
        let goal = Double(max(dailyGoal, 1)) * 60_000
        let progress = min(Double(today) / goal, 1)
        let weekStart = digest.shift(digest.today, by: -6)
        let todayBooks = digest.books(on: digest.today).count
        return card {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    cardTitle("今日阅读", icon: "sun.max")
                    Spacer(minLength: 0)
                    Button { showsSettings = true } label: {
                        HStack(spacing: 4) {
                            Text("目标 \(dailyGoal) 分钟").font(font(13))
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(ReadingTheme.secondaryInk)
                        .frame(minHeight: 30)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("调整每日目标")
                }
                HStack(alignment: .center, spacing: 18) {
                    ReadingGoalRing(progress: progress)
                        .frame(width: 100, height: 100)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(Self.durationNumber(today))
                                .font(font(36, .bold).monospacedDigit())
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                            Text(Self.durationUnit(today)).font(font(14)).foregroundStyle(ReadingTheme.secondaryInk)
                        }
                        Text(progress >= 1 ? "今日目标已达成" : "距目标还差 \(Self.minutesText(max(Int64(goal) - today, 0)))")
                            .font(font(13))
                            .foregroundStyle(progress >= 1 ? ReadingTheme.accent : ReadingTheme.secondaryInk)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 0) {
                    figure(Self.durationNumber(digest.total(from: weekStart, days: 7)),
                           unit: Self.durationUnit(digest.total(from: weekStart, days: 7)), title: "近 7 天", alignment: .center)
                    divider
                    figure("\(digest.currentStreak)", unit: "天", title: "连续阅读", alignment: .center)
                    divider
                    figure("\(todayBooks)", unit: "本", title: "今日读过", alignment: .center)
                }
                .padding(.vertical, 10)
                .background { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(softFill) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("statistics.todayCard")
    }

    private var divider: some View {
        Rectangle().fill(ReadingTheme.separator.opacity(0.7)).frame(width: 0.5, height: 26)
    }

    // MARK: 趋势（含环比）

    private func trendCard(_ digest: ReadingStatsDigest) -> some View {
        let count = range.days
        let days = digest.days(count)
        let start = digest.shift(digest.today, by: -(count - 1))
        let total = days.reduce(0) { $0 + $1.time }
        let previous = digest.total(from: digest.shift(start, by: -count), days: count)
        let average = total / Int64(max(count, 1))
        let active = digest.activeDays(from: start, days: count)
        return card {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    cardTitle("阅读趋势", icon: "chart.bar")
                    Spacer(minLength: 8)
                    changeBadge(current: total, previous: previous)
                }
                ReadingStatsRangePicker(range: $range)
                HStack(spacing: 0) {
                    figure(Self.durationNumber(total), unit: Self.durationUnit(total), title: "合计")
                    figure("\(active)", unit: "天", title: "阅读天数")
                    figure(Self.durationNumber(average), unit: Self.durationUnit(average), title: "日均")
                }
                ReadingTrendChart(days: days.map { (date: $0.date, minutes: Double($0.time) / 60_000) },
                                  goalMinutes: dailyGoal, range: range)
                    .frame(height: 150)
                    .animation(.easeInOut(duration: 0.25), value: range)
                HStack(spacing: 16) {
                    legend(color: ReadingTheme.accent, title: "达成目标")
                    legend(color: ReadingTheme.accent.opacity(0.5), title: "未达成")
                    legend(color: ReadingTheme.secondaryInk.opacity(0.5), title: "虚线：每日目标")
                }
            }
        }
    }

    @ViewBuilder
    private func changeBadge(current: Int64, previous: Int64) -> some View {
        if previous > 0 {
            let change = (Double(current) - Double(previous)) / Double(previous)
            let up = change >= 0
            HStack(spacing: 3) {
                Image(systemName: up ? "arrow.up.right" : "arrow.down.right").font(.system(size: 10, weight: .bold))
                Text("\(Int((abs(change) * 100).rounded()))%").font(font(12, .semibold).monospacedDigit())
                Text("较上期").font(font(11)).foregroundStyle(ReadingTheme.secondaryInk)
            }
            .foregroundStyle(up ? Color.green : Color.orange)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background { Capsule().fill(softFill) }
            .accessibilityElement(children: .combine)
        } else if current > 0 {
            Text("新开始").font(font(12, .semibold))
                .foregroundStyle(ReadingTheme.accent)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background { Capsule().fill(softFill) }
        }
    }

    private func legend(color: Color, title: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(font(11)).foregroundStyle(ReadingTheme.secondaryInk)
        }
    }

    // MARK: 阅读日历

    private func calendarCard(_ digest: ReadingStatsDigest) -> some View {
        let month = digest.startOfMonth(displayedMonth ?? digest.today)
        let currentMonth = digest.startOfMonth(digest.today)
        let cells = digest.monthGrid(month)
        let monthDays = cells.compactMap { $0 }
        let monthTotal = monthDays.reduce(0) { $0 + digest.readTime(on: $1) }
        let monthActive = monthDays.filter { digest.isActive($0) }.count
        let monthBooks = digest.books(from: month, days: monthDays.count).count
        return card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    cardTitle("阅读日历", icon: "calendar")
                    Spacer(minLength: 0)
                    monthButton("chevron.left", label: "上个月") {
                        changeMonth(-1, from: month, digest: digest)
                    }
                    Text("\(digest.calendar.component(.year, from: month))年\(digest.calendar.component(.month, from: month))月")
                        .font(font(14, .semibold).monospacedDigit())
                        .frame(minWidth: 82)
                    monthButton("chevron.right", label: "下个月") {
                        changeMonth(1, from: month, digest: digest)
                    }
                    .disabled(month >= currentMonth)
                    .opacity(month >= currentMonth ? 0.3 : 1)
                }
                HStack(spacing: 0) {
                    ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { symbol in
                        Text(symbol).font(font(11)).foregroundStyle(ReadingTheme.secondaryInk)
                            .frame(maxWidth: .infinity)
                    }
                }
                VStack(spacing: 6) {
                    ForEach(0..<(cells.count / 7), id: \.self) { row in
                        HStack(spacing: 6) {
                            ForEach(0..<7, id: \.self) { column in
                                dayCell(cells[row * 7 + column], digest: digest)
                            }
                        }
                    }
                }
                calendarFooter(digest, total: monthTotal, active: monthActive, books: monthBooks)
            }
        }
    }

    private func monthButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ReadingTheme.ink)
                .frame(width: 30, height: 30)
                .background { Circle().fill(softFill) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func changeMonth(_ delta: Int, from month: Date, digest: ReadingStatsDigest) {
        guard let next = digest.calendar.date(byAdding: .month, value: delta, to: month) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            displayedMonth = min(next, digest.startOfMonth(digest.today))
            selectedDay = nil
        }
    }

    @ViewBuilder
    private func dayCell(_ day: Date?, digest: ReadingStatsDigest) -> some View {
        if let day {
            let level = digest.level(on: day, goalMinutes: dailyGoal)
            let isToday = day == digest.today
            let isFuture = day > digest.today
            let isSelected = selectedDay == day
            Button {
                withAnimation(.easeOut(duration: 0.15)) { selectedDay = isSelected ? nil : day }
            } label: {
                Text("\(digest.calendar.component(.day, from: day))")
                    .font(font(13, isToday || isSelected ? .bold : .regular).monospacedDigit())
                    .foregroundStyle(level >= 3 ? ReadingTheme.onAccent
                                     : (isFuture ? ReadingTheme.secondaryInk.opacity(0.5) : ReadingTheme.ink))
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(level > 0 ? ReadingHeatmap.fill(level) : Color.clear)
                    }
                    .overlay {
                        if isSelected || isToday {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(ReadingTheme.accent, lineWidth: isSelected ? 2 : 1.2)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isFuture)
            .accessibilityLabel("\(digest.calendar.component(.month, from: day))月\(digest.calendar.component(.day, from: day))日，\(Self.minutesText(digest.readTime(on: day)))")
        } else {
            Color.clear.frame(maxWidth: .infinity).frame(height: 34)
        }
    }

    @ViewBuilder
    private func calendarFooter(_ digest: ReadingStatsDigest, total: Int64, active: Int, books: Int) -> some View {
        if let day = selectedDay {
            let list = digest.books(on: day)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(digest.calendar.component(.month, from: day))月\(digest.calendar.component(.day, from: day))日 \(Self.weekdayName(day, calendar: digest.calendar))")
                        .font(font(13, .semibold))
                    Spacer(minLength: 8)
                    Text(Self.minutesText(digest.readTime(on: day)))
                        .font(font(13, .semibold).monospacedDigit())
                        .foregroundStyle(ReadingTheme.accent)
                }
                if list.isEmpty {
                    Text("这一天没有阅读记录").font(font(12)).foregroundStyle(ReadingTheme.secondaryInk)
                } else {
                    ForEach(Array(list.prefix(4).enumerated()), id: \.offset) { _, book in
                        HStack(spacing: 8) {
                            Circle().fill(ReadingTheme.accent.opacity(0.6)).frame(width: 5, height: 5)
                            Text(book.name).font(font(13)).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(Self.minutesText(book.time)).font(font(12).monospacedDigit())
                                .foregroundStyle(ReadingTheme.secondaryInk)
                        }
                    }
                }
            }
            .padding(12)
            .background { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(softFill) }
            .transition(.opacity)
        } else {
            HStack(spacing: 0) {
                figure(Self.durationNumber(total), unit: Self.durationUnit(total), title: "本月时长", alignment: .center)
                divider
                figure("\(active)", unit: "天", title: "阅读天数", alignment: .center)
                divider
                figure("\(books)", unit: "本", title: "读过", alignment: .center)
            }
            .padding(.vertical, 10)
            .background { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(softFill) }
        }
    }

    // MARK: 年度

    private func yearlyCard(_ digest: ReadingStatsDigest) -> some View {
        let yearly = digest.yearly()
        let year = digest.calendar.component(.year, from: digest.today)
        return card {
            VStack(alignment: .leading, spacing: 14) {
                cardTitle("\(String(year)) 年度", icon: "sparkles")
                HStack(alignment: .firstTextBaseline) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(Self.durationNumber(yearly.total)).font(font(32, .bold).monospacedDigit())
                        Text(Self.durationUnit(yearly.total)).font(font(14)).foregroundStyle(ReadingTheme.secondaryInk)
                    }
                    Spacer(minLength: 8)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(yearly.books)").font(font(24, .bold).monospacedDigit())
                        Text("本书").font(font(13)).foregroundStyle(ReadingTheme.secondaryInk)
                    }
                }
                if yearlyGoal > 0 {
                    let ratio = min(Double(yearly.books) / Double(yearlyGoal), 1)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("年度目标 \(yearlyGoal) 本").font(font(12)).foregroundStyle(ReadingTheme.secondaryInk)
                            Spacer()
                            Text("\(Int((ratio * 100).rounded()))%").font(font(12, .semibold).monospacedDigit())
                                .foregroundStyle(ReadingTheme.accent)
                        }
                        GeometryReader { geometry in
                            Capsule().fill(ReadingTheme.accent.opacity(0.12))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(ReadingTheme.accent)
                                        .frame(width: max(ratio > 0 ? 6 : 0, geometry.size.width * CGFloat(ratio)))
                                }
                        }
                        .frame(height: 6)
                    }
                }
                ReadingYearlyBars(values: yearly.monthly,
                                  currentMonth: digest.calendar.component(.month, from: digest.today) - 1)
                    .frame(height: 110)
            }
        }
    }

    // MARK: 个人纪录

    private func recordsCard(_ digest: ReadingStatsDigest) -> some View {
        let best = digest.bestDay
        let bestCaption = best.map { "最佳单日 · \(digest.calendar.component(.month, from: $0.date))/\(digest.calendar.component(.day, from: $0.date))" } ?? "最佳单日"
        return card {
            VStack(alignment: .leading, spacing: 14) {
                cardTitle("个人纪录", icon: "trophy")
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        recordTile(icon: "crown", value: Self.minutesText(best?.time ?? 0), title: bestCaption)
                        recordTile(icon: "flame", value: "\(digest.longestStreak) 天", title: "最长连续")
                    }
                    HStack(spacing: 10) {
                        recordTile(icon: "bolt", value: "\(digest.currentStreak) 天", title: "当前连续")
                        recordTile(icon: "calendar.badge.clock", value: "\(digest.activeDayCount) 天", title: "累计阅读天数")
                    }
                    HStack(spacing: 10) {
                        recordTile(icon: "hourglass", value: Self.minutesText(digest.totalReadTime), title: "累计阅读时长")
                        recordTile(icon: "books.vertical", value: "\(digest.bookCount) 本", title: "读过的书")
                    }
                }
            }
        }
    }

    private func recordTile(icon: String, value: String, title: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ReadingTheme.accent)
                .frame(width: 32, height: 32)
                .background { Circle().fill(ReadingTheme.accent.opacity(0.12)) }
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(font(15, .bold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
                Text(title).font(font(11)).foregroundStyle(ReadingTheme.secondaryInk).lineLimit(1).minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(softFill) }
        .accessibilityElement(children: .combine)
    }

    // MARK: 书籍排行

    @ViewBuilder
    private func topBooksCard(_ digest: ReadingStatsDigest) -> some View {
        let books = digest.topBooks(days: range.days)
        if !books.isEmpty {
            let maximum = max(books.first?.time ?? 1, 1)
            card {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        cardTitle("书籍排行", icon: "list.number")
                        Spacer(minLength: 8)
                        Text(range.title).font(font(12)).foregroundStyle(ReadingTheme.secondaryInk)
                    }
                    ForEach(Array(books.enumerated()), id: \.offset) { index, book in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 10) {
                                Text("\(index + 1)")
                                    .font(font(12, .bold).monospacedDigit())
                                    .foregroundStyle(index < 3 ? ReadingTheme.onAccent : ReadingTheme.secondaryInk)
                                    .frame(width: 22, height: 22)
                                    .background(Circle().fill(index < 3 ? ReadingTheme.accent.opacity(1 - Double(index) * 0.25) : ReadingTheme.separator))
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

    /// 大数字：不足 1 小时按分钟，否则按小时（保留一位小数）。
    static func durationNumber(_ milliseconds: Int64) -> String {
        let minutes = Int((Double(max(milliseconds, 0)) / 60_000).rounded())
        if minutes < 60 { return "\(minutes)" }
        let hours = Double(minutes) / 60
        return hours < 100 ? String(format: "%.1f", hours) : "\(Int(hours.rounded()))"
    }

    static func durationUnit(_ milliseconds: Int64) -> String {
        Int((Double(max(milliseconds, 0)) / 60_000).rounded()) < 60 ? "分钟" : "小时"
    }

    static func clockText(_ milliseconds: Int64) -> String {
        let total = Int(max(milliseconds, 0) / 60_000)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - 统计设置

struct ReadingStatsSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ReadingStatsSettings.dailyGoalKey) private var dailyGoal = 30
    @AppStorage(ReadingStatsSettings.yearlyGoalKey) private var yearlyGoal = 0
    @AppStorage(ReadingStatsSettings.streakMinimumKey) private var streakMinimum = 1

    var body: some View {
        ReadingNavigationStack {
            Form {
                Section {
                    Stepper(value: $dailyGoal, in: 5...240, step: 5) {
                        ReadingLabeledContent("每日目标", value: "\(dailyGoal) 分钟")
                    }
                } header: { Text("每日目标") } footer: {
                    Text("今日阅读的进度环、日历颜色深浅和趋势图的虚线都按这个目标计算。")
                }
                .readingRowBackground()
                Section {
                    Stepper(value: $yearlyGoal, in: 0...500, step: 1) {
                        ReadingLabeledContent("年度阅读目标", value: yearlyGoal == 0 ? "未设定" : "\(yearlyGoal) 本")
                    }
                } header: { Text("年度目标") } footer: {
                    Text("设为 0 表示不启用年度目标；启用后年度卡片会显示完成进度。")
                }
                .readingRowBackground()
                Section {
                    Stepper(value: $streakMinimum, in: 1...60, step: 1) {
                        ReadingLabeledContent("最低计入时长", value: "\(streakMinimum) 分钟")
                    }
                } header: { Text("连续天数") } footer: {
                    Text("一天累计阅读超过这个时长，才计入连续阅读和阅读天数。")
                }
                .readingRowBackground()
            }
            .readingThemedListBackground()
            .navigationTitle("统计设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
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

// MARK: - 今年每月柱状图（阅读时长）

struct ReadingYearlyBars: View {
    let values: [Int64]
    let currentMonth: Int

    private static func label(_ milliseconds: Int64) -> String {
        let minutes = Int((Double(max(milliseconds, 0)) / 60_000).rounded())
        if minutes < 60 { return "\(minutes)分" }
        let hours = Double(minutes) / 60
        return hours < 10 ? String(format: "%.1f时", hours) : "\(Int(hours.rounded()))时"
    }

    var body: some View {
        let maximum = max(values.max() ?? 0, 1)
        GeometryReader { geometry in
            let labelHeight: CGFloat = 16
            let area = max(geometry.size.height - labelHeight - 6, 1)
            let slot = geometry.size.width / 12
            let barWidth = min(18, slot * 0.56)
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(0..<12, id: \.self) { index in
                    let value = values.indices.contains(index) ? values[index] : 0
                    VStack(spacing: 4) {
                        Spacer(minLength: 0)
                        if value > 0, index == currentMonth || value == maximum {
                            Text(Self.label(value))
                                .font(AppFontStyle.system(size: 9, weight: .semibold).themed.monospacedDigit())
                                .foregroundStyle(ReadingTheme.secondaryInk)
                                .fixedSize()
                        }
                        RoundedRectangle(cornerRadius: min(barWidth / 2, 6), style: .continuous)
                            .fill(index > currentMonth ? ReadingTheme.separator.opacity(0.5)
                                  : (value > 0 ? ReadingTheme.accent.opacity(index == currentMonth ? 1 : 0.55)
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
        .accessibilityLabel("今年每月阅读时长")
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
                                ThemeSurface(shape: Capsule())
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
