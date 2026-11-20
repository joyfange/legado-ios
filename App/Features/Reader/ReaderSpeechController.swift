@preconcurrency import AVFoundation
@preconcurrency import MediaPlayer
import SwiftUI
import UniformTypeIdentifiers

private final class IncrementalAudioResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.legado.tts.stream-loader")
    private let contentType: String?
    private let expectedLength: Int64
    private var data = Data()
    private var pending: [AVAssetResourceLoadingRequest] = []
    private var finished = false
    private var failure: Error?
    private var consumeTask: Task<Void, Never>?

    init(stream: HttpTTSAudioStream) {
        contentType = stream.contentType
        expectedLength = stream.expectedContentLength ?? 0
        super.init()
        consumeTask = Task { [weak self] in
            do {
                for try await chunk in stream.chunks {
                    guard let self else { return }
                    self.queue.async { [weak self] in
                        self?.data.append(chunk)
                        self?.processPendingRequests()
                    }
                }
                self?.queue.async { [weak self] in
                    self?.finished = true
                    self?.processPendingRequests()
                }
            } catch {
                self?.queue.async { [weak self] in
                    self?.failure = error
                    self?.finished = true
                    self?.processPendingRequests()
                }
            }
        }
    }

    deinit { consumeTask?.cancel() }

    func cancel() {
        consumeTask?.cancel()
        queue.async { [weak self] in
            guard let self, !finished else { return }
            failure = CancellationError()
            finished = true
            processPendingRequests()
        }
    }

    func install(on asset: AVURLAsset) {
        asset.resourceLoader.setDelegate(self, queue: queue)
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        pending.append(loadingRequest)
        processPendingRequests()
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        pending.removeAll { $0 === loadingRequest }
    }

    private func processPendingRequests() {
        pending.removeAll { request in
            if let info = request.contentInformationRequest {
                info.contentType = contentType.flatMap { UTType(mimeType: $0)?.identifier }
                info.contentLength = expectedLength
                info.isByteRangeAccessSupported = false
            }
            if let failure {
                request.finishLoading(with: failure)
                return true
            }
            guard let dataRequest = request.dataRequest else {
                if finished { request.finishLoading(); return true }
                return false
            }
            let offset = max(Int(dataRequest.currentOffset), Int(dataRequest.requestedOffset))
            if offset < data.count {
                let requestedEnd = Int(dataRequest.requestedOffset) + dataRequest.requestedLength
                let end = min(data.count, requestedEnd)
                if end > offset { dataRequest.respond(with: data.subdata(in: offset..<end)) }
            }
            let deliveredEnd = max(Int(dataRequest.currentOffset), Int(dataRequest.requestedOffset))
            let requestedEnd = Int(dataRequest.requestedOffset) + dataRequest.requestedLength
            if deliveredEnd >= requestedEnd || finished {
                request.finishLoading()
                return true
            }
            return false
        }
    }
}

@MainActor
final class ReaderSpeechController: NSObject, ObservableObject, @preconcurrency AVSpeechSynthesizerDelegate, @preconcurrency AVAudioPlayerDelegate {
    @Published private(set) var isSpeaking = false
    @Published private(set) var isPaused = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var completionCount = 0
    @Published private(set) var currentSegmentIndex = 0
    private let synthesizer = AVSpeechSynthesizer()
    private let httpService = HttpTTSService()
    private var audioPlayer: AVAudioPlayer?
    private var streamPlayer: AVPlayer?
    private var streamLoader: IncrementalAudioResourceLoader?
    private var streamCompletionToken: NSObjectProtocol?
    private var httpTask: Task<Void, Never>?
    private var httpPrefetchTasks: [Task<Void, Never>] = []
    private var httpSegments: [String] = []
    private var httpSegmentIndex = 0
    private var httpEngine: HttpTTS?
    private var systemSegments: [String] = []
    private var systemSegmentIndex = 0
    private var segmentIndexOffset = 0
    private var followsSystemRate = true
    private var speechRate = 5
    private var readByPage = false
    private var streamsHTTPAudio = true
    private var voiceIdentifier = ""
    private var continuesAcrossChapters = false
    private var notificationTokens: [NSObjectProtocol] = []
    nonisolated(unsafe) private var remoteCommandTargets: [(MPRemoteCommand, Any)] = []
    private var resumesAfterInterruption = false
    private var isChangingSystemSegment = false
    private var ignoresAudioFocus = false
    private var pausesForPhoneCalls = false
    private var mediaButtonPerNext = false
    private var bookName = ""
    private var chapterTitle = ""
    private var author = ""
    /// AI 多角色朗读：每个片段对应的段落序号（同一段被拆成旁白 / 对白多片时共用一个段落序号，用于跟读定位）。
    private var segmentParagraphs: [Int] = []
    /// AI 识别出的片段角色（键是片段序号）。
    private var segmentRoles: [Int: AIRoleAssignment] = [:]
    private var roleTask: Task<Void, Never>?
    private var roleSettings: AIRoleSpeechSettings?
    private var roleGeneration = 0
    /// 试听等场景关闭 AI 角色识别。
    var allowsRoleAnalysis = true
    /// 角色声音可选的在线朗读源（由阅读页传入）。
    var availableHTTPEngines: [HttpTTS] = []
    /// AI 角色识别的状态（识别中 / 失败原因），阅读设置里显示。
    @Published private(set) var roleStatus: String?
    var onNextChapter: (() -> Void)?
    var onPreviousChapter: (() -> Void)?
    var onRemoteStop: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
        observeAudioSession()
        installRemoteCommands()
    }

    deinit {
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        remoteCommandTargets.forEach { command, target in command.removeTarget(target) }
    }

    func toggle(text: String, continuesAcrossChapters: Bool = false) {
        if isSpeaking || isPaused {
            stop()
            return
        }
        speak(text, continuesAcrossChapters: continuesAcrossChapters)
    }

    func toggleHTTP(engine: HttpTTS, text: String, continuesAcrossChapters: Bool = false) {
        if isSpeaking || isPaused {
            stop()
            return
        }
        speakHTTP(engine: engine, text: text, continuesAcrossChapters: continuesAcrossChapters)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .word)
        audioPlayer?.stop()
        audioPlayer = nil
        streamPlayer?.pause()
        streamLoader?.cancel()
        streamPlayer = nil
        streamLoader = nil
        if let streamCompletionToken {
            NotificationCenter.default.removeObserver(streamCompletionToken)
            self.streamCompletionToken = nil
        }
        httpTask?.cancel()
        httpTask = nil
        httpPrefetchTasks.forEach { $0.cancel() }
        httpPrefetchTasks.removeAll()
        roleTask?.cancel()
        roleTask = nil
        roleGeneration += 1
        segmentRoles = [:]
        segmentParagraphs = []
        httpSegments = []
        httpSegmentIndex = 0
        httpEngine = nil
        systemSegments = []
        systemSegmentIndex = 0
        segmentIndexOffset = 0
        continuesAcrossChapters = false
        isSpeaking = false
        isPaused = false
        updateNowPlaying()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func configure(
        followsSystemRate: Bool,
        speechRate: Int,
        readByPage: Bool,
        streamsHTTPAudio: Bool = true,
        voiceIdentifier: String = "",
        ignoresAudioFocus: Bool = false,
        pausesForPhoneCalls: Bool = false,
        mediaButtonPerNext: Bool = false,
        bookName: String = "",
        chapterTitle: String = "",
        author: String = ""
    ) {
        self.followsSystemRate = followsSystemRate
        self.speechRate = min(max(speechRate, 0), 45)
        self.readByPage = readByPage
        self.streamsHTTPAudio = streamsHTTPAudio
        self.voiceIdentifier = voiceIdentifier
        self.ignoresAudioFocus = ignoresAudioFocus
        self.pausesForPhoneCalls = pausesForPhoneCalls
        self.mediaButtonPerNext = mediaButtonPerNext
        self.bookName = bookName
        self.chapterTitle = chapterTitle
        self.author = author
    }

    func speak(_ text: String, continuesAcrossChapters: Bool = false, segmentIndexOffset: Int = 0) {
        stop()
        errorMessage = nil
        activateAudioSession()
        self.continuesAcrossChapters = continuesAcrossChapters
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        systemSegments = prepareSegments(for: text)
        guard !systemSegments.isEmpty else { return }
        systemSegmentIndex = 0
        self.segmentIndexOffset = max(segmentIndexOffset, 0)
        startPlayback(segments: systemSegments) { controller in
            controller.playCurrentSystemSegment()
        }
    }

    func speakHTTP(
        engine: HttpTTS,
        text: String,
        continuesAcrossChapters: Bool = false,
        segmentIndexOffset: Int = 0
    ) {
        stop()
        errorMessage = nil
        activateAudioSession()
        self.continuesAcrossChapters = continuesAcrossChapters
        httpEngine = engine
        httpSegments = prepareSegments(for: text)
        guard !httpSegments.isEmpty else { return }
        httpSegmentIndex = 0
        self.segmentIndexOffset = max(segmentIndexOffset, 0)
        isSpeaking = true
        startPlayback(segments: httpSegments) { controller in
            controller.playCurrentHTTPSegment()
            controller.prefetchHTTPSegments(from: 1)
        }
    }

    func prefetchHTTP(engine: HttpTTS, text: String, limit: Int = 10) {
        // AI 多角色朗读开启时，下一章会按角色拆分、换声音，提前按整段预取没有意义。
        if allowsRoleAnalysis, AIRoleSpeechSettings.load().isActive { return }
        let values = Array(segments(for: text).prefix(max(limit, 0)))
        prefetchHTTP(engine: engine, texts: values)
    }

    func pauseOrResume(text: String, continuesAcrossChapters: Bool = false) {
        if isPaused {
            resumePlayback()
        } else if isSpeaking {
            pausePlayback()
        } else {
            speak(text, continuesAcrossChapters: continuesAcrossChapters)
        }
    }

    func pauseOrResumeHTTP(engine: HttpTTS, text: String, continuesAcrossChapters: Bool = false) {
        if audioPlayer != nil {
            pauseOrResume(text: text, continuesAcrossChapters: continuesAcrossChapters)
        } else if isSpeaking {
            httpTask?.cancel()
            isSpeaking = false
            isPaused = true
        } else if isPaused, httpEngine != nil {
            isPaused = false
            isSpeaking = true
            playCurrentHTTPSegment()
        } else {
            speakHTTP(engine: engine, text: text, continuesAcrossChapters: continuesAcrossChapters)
        }
    }

    private func segments(for text: String) -> [String] {
        let values = readByPage ? [text] : text.components(separatedBy: .newlines)
        return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// 拆分朗读片段：AI 多角色朗读开启时把每段的旁白和对白（引号内）拆成独立片段，分别配声音。
    private func prepareSegments(for text: String) -> [String] {
        let settings = allowsRoleAnalysis ? AIRoleSpeechSettings.load() : nil
        roleSettings = settings?.isActive == true ? settings : nil
        segmentRoles = [:]
        guard roleSettings != nil else {
            let values = segments(for: text)
            segmentParagraphs = Array(values.indices).map { readByPage ? 0 : $0 }
            return values
        }
        var texts: [String] = []
        var paragraphs: [Int] = []
        var paragraph = 0
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            for piece in AIRoleText.split(trimmed) {
                texts.append(piece)
                paragraphs.append(readByPage ? 0 : paragraph)
            }
            paragraph += 1
        }
        segmentParagraphs = paragraphs
        return texts
    }

    /// 片段序号 → 段落序号（跟读高亮 / 跳转用）。
    private func paragraphIndex(for segment: Int) -> Int {
        segmentParagraphs.indices.contains(segment) ? segmentParagraphs[segment] : segment
    }

    /// 开始播放：AI 多角色朗读开启时先识别第一批（较小，几秒内返回）再开口，其余批次在播放时并发识别。
    private func startPlayback(segments: [String], play: @escaping @MainActor @Sendable (ReaderSpeechController) -> Void) {
        guard let settings = roleSettings, let endpoint = settings.activeEndpoint else {
            play(self)
            return
        }
        isSpeaking = true
        let store = AIRoleSpeechStore.shared
        for (index, text) in segments.enumerated() {
            if let cached = store.cached(text) { segmentRoles[index] = cached }
        }
        let ranges = AIRoleAnalyzer.batches(
            for: segments,
            limit: endpoint.batchCharacters,
            firstLimit: min(endpoint.batchCharacters, 1_500),
            known: Set(segmentRoles.keys)
        )
        guard let first = ranges.first else {
            play(self)
            return
        }
        roleStatus = "AI 正在识别角色…"
        let analyzer = AIRoleAnalyzer(endpoint: endpoint, apiKey: AIRoleKeychain.key(for: endpoint.id))
        let generation = roleGeneration
        let concurrency = max(endpoint.concurrency, 1)
        roleTask = Task { [weak self] in
            var failure: String?
            do {
                let roles = try await analyzer.analyze(first, in: segments)
                self?.applyRoles(roles, segments: segments, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                failure = error.localizedDescription
            }
            guard let self, !Task.isCancelled, generation == self.roleGeneration else { return }
            self.roleStatus = failure.map { "角色识别失败，本段使用默认声音：\($0)" }
            // 识别期间被暂停（在线朗读）时不自动开口，继续播放时从当前片段开始。
            if self.isSpeaking { play(self) }
            await self.analyzeRemaining(Array(ranges.dropFirst()), segments: segments,
                                        analyzer: analyzer, concurrency: concurrency, generation: generation)
        }
    }

    private func analyzeRemaining(
        _ ranges: [ClosedRange<Int>],
        segments: [String],
        analyzer: AIRoleAnalyzer,
        concurrency: Int,
        generation: Int
    ) async {
        guard !ranges.isEmpty else { return }
        var pending = ranges[...]
        await withTaskGroup(of: [Int: AIRoleAssignment].self) { group in
            var started = 0
            while started < concurrency, let next = pending.popFirst() {
                group.addTask { (try? await analyzer.analyze(next, in: segments)) ?? [:] }
                started += 1
            }
            for await roles in group {
                let current = await self.roleGeneration
                if Task.isCancelled || generation != current {
                    group.cancelAll()
                    return
                }
                await self.applyRoles(roles, segments: segments, generation: generation)
                if let next = pending.popFirst() {
                    group.addTask { (try? await analyzer.analyze(next, in: segments)) ?? [:] }
                }
            }
        }
    }

    private func applyRoles(_ roles: [Int: AIRoleAssignment], segments: [String], generation: Int) {
        guard generation == roleGeneration, !roles.isEmpty else { return }
        var remembered: [String: AIRoleAssignment] = [:]
        for (index, role) in roles where segments.indices.contains(index) {
            segmentRoles[index] = role
            remembered[segments[index]] = role
        }
        AIRoleSpeechStore.shared.remember(remembered)
    }

    /// 系统语音：旁白用阅读设置里的声音；男 / 女角色用 AI 朗读页设置的声音（未设置时自动挑同性别的中文声音，
    /// 没有同性别声音时用音调区分）；同性别不同角色再按名字微调音调。
    private func systemVoice(for role: AIRoleAssignment?) -> (AVSpeechSynthesisVoice?, Float) {
        // 书架长按「角色配音」可以给这本书单独指定旁白声音。
        let bookVoice = AIRoleBookVoice.load(bookName: bookName)
        let base = AVSpeechSynthesisVoice(identifier: bookVoice.narratorVoiceID)
            ?? AVSpeechSynthesisVoice(identifier: voiceIdentifier)
            ?? AVSpeechSynthesisVoice(language: "zh-CN")
        guard let role, let settings = roleSettings, let kind = effectiveKind(role.kind, bookVoice: bookVoice),
              kind != .narrator else { return (base, 1) }
        let variation: Float = settings.variesCharacterPitch ? AIRoleText.pitchVariation(for: role.name) : 1
        switch kind {
        case .male:
            if let voice = AVSpeechSynthesisVoice(identifier: settings.maleVoiceID)
                ?? SpeechVoiceCatalog.automaticVoice(gender: .male, avoiding: base?.identifier) {
                return (voice, variation)
            }
            return (base, 0.82 * variation)
        case .female:
            if let voice = AVSpeechSynthesisVoice(identifier: settings.femaleVoiceID)
                ?? SpeechVoiceCatalog.automaticVoice(gender: .female, avoiding: base?.identifier) {
                return (voice, variation)
            }
            return (base, 1.18 * variation)
        default:
            return (base, variation)
        }
    }

    /// 未识别出性别的角色：按这本书「角色配音 → 未知角色」的设置跟随旁白或用男 / 女声。
    private func effectiveKind(_ kind: AIRoleKind, bookVoice: AIRoleBookVoice) -> AIRoleKind? {
        guard kind == .unknown else { return kind }
        switch bookVoice.unknownMode {
        case "male": return .male
        case "female": return .female
        default: return .narrator
        }
    }

    /// 在线朗读：男 / 女角色可以各用一个朗读源（AI 朗读页设置），未设置时用默认朗读源。
    private func roleEngine(for index: Int) -> HttpTTS? {
        guard let settings = roleSettings, let role = segmentRoles[index],
              let kind = effectiveKind(role.kind, bookVoice: AIRoleBookVoice.load(bookName: bookName)) else { return nil }
        let id: String
        switch kind {
        case .male: id = settings.maleEngineID
        case .female: id = settings.femaleEngineID
        default: return nil
        }
        guard !id.isEmpty else { return nil }
        return availableHTTPEngines.first { String($0.id) == id }
    }

    private func prefetchHTTPSegments(from start: Int) {
        guard let engine = httpEngine, start < httpSegments.count else { return }
        let items: [(HttpTTS, String)] = (start..<httpSegments.count).map { (roleEngine(for: $0) ?? engine, httpSegments[$0]) }
        let rate = speechRate + 5
        let task = Task { [weak self] in
            guard let self else { return }
            for (engine, text) in items {
                guard !Task.isCancelled else { return }
                _ = try? await self.httpService.audio(engine: engine, text: text, speechRate: rate)
            }
        }
        httpPrefetchTasks.append(task)
    }

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: ignoresAudioFocus ? [.mixWithOthers] : [])
        try? session.setActive(true)
    }

    private func pausePlayback() {
        if let audioPlayer, audioPlayer.isPlaying {
            audioPlayer.pause()
        } else if let streamPlayer {
            streamPlayer.pause()
        } else if synthesizer.isSpeaking {
            synthesizer.pauseSpeaking(at: .word)
        } else if httpTask != nil {
            httpTask?.cancel()
            httpTask = nil
        } else {
            return
        }
        isPaused = true
        isSpeaking = false
        updateNowPlaying()
    }

    private func resumePlayback() {
        activateAudioSession()
        if let audioPlayer {
            isSpeaking = audioPlayer.play()
        } else if let streamPlayer {
            streamPlayer.play()
            isSpeaking = true
        } else if synthesizer.isPaused {
            synthesizer.continueSpeaking()
            isSpeaking = true
        } else if httpEngine != nil, httpSegments.indices.contains(httpSegmentIndex) {
            isSpeaking = true
            playCurrentHTTPSegment()
        } else {
            return
        }
        isPaused = false
        updateNowPlaying()
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in self?.handleAudioInterruption(type: type, options: options) }
        })
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in self?.handleRouteChange(reason: reason) }
        })
    }

    private func handleAudioInterruption(type raw: UInt?, options rawOptions: UInt) {
        guard let raw,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            if ignoresAudioFocus && !pausesForPhoneCalls { return }
            resumesAfterInterruption = isSpeaking
            if isSpeaking { pausePlayback() }
        case .ended:
            if ignoresAudioFocus && !pausesForPhoneCalls { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            if resumesAfterInterruption, options.contains(.shouldResume) { resumePlayback() }
            resumesAfterInterruption = false
        @unknown default:
            break
        }
    }

    private func handleRouteChange(reason raw: UInt?) {
        guard let raw,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
        if isSpeaking { pausePlayback() }
    }

    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.stopCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        addRemoteTarget(center.playCommand) { $0.resumePlayback() }
        addRemoteTarget(center.pauseCommand) { $0.pausePlayback() }
        addRemoteTarget(center.togglePlayPauseCommand) { controller in
            controller.isPaused ? controller.resumePlayback() : controller.pausePlayback()
        }
        addRemoteTarget(center.stopCommand) { controller in
            controller.stop()
            controller.onRemoteStop?()
        }
        addRemoteTarget(center.nextTrackCommand) { $0.skipForward(usesChapterPreference: true) }
        addRemoteTarget(center.previousTrackCommand) { $0.skipBackward(usesChapterPreference: true) }
    }

    private func addRemoteTarget(_ command: MPRemoteCommand, action: @escaping @MainActor (ReaderSpeechController) -> Void) {
        let target = command.addTarget { [weak self] _ in
            guard self != nil else { return .noSuchContent }
            Task { @MainActor [weak self] in
                guard let self else { return }
                action(self)
            }
            return .success
        }
        remoteCommandTargets.append((command, target))
    }

    func nextSegment() {
        guard isSpeaking || isPaused else { return }
        skipForward(usesChapterPreference: false)
    }

    func previousSegment() {
        guard isSpeaking || isPaused else { return }
        skipBackward(usesChapterPreference: false)
    }

    private func playCurrentSystemSegment() {
        guard systemSegments.indices.contains(systemSegmentIndex) else {
            finishNaturally()
            return
        }
        let utterance = AVSpeechUtterance(string: systemSegments[systemSegmentIndex])
        let (voice, pitch) = systemVoice(for: segmentRoles[systemSegmentIndex])
        utterance.voice = voice
        let multiplier = followsSystemRate ? 1 : Float(speechRate + 5) / 10
        utterance.rate = min(
            max(AVSpeechUtteranceDefaultSpeechRate * multiplier, AVSpeechUtteranceMinimumSpeechRate),
            AVSpeechUtteranceMaximumSpeechRate
        )
        utterance.pitchMultiplier = min(max(pitch, 0.5), 2)
        synthesizer.speak(utterance)
        currentSegmentIndex = segmentIndexOffset + paragraphIndex(for: systemSegmentIndex)
        isSpeaking = true
        isPaused = false
        updateNowPlaying()
    }

    private func skipForward(usesChapterPreference: Bool) {
        if usesChapterPreference && mediaButtonPerNext {
            onNextChapter?()
        } else if httpEngine != nil, httpSegmentIndex + 1 < httpSegments.count {
            stopCurrentHTTPPlayback()
            httpSegmentIndex += 1
            playCurrentHTTPSegment()
        } else if !systemSegments.isEmpty, systemSegmentIndex + 1 < systemSegments.count {
            changeSystemSegment(to: systemSegmentIndex + 1)
        } else {
            onNextChapter?()
        }
    }

    private func skipBackward(usesChapterPreference: Bool) {
        if usesChapterPreference && mediaButtonPerNext {
            onPreviousChapter?()
        } else if httpEngine != nil, httpSegmentIndex > 0 {
            stopCurrentHTTPPlayback()
            httpSegmentIndex -= 1
            playCurrentHTTPSegment()
        } else if !systemSegments.isEmpty, systemSegmentIndex > 0 {
            changeSystemSegment(to: systemSegmentIndex - 1)
        } else {
            onPreviousChapter?()
        }
    }

    private func stopCurrentHTTPPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        streamPlayer?.pause()
        streamLoader?.cancel()
        streamPlayer = nil
        streamLoader = nil
        if let streamCompletionToken {
            NotificationCenter.default.removeObserver(streamCompletionToken)
            self.streamCompletionToken = nil
        }
        httpTask?.cancel()
        httpTask = nil
    }

    private func changeSystemSegment(to index: Int) {
        isChangingSystemSegment = true
        synthesizer.stopSpeaking(at: .immediate)
        systemSegmentIndex = index
        playCurrentSystemSegment()
        DispatchQueue.main.async { [weak self] in self?.isChangingSystemSegment = false }
    }

    private func updateNowPlaying() {
        guard isSpeaking || isPaused else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: chapterTitle,
            MPMediaItemPropertyAlbumTitle: bookName,
            MPMediaItemPropertyArtist: author,
            MPNowPlayingInfoPropertyPlaybackRate: isSpeaking ? 1 : 0
        ]
    }

    private func playCurrentHTTPSegment() {
        guard let defaultEngine = httpEngine, httpSegments.indices.contains(httpSegmentIndex) else {
            stop()
            return
        }
        let engine = roleEngine(for: httpSegmentIndex) ?? defaultEngine
        let text = httpSegments[httpSegmentIndex]
        currentSegmentIndex = segmentIndexOffset + paragraphIndex(for: httpSegmentIndex)
        let rate = speechRate + 5
        httpTask?.cancel()
        httpTask = Task { [weak self] in
            guard let self else { return }
            do {
                if streamsHTTPAudio {
                    let stream = try await httpService.audioStream(engine: engine, text: text, speechRate: rate)
                    try Task.checkCancellation()
                    if stream.isIncremental, stream.expectedContentLength ?? 0 > 0 {
                        playIncrementalHTTPStream(stream)
                    } else {
                        var data = Data()
                        for try await chunk in stream.chunks { data.append(chunk) }
                        try Task.checkCancellation()
                        try playBufferedHTTPAudio(data)
                    }
                } else {
                    let audio = try await httpService.audio(engine: engine, text: text, speechRate: rate)
                    try Task.checkCancellation()
                    try playBufferedHTTPAudio(audio.data)
                }
                isPaused = false
                updateNowPlaying()
                if !isSpeaking { throw CocoaError(.fileReadCorruptFile) }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
                stop()
            }
        }
    }

    private func playBufferedHTTPAudio(_ data: Data) throws {
        let player = try AVAudioPlayer(data: data)
        player.delegate = self
        player.prepareToPlay()
        audioPlayer = player
        isSpeaking = player.play()
    }

    private func playIncrementalHTTPStream(_ stream: HttpTTSAudioStream) {
        let url = URL(string: "legado-tts-stream://audio/\(UUID().uuidString)")!
        let asset = AVURLAsset(url: url)
        let loader = IncrementalAudioResourceLoader(stream: stream)
        loader.install(on: asset)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        streamLoader = loader
        streamPlayer = player
        streamCompletionToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.incrementalPlayerDidFinish() }
        }
        player.play()
        isSpeaking = true
    }

    private func incrementalPlayerDidFinish() {
        stopCurrentHTTPPlayback()
        httpSegmentIndex += 1
        if httpSegmentIndex < httpSegments.count { playCurrentHTTPSegment() }
        else { finishNaturally() }
    }

    private func prefetchHTTP(engine: HttpTTS, texts: [String]) {
        guard !texts.isEmpty else { return }
        let rate = speechRate + 5
        let task = Task { [weak self] in
            guard let self else { return }
            for text in texts {
                guard !Task.isCancelled else { return }
                _ = try? await self.httpService.audio(engine: engine, text: text, speechRate: rate)
            }
        }
        httpPrefetchTasks.append(task)
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        audioPlayer = nil
        guard flag else {
            errorMessage = "HTTP TTS 音频播放失败"
            stop()
            return
        }
        httpSegmentIndex += 1
        if httpSegmentIndex < httpSegments.count {
            playCurrentHTTPSegment()
        } else {
            finishNaturally()
        }
    }

    private func finishNaturally() {
        let shouldContinue = continuesAcrossChapters
        stop()
        if shouldContinue { completionCount += 1 }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard !isChangingSystemSegment else { return }
        systemSegmentIndex += 1
        if systemSegmentIndex < systemSegments.count { playCurrentSystemSegment() }
        else { finishNaturally() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        guard !isChangingSystemSegment else { return }
        guard !synthesizer.isSpeaking else { return }
        isSpeaking = false
        isPaused = false
        updateNowPlaying()
    }
}
