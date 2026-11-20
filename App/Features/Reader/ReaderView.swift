@preconcurrency import AVFoundation
import AVKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ReaderView: View {
    private var usesEPUBLayout = true

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.appTheme) private var appTheme
    @EnvironmentObject private var library: BookLibraryModel
    @EnvironmentObject private var sourceLibrary: SourceLibraryModel
    @EnvironmentObject private var replaceRules: ReplaceRuleLibraryModel
    @EnvironmentObject private var activity: ReadingActivityModel
    @StateObject private var model: ReaderViewModel
    private var book: Book { model.book }
    @State private var sourceSwitchBook: Book?
    @StateObject private var speech = ReaderSpeechController()
    @State private var showsTableOfContents = false
    @State private var showsBookmarks = false
    @State private var illustrationChapter: BookChapter?
    @State private var showsAutoReadControls = false
    @State private var showsStyleControls = false
    @State private var isAutoReading = false
    @State private var showsReaderMenu = false
    @State private var followsSystemBrightness = true
    @State private var readerBrightness = Double(UIScreen.main.brightness)
    @State private var brightnessBeforeReading = Double(UIScreen.main.brightness)
    @State private var tocDescending = false
    @State private var showsContentSearch = false
    @State private var showsReplaceRules = false
    @State private var quickReplacePick: ReaderTextPick?
    @State private var showsReaderSettings = false
    @State private var showsBookActions = false
    /// 退出阅读时，书还不在书架上：先问是否加入书架。
    @State private var showsAddToShelfPrompt = false
    /// 拖动底部进度条时的本章位置（0…1）；松手后跳转，拖动过程中只预览页码。
    @State private var scrubFraction: Double?
    @State private var showsClickActionSettings = false
    @State private var showsContentEditor = false
    @State private var editedContent = ""
    @State private var contentEditError: String?
    @State private var backgroundImage: UIImage?
    @State private var readerJumpPosition: Int?
    @State private var contentSearchQuery = ""
    @State private var readerPosition = 0
    @State private var readerPageRanges: [NSRange] = []
    @State private var speechPageIndex = 0
    @State private var currentPage = 1
    @State private var totalPages = 1
    @State private var readerRenderRevision = 0
    @State private var isWaitingForNextChapter = false
    @State private var chapterTurnWait: Task<Void, Never>?
    @State private var isWaitingForChapterTurn = false
    @State private var chapterTurnToken = 0
    @State private var reviewPage: ReaderReviewPage?
    @AppStorage("showsReviewBubbles") private var showsReviewBubbles = true
    @ObservedObject private var bubbleStyles = BubbleStyleStore.shared
    @ObservedObject private var highlightRules = ReaderHighlightStore.shared
    @State private var reviewError: String?
    @State private var chapterTurnDirection = 0
    @State private var isWaitingForPreviousChapter = false
    @State private var httpTTSEngines: [HttpTTS] = []
    @State private var resumesSpeechAfterChapterLoad = false
    @State private var speechTimerTask: Task<Void, Never>?
    @State private var progressSaveTask: Task<Void, Never>?
    @State private var progressSaveGeneration = 0
    @State private var speechStartGeneration = 0
    @State private var speechTimerRemaining = 0
    @State private var isSavingBookmark = false
    @ScaledMetric(relativeTo: .body) private var toolbarIconSize = 21
    @AppStorage("textSize") private var fontSize = 20.0
    @AppStorage("letterSpacing") private var letterSpacing = 0.1
    @AppStorage("lineSpacingExtra") private var lineSpacing = 12.0
    @AppStorage("paragraphSpacing") private var paragraphSpacing = 2.0
    @AppStorage("paragraphIndent") private var paragraphIndent = "　　"
    @AppStorage("paddingLeft") private var paddingLeft = 16.0
    @AppStorage("paddingRight") private var paddingRight = 16.0
    @AppStorage("paddingTop") private var paddingTop = 6.0
    @AppStorage("paddingBottom") private var paddingBottom = 6.0
    @AppStorage("textBold") private var fontWeight = 0
    @AppStorage("textFont") private var fontPath = ""
    @AppStorage("titleMode") private var titleMode = 0
    @AppStorage("titleSize") private var titleSize = 0.0
    @AppStorage("titleTopSpacing") private var titleTopSpacing = 0.0
    @AppStorage("titleBottomSpacing") private var titleBottomSpacing = 0.0
    @AppStorage("titleColorHex") private var titleColorHex = ""
    @AppStorage("titleBold") private var titleBold = true
    @AppStorage(ReaderStylePreset.customBackgroundKey) private var customBackgroundHex = ReaderStylePreset.defaultCustomBackground
    @AppStorage(ReaderStylePreset.customForegroundKey) private var customForegroundHex = ReaderStylePreset.defaultCustomForeground
    @AppStorage(ReaderStylePreset.customDarkBackgroundKey) private var customDarkBackgroundHex = ReaderStylePreset.defaultCustomDarkBackground
    @AppStorage(ReaderStylePreset.customDarkForegroundKey) private var customDarkForegroundHex = ReaderStylePreset.defaultCustomDarkForeground
    @AppStorage(ReaderCustomThemeImage.lightUseKey) private var customUsesImage = false
    @AppStorage(ReaderCustomThemeImage.darkUseKey) private var customDarkUsesImage = false
    @State private var darkBackgroundImage: UIImage?
    @AppStorage("underlineMode") private var underlineMode = 0
    @AppStorage("headerPaddingBottom") private var headerPaddingBottom = 0.0
    @AppStorage("headerPaddingLeft") private var headerPaddingLeft = 16.0
    @AppStorage("headerPaddingRight") private var headerPaddingRight = 16.0
    @AppStorage("headerPaddingTop") private var headerPaddingTop = 0.0
    @AppStorage("footerPaddingBottom") private var footerPaddingBottom = 6.0
    @AppStorage("footerPaddingLeft") private var footerPaddingLeft = 16.0
    @AppStorage("footerPaddingRight") private var footerPaddingRight = 16.0
    @AppStorage("footerPaddingTop") private var footerPaddingTop = 6.0
    @AppStorage("showHeaderLine") private var showHeaderLine = false
    @AppStorage("showFooterLine") private var showFooterLine = true
    @AppStorage("tipHeaderLeft") private var tipHeaderLeft = 2
    @AppStorage("tipHeaderMiddle") private var tipHeaderMiddle = 0
    @AppStorage("tipHeaderRight") private var tipHeaderRight = 3
    @AppStorage("tipFooterLeft") private var tipFooterLeft = 1
    @AppStorage("tipFooterMiddle") private var tipFooterMiddle = 0
    @AppStorage("tipFooterRight") private var tipFooterRight = 6
    @AppStorage("headerMode") private var headerMode = 0
    @AppStorage("footerMode") private var footerMode = 0
    @AppStorage("readerTheme") private var theme = "wechat"
    @AppStorage("readerPreviousDayTheme") private var previousDayTheme = "wechat"
    @AppStorage("readerDarkTheme") private var darkTheme = "night"
    @AppStorage("readerFollowSystemDark") private var followSystemDark = false
    @AppStorage("readerFullScreenTurn") private var fullScreenTurn = false
    @AppStorage("readerSwipeUpExit") private var swipeUpExit = false
    @AppStorage("readerTextCenter") private var centerText = false
    @AppStorage("readerParagraphBlankLines") private var paragraphBlankLines = 0
    @AppStorage("readerTipCustomFont") private var tipCustomFont = false
    @AppStorage("readerBackgroundRevision") private var backgroundRevision = 0
    @AppStorage("autoReadSpeed") private var autoReadSpeed = 10
    @AppStorage("ttsFollowSys") private var ttsFollowSystem = true
    @AppStorage("ttsSpeechRate") private var ttsSpeechRate = 5
    @AppStorage("appTtsEngine") private var appTTSEngine = ""
    @AppStorage("systemTtsVoice") private var systemTTSVoice = ""
    @AppStorage("readAloudByPage") private var readAloudByPage = false
    @AppStorage("streamReadAloudAudio") private var streamReadAloudAudio = true
    @AppStorage("readAloudWakeLock") private var readAloudWakeLock = false
    @AppStorage("ignoreAudioFocus") private var ignoreAudioFocus = false
    @AppStorage("pauseReadAloudWhilePhoneCalls") private var pauseReadAloudWhilePhoneCalls = false
    @AppStorage("mediaButtonPerNext") private var mediaButtonPerNext = false
    @AppStorage("ttsTimer") private var ttsTimer = 0
    @AppStorage("readerFullJustify") private var fullJustify = true
    @AppStorage("readerKeepScreenOn") private var keepScreenOn = false
    @AppStorage("readerHideHomeIndicator") private var hideHomeIndicator = false
    @AppStorage("readerHideStatusBar") private var hideStatusBar = false
    @AppStorage("readerShowBrightness") private var showBrightness = true
    @AppStorage("readerBrightness") private var storedReaderBrightness = 0.0
    @AppStorage("readerUseBackgroundImage") private var useBackgroundImage = false
    @AppStorage("themeMode") private var themeMode = "0"
    @AppStorage("enableReadRecord") private var enableReadRecord = true
    @State private var pageAnimation: Int
    @AppStorage("screenOrientation") private var screenOrientation = "0"
    @AppStorage("clickActionTopLeft") private var clickActionTL = 2
    @AppStorage("clickActionTopCenter") private var clickActionTC = 2
    @AppStorage("clickActionTopRight") private var clickActionTR = 1
    @AppStorage("clickActionMiddleLeft") private var clickActionML = 2
    @AppStorage("clickActionMiddleRight") private var clickActionMR = 1
    @AppStorage("clickActionBottomLeft") private var clickActionBL = 2
    @AppStorage("clickActionBottomCenter") private var clickActionBC = 1
    @AppStorage("clickActionBottomRight") private var clickActionBR = 1


    init(book: Book, chapters: [BookChapter], initialIndex: Int, source: BookSource) {
        _pageAnimation = State(initialValue: book.readConfig?.pageAnim.flatMap { $0 >= 0 ? $0 : nil }
            ?? Self.globalPageAnimation())
        _model = StateObject(wrappedValue: ReaderViewModel(
            book: book,
            chapters: chapters,
            initialIndex: initialIndex,
            source: source
        ))
    }

    init(book: Book, chapters: [BookChapter], initialIndex: Int, usesEPUBLayout: Bool = true) {
        self.usesEPUBLayout = usesEPUBLayout
        _pageAnimation = State(initialValue: book.readConfig?.pageAnim.flatMap { $0 >= 0 ? $0 : nil }
            ?? Self.globalPageAnimation())
        _model = StateObject(wrappedValue: ReaderViewModel(
            book: book,
            chapters: chapters,
            initialIndex: initialIndex
        ))
    }

    init(demoBook book: Book, chapters: [BookChapter], initialIndex: Int, content: String) {
        var readerChapters = chapters
        var readerInitialIndex = initialIndex
        var readerContent = content
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-uiScrollRegression") {
            readerChapters = (0..<80).map {
                BookChapter(url: "demo://scroll/\($0)", title: "第\($0 + 1)章 · 连续阅读", bookUrl: book.bookUrl, index: $0)
            }
            readerInitialIndex = 20
            if arguments.contains("-uiShortChapters") { readerContent = "短章正文，继续向下可以自然读到下一章。" }
        }
        #endif
        _pageAnimation = State(initialValue: book.readConfig?.pageAnim.flatMap { $0 >= 0 ? $0 : nil }
            ?? Self.globalPageAnimation())
        #if DEBUG
        if arguments.contains("-uiReaderFailure") {
            _model = StateObject(wrappedValue: ReaderViewModel(
                book: book, chapters: readerChapters, initialIndex: readerInitialIndex,
                source: BookSource(bookSourceUrl: "https://reader-failure.invalid", bookSourceName: "正文失败测试源"),
                service: ReaderFailureTestLoader()
            ))
            return
        }
        #endif
        _model = StateObject(wrappedValue: ReaderViewModel(
            demoBook: book,
            chapters: readerChapters,
            initialIndex: readerInitialIndex,
            content: readerContent
        ))
    }


    var body: some View {
        if usesEPUBLayout, book.origin == "local", URL(string: book.bookUrl)?.pathExtension.lowercased() == "epub" {
            EPUBReaderView(book: book, chapters: model.chapters, initialIndex: model.currentIndex)
        } else {
            textReaderBody
        }
    }

    private var textReaderBody: some View {
        readerCanvas
        .preferredColorScheme(resolvedStyle.isDark ? .dark : .light)
        .readingTabBarHidden()
        .navigationBarBackButtonHidden(true)
        .background {
            ReaderInteractivePopEnabler()
                .frame(width: 0, height: 0)
        }
        .statusBarHidden(hideStatusBar)
        .readingHomeIndicatorHidden(hideHomeIndicator)
        .overlay(alignment: .top) {
            if showsReaderMenu {
                readerTopChrome
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.22), value: showsReaderMenu)
        .onAppear {
            activity.beginReading(book)
            speech.onNextChapter = { moveSpeechToChapter(direction: 1) }
            speech.onPreviousChapter = { moveSpeechToChapter(direction: -1) }
            speech.onRemoteStop = {
                speechTimerTask?.cancel()
                speechTimerRemaining = 0
                resumesSpeechAfterChapterLoad = false
            }
            UIDevice.current.isBatteryMonitoringEnabled = true
            brightnessBeforeReading = Double(UIScreen.main.brightness)
            if storedReaderBrightness > 0.05 {
                followsSystemBrightness = false
                readerBrightness = storedReaderBrightness
                UIScreen.main.brightness = CGFloat(storedReaderBrightness)
            } else {
                readerBrightness = brightnessBeforeReading
            }
            backgroundImage = ReaderBackgroundStore.load()
            darkBackgroundImage = ReaderCustomThemeImage.load(dark: true)
            ReaderScreenOrientation.apply(screenOrientation)
            Task { await loadHTTPEngines() }
            if ProcessInfo.processInfo.arguments.contains("-uiDemoBookmarks") {
                showsBookmarks = true
            }
            if ProcessInfo.processInfo.arguments.contains("-uiDemoReaderMenu") {
                showsReaderMenu = true
            }
            if ProcessInfo.processInfo.arguments.contains("-uiDemoReaderStyle") {
                DispatchQueue.main.async { showsStyleControls = true }
            }
        }
        .alert("加入书架", isPresented: $showsAddToShelfPrompt) {
            Button("不加入", role: .cancel) { dismiss() }
            Button("加入书架") {
                let current = book
                Task {
                    await library.addOrUpdate(current)
                    // 加入后再存一次当前进度（此时书已在书架上，进度直接写进书架）。
                    saveProgress(immediate: true)
                    dismiss()
                }
            }
        } message: {
            Text("将《\(book.name)》加入书架？")
        }
        .onDisappear {
            model.cancelPreload()
            isAutoReading = false
            UIApplication.shared.isIdleTimerDisabled = false
            if speech.isSpeaking || speech.isPaused { speech.toggle(text: "") }
            saveProgress(immediate: true)
            ReaderScreenOrientation.restoreApplicationDefault()
            activity.cancelReading(book)
            UIDevice.current.isBatteryMonitoringEnabled = false
            if !followsSystemBrightness {
                UIScreen.main.brightness = CGFloat(brightnessBeforeReading)
            }
            speechTimerTask?.cancel()
            speechTimerRemaining = 0
            speech.onNextChapter = nil
            speech.onPreviousChapter = nil
            speech.onRemoteStop = nil
        }
        .overlay(alignment: .bottom) {
            if showsReaderMenu {
                Group {
                    if appTheme.customization?.readerBarStyle == .chat {
                        readerChatBottomChrome
                    } else {
                        readerBottomChrome
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .dismissesSheetOnOutsideTap(Binding(
            get: { showsStyleControls || showsReaderSettings || showsBookActions },
            set: { shown in
                if !shown {
                    showsStyleControls = false
                    showsReaderSettings = false
                    showsBookActions = false
                }
            }
        ))
        .sheet(isPresented: $showsTableOfContents) { tableOfContents.readerPanelAppearance(followsPanelTheme) }
        .sheet(isPresented: $showsBookmarks) { bookmarksSheet.readerPanelAppearance(followsPanelTheme) }
        .sheet(item: $reviewPage) { page in
            ReaderReviewSheet(page: page)
        }
        .alert("打不开段评", isPresented: Binding(get: { reviewError != nil }, set: { if !$0 { reviewError = nil } })) {
            Button("好", role: .cancel) { reviewError = nil }
        } message: {
            Text(reviewError ?? "")
        }
        .sheet(item: $illustrationChapter) { chapter in
            EPUBIllustrationsView(book: book, chapter: chapter)
        }
        .sheet(isPresented: $showsAutoReadControls) { autoReadControls.readerPanelAppearance(followsPanelTheme) }
        .sheet(isPresented: $showsStyleControls) { styleControls.readerPanelAppearance(followsPanelTheme) }
        .sheet(isPresented: $showsContentSearch) { contentSearchSheet.readerPanelAppearance(followsPanelTheme) }
        .sheet(item: $sourceSwitchBook) { currentBook in
            ReadingNavigationStack {
                SourceSwitchView(book: currentBook, sources: sourceLibrary.sources) { report, source in
                    Task {
                        await progressSaveTask?.value
                        await activity.endReading(book)
                        await library.replace(oldBookURL: book.bookUrl, with: report.book)
                        model.applySourceSwitch(report, source: source)
                        readerPosition = report.book.durChapterPos
                        readerJumpPosition = nil
                        readerPageRanges = []
                        readerRenderRevision &+= 1
                        activity.beginReading(report.book)
                    }
                }
            }
        }
        .sheet(isPresented: $showsReplaceRules) {
            ReadingNavigationStack { ReplaceRuleManagementView() }
        }
        .sheet(item: $quickReplacePick) { pick in
            ReaderQuickReplaceSheet(pick: pick, bookName: model.book.name, sourceURL: model.book.origin,
                                    rulesDisabled: !model.usesReplaceRules,
                                    makeRule: { replaceRules.newRule() }) { rule in
                let saved = await replaceRules.save(rule)
                if saved { await applyReplaceRulesInPlace() }
                return saved ? nil : (replaceRules.notice?.detail ?? "保存失败")
            }
        }
        .sheet(isPresented: $showsReaderSettings) { readerSettings.readerPanelAppearance(followsPanelTheme) }
        .sheet(isPresented: $showsBookActions) { bookActionsSheet.readerPanelAppearance(followsPanelTheme) }
        .sheet(isPresented: $showsClickActionSettings) { clickActionSettings }
        .sheet(isPresented: $showsContentEditor) { contentEditor }
        .task(id: model.chapterLoadGeneration) {
            isWaitingForNextChapter = false
            isWaitingForPreviousChapter = false
            let needsInitialPosition = !model.hasLoadedCurrentChapter
            if let pending = progressSaveTask {
                let pendingGeneration = progressSaveGeneration
                await pending.value
                // A newer page callback may have scheduled another save while
                // this chapter task was waiting. Never erase that newer task's
                // handle, or a subsequent chapter transition could skip it.
                if progressSaveGeneration == pendingGeneration {
                    progressSaveTask = nil
                }
            }
            readerJumpPosition = nil
            readerPageRanges = []
            if needsInitialPosition { readerPosition = model.requestedPosition }
            await model.load(rules: model.usesReplaceRules ? replaceRules.rules : [], prefetchNextChapter: true)
            guard !Task.isCancelled else { return }
            if needsInitialPosition {
                readerPosition = pageAnimation == 3
                    ? continuousPosition(model.requestedPosition, content: model.content)
                    : min(model.requestedPosition, max(model.content.utf16.count - 1, 0))
            }
            if let chapter = model.currentChapter {
                await library.updateProgress(for: book, chapter: chapter, position: readerPosition)
            }
            if resumesSpeechAfterChapterLoad, !model.content.isEmpty {
                resumesSpeechAfterChapterLoad = false
                startConfiguredSpeech()
            }
        }
        .task(id: "\(model.chapterLoadGeneration):\(pageAnimation == 3):\(model.hasLoadedCurrentChapter):\(model.scrollRevision)") {
            guard pageAnimation == 3 else { return }
            await model.prepareContinuousReading(rules: model.usesReplaceRules ? replaceRules.rules : [])
        }
        .onAppear { updateIdleTimer() }
        .onChange(of: keepScreenOn) { _ in
            updateIdleTimer()
        }
        .onChange(of: adjacentReadiness) { _ in
            if model.isContinuationWindowReady, isWaitingForNextChapter {
                isWaitingForNextChapter = false
                readerRenderRevision &+= 1
            }
            if model.isPreviousWindowReady, isWaitingForPreviousChapter {
                advanceToPreparedPreviousChapter()
            }
        }
        .onChange(of: isAutoReading) { _ in
            updateIdleTimer()
        }
        .onChange(of: speech.isSpeaking) { _ in
            updateIdleTimer()
        }
        .onChange(of: speech.completionCount) { _ in
            if readAloudByPage {
                continueSpeechToNextPage()
            } else {
                continueSpeechToNextChapter()
            }
        }
        .onChange(of: speech.currentSegmentIndex) { index in
            guard model.paragraphs.indices.contains(index), !readAloudByPage else { return }
            readerJumpPosition = nil
            DispatchQueue.main.async { readerJumpPosition = model.paragraphs[index].id }
        }
        .onChange(of: readAloudByPage) { _ in
            restartSpeechAfterReaderLayoutChange()
        }
        .onChange(of: readAloudWakeLock) { _ in
            updateIdleTimer()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                if !followsSystemBrightness {
                    UIScreen.main.brightness = CGFloat(readerBrightness)
                }
                activity.beginReading(book)
            } else {
                isAutoReading = false
                if !followsSystemBrightness {
                    UIScreen.main.brightness = CGFloat(brightnessBeforeReading)
                }
                saveProgress(immediate: true)
                activity.cancelReading(book)
            }
        }
        .onChange(of: screenOrientation) { value in
            ReaderScreenOrientation.apply(value)
        }
        .onChange(of: backgroundRevision) { _ in
            // 阅读设置里换了 / 删了背景图，或套用了带背景图的主题。
            backgroundImage = ReaderBackgroundStore.load()
            darkBackgroundImage = ReaderCustomThemeImage.load(dark: true)
        }
        .onChange(of: themeMode) { _ in
            isAutoReading = false
            readerJumpPosition = nil
            currentPage = 1
            totalPages = 1
        }
        .onChange(of: pageAnimation) { value in
            isAutoReading = false
            saveProgress(immediate: true)
            readerJumpPosition = readerPosition
            currentPage = 1
            totalPages = 1
            UserDefaults.standard.set(value, forKey: "pageAnim")
            let updatedBook = model.useGlobalPageAnimation()
            Task { await library.addOrUpdate(updatedBook) }
        }
    }


    private var readerCanvas: some View {
        ZStack {
            readerContent
            readerMenuDismissOverlay
        }
        .background {
            ZStack {
                backgroundColor
                if let backgroundImage = activeBackgroundImage {
                    Image(uiImage: backgroundImage)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .ignoresSafeArea()
        }
    }

    @ViewBuilder private var readerContent: some View {
        if let mediaURL = model.currentMediaURL {
            // 短剧 / 漫剧 / 听书：正文是一个播放地址，直接播放，下面是选集。
            ReaderMediaChapterView(
                url: mediaURL,
                headers: model.mediaHeaders,
                bookName: book.name,
                title: model.title,
                isAudio: model.isAudioBook,
                chapters: model.chapters,
                currentIndex: model.currentIndex,
                canGoPrevious: model.canGoPrevious,
                canGoNext: model.canGoNext,
                onPrevious: { moveChapter(-1) },
                onNext: { moveChapter(1) },
                onSelect: { index in selectMediaEpisode(index) },
                onMenu: { showsReaderMenu.toggle() }
            )
            .transition(.opacity)
        } else if pageAnimation != 3,
           (model.isLoading && model.content.isEmpty) || (model.content.isEmpty && !model.hasLoadedCurrentChapter) {
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.regular)
                Text("正在打开本章")
                    .font(.subheadline.weight(.medium))
                Text(model.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(foregroundColor)
            .background(backgroundColor.ignoresSafeArea())
            .contentShape(Rectangle())
            .onTapGesture { showsReaderMenu.toggle() }
            .transition(.opacity)
        } else if pageAnimation != 3, model.content.isEmpty && model.hasLoadedCurrentChapter {
            VStack(spacing: 18) {
                Image(systemName: "text.page.slash").font(.largeTitle)
                Text(model.currentChapterError == nil ? "正文为空" : "本章加载失败").font(.title3.weight(.semibold))
                Text(model.currentChapterError ?? "本章暂无正文。")
                    .font(.subheadline).multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                readerRecoveryActions
                Button("打开阅读菜单") { showsReaderMenu = true }
                    .accessibilityIdentifier("reader.failureMenu")
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(foregroundColor)
            .background(backgroundColor.ignoresSafeArea())
        } else {
            VStack(spacing: 0) {
                if headerVisible { readerTipBar(isHeader: true) }
                readerSurface
                if footerVisible { readerTipBar(isHeader: false) }
            }
            .frame(maxWidth: readingColumnMaxWidth)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottom) {
                if let error = model.currentChapterError, !showsReaderMenu {
                    VStack(spacing: 10) {
                        Text(model.content.isEmpty ? "本章加载失败" : "本章加载不完整").font(.subheadline.weight(.semibold))
                        Text(error).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                        readerRecoveryActions
                        Button("打开阅读菜单") { showsReaderMenu = true }
                            .accessibilityIdentifier("reader.failureMenu")
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(foregroundColor)
                    .background(backgroundColor)
                }
            }
        }
    }

    private var readerRecoveryActions: some View {
        HStack(spacing: 16) {
            Button {
                Task {
                    if pageAnimation == 3, model.scrollChapters.contains(where: { $0.id == model.currentIndex }) {
                        await model.retryContinuousChapter(index: model.currentIndex, rules: model.usesReplaceRules ? replaceRules.rules : [])
                    } else {
                        await model.load(rules: model.usesReplaceRules ? replaceRules.rules : [], forceRefresh: true)
                    }
                }
            } label: {
                Label(model.scrollRetries.contains(model.currentIndex) ? "重试中…" : "重试本章", systemImage: "arrow.clockwise")
            }
            .disabled(model.isLoading || model.scrollRetries.contains(model.currentIndex))
            .accessibilityIdentifier("reader.retryChapter")
            if model.canEditContent {
                Button(action: openSourceSwitch) {
                    Label("换源", systemImage: "arrow.triangle.2.circlepath")
                }
                .accessibilityIdentifier("reader.failureChangeSource")
            }
        }
        .readingSecondaryButtonStyle()
    }

    private func openSourceSwitch() {
        stopSpeechIfNeeded()
        isAutoReading = false
        saveProgress(immediate: true)
        showsReaderMenu = false
        sourceSwitchBook = model.bookForSourceSwitch(position: readerPosition)
    }

    @ViewBuilder private var readerSurface: some View {
        if pageAnimation == 3 {
            ReaderScrollView(
                configuration: readerTextConfiguration,
                chapters: model.scrollChapters,
                resetID: model.scrollRevision,
                activeIndex: model.currentIndex,
                loadingAhead: model.isLoadingScrollAhead,
                loadingBehind: model.isLoadingScrollBehind,
                onNeedChapters: { direction in
                    Task { await model.extendContinuousReading(direction: direction, rules: model.usesReplaceRules ? replaceRules.rules : []) }
                },
                onPositionChanged: { index, position in
                    if index != model.currentIndex {
                        saveProgress(immediate: true)
                        model.updateContinuousPosition(chapter: index)
                        readerJumpPosition = nil
                    }
                    let resolved = min(max(position, 0), model.content.utf16.count)
                    if readerPosition != resolved { readerPosition = resolved }
                },
                onRetainChapters: { model.retainContinuousChapters($0) }
            )
        } else {
            readerTextConfiguration
        }
    }

    private var readerTextConfiguration: ReaderTextView {
        ReaderTextView(
            text: readerDisplayText,
            title: model.title,
            previousTitle: pageAnimation == 3 ? model.previousTitle : nil,
            previousText: pageAnimation == 3 ? model.previousContent : "",
            isPreviousReady: pageAnimation == 3 && model.isPreviousWindowReady,
            continuationTitle: pageAnimation == 3 ? model.continuationTitle : nil,
            continuationText: pageAnimation == 3 ? model.continuationContent : "",
            isContinuationReady: pageAnimation == 3 && model.isContinuationWindowReady,
            isVolume: model.currentChapter?.isVolume == true,
            fontSize: fontSize,
            fontPath: fontPath,
            letterSpacing: letterSpacing,
            lineSpacing: lineSpacing,
            paragraphSpacing: paragraphSpacing,
            paragraphIndent: paragraphIndent,
            paddingLeft: paddingLeft,
            paddingRight: paddingRight,
            paddingTop: paddingTop,
            paddingBottom: paddingBottom,
            headerInset: 0,
            footerInset: 0,
            fontWeight: fontWeight,
            titleMode: titleMode,
            titleSize: titleSize,
            titleTopSpacing: titleTopSpacing,
            titleBottomSpacing: titleBottomSpacing,
            underlineMode: underlineMode,
            isSelectable: false,
            fullJustify: fullJustify,
            pageAnimation: pageAnimation,
            isEInkMode: themeMode == "3",
            clickActions: clickActions,
            backgroundColor: activeBackgroundImage == nil ? resolvedStyle.background : .clear,
            foregroundColor: resolvedStyle.foreground,
            requestedPosition: pageAnimation == 3 ? readerPosition : model.requestedPosition,
            jumpPosition: readerJumpPosition,
            renderRevision: readerRenderRevision,
            readerPosition: $readerPosition,
            pageRanges: $readerPageRanges,
            currentPage: $currentPage,
            totalPages: $totalPages,
            isAutoReading: isAutoReading,
            isAutoReadPaused: pausesAutoReading,
            isLoadingNextChapter: isWaitingForNextChapter || isWaitingForChapterTurn,
            secondsPerScreen: Double(autoReadSpeed),
            onReachedEnd: { boundaryPosition in
                if pageAnimation == 3 {
                    requestNextChapter()
                    return
                }
                if model.canGoNext {
                    turnChapterWhenReady(direction: 1, boundaryPosition: boundaryPosition)
                } else {
                    isAutoReading = false
                }
            },
            onReachedStart: { boundaryPosition in
                if pageAnimation == 3 {
                    requestPreviousChapter()
                    return
                }
                guard model.canGoPrevious else { return }
                turnChapterWhenReady(direction: -1, boundaryPosition: boundaryPosition)
            },
            onEnteredPrevious: { position in
                guard pageAnimation == 3, model.canGoPrevious, model.hasPreviousWindow else { return }
                saveProgress(immediate: true)
                readerPosition = continuousPosition(position, content: model.previousContent)
                readerJumpPosition = nil
                model.promotePrevious(position: readerPosition)
            },
            onEnteredContinuation: { position in
                guard pageAnimation == 3, model.canGoNext, model.hasContinuationWindow else { return }
                saveProgress(immediate: true)
                readerPosition = continuousPosition(position, content: model.continuationContent)
                readerJumpPosition = nil
                model.promoteContinuation(position: readerPosition)
            },
            onDeferredRender: { readerRenderRevision &+= 1 },
            onCancelNextLoading: {
                isWaitingForNextChapter = false
                chapterTurnWait?.cancel()
                chapterTurnWait = nil
                isWaitingForChapterTurn = false
            },
            onPageChanged: pageDidChange,
            onTapAction: handleTapAction,
            titleColor: titleColorHex.isEmpty ? nil : UIColor(readerHex: titleColorHex),
            titleBold: titleBold,
            chapterTurnToken: chapterTurnToken,
            chapterTurnDirection: chapterTurnDirection,
            onOpenLink: { url in openReviewLink(url) },
            showsReviewBubbles: showsReviewBubbles,
            reviewBubbleStyle: 0,
            reviewBubbleAccent: false,
            reviewBubbleImageRevision: bubbleStyles.revision,
            onLongPressText: { pick in quickReplacePick = pick },
            highlightRevision: highlightRules.revision,
            paragraphBlankLines: paragraphBlankLines,
            centerText: centerText,
            onSwipeUp: swipeUpExit ? { leaveReader() } : nil
        )
    }

    @ViewBuilder private var readerMenuDismissOverlay: some View {
        if showsReaderMenu {
            Color.black
                .opacity(resolvedStyle.isDark ? 0.08 : 0.03)
                .ignoresSafeArea()
                .contentShape(ReaderMenuDismissShape())
                .onTapGesture { showsReaderMenu = false }
                .accessibilityHidden(true)
        }
    }

    private var readingColumnMaxWidth: CGFloat {
        UIDevice.current.userInterfaceIdiom == .pad ? 760 : .greatestFiniteMagnitude
    }

    private var adjacentReadiness: Int {
        (model.isPreviousWindowReady ? 1 : 0) | (model.isContinuationWindowReady ? 2 : 0)
    }

    private var readerDisplayText: String {
        if !model.content.isEmpty { return model.content }
        if pageAnimation == 3 {
            return String(repeating: "\n", count: 80)
        }
        if model.isLoading || !model.hasLoadedCurrentChapter {
            // 正文加载中保持空白页，避免打开书时先闪一下提示文字再换成正文。
            return " "
        }
        let reason = model.diagnostics.first?.message ?? "当前书源没有返回正文。"
        return "本章加载失败\n\n\(reason)\n\n本章位置会保留，请继续向下进入下一章。"
    }

    private func continuousPosition(_ position: Int, content: String) -> Int {
        let length = content.isEmpty ? 80 : content.utf16.count
        return min(max(position, 0), max(length - 1, 0))
    }

    private var activeBackgroundImage: UIImage? {
        guard themeMode != "3" else { return nil }
        if useBackgroundImage { return backgroundImage }
        // 自定义主题（浅色 / 深色各一套）带的背景图。
        let style = resolvedStyle
        if style.id == ReaderStylePreset.customID, customUsesImage { return backgroundImage }
        if style.id == ReaderStylePreset.customDarkID, customDarkUsesImage { return darkBackgroundImage }
        return nil
    }

    private var backgroundColor: Color {
        Color(uiColor: resolvedStyle.background)
    }

    private var foregroundColor: Color {
        Color(uiColor: resolvedStyle.foreground)
    }

    private var resolvedStyle: ReaderStylePreset {
        if themeMode == "3" { return .eInk }
        if let bound = ReaderStylePreset.boundToAppTheme(themeMode: themeMode) { return bound }
        _ = (customBackgroundHex, customForegroundHex, customDarkBackgroundHex, customDarkForegroundHex)
        if followSystemDark {
            // 「跟随系统深色模式」：系统深色用选中的深色主题，浅色时用浅色主题。
            if systemPrefersDark {
                return ReaderStylePreset.darkIDs.contains(darkTheme) ? ReaderStylePreset.resolve(darkTheme) : ReaderStylePreset.resolve("night")
            }
            if ReaderStylePreset.darkIDs.contains(theme) {
                return ReaderStylePreset.darkIDs.contains(previousDayTheme) ? ReaderStylePreset.resolve("wechat") : preset(previousDayTheme)
            }
        }
        return preset(theme)
    }

    private func preset(_ id: String) -> ReaderStylePreset {
        id == ReaderStylePreset.customID ? ReaderStylePreset.custom() : ReaderStylePreset.resolve(id)
    }

    /// 系统（窗口场景）是否深色；「显示模式」强制深 / 浅时以它为准。
    private var systemPrefersDark: Bool {
        switch themeMode {
        case "2": return true
        case "1", "3": return false
        default:
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            return (scene?.traitCollection.userInterfaceStyle ?? .light) == .dark
        }
    }

    private var headerVisible: Bool {
        switch headerMode {
        case 1: true
        case 2: false
        default: hideStatusBar
        }
    }

    private var footerVisible: Bool { footerMode == 0 }

    private var pausesAutoReading: Bool {
        isWaitingForNextChapter
            || isWaitingForPreviousChapter
            || isWaitingForChapterTurn
            || showsReaderMenu
            || showsTableOfContents
            || showsBookmarks
            || illustrationChapter != nil
            || showsAutoReadControls
            || showsStyleControls
            || showsContentSearch
            || showsReplaceRules
            || showsReaderSettings
            || showsBookActions
            || showsClickActionSettings
            || showsContentEditor
    }


    private func readerTipBar(isHeader: Bool) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            readerTipRow(
                isHeader ? [tipHeaderLeft, tipHeaderMiddle, tipHeaderRight] : [tipFooterLeft, tipFooterMiddle, tipFooterRight],
                date: context.date,
                showDivider: isHeader ? showHeaderLine : showFooterLine,
                isHeader: isHeader
            )
            .padding(.top, isHeader ? headerPaddingTop : footerPaddingTop)
            .padding(.bottom, isHeader ? headerPaddingBottom : footerPaddingBottom)
        }
        .allowsHitTesting(false)
    }

    private func readerTipRow(_ values: [Int], date: Date, showDivider: Bool, isHeader: Bool) -> some View {
        let texts = values.map { readerTipText($0, date: date) }
        return ReaderTipRowLayout(left: texts[0], middle: texts[1], right: texts[2])
        .font(ReaderTipFont.font(path: fontPath, enabled: tipCustomFont))
        .foregroundStyle(foregroundColor)
        .padding(.leading, isHeader ? headerPaddingLeft : footerPaddingLeft)
        .padding(.trailing, isHeader ? headerPaddingRight : footerPaddingRight)
        .overlay(alignment: .bottom) {
            if showDivider { Divider().overlay(foregroundColor.opacity(0.35)) }
        }
    }

    private func readerTipText(_ value: Int, date: Date) -> String {
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        let batteryValue = UIDevice.current.batteryLevel
        let battery = batteryValue >= 0 ? Int((batteryValue * 100).rounded()) : 100
        let chapterCount = max(model.readableChapterCount, 1)
        let readableIndex = model.readableNumber(at: model.currentIndex)
        let chapterFraction = chapterPageFraction
        let progress = min(max((Double(max(readableIndex - 1, 0)) + chapterFraction) / Double(chapterCount), 0), 1)
        let progressText = String(format: "%.1f%%", progress * 100)
        switch value {
        case 1: return model.title
        case 2: return time
        case 3: return "▰"
        case 4: return "\(currentPage)/\(totalPages)"
        case 5: return progressText
        case 6: return "\(currentPage)/\(totalPages)  \(progressText)"
        case 7: return book.name
        case 8: return "\(time) ▰"
        case 9: return "\(time) \(battery)%"
        case 10: return "\(battery)%"
        case 11: return "\(readableIndex)/\(chapterCount)"
        default: return ""
        }
    }

    private var readerChromeTint: Color {
        .primary
    }

    private var chapterProgress: Double {
        let chapter = max(model.readableChapterCount, 1)
        let readable = model.readableNumber(at: model.currentIndex)
        let pagePart = chapterPageFraction
        return min(max((Double(max(readable - 1, 0)) + pagePart) / Double(chapter), 0), 1)
    }

    /// 底部滑块显示的本章位置：翻页模式按页码，滚动模式按正文字符位置。
    private var chapterSliderFraction: Double {
        if pageAnimation == 3 {
            let length = model.content.utf16.count
            guard length > 1 else { return 0 }
            return min(max(Double(readerPosition) / Double(length - 1), 0), 1)
        }
        return chapterPageFraction
    }

    private var chapterPageFraction: Double {
        guard totalPages > 1 else { return 1 }
        return min(max(Double(max(currentPage - 1, 0)) / Double(totalPages - 1), 0), 1)
    }


    /// 返回：书不在书架上（从发现、搜索直接进来读的）先问要不要加入书架。
    private func leaveReader() {
        let automation = ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("-ui") }
        if !automation, !library.contains(book), book.origin != "local" {
            showsAddToShelfPrompt = true
        } else {
            dismiss()
        }
    }

    /// 顶部工具栏：悬浮的玻璃按钮（返回 / 书签 / 更多）+ 中间玻璃胶囊（书名、章节名）。
    /// 没有整条背景，只有各个控件本身能点；控件之间的空白由外层吞掉点击，不会穿透翻页。
    private var readerTopChrome: some View {
        HStack(spacing: 10) {
            readerGlassCircleButton("chevron.backward", label: "返回") { leaveReader() }
            VStack(spacing: 2) {
                Text(book.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(model.title).lineLimit(1)
                    if model.loadedFromCache {
                        Image(systemName: "arrow.down.circle")
                            .accessibilityLabel("已缓存")
                    }
                }
                .font(.caption)
                .foregroundStyle(readerChromeTint.opacity(0.62))
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background { readerGlass(Capsule()) }
            .accessibilityElement(children: .combine)
            readerGlassCircleButton(bookmarkSaved ? "bookmark.fill" : "bookmark", label: "书签") {
                toggleBookmark()
            }
            .accessibilityValue(bookmarkSaved ? "已添加" : "添加当前位置")
            .accessibilityHint(bookmarkSaved ? "轻点取消本页书签" : "")
            .disabled(isSavingBookmark)
            readerCoverButton
        }
        .foregroundStyle(readerChromeTint)
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        // 整条（含按钮之间的空白和状态栏区域）都吃掉点击，避免点空白处穿透到正文触发翻页。
        .background { Color.white.opacity(0.001).ignoresSafeArea(edges: .top).onTapGesture {} }
    }

    /// 玻璃材质：iOS 26 用系统 Liquid Glass，旧系统用毛玻璃 + 阅读底色轻染；
    /// 「减少透明度」或关闭玻璃模式时退回实色。
    @ViewBuilder
    private func readerGlass<S: InsettableShape>(_ shape: S) -> some View {
        if followsPanelTheme {
            // 外观主题「阅读半屏卡片跟随外观」：阅读页的菜单卡片也用主题卡片（界面效果 / 卡片背景）。
            ThemeSurface(shape: shape, isCard: true)
                .environment(\.colorScheme, resolvedStyle.isDark ? .dark : .light)
        } else {
            AppGlassSurface(shape: shape, tint: backgroundColor, tintOpacity: 0.32,
                            reduceTransparency: reduceTransparency)
                .environment(\.colorScheme, resolvedStyle.isDark ? .dark : .light)
        }
    }

    private var followsPanelTheme: Bool { appTheme.customization?.readerPanelFollowsTheme == true }

    private var readerIsDark: Bool { resolvedStyle.isDark }

    /// 外观主题「阅读工具栏图标 → 图标大小」（未自定义时沿用原来的大小）。
    private var readerToolbarIconPointSize: CGFloat {
        if let value = appTheme.customization?.readerToolbarIconSize { return CGFloat(min(max(value, 10), 40)) }
        return CGFloat(min(toolbarIconSize, 26))
    }

    /// 工具栏图标：外观主题里为亮色 / 深色选了图片就用图片，否则用系统图标。
    @ViewBuilder
    private func readerToolbarIcon(_ item: ThemeReaderToolbarItem?, symbol: String) -> some View {
        let size = readerToolbarIconPointSize
        if let item, let id = appTheme.customization?.readerToolbarIcon(item, dark: readerIsDark),
           let image = ThemeAssetStore.shared.image(for: id) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size + 4, height: size + 4)
        } else {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .regular))
        }
    }

    /// 底栏样式「聊天输入框」：进度卡片 + 一条像聊天输入框的胶囊（目录 · 搜索框 · 朗读 · 外观 · 更多）。
    private var readerChatBottomChrome: some View {
        VStack(spacing: 8) {
            readerChapterControls
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 2)
                .background { readerGlass(RoundedRectangle(cornerRadius: 22, style: .continuous)) }
            HStack(spacing: 8) {
                readerChatButton(.toc, symbol: "list.bullet", label: "目录") {
                    showsReaderMenu = false
                    showsTableOfContents = true
                }
                Button {
                    showsReaderMenu = false
                    showsContentSearch = true
                } label: {
                    HStack(spacing: 8) {
                        readerToolbarIcon(.search, symbol: "magnifyingglass")
                            .foregroundStyle(readerChromeTint.opacity(0.7))
                        Text("搜索本章内容")
                            .font(.subheadline)
                            .foregroundStyle(readerChromeTint.opacity(0.45))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background { readerGlass(Capsule()) }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("搜索正文")
                if speech.isSpeaking {
                    readerChatButton(nil, symbol: "stop.fill", label: "停止") { toggleSpeech() }
                } else {
                    readerChatButton(.tts, symbol: "speaker.wave.2", label: "朗读") { toggleSpeech() }
                }
                readerChatButton(.style, symbol: "textformat.size", label: "外观") {
                    showsReaderMenu = false
                    showsStyleControls = true
                }
                Menu {
                    Button {
                        showsReaderMenu = false
                        showsReaderSettings = true
                    } label: { Label("阅读设置", systemImage: "gearshape") }
                    if model.canEditContent {
                        Button(action: openSourceSwitch) { Label("换源", systemImage: "arrow.triangle.2.circlepath") }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 46, height: 46)
                        .background { readerGlass(Circle()) }
                        .contentShape(Circle())
                }
                .accessibilityLabel("更多")
            }
        }
        .foregroundStyle(readerChromeTint)
        .frame(maxWidth: 560)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .background { Color.white.opacity(0.001).ignoresSafeArea(edges: .bottom).onTapGesture {} }
    }

    private func readerChatButton(_ item: ThemeReaderToolbarItem?, symbol: String, label: String,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            readerToolbarIcon(item, symbol: symbol)
                .frame(width: 46, height: 46)
                .background { readerGlass(Circle()) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func readerGlassCircleButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 44, height: 44)
                .background { readerGlass(Circle()) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// 右上角的圆形封面：轻点打开「书籍操作」面板（原「更多」菜单里的功能都在里面）。
    private var readerCoverButton: some View {
        Button {
            showsReaderMenu = false
            showsBookActions = true
        } label: {
            BookCoverArtwork(title: book.name, author: book.author, remoteURL: book.displayCoverUrl, width: 40, height: 56)
                .frame(width: 38, height: 38, alignment: .center)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(readerChromeTint.opacity(0.12), lineWidth: 0.5))
                .frame(width: 44, height: 44)
                .background { readerGlass(Circle()) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("更多")
        .accessibilityHint("书籍操作：搜索正文、书签列表、自动阅读等")
    }

    /// 关掉「书籍操作」面板后再打开另一个面板（两个 sheet 不能同时弹出）。
    private func afterBookActions(_ action: @escaping @MainActor () -> Void) {
        showsBookActions = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            action()
        }
    }

    private var isLocalEPUB: Bool {
        book.origin == "local" && URL(string: book.bookUrl)?.pathExtension.lowercased() == "epub"
    }

    /// 书籍操作面板：上面是封面、书名、作者、书源、进度；下面是操作网格。半屏，不遮住正文。
    private var bookActionsSheet: some View {
        ReadingNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top, spacing: 14) {
                        BookCoverArtwork(title: book.name, author: book.author, remoteURL: book.displayCoverUrl, width: 64, height: 88)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(book.name)
                                .font(.headline)
                                .lineLimit(2)
                            if !book.author.isEmpty {
                                Text(book.author)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            if !book.originName.isEmpty {
                                Label(book.originName, systemImage: "globe")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Label("进度 \(model.readableNumber(at: model.currentIndex))/\(model.readableChapterCount)", systemImage: "book")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 18) {
                        bookAction("arrow.clockwise", "重新获取", enabled: !model.isLoading && model.canEditContent) {
                            showsBookActions = false
                            refreshCurrentChapter()
                        }
                        bookAction("square.and.pencil", "编辑正文", enabled: model.canEditContent && !model.content.isEmpty) {
                            afterBookActions {
                                editedContent = model.content
                                contentEditError = nil
                                showsContentEditor = true
                            }
                        }
                        bookAction("arrow.triangle.2.circlepath", "换源", enabled: model.canEditContent) {
                            afterBookActions { openSourceSwitch() }
                        }
                        bookAction("wand.and.stars", "替换净化") {
                            afterBookActions { showsReplaceRules = true }
                        }
                        bookAction("magnifyingglass", "搜索正文") {
                            afterBookActions { showsContentSearch = true }
                        }
                        bookAction("bookmark", "书签列表") {
                            afterBookActions { showsBookmarks = true }
                        }
                        bookAction(isAutoReading ? "stop.circle" : "play.circle", isAutoReading ? "停止自动阅读" : "自动阅读") {
                            if isAutoReading {
                                isAutoReading = false
                                showsBookActions = false
                            } else {
                                afterBookActions { showsAutoReadControls = true }
                            }
                        }
                        bookAction(resolvedStyle.isDark ? "sun.max" : "moon",
                                   resolvedStyle.isDark ? "切换为日间" : "切换为夜间",
                                   enabled: themeMode != "3") {
                            toggleNightTheme()
                        }
                        if isLocalEPUB {
                            bookAction("photo.on.rectangle", "本章插图") {
                                afterBookActions { illustrationChapter = model.currentChapter }
                            }
                        }
                        // 书源自带的评论 / 功能入口（番茄等书源的 callBackJs 与评论函数），和安卓「阅读」一致。
                        if model.hasSourceCallback {
                            bookAction("text.bubble", "书评") {
                                afterBookActions { openSourceScript(sourceEventScript("clickBookName")) }
                            }
                            bookAction("square.grid.2x2", "作品功能") {
                                afterBookActions { openSourceScript(sourceEventScript("clickCustomButton")) }
                            }
                        }
                        if model.sourceDefines("getChapComments") {
                            bookAction("bubble.left.and.bubble.right", "本章章评") {
                                afterBookActions { openSourceScript(chapterCommentScript("getChapComments")) }
                            }
                        }
                        if model.sourceDefines("getAuthorSay") {
                            bookAction("pencil.and.outline", "作家说") {
                                afterBookActions { openSourceScript(chapterCommentScript("getAuthorSay")) }
                            }
                        }
                    }
                    Text("重新获取、编辑正文只作用于当前章节。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .navigationTitle("书籍操作")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showsBookActions = false }
                }
            }
        }
        .readingLivePreviewSheet()
        .readingPresentationDragIndicator()
    }

    private func bookAction(_ icon: String, _ title: String, enabled: Bool = true,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 21, weight: .regular))
                    .frame(height: 26)
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.5))
        .disabled(!enabled)
        .accessibilityLabel(title)
    }

    private var readerBottomChrome: some View {
        VStack(spacing: 6) {
            readerChapterControls
            LazyVGrid(columns: readerToolbarColumns, spacing: 4) {
                readerChromeAction("list.bullet", "目录", item: .toc) {
                    showsReaderMenu = false
                    showsTableOfContents = true
                }
                if model.canEditContent {
                    readerChromeAction("arrow.triangle.2.circlepath", "换源", action: openSourceSwitch)
                    .accessibilityIdentifier("reader.changeSource")
                    .accessibilityValue(book.originName)
                }
                readerChromeAction(speech.isSpeaking ? "stop.fill" : "headphones", speech.isSpeaking ? "停止" : "朗读",
                                   isActive: speech.isSpeaking, item: speech.isSpeaking ? nil : .tts) { toggleSpeech() }
                readerChromeAction("textformat.size", "外观", item: .style) {
                    showsReaderMenu = false
                    showsStyleControls = true
                }
                readerChromeAction("gearshape", "设置") {
                    showsReaderMenu = false
                    showsReaderSettings = true
                }
            }
        }
        .foregroundStyle(readerChromeTint)
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .frame(maxWidth: 560)
        .background { readerGlass(RoundedRectangle(cornerRadius: 26, style: .continuous)) }
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .onTapGesture {}
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        // 卡片四周和底部安全区的空白也吃掉点击，不穿透到正文。
        .background { Color.white.opacity(0.001).ignoresSafeArea(edges: .bottom).onTapGesture {} }
    }

    private var readerToolbarColumns: [GridItem] {
        let count = dynamicTypeSize.isAccessibilitySize ? (model.canEditContent ? 3 : 2) : (model.canEditContent ? 5 : 4)
        return Array(repeating: GridItem(.flexible(), spacing: 0), count: count)
    }

    /// 进度区：上面一行章节名和本章页码；下面「‹ 滑块 ›」——左右箭头切换章节，
    /// 滑块拖动调整在本章里的位置，松手后跳过去。
    private var readerChapterControls: some View {
        let fraction = scrubFraction ?? chapterSliderFraction
        let pages = max(totalPages, 1)
        let previewPage = min(max(Int((fraction * Double(pages - 1)).rounded()) + 1, 1), pages)
        return VStack(spacing: 2) {
            HStack(spacing: 8) {
                Text(model.title)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Group {
                    if pageAnimation == 3 {
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                    } else {
                        Text("\(scrubFraction == nil ? currentPage : previewPage)/\(pages)")
                    }
                }
                .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(readerChromeTint.opacity(0.62))
            .padding(.horizontal, 10)
            .accessibilityElement(children: .combine)
            HStack(spacing: 0) {
                readerChromeIconButton("chevron.left", label: "上一章") { moveChapter(-1) }
                    .disabled(!model.canGoPrevious)
                    .opacity(model.canGoPrevious ? 1 : 0.25)
                Slider(value: Binding(
                    get: { scrubFraction ?? chapterSliderFraction },
                    set: { scrubFraction = min(max($0, 0), 1) }
                ), in: 0...1, onEditingChanged: { editing in
                    if !editing { commitScrub() }
                })
                .tint(appTheme.customization?.progressBarFollowsTheme == true
                      ? ReadingTheme.accent : readerChromeTint.opacity(0.8))
                .disabled(model.content.isEmpty || model.isLoading)
                .accessibilityLabel("阅读进度")
                .accessibilityValue(chapterProgress.formatted(.percent.precision(.fractionLength(0))))
                readerChromeIconButton("chevron.right", label: "下一章") { moveChapter(1) }
                    .disabled(!model.canGoNext)
                    .opacity(model.canGoNext ? 1 : 0.25)
            }
        }
    }

    /// 松开进度条：按比例换算成本章正文里的字符位置并跳转。
    private func commitScrub() {
        guard let fraction = scrubFraction else { return }
        let length = model.content.utf16.count
        guard length > 0 else { scrubFraction = nil; return }
        let target = fraction >= 0.999 ? max(length - 1, 0) : min(max(Int(Double(length) * fraction), 0), max(length - 1, 0))
        stopSpeechIfNeeded()
        readerJumpPosition = nil
        DispatchQueue.main.async {
            readerJumpPosition = target
            readerPosition = target
            scrubFraction = nil
            saveProgress(immediate: false)
        }
    }

    private func readerChromeIconButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .regular))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func readerChromeAction(_ icon: String, _ title: String, isActive: Bool = false,
                                    item: ThemeReaderToolbarItem? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                readerToolbarIcon(item, symbol: icon)
                    .frame(height: max(26, readerToolbarIconPointSize + 4))
                Text(title)
                    .font(.system(size: 10.5))
                    .foregroundStyle(readerChromeTint.opacity(isActive ? 1 : 0.6))
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .background {
                if isActive {
                    Capsule().fill(readerChromeTint.opacity(0.1)).padding(.horizontal, 6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func toggleNightTheme() {
        if resolvedStyle.isDark {
            // 跟随系统深色时手动切回日间：关掉跟随，否则下一次刷新又会变回深色。
            if followSystemDark { followSystemDark = false }
            theme = ReaderStylePreset.darkIDs.contains(previousDayTheme) ? "wechat" : previousDayTheme
        } else {
            previousDayTheme = resolvedStyle.id
            theme = ReaderStylePreset.darkIDs.contains(darkTheme) ? darkTheme : "night"
        }
    }

    private func selectMediaEpisode(_ index: Int) {
        guard model.chapters.indices.contains(index), index != model.currentIndex else { return }
        saveProgress(immediate: true)
        readerJumpPosition = nil
        model.select(index: index)
        readerPosition = 0
    }

    private func moveChapter(_ direction: Int) {
        stopSpeechIfNeeded()
        showsReaderMenu = false
        saveProgress(immediate: true)
        readerJumpPosition = nil
        if direction < 0 { model.goPrevious() } else { model.goNext() }
        readerPosition = model.requestedPosition
    }

    private func requestNextChapter() {
        if pageAnimation == 3 {
            guard model.canGoNext else { isAutoReading = false; return }
            Task { await model.extendContinuousReading(direction: 1, rules: model.usesReplaceRules ? replaceRules.rules : []) }
            return
        }
        guard model.canGoNext, model.hasContinuationWindow else {
            isAutoReading = false
            return
        }
        if model.isContinuationWindowReady {
            isWaitingForNextChapter = false
            readerRenderRevision &+= 1
        } else {
            isWaitingForNextChapter = true
        }
    }

    /// Paged chapter turn. When the neighbouring chapter is already in memory
    /// it swaps in the same frame and animates like an in-chapter page turn;
    /// otherwise the page stays put with a small loading footer until it is
    /// ready, instead of flashing a full-screen loading page.
    private func turnChapterWhenReady(direction: Int, boundaryPosition: Int) {
        guard chapterTurnWait == nil else { return }
        if model.isNeighborReady(direction: direction) {
            performChapterTurn(direction: direction, boundaryPosition: boundaryPosition)
            return
        }
        isWaitingForChapterTurn = true
        let generation = model.chapterLoadGeneration
        chapterTurnWait = Task { @MainActor in
            _ = await model.waitForNeighbor(direction: direction)
            let cancelled = Task.isCancelled
            chapterTurnWait = nil
            isWaitingForChapterTurn = false
            guard !cancelled, generation == model.chapterLoadGeneration else { return }
            performChapterTurn(direction: direction, boundaryPosition: boundaryPosition)
        }
    }

    private func performChapterTurn(direction: Int, boundaryPosition: Int) {
        showsReaderMenu = false
        readerPosition = boundaryPosition
        saveProgress(immediate: true)
        readerJumpPosition = nil
        // Keep every chapter in its own TextKit document. Appending text here
        // makes the absolute UTF-16 offset belong to the previous chapter
        // while progress is saved under the next.
        chapterTurnDirection = direction
        chapterTurnToken &+= 1
        if direction > 0 {
            model.goNext()
            readerPosition = model.requestedPosition
        } else {
            model.goPrevious(position: Int.max)
        }
    }

    private func requestPreviousChapter() {
        guard model.canGoPrevious, model.hasPreviousWindow else { return }
        if model.isPreviousWindowReady {
            advanceToPreparedPreviousChapter()
        } else {
            isWaitingForPreviousChapter = true
        }
    }

    private func advanceToPreparedPreviousChapter() {
        guard model.canGoPrevious, model.hasPreviousWindow, model.isPreviousWindowReady else { return }
        isWaitingForPreviousChapter = false
        saveProgress(immediate: true)
        readerJumpPosition = nil
        let position = max(model.previousContent.utf16.count - 1, 0)
        readerPosition = position
        model.promotePrevious(position: position)
    }

    private func startAutoReading() {
        stopSpeechIfNeeded()
        showsReaderMenu = false
        isAutoReading = true
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = keepScreenOn || isAutoReading
            || (readAloudWakeLock && speech.isSpeaking)
    }

    private func pageDidChange() {
        saveProgress()
        guard enableReadRecord else { return }
        Task { await activity.checkpoint(book) }
    }


    private var autoReadControls: some View {
        ReadingNavigationStack {
            Form {
                Section {
                    AdjustableSlider(
                        title: "自动翻页速度",
                        value: Binding(
                            get: { Double(autoReadSpeed) },
                            set: { autoReadSpeed = max(1, min(Int($0.rounded()), 120)) }
                        ),
                        range: 1...120,
                        step: 1,
                        format: { "\(Int($0))s" }
                    )
                } footer: {
                    Text("数值表示自动阅读一屏所用的秒数，范围 1–120 秒。")
                }
                Section {
                    Button("目录", systemImage: "list.bullet") {
                        showsAutoReadControls = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { showsTableOfContents = true }
                    }
                    Button("开始自动阅读", systemImage: "play.fill") {
                        showsAutoReadControls = false
                        startAutoReading()
                    }
                    Button("主菜单", systemImage: "menubar.rectangle") {
                        showsAutoReadControls = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { showsReaderMenu = true }
                    }
                    Button("停止自动阅读", systemImage: "stop.fill", role: .destructive) {
                        isAutoReading = false
                        showsAutoReadControls = false
                    }
                    Button("设置", systemImage: "gearshape") {
                        showsAutoReadControls = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { showsStyleControls = true }
                    }
                }
            }
            .navigationTitle("自动阅读")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("继续阅读") { showsAutoReadControls = false }
                }
            }
        }
        .readingPresentationDetents([.medium])
    }


    /// 「外观」与「阅读设置」打开同一个阅读设置面板（主题 / 显示 / 朗读），分别停在「主题」「显示」。
    private var styleControls: some View { readerSettingsPanel(.theme) }

    private var readerSettings: some View { readerSettingsPanel(.display) }

    private func readerSettingsPanel(_ tab: ReaderSettingsPage.Tab) -> some View {
        ReaderSettingsPage(initialTab: tab, context: ReaderSettingsPage.ReaderContext(
            pageAnimation: $pageAnimation,
            displayExtras: AnyView(readerDisplayExtras),
            speechExtras: AnyView(readerSpeechExtras),
            close: closeSettingsPanels
        ))
        // 固定半屏、不压暗正文：调整时直接看到后面正文的变化。
        .readingLivePreviewSheet()
        .readingPresentationDragIndicator()
    }

    private func closeSettingsPanels() {
        showsStyleControls = false
        showsReaderSettings = false
    }

    /// 只在阅读页才有的显示项：本章正文、自动阅读、点击区域、亮度。
    @ViewBuilder private var readerDisplayExtras: some View {
        AppearanceGroup("正文", prominent: true) {
            Button {
                editedContent = model.content
                contentEditError = nil
                closeSettingsPanels()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { showsContentEditor = true }
            } label: { AppearanceRowLabel(title: "编辑本章正文", icon: "square.and.pencil") }
            .buttonStyle(.plain)
            .disabled(!model.canEditContent || model.content.isEmpty)
            .opacity(!model.canEditContent || model.content.isEmpty ? 0.45 : 1)
            Button {
                closeSettingsPanels()
                refreshCurrentChapter()
            } label: { AppearanceRowLabel(title: "重新获取本章", icon: "arrow.clockwise") }
            .buttonStyle(.plain)
            .disabled(model.isLoading || !model.canEditContent)
            .opacity(model.isLoading || !model.canEditContent ? 0.45 : 1)
            if !model.canEditContent {
                ReaderSettingsFootnote(text: "本地 TXT / EPUB 直接读取原文件。本章编辑与网络刷新仅对网络书籍开放。")
            }
        }
        AppearanceGroup("操作", prominent: true) {
            Button {
                closeSettingsPanels()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { showsAutoReadControls = true }
            } label: { AppearanceRowLabel(title: "自动阅读设置", icon: "play.circle", chevron: true) }
            .buttonStyle(.plain)
            Button {
                closeSettingsPanels()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { showsClickActionSettings = true }
            } label: { AppearanceRowLabel(title: "点击区域设置", icon: "square.grid.3x3", chevron: true) }
            .buttonStyle(.plain)
            Button {
                followsSystemBrightness = true
                storedReaderBrightness = 0
                UIScreen.main.brightness = CGFloat(brightnessBeforeReading)
                readerBrightness = brightnessBeforeReading
            } label: { AppearanceRowLabel(title: "跟随系统亮度", icon: "sun.max") }
            .buttonStyle(.plain)
        }
    }

    /// 只在阅读页才有的朗读项：本书单独的朗读引擎、本次定时、朗读状态。
    @ViewBuilder private var readerSpeechExtras: some View {
        AppearanceGroup("本书", prominent: true) {
            AppearancePickerRow(
                title: "本书朗读引擎",
                options: [("__global__", "跟随全局"), ("", "系统 TTS")] + httpTTSEngines.map { (String($0.id), $0.name) },
                selection: bookTTSEngineBinding
            )
            if speechTimerRemaining > 0 {
                ReaderSettingsFootnote(text: "本次朗读还剩 \(speechTimerRemaining) 分钟")
            }
            if let status = speech.roleStatus {
                ReaderSettingsFootnote(text: status)
            }
            if let error = speech.errorMessage {
                Text(error)
                    .font(AppFontStyle.footnote.themed)
                    .foregroundStyle(Color.red)
                    .padding(.horizontal, 6)
            }
        }
    }

    /// 执行书源回调脚本（书评、章评、作家说、作品功能），拿到网址后半屏打开。
    private func openSourceScript(_ script: String) {
        guard reviewPage == nil else { return }
        let model = model
        reviewPage = ReaderReviewPage(
            url: nil,
            bridge: { await model.runSourceBridge($0) },
            loader: { await model.resolveReviewClick(script) }
        )
    }

    private func sourceEventScript(_ event: String) -> String {
        "var event = '\(event)';\n" + model.sourceCallbackScript
    }

    /// 番茄类书源的章评 / 作家说函数：参数是作品 ID 和本章 ID（章节地址里的 q 参数）。
    private func chapterCommentScript(_ function: String) -> String {
        """
        (function () {
          var page = String(baseUrl || '');
          var bookId = typeof currentBookId === 'function' ? currentBookId(page, book) : '';
          var itemId = typeof queryValue === 'function' ? queryValue(page, 'q') : '';
          return \(function).call(this, bookId, itemId);
        }).call(this);
        """
    }

    /// 段评气泡 / 插图点击：网址直接半屏打开；书源回调先在后台执行拿到网址。
    private func openReviewLink(_ url: URL) {
        // 气泡设置 › 交互 › 触感反馈。
        if BubblePreferences.hapticsEnabled { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        guard let script = ReaderInlineMarkup.script(from: url) else {
            reviewPage = ReaderReviewPage(url: url)
            return
        }
        guard reviewPage == nil else { return }
        let model = model
        reviewPage = ReaderReviewPage(
            url: nil,
            bridge: { await model.runSourceBridge($0) },
            loader: { await model.resolveReviewClick(script) }
        )
    }


    private var clickActions: [Int] {
        // Keep persisted action IDs stable; the removed sync action becomes a no-op.
        // 「全屏翻页」：左侧的「上一页」也翻到下一页，单手点哪都往后翻。
        [clickActionTL, clickActionTC, clickActionTR, clickActionML, 0, clickActionMR, clickActionBL, clickActionBC, clickActionBR]
            .map { $0 == 12 ? -1 : $0 }
            .map { fullScreenTurn && $0 == 2 ? 1 : $0 }
    }

    private static let tapActionChoices: [(Int, String)] = [
        (-1, "无动作"), (0, "菜单"), (1, "下一页"), (2, "上一页"),
        (3, "下一章"), (4, "上一章"), (5, "朗读上一段"), (6, "朗读下一段"),
        (7, "添加书签"), (8, "编辑正文"), (9, "替换(启用/禁用)"), (10, "目录"),
        (11, "搜索正文"), (13, "暂停/继续朗读")
    ]

    private var clickActionSettings: some View {
        ReadingNavigationStack {
            VStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: 8) {
                        ForEach(0..<3, id: \.self) { column in
                            let index = row * 3 + column
                            VStack(spacing: 8) {
                                Text(["左上", "上中", "右上", "左中", "中央", "右中", "左下", "下中", "右下"][index])
                                    .font(.caption).foregroundStyle(.secondary)
                                if index == 4 {
                                    Text("固定：菜单")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(ReadingTheme.accent)
                                        .frame(maxWidth: .infinity, minHeight: 32)
                                } else {
                                    Picker("动作", selection: clickActionBinding(at: index)) {
                                        ForEach(Self.tapActionChoices, id: \.0) { action in
                                            Text(action.1).tag(action.0)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(maxWidth: .infinity)
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(6)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
            .padding(10)
            .navigationTitle("点击区域设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showsClickActionSettings = false }
                }
            }
        }
    }

    private func clickActionBinding(at index: Int) -> Binding<Int> {
        let binding: Binding<Int> = switch index {
        case 0: $clickActionTL
        case 1: $clickActionTC
        case 2: $clickActionTR
        case 3: $clickActionML
        case 5: $clickActionMR
        case 6: $clickActionBL
        case 7: $clickActionBC
        default: $clickActionBR
        }
        return Binding(
            get: { binding.wrappedValue == 12 ? -1 : binding.wrappedValue },
            set: { binding.wrappedValue = $0 }
        )
    }

    private func handleTapAction(_ action: Int) {
        switch action {
        case 0: showsReaderMenu.toggle()
        case 3: if model.canGoNext { moveChapter(1) }
        case 4: if model.canGoPrevious { moveChapter(-1) }
        case 5: speech.previousSegment()
        case 6: speech.nextSegment()
        case 7: addBookmark()
        case 8:
            guard model.canEditContent else { return }
            showsReaderMenu = false
            editedContent = model.content
            contentEditError = nil
            showsContentEditor = true
        case 9:
            showsReaderMenu = false
            let updatedBook = model.toggleReplaceRules(position: readerPosition)
            Task {
                await library.addOrUpdate(updatedBook)
            }
        case 10:
            showsReaderMenu = false
            showsTableOfContents = true
        case 11:
            showsReaderMenu = false
            showsContentSearch = true
        case 13:
            isAutoReading = false
            configureSpeech()
            if let engine = selectedHTTPEngine {
                speech.pauseOrResumeHTTP(engine: engine, text: model.content, continuesAcrossChapters: true)
            } else {
                speech.pauseOrResume(text: model.content, continuesAcrossChapters: true)
            }
        default: break
        }
    }


    private var contentEditor: some View {
        ReadingNavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $editedContent)
                    .font(.body.monospaced())
                    .padding(8)
                if let contentEditError {
                    Text(contentEditError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }
            }
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showsContentEditor = false }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("重置") { refreshEditorFromSource() }
                    Button("保存") { saveEditedContent() }
                        .disabled(editedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    /// 新规则保存后就地重排当前章节：读缓存正文重新净化，不重新联网，尽量留在原位置。
    private func applyReplaceRulesInPlace() async {
        let position = readerPosition
        await model.reapplyReplaceRules(replaceRules.rules)
        readerPosition = min(position, max(model.content.utf16.count - 1, 0))
        readerJumpPosition = readerPosition
        readerPageRanges = []
        readerRenderRevision &+= 1
    }

    private func refreshCurrentChapter() {
        stopSpeechIfNeeded()
        Task {
            await model.load(rules: replaceRules.rules, forceRefresh: true, prefetchNextChapter: pageAnimation != 3)
            readerPosition = min(readerPosition, model.content.utf16.count)
        }
    }

    private func refreshEditorFromSource() {
        contentEditError = nil
        Task {
            await model.load(rules: replaceRules.rules, forceRefresh: true, prefetchNextChapter: pageAnimation != 3)
            editedContent = model.content
            if let error = model.diagnostics.first(where: { $0.severity == .error }) {
                contentEditError = error.message
            }
        }
    }

    private func saveEditedContent() {
        contentEditError = nil
        Task {
            do {
                try await model.saveEditedContent(editedContent)
                readerPosition = min(readerPosition, editedContent.utf16.count)
                showsContentEditor = false
            } catch {
                contentEditError = error.localizedDescription
            }
        }
    }


    private var tableOfContents: some View {
        ReaderTableOfContentsView(
            bookName: book.name,
            chapters: model.chapters,
            currentIndex: model.currentIndex,
            progress: chapterProgress,
            descending: $tocDescending,
            onClose: { showsTableOfContents = false },
            onSelect: { index in
                guard model.chapters.indices.contains(index) else { return }
                showsTableOfContents = false
                guard index != model.currentIndex else { return }
                stopSpeechIfNeeded()
                saveProgress(immediate: true)
                readerJumpPosition = nil
                model.select(index: index)
                readerPosition = 0
            }
        )
    }


    private var contentSearchSheet: some View {
        ReadingNavigationStack {
            Group {
                if contentSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ReadingUnavailableView("搜索正文", systemImage: "magnifyingglass", description: Text("输入本章正文关键字"))
                } else if contentSearchResults.isEmpty {
                    ReadingUnavailableView.search(text: contentSearchQuery)
                } else {
                    List(contentSearchResults) { paragraph in
                        Button {
                            readerPosition = paragraph.id
                            readerJumpPosition = nil
                            DispatchQueue.main.async { readerJumpPosition = paragraph.id }
                            showsContentSearch = false
                        } label: {
                            Text(paragraph.text)
                                .foregroundStyle(.primary)
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .navigationTitle("正文搜索")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $contentSearchQuery, prompt: "搜索本章")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showsContentSearch = false }
                }
            }
        }
    }

    private var contentSearchResults: [ReaderParagraph] {
        let query = contentSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return model.paragraphs.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    private var bookmarksSheet: some View {
        ReadingNavigationStack {
            Group {
                let bookmarks = activity.bookmarks(for: book)
                if bookmarks.isEmpty {
                    ReadingUnavailableView(
                        "本书还没有书签",
                        systemImage: "bookmark",
                        description: Text("阅读时点击顶部书签按钮即可记录当前位置。")
                    )
                } else {
                    List(bookmarks) { bookmark in
                        Button {
                            jump(to: bookmark)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(bookmark.chapterName).font(.headline).foregroundStyle(.primary)
                                if !bookmark.bookText.isEmpty {
                                    Text(bookmark.bookText).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                                }
                                Text("位置 \(bookmark.chapterPosition)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .swipeActions {
                            Button("删除", role: .destructive) { Task { await activity.removeBookmark(bookmark) } }
                        }
                    }
                }
            }
            .navigationTitle("书签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showsBookmarks = false } } }
        }
    }

    private var bookmarksOnCurrentPage: [Bookmark] {
        let page = currentPage - 1
        let range = pageAnimation != 3 && readerPageRanges.indices.contains(page) ? readerPageRanges[page] : nil
        return model.bookmarks(at: readerPosition, in: activity.bookmarks, pageRange: range)
    }

    private var bookmarkSaved: Bool { !bookmarksOnCurrentPage.isEmpty }

    /// 书签按钮是开关：当前页没有书签时添加，已有书签时再点一次取消（删除这一页上的书签）。
    private func toggleBookmark() {
        guard !isSavingBookmark else { return }
        let existing = bookmarksOnCurrentPage
        guard !existing.isEmpty else {
            addBookmark()
            return
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        isSavingBookmark = true
        Task {
            defer { isSavingBookmark = false }
            await activity.removeBookmarks(existing)
        }
    }

    private func addBookmark() {
        guard !isSavingBookmark, !bookmarkSaved, let chapter = model.currentChapter else { return }
        let currentBook = book
        let position = readerPosition
        let content = model.content
        isSavingBookmark = true
        Task {
            defer { isSavingBookmark = false }
            await activity.addBookmark(
                book: currentBook,
                chapter: chapter,
                position: position,
                content: content
            )
        }
    }

    private func jump(to bookmark: Bookmark) {
        guard let index = bookmark.resolvedChapterIndex(in: model.chapters) else { return }
        stopSpeechIfNeeded()
        saveProgress(immediate: true)
        model.select(index: index, position: bookmark.chapterPosition)
        readerPosition = bookmark.chapterPosition
        readerJumpPosition = nil
        showsBookmarks = false
    }


    private func saveProgress(immediate: Bool = false) {
        guard let chapter = model.currentChapter else { return }
        let position = readerPosition
        let currentBook = book
        progressSaveGeneration &+= 1
        progressSaveTask?.cancel()
        progressSaveTask = Task { @MainActor [weak library] in
            if !immediate { try? await Task.sleep(nanoseconds: 100_000_000) }
            guard !Task.isCancelled, let library else { return }
            await library.updateProgress(for: currentBook, chapter: chapter, position: position)
        }
    }


    private func stopSpeechIfNeeded() {
        speechStartGeneration &+= 1
        if speech.isSpeaking || speech.isPaused { speech.toggle(text: "") }
    }

    private func restartSpeechAfterReaderLayoutChange() {
        readerPageRanges = []
        guard speech.isSpeaking || speech.isPaused else { return }
        speechStartGeneration &+= 1
        speech.stop()
        configureSpeech()
        startConfiguredSpeech()
    }

    private func toggleSpeech() {
        isAutoReading = false
        configureSpeech()
        if speech.isSpeaking || speech.isPaused {
            speechStartGeneration &+= 1
            speech.stop()
            speechTimerTask?.cancel()
            speechTimerRemaining = 0
            return
        }
        scheduleSpeechTimer()
        startConfiguredSpeech()
    }

    private func startConfiguredSpeech() {
        if readAloudByPage {
            guard !readerPageRanges.isEmpty else {
                guard !model.content.isEmpty else { return }
                let generation = speechStartGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    guard generation == speechStartGeneration,
                          readAloudByPage,
                          !speech.isSpeaking,
                          !speech.isPaused else { return }
                    startConfiguredSpeech()
                }
                return
            }
            let pageIndex = readerPageRanges.firstIndex { readerPosition < NSMaxRange($0) }
                ?? max(readerPageRanges.count - 1, 0)
            speechPageIndex = pageIndex
            speakPage(at: pageIndex, from: readerPosition)
            return
        }
        let start = model.paragraphs.lastIndex(where: { $0.id <= readerPosition }) ?? 0
        let text = model.paragraphs.indices.contains(start)
            ? model.paragraphs[start...].map(\.text).joined(separator: "\n")
            : model.content
        if let engine = selectedHTTPEngine {
            speech.speakHTTP(
                engine: engine,
                text: text,
                continuesAcrossChapters: true,
                segmentIndexOffset: start
            )
            prefetchNextChapterSpeech(engine: engine)
        } else {
            speech.speak(text, continuesAcrossChapters: true, segmentIndexOffset: start)
        }
    }

    private func speakPage(at index: Int, from position: Int? = nil) {
        guard readerPageRanges.indices.contains(index) else {
            continueSpeechToNextChapter()
            return
        }
        let range = readerPageRanges[index]
        let start = min(max(position ?? range.location, range.location), NSMaxRange(range))
        let pageRange = NSRange(location: start, length: max(NSMaxRange(range) - start, 0))
        guard pageRange.length > 0 else {
            continueSpeechToNextPage()
            return
        }
        let pageText = (model.content as NSString).substring(with: pageRange)
        if let engine = selectedHTTPEngine {
            speech.speakHTTP(
                engine: engine,
                text: pageText,
                continuesAcrossChapters: true,
                segmentIndexOffset: 0
            )
        } else {
            speech.speak(pageText, continuesAcrossChapters: true, segmentIndexOffset: 0)
        }
    }

    private func continueSpeechToNextPage() {
        guard readAloudByPage, readerPageRanges.indices.contains(speechPageIndex) else {
            continueSpeechToNextChapter()
            return
        }
        readerPosition = NSMaxRange(readerPageRanges[speechPageIndex])
        guard readerPageRanges.indices.contains(speechPageIndex + 1) else {
            continueSpeechToNextChapter()
            return
        }
        speechPageIndex += 1
        let nextPosition = readerPageRanges[speechPageIndex].location
        readerPosition = nextPosition
        readerJumpPosition = nextPosition
        speakPage(at: speechPageIndex)
    }

    private func prefetchNextChapterSpeech(engine: HttpTTS) {
        Task {
            guard let content = await model.nextSpeechContent(
                rules: model.usesReplaceRules ? replaceRules.rules : []
            ), selectedHTTPEngine?.id == engine.id else { return }
            speech.prefetchHTTP(engine: engine, text: content, limit: 10)
        }
    }

    private func continueSpeechToNextChapter() {
        guard model.canGoNext else {
            speechTimerTask?.cancel()
            speechTimerRemaining = 0
            return
        }
        saveProgress(immediate: true)
        resumesSpeechAfterChapterLoad = true
        readerJumpPosition = nil
        model.goNext()
        readerPosition = model.requestedPosition
    }

    private func moveSpeechToChapter(direction: Int) {
        let canMove = direction < 0 ? model.canGoPrevious : model.canGoNext
        guard canMove else { return }
        speech.stop()
        saveProgress(immediate: true)
        resumesSpeechAfterChapterLoad = true
        readerJumpPosition = nil
        if direction < 0 { model.goPrevious() } else { model.goNext() }
        readerPosition = model.requestedPosition
    }

    private func scheduleSpeechTimer() {
        speechTimerTask?.cancel()
        speechTimerRemaining = ttsTimer
        guard speechTimerRemaining > 0 else { return }
        speechTimerTask = Task { @MainActor in
            do {
                while speechTimerRemaining > 0 {
                    try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                    if !speech.isSpeaking && !speech.isPaused && !resumesSpeechAfterChapterLoad {
                        speechTimerRemaining = 0
                        break
                    }
                    if !speech.isPaused { speechTimerRemaining -= 1 }
                    if speechTimerRemaining == 0 {
                        speech.stop()
                        resumesSpeechAfterChapterLoad = false
                    }
                }
            } catch { }
        }
    }

    private func configureSpeech() {
        speech.allowsRoleAnalysis = true
        speech.availableHTTPEngines = httpTTSEngines
        speech.configure(
            followsSystemRate: ttsFollowSystem,
            speechRate: ttsSpeechRate,
            readByPage: readAloudByPage,
            streamsHTTPAudio: streamReadAloudAudio,
            voiceIdentifier: systemTTSVoice,
            ignoresAudioFocus: ignoreAudioFocus,
            pausesForPhoneCalls: pauseReadAloudWhilePhoneCalls,
            mediaButtonPerNext: mediaButtonPerNext,
            bookName: model.book.name,
            chapterTitle: model.title,
            author: model.book.author
        )
    }

    private static func globalPageAnimation() -> Int {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "pageAnim") == nil,
           let legacy = defaults.object(forKey: "readerPageAnimation") as? NSNumber {
            defaults.set(legacy.intValue, forKey: "pageAnim")
        }
        return defaults.integer(forKey: "pageAnim")
    }

    private var selectedHTTPEngine: HttpTTS? {
        let value = model.book.readConfig?.ttsEngine ?? appTTSEngine
        guard let id = Int64(value) else { return nil }
        return httpTTSEngines.first { $0.id == id }
    }

    private var systemTTSVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("zh") }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var bookTTSEngineBinding: Binding<String> {
        Binding(
            get: { model.book.readConfig?.ttsEngine ?? "__global__" },
            set: { value in
                let updated = model.setTTSEngine(value == "__global__" ? nil : value)
                Task { await library.addOrUpdate(updated) }
            }
        )
    }

    private func loadHTTPEngines() async {
        guard let database = try? LegadoDatabase(url: LegadoDatabase.defaultURL()) else { return }
        let repository = SQLiteConfigurationRepository(database: database)
        var values = (try? await repository.loadHttpTTS()) ?? []
        if values.isEmpty,
           let url = Bundle.main.url(forResource: "httpTTS", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let defaults = try? JSONDecoder().decode([HttpTTS].self, from: data) {
            values = defaults
            try? await repository.saveHttpTTS(values)
        }
        httpTTSEngines = values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !appTTSEngine.isEmpty, selectedHTTPEngine == nil { appTTSEngine = "" }
    }
}

#if DEBUG
private struct ReaderFailureTestLoader: ChapterContentLoading {
    func loadContent(book: Book, chapter: BookChapter, source: BookSource, nextChapterURL: String?, maxPages: Int) async -> ChapterContentReport {
        .init(content: ProcessInfo.processInfo.arguments.contains("-uiReaderPartialFailure") ? "本章只加载了第一页正文。" : "",
              diagnostics: [.init(severity: .error, code: "content.request", message: "测试书源正文请求失败", rule: chapter.url)])
    }
}
#endif


/// 长按正文弹出的快速替换：选好要替换的文字和替换成的内容，保存为净化规则并立即生效。
private struct ReaderQuickReplaceSheet: View {
    let pick: ReaderTextPick
    let bookName: String
    let sourceURL: String
    let rulesDisabled: Bool
    let makeRule: () -> ReplaceRule
    let onSave: (ReplaceRule) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var pattern: String
    @State private var replacement = ""
    @State private var scope = 0
    @State private var isRegex = false
    @State private var saving = false
    @State private var error: String?

    init(pick: ReaderTextPick, bookName: String, sourceURL: String, rulesDisabled: Bool,
         makeRule: @escaping () -> ReplaceRule, onSave: @escaping (ReplaceRule) async -> String?) {
        self.pick = pick
        self.bookName = bookName
        self.sourceURL = sourceURL
        self.rulesDisabled = rulesDisabled
        self.makeRule = makeRule
        self.onSave = onSave
        _pattern = State(initialValue: pick.word)
    }

    private var trimmedPattern: String { pattern.trimmingCharacters(in: .newlines) }

    private var paragraphHeight: CGFloat {
        let lines = max(1, min(6, pick.paragraph.count / 18 + 1))
        return CGFloat(lines) * 22 + 12
    }

    private var matchCount: Int {
        guard !trimmedPattern.isEmpty else { return 0 }
        if isRegex {
            guard let regex = try? NSRegularExpression(pattern: trimmedPattern) else { return 0 }
            return regex.numberOfMatches(in: pick.paragraph, range: NSRange(location: 0, length: (pick.paragraph as NSString).length))
        }
        return pick.paragraph.components(separatedBy: trimmedPattern).count - 1
    }

    var body: some View {
        ReadingNavigationStack {
            Form {
                Section {
                    ReaderParagraphSelectView(text: pick.paragraph, selection: $pattern)
                        .frame(height: paragraphHeight)
                } header: {
                    Text("所在段落")
                } footer: {
                    Text("在段落里拖动选择要替换的文字，会自动填到下面。")
                }
                Section("替换") {
                    ReadingTextField("要替换的文字", text: $pattern, axis: .vertical)
                        .accessibilityIdentifier("quickReplace.pattern")
                    ReadingTextField("替换为（留空则删除）", text: $replacement, axis: .vertical)
                        .accessibilityIdentifier("quickReplace.replacement")
                    Toggle("使用正则表达式", isOn: $isRegex)
                    if !trimmedPattern.isEmpty {
                        Text(isRegex && (try? NSRegularExpression(pattern: trimmedPattern)) == nil
                             ? "正则表达式无效"
                             : "本段匹配 \(matchCount) 处")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Picker("作用范围", selection: $scope) {
                        Text("仅本书").tag(0)
                        Text("本书源").tag(1)
                        Text("全部书籍").tag(2)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("作用范围")
                } footer: {
                    Text(rulesDisabled
                         ? "本书已关闭净化规则，规则会保存，但要在阅读菜单里打开「替换规则」后才生效。"
                         : "保存后立即重排本章；之后可在「我的 → 净化规则」里修改或删除。")
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("替换文字")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(saving || trimmedPattern.isEmpty
                                  || (isRegex && (try? NSRegularExpression(pattern: trimmedPattern)) == nil))
                        .accessibilityIdentifier("quickReplace.save")
                }
            }
        }
        .readingPresentationDetents([.medium, .large])
    }

    private func save() {
        var rule = makeRule()
        let shown = trimmedPattern.count > 12 ? String(trimmedPattern.prefix(12)) + "…" : trimmedPattern
        rule.name = replacement.isEmpty ? "删除「\(shown)」" : "「\(shown)」→「\(replacement.prefix(12))」"
        rule.group = "阅读时添加"
        rule.pattern = trimmedPattern
        rule.replacement = replacement
        rule.isRegex = isRegex
        rule.scopeContent = true
        rule.scopeTitle = false
        rule.isEnabled = true
        switch scope {
        case 0: rule.scope = bookName.isEmpty ? nil : bookName
        case 1: rule.scope = sourceURL.isEmpty ? nil : sourceURL
        default: rule.scope = nil
        }
        saving = true
        error = nil
        Task {
            let failure = await onSave(rule)
            saving = false
            if let failure { error = failure } else { dismiss() }
        }
    }
}


/// 替换面板里可选字的段落：选中的文字实时填入「要替换的文字」。
private struct ReaderParagraphSelectView: UIViewRepresentable {
    let text: String
    @Binding var selection: String

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.font = UIFont.preferredFont(forTextStyle: .callout)
        view.adjustsFontForContentSizeCategory = true
        view.text = text
        view.delegate = context.coordinator
        view.accessibilityIdentifier = "quickReplace.paragraph"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.selection = $selection
        if view.text != text { view.text = text }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var selection: Binding<String>
        init(selection: Binding<String>) { self.selection = selection }

        func textViewDidChangeSelection(_ textView: UITextView) {
            let range = textView.selectedRange
            guard range.length > 0, NSMaxRange(range) <= (textView.text as NSString).length else { return }
            let value = (textView.text as NSString).substring(with: range)
            if selection.wrappedValue != value { selection.wrappedValue = value }
        }
    }
}

// MARK: - 短剧 / 听书播放

extension ReaderViewModel {
    /// 本章正文只有一个音视频地址（番茄短剧、漫剧、听书模式）时返回它，阅读页改为播放器。
    var currentMediaURL: URL? {
        let raw = scrollChapters.first(where: { $0.id == currentIndex })?.content ?? content
        return Self.mediaURL(in: raw, bookType: book.type)
    }

    var isAudioBook: Bool { book.type & 32 != 0 }

    /// 书源的事件回调脚本（ruleContent.callBackJs），去掉 @js: / <js> 包装。
    var sourceCallbackScript: String {
        var script = (source?.ruleContent?.callBackJs ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if script.lowercased().hasPrefix("@js:") { script = String(script.dropFirst(4)) }
        if script.lowercased().hasPrefix("<js>") {
            script = String(script.dropFirst(4))
            if let end = script.range(of: "</js>", options: [.caseInsensitive, .backwards]) {
                script = String(script[..<end.lowerBound])
            }
        }
        return script
    }

    var hasSourceCallback: Bool { !sourceCallbackScript.isEmpty }

    func sourceDefines(_ function: String) -> Bool {
        guard let source else { return false }
        let needle = "function " + function + "("
        return (source.jsLib ?? "").contains(needle) || (source.loginUrl ?? "").contains(needle)
    }

    /// 书源请求头里的 Referer / User-Agent 一并带给播放器，部分视频地址要校验。
    var mediaHeaders: [String: String] {
        guard let source, let headers = try? BookSourceHeaderResolver().resolve(source) else { return [:] }
        return headers.filter { ["referer", "user-agent", "cookie"].contains($0.key.lowercased()) }
    }

    nonisolated static func mediaURL(in raw: String, bookType: Int) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<"), let start = text.range(of: "http") {
            text = String(text[start.lowerBound...])
            if let end = text.firstIndex(where: { "\"'<> ".contains($0) }) { text = String(text[..<end]) }
        }
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        guard !text.isEmpty, !text.contains("\n"), !text.contains(" "),
              text.lowercased().hasPrefix("http") else { return nil }
        let lower = text.lowercased()
        let mediaExtensions = [".mp4", ".m3u8", ".mov", ".m4v", ".flv", ".mp3", ".m4a", ".aac", ".flac", ".wav", ".ogg"]
        let looksLikeMedia = mediaExtensions.contains { lower.contains($0) } || lower.contains("video") || lower.contains("audio")
        guard bookType & (4 | 32) != 0 || looksLikeMedia else { return nil }
        return URL(string: text)
    }
}

@MainActor
final class ReaderMediaPlayerHolder: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var isPlaying = false
    @Published private(set) var failure: String?
    private var currentURL: URL?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    var onEnd: (() -> Void)?

    init() {
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
            let playing = player.rate > 0
            Task { @MainActor in self?.isPlaying = playing }
        }
    }

    func play(_ url: URL, headers: [String: String]) {
        guard url != currentURL else { return }
        currentURL = url
        failure = nil
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        var options: [String: Any] = [:]
        if !headers.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = headers }
        let item = AVPlayerItem(asset: AVURLAsset(url: url, options: options))
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.onEnd?() }
        }
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let failed = item.status == .failed
            let message = item.error?.localizedDescription
            Task { @MainActor in if failed { self?.failure = message ?? "播放失败" } }
        }
        player.replaceCurrentItem(with: item)
        player.play()
    }

    func toggle() {
        if player.rate > 0 { player.pause() } else { player.play() }
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentURL = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }
}

struct ReaderMediaChapterView: View {
    let url: URL
    let headers: [String: String]
    let bookName: String
    let title: String
    let isAudio: Bool
    let chapters: [BookChapter]
    let currentIndex: Int
    let canGoPrevious: Bool
    let canGoNext: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onSelect: (Int) -> Void
    let onMenu: () -> Void
    @StateObject private var holder = ReaderMediaPlayerHolder()
    @AppStorage("readerMediaAutoNext") private var autoNext = true

    private var episodes: [(offset: Int, element: BookChapter)] {
        Array(chapters.enumerated()).filter { !$0.element.isVolume }
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    if isAudio {
                        VStack(spacing: 16) {
                            Image(systemName: holder.isPlaying ? "waveform" : "headphones")
                                .font(.system(size: 54, weight: .light))
                                .foregroundStyle(.white.opacity(0.9))
                            Text(title).font(.headline).foregroundStyle(.white).lineLimit(2)
                            Button { holder.toggle() } label: {
                                Image(systemName: holder.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                    .font(.system(size: 56))
                                    .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding()
                    } else {
                        VideoPlayer(player: holder.player)
                    }
                    if let failure = holder.failure {
                        Text("播放失败：\(failure)")
                            .font(.footnote)
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                            .padding()
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
                .frame(height: isAudio ? proxy.size.height * 0.38 : proxy.size.height * 0.62)
                .clipped()

                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(bookName).font(.headline).lineLimit(1)
                            Text(title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Button(action: onMenu) {
                            Image(systemName: "ellipsis.circle").font(.title3)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("阅读菜单")
                    }
                    HStack(spacing: 10) {
                        mediaButton("上一集", systemImage: "backward.end.fill", enabled: canGoPrevious, action: onPrevious)
                        mediaButton(holder.isPlaying ? "暂停" : "播放", systemImage: holder.isPlaying ? "pause.fill" : "play.fill", enabled: true) { holder.toggle() }
                        mediaButton("下一集", systemImage: "forward.end.fill", enabled: canGoNext, action: onNext)
                    }
                    Toggle("自动播放下一集", isOn: $autoNext).font(.subheadline)
                    Text("选集 · 共 \(episodes.count) 集").font(.subheadline.weight(.semibold))
                    ScrollViewReader { reader in
                        ScrollView(showsIndicators: false) {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                                ForEach(episodes, id: \.offset) { item in
                                    let current = item.offset == currentIndex
                                    Button { onSelect(item.offset) } label: {
                                        Text(episodeLabel(item.element.title, fallback: item.offset + 1))
                                            .font(.footnote.weight(current ? .semibold : .regular))
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.7)
                                            .frame(maxWidth: .infinity, minHeight: 38)
                                            .foregroundStyle(current ? Color.white : Color.primary)
                                            .background(current ? Color.accentColor : Color.secondary.opacity(0.12),
                                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                    .id(item.offset)
                                }
                            }
                            .padding(.bottom, 24)
                        }
                        .onAppear { reader.scrollTo(currentIndex, anchor: .center) }
                        .onChange(of: currentIndex) { value in
                            withAnimation { reader.scrollTo(value, anchor: .center) }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Color(uiColor: .systemBackground))
            }
        }
        .onAppear {
            holder.onEnd = { if autoNext && canGoNext { onNext() } }
            holder.play(url, headers: headers)
        }
        .onChange(of: url) { value in
            holder.onEnd = { if autoNext && canGoNext { onNext() } }
            holder.play(value, headers: headers)
        }
        .onDisappear { holder.stop() }
    }

    private func episodeLabel(_ title: String, fallback: Int) -> String {
        let digits = title.filter(\.isNumber)
        if !digits.isEmpty, title.count <= 8 { return digits }
        return title.isEmpty ? "\(fallback)" : title
    }

    private func mediaButton(_ title: String, systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(Color.secondary.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}


/// 外观主题「阅读半屏卡片跟随外观」：阅读页弹出的半屏面板铺主题页面背景（颜色 / 渐变 / 背景图），
/// 列表行用主题卡片底。关闭时保持原来的系统样式。
private struct ReaderPanelAppearanceModifier: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .readingScrollContentBackgroundHidden()
                .background { AppThemeCanvas().ignoresSafeArea() }
        } else {
            content
        }
    }
}

extension View {
    func readerPanelAppearance(_ enabled: Bool) -> some View {
        modifier(ReaderPanelAppearanceModifier(enabled: enabled))
    }
}
