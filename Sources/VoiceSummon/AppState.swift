import AppKit
import AVFoundation
import Foundation
import Speech
import UserNotifications

struct HitRecord: Identifiable, Equatable {
    let id: UUID
    let keyword: String
    let text: String
    let date: Date
    let matchWay: String
    var clipURL: URL?
    var delivered: [String] = []
    var errors: [String] = []
    var status: String = "裁剪录音中…"
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var config: AppConfig {
        didSet {
            guard !suppressConfigSideEffects else { return }
            ConfigStore.save(config)
            rebuildMatcher()
            syncRuntimeConfig()
        }
    }

    @Published private(set) var isRunning = false
    @Published private(set) var level: Float = 0
    @Published private(set) var gainFactor: Float = 1
    @Published private(set) var liveText = ""
    @Published private(set) var status = "待启动"
    @Published private(set) var sessionState = ""
    @Published private(set) var permissionSummary = "检查权限中…"
    @Published private(set) var menuSymbol = "waveform.slash"
    @Published private(set) var hits: [HitRecord] = []
    @Published private(set) var lastError: String?
    @Published private(set) var engineInfo = ""
    @Published private(set) var notificationStatus = "通知 ?"

    let audio = AudioHub()
    private let transcriber = Transcriber()
    private var matcher: KeywordMatcher
    private var lastHitAt: Date?
    private var lastTranscriptLength = 0
    private var sleepActivity: NSObjectProtocol?
    private var appliedRuntimeSignature = ""
    private var suppressConfigSideEffects = false
    private var flashTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?

    private init() {
        var loaded = ConfigStore.load()
        // 老配置里的上传端点升级：把自建的插到最前面，免得还在踩公网图床的 412
        let builtinEndpoint = "https://notify.v2.wobuqu.icu/vs-audio/upload"
        if !loaded.audioUpload.targets.contains(where: { $0.url.contains("notify.v2.wobuqu.icu") }) {
            loaded.audioUpload.targets.insert(
                AudioUploader.Target(url: builtinEndpoint, field: "file", extra: [:]),
                at: 0
            )
            ConfigStore.save(loaded)
            Log.info("上传端点已升级为自建优先")
        }
        config = loaded
        matcher = KeywordMatcher(keywords: loaded.keywords, level: loaded.matchLevel)
        wireAudio()
    }

    // MARK: - 启动

    func bootstrap() {
        Log.info("VoiceSummon 启动 v1.0，配置目录 \(Paths.support.path)")
        if !FileManager.default.fileExists(atPath: Paths.configFile.path) {
            ConfigStore.save(config)
            Log.info("首次启动，已写入默认配置")
        } else {
            // 老配置补齐新字段（远场增强之类的），省得界面上显示 undefined
            ConfigStore.save(config)
        }
        refreshPermissions()
        refreshNotificationPermission()
        let authorized = Transcriber.microphoneAuthorized && Transcriber.speechAuthorized
        if !authorized { status = "等待系统授权弹窗…" }
        Task {
            if !authorized {
                // 弹窗照弹，但不等回调——用户去系统设置里手动勾选也能被轮询接住。
                Task { _ = await Transcriber.requestPermissions() }
                let granted = await waitForPermissions()
                refreshPermissions()
                Log.info("权限轮询结果：\(granted)")
                guard granted else {
                    status = "缺少麦克风/语音识别权限，去系统设置里打开"
                    return
                }
            }
            await Notifier.requestLocalAuthorization()
            refreshNotificationPermission()
            ClipExporter.cleanup(keepDays: config.keepDays)
            if config.autoStart { start() }
        }
    }

    /// 等用户授权：不管是点系统弹窗，还是去设置里手动勾。
    private func waitForPermissions(timeout: TimeInterval = 900) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Transcriber.microphoneAuthorized, Transcriber.speechAuthorized {
                return true
            }
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
        return false
    }

    func refreshPermissions() {
        let mic = Transcriber.microphoneAuthorized ? "麦克风 ✓" : "麦克风 ✗"
        let speech = Transcriber.speechAuthorized ? "语音识别 ✓" : "语音识别 ✗"
        permissionSummary = "\(mic) · \(speech) · \(notificationStatus)"
    }

    private func refreshNotificationPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let text: String
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: text = "通知 ✓"
            case .denied: text = "通知 ✗"
            case .notDetermined: text = "通知 ?"
            @unknown default: text = "通知 ?"
            }
            Task { @MainActor in
                self?.notificationStatus = text
                self?.refreshPermissions()
            }
        }
    }

    // MARK: - 监听开关

    func toggle() {
        isRunning ? stop() : start()
    }

    func start() {
        guard !isRunning else { return }
        guard !matcher.isEmpty else {
            status = "先添加至少一个关键词"
            return
        }
        if !Transcriber.microphoneAuthorized || !Transcriber.speechAuthorized {
            let wakeUpNeeded = AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
                || SFSpeechRecognizer.authorizationStatus() == .notDetermined
            if wakeUpNeeded {
                status = "等系统弹窗授权…"
                Task {
                    Task { _ = await Transcriber.requestPermissions() }
                    let granted = await waitForPermissions()
                    refreshPermissions()
                    if granted { start() }
                }
            } else {
                status = "权限没给全，先去系统设置授权"
                refreshPermissions()
            }
            return
        }

        do {
            audio.farFieldBoost = config.farFieldBoost
            audio.maxBoostDB = config.maxBoostDB
            try audio.start(historySeconds: config.requiredHistorySeconds,
                            deviceUID: config.inputDeviceUID.isEmpty ? nil : config.inputDeviceUID)
        } catch {
            lastError = error.localizedDescription
            status = "音频启动失败：\(error.localizedDescription)"
            Log.error("音频启动失败：\(error.localizedDescription)")
            return
        }

        guard transcriber.start(options: .init(
            localeID: config.localeID,
            onDevice: config.onDeviceRecognition,
            contextualStrings: config.keywords
        )) else {
            audio.stop()
            engineInfo = transcriber.availability
            status = "识别器没起来：\(lastError ?? "看日志")"
            updateMenuSymbol()
            return
        }

        appliedRuntimeSignature = runtimeSignature()
        lastTranscriptLength = 0
        engineInfo = transcriber.availability
        isRunning = true
        lastError = nil
        status = "正在监听"
        updateMenuSymbol()
        keepAwakeIfNeeded()
        Log.info("开始监听，关键词 \(config.keywords.joined(separator: "/"))")
    }

    func stop() {
        transcriber.stop()
        // 注意：不要清 audio.onBuffer，sink 在 request 为 nil 时会自己丢弃，清掉会导致下次启动收不到音频。
        audio.stop()
        isRunning = false
        level = 0
        sessionState = ""
        status = "已暂停"
        updateMenuSymbol()
        allowSleep()
        Log.info("停止监听")
    }

    private func wireAudio() {
        // 音频线程回调：只捕获 Sendable 的 sink，不碰主线程状态。
        audio.onBuffer = { [sink = transcriber.sink] buffer in
            sink.feed(buffer)
        }
        audio.onLevel = { [weak self] value in
            Task { @MainActor in
                guard let self else { return }
                self.level = value
                self.gainFactor = self.audio.enhancerGain
            }
        }
        transcriber.onTranscript = { [weak self] text in
            self?.handleTranscript(text)
        }
        transcriber.onSessionState = { [weak self] state in
            self?.sessionState = state
        }
        transcriber.onError = { [weak self] message in
            guard let self else { return }
            self.lastError = message
            if !self.isRunning { self.status = message }
        }
    }

    private func updateMenuSymbol() {
        menuSymbol = isRunning ? "waveform" : "waveform.slash"
    }

    // MARK: - 配置

    private func rebuildMatcher() {
        matcher = KeywordMatcher(keywords: config.keywords, level: config.matchLevel)
    }

    private func runtimeSignature() -> String {
        "\(config.preRoll)|\(config.postRoll)|\(config.localeID)|\(config.onDeviceRecognition)|\(config.inputDeviceUID)|\(config.farFieldBoost)|\(config.maxBoostDB)"
    }

    private func syncRuntimeConfig() {
        guard isRunning, runtimeSignature() != appliedRuntimeSignature else { return }
        // 拖滑块会连着改好几次，防抖一下别让采集链路来回抖动。
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self, !Task.isCancelled, self.isRunning else { return }
            guard self.runtimeSignature() != self.appliedRuntimeSignature else { return }
            Log.info("音频/识别参数变化，重启监听链路")
            self.stop()
            self.start()
        }
    }

    func addKeyword(_ raw: String) {
        let keyword = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty, !config.keywords.contains(keyword) else { return }
        config.keywords.append(keyword)
    }

    func removeKeyword(_ keyword: String) {
        config.keywords.removeAll { $0 == keyword }
    }

    func addChannel(_ kind: Channel.Kind) {
        config.channels.append(Channel(kind: kind))
    }

    func removeChannel(_ id: UUID) {
        config.channels.removeAll { $0.id == id }
    }

    // MARK: - 命中

    private func handleTranscript(_ text: String) {
        // 界面只显示最近一段，别让人看到一堆旧内容。
        liveText = String(text.suffix(80))
        guard isRunning else { return }

        let length = text.count
        if length + 20 < lastTranscriptLength {
            // 识别会话滚动，文本从头开始
            lastTranscriptLength = 0
        } else if length < lastTranscriptLength {
            // 识别器修正了前文，长度小幅回退，不算新内容
            lastTranscriptLength = length
            return
        }
        guard length > lastTranscriptLength else { return }

        // 只在「这次新增的部分」里找关键词，前面留 12 字重叠，防止词被切在两次结果之间。
        let newCharacters = length - lastTranscriptLength
        let fresh = String(text.suffix(newCharacters + 12))
        lastTranscriptLength = length

        guard let hit = matcher.match(in: fresh, tailLength: 200) else { return }

        let now = Date()
        if let last = lastHitAt, now.timeIntervalSince(last) < config.cooldown { return }
        lastHitAt = now
        trigger(hit: hit, text: String(text.suffix(120)), at: now, frame: audio.currentFrame)
    }

    private func trigger(hit: KeywordMatcher.Hit, text: String, at date: Date, frame: AVAudioFramePosition) {
        let record = HitRecord(
            id: UUID(),
            keyword: hit.keyword,
            text: String(text.suffix(400)),
            date: date,
            matchWay: hit.way.label
        )
        hits.insert(record, at: 0)
        if hits.count > 40 { hits.removeLast(hits.count - 40) }

        status = "命中「\(hit.keyword)」，\(Int(config.postRoll)) 秒后取录音"
        Log.info("命中关键词「\(hit.keyword)」（\(hit.way.label)）")
        if config.playSoundOnHit {
            NSSound(named: "Glass")?.play()
        }
        flashMenuIcon()

        // 先推文字：不带音频、也不需要链接的渠道。
        let instantChannels = config.channels.filter { isInstantChannel($0) }
        if !instantChannels.isEmpty {
            let payload = NotificationPayload(
                keyword: hit.keyword,
                text: String(text.suffix(200)),
                date: date,
                clipURL: nil,
                clipSeconds: 0,
                matchWay: hit.way.label
            )
            Task { [weak self] in
                let result = await Notifier.broadcast(payload, channels: instantChannels)
                guard let self else { return }
                self.updateHit(record.id) { item in
                    item.delivered.append(contentsOf: result.delivered)
                    item.errors.append(contentsOf: result.errors)
                    item.status = result.errors.isEmpty ? "文字已推送，录音随后" : "文字推送失败"
                }
            }
        }

        let preRoll = config.preRoll
        let postRoll = config.postRoll
        Task { [weak self] in
            guard let self else { return }
            // 等「命中之后的那一段」录完再切片；0.5 秒是调度余量。
            try? await Task.sleep(nanoseconds: UInt64((postRoll + 0.5) * 1_000_000_000))
            await self.finishHit(record.id, frame: frame, preRoll: preRoll, postRoll: postRoll)
        }
    }

    private func finishHit(_ id: UUID, frame: AVAudioFramePosition, preRoll: Double, postRoll: Double) async {
        guard let format = audio.format else {
            updateHit(id) { $0.status = "监听已停止，录音没取到" }
            return
        }

        let sampleRate = format.sampleRate
        let start = frame - AVAudioFramePosition(preRoll * sampleRate)
        let end = frame + AVAudioFramePosition(postRoll * sampleRate)

        guard let buffer = audio.extract(from: start, to: end) else {
            updateHit(id) { $0.status = "缓冲里没有这段音频" }
            status = "录音裁切失败"
            return
        }

        let record = hits.first { $0.id == id }
        var clipURL: URL?
        do {
            clipURL = try ClipExporter.save(
                buffer,
                keyword: record?.keyword ?? "hit",
                date: record?.date ?? Date(),
                format: config.clipFormat
            )
            Log.info("录音已保存：\(clipURL?.lastPathComponent ?? "-")")
        } catch {
            Log.error("录音保存失败：\(error.localizedDescription)")
            updateHit(id) { $0.status = "录音保存失败：\(error.localizedDescription)" }
        }

        // 需要链接的渠道（Server 酱）在这里才等到链接
        var clipLink: URL?
        if config.audioUpload.enabled, let clipURL {
            do {
                clipLink = try await AudioUploader.upload(clipURL, config: config.audioUpload)
                Log.info("录音已传公网：\(clipLink?.absoluteString ?? "-")")
            } catch {
                Log.error("录音上传失败：\(error.localizedDescription)")
                updateHit(id) { $0.errors.append("录音外链：\(error.localizedDescription)") }
            }
        }

        let payload = NotificationPayload(
            keyword: record?.keyword ?? "关键词",
            text: record?.text ?? "",
            date: record?.date ?? Date(),
            clipURL: clipURL,
            clipSeconds: preRoll + postRoll,
            matchWay: record?.matchWay ?? "原文",
            clipLink: clipLink
        )

        // 只把「要等录音/链接」的渠道留到这一步，纯文字渠道刚命中时已经推过了。
        let audioChannels = config.channels.filter { $0.enabled && !isInstantChannel($0) }

        if audioChannels.isEmpty {
            updateHit(id) { item in
                item.clipURL = clipURL
                let unique = item.delivered.reduce(into: [String]()) { list, name in
                    if !list.contains(name) { list.append(name) }
                }
                item.status = unique.isEmpty ? "录音已存，没有可推送的渠道" : "已推送 \(unique.joined(separator: "、"))，录音已存"
            }
            status = "已通知"
            updateMenuSymbol()
            return
        }

        let result = await Notifier.broadcast(payload, channels: audioChannels)
        updateHit(id) {
            $0.clipURL = clipURL
            $0.delivered.append(contentsOf: result.delivered)
            $0.errors.append(contentsOf: result.errors)

            let unique = $0.delivered.reduce(into: [String]()) { list, name in
                if !list.contains(name) { list.append(name) }
            }
            if $0.errors.isEmpty {
                $0.status = "已通知 \(unique.joined(separator: "、"))"
            } else if unique.isEmpty {
                $0.status = "通知失败：\($0.errors.joined(separator: "；"))"
            } else {
                $0.status = "部分成功：\(unique.joined(separator: "、"))；失败 \($0.errors.joined(separator: "；"))"
            }
        }
        status = result.errors.isEmpty ? "已通知" : "通知有失败，看记录"
        updateMenuSymbol()
    }

    /// 命中就能发的渠道：不带附件、也不需要外链。
    private func isInstantChannel(_ channel: Channel) -> Bool {
        guard channel.enabled else { return false }
        if channel.kind.supportsAudio { return false }
        // Server 酱 配了外链就要等链接，否则先发文字
        if channel.kind == .serverChan, config.audioUpload.enabled { return false }
        return true
    }

    private func updateHit(_ id: UUID, _ body: (inout HitRecord) -> Void) {
        guard let index = hits.firstIndex(where: { $0.id == id }) else { return }
        body(&hits[index])
    }

    private func flashMenuIcon() {
        flashTask?.cancel()
        menuSymbol = "bell.badge.fill"
        flashTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.updateMenuSymbol()
        }
    }

    // MARK: - 其它

    func sendTestNotification() async -> String {
        let url = makeTestClip()
        let payload = NotificationPayload(
            keyword: config.keywords.first ?? "测试",
            text: "这是一条测试通知，链路通了。",
            date: Date(),
            clipURL: url,
            clipSeconds: 3,
            matchWay: "原文"
        )
        let result = await Notifier.broadcast(payload, channels: config.channels)
        if result.errors.isEmpty {
            return "已发送：\(result.delivered.joined(separator: "、"))"
        }
        return "失败：\(result.errors.joined(separator: "；"))"
    }

    /// 生成 3 秒提示音，用来验证渠道是否能收到音频。
    private func makeTestClip() -> URL? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: ClipExporter.targetFormat, frameCapacity: 48_000) else {
            return nil
        }
        buffer.frameLength = 48_000
        if let channel = buffer.floatChannelData?[0] {
            for index in 0..<48_000 {
                let t = Double(index) / 16_000.0
                channel[index] = Float(sin(2 * .pi * 660 * t) * 0.2)
            }
        }
        return try? ClipExporter.save(buffer, keyword: "test", date: Date(), format: config.clipFormat)
    }

    /// 录 4 秒做一次完整识别，用来确认「语音识别」这条路通不通。
    func runRecognitionProbe() async -> String {
        guard isRunning else { return "先点「开始监听」，再自检" }
        guard let format = audio.format, format.sampleRate > 0 else { return "当前没有音频输入" }
        let sampleRate = format.sampleRate
        if audio.currentFrame < AVAudioFramePosition(sampleRate * 2) {
            return "刚启动，等两秒再点"
        }

        let anchor = audio.currentFrame
        try? await Task.sleep(nanoseconds: 4_000_000_000)

        guard let buffer = audio.extract(from: anchor - AVAudioFramePosition(sampleRate * 4),
                                         to: anchor) else {
            return "没取到刚才那 4 秒音频"
        }
        guard let url = try? ClipExporter.save(buffer, keyword: "probe", date: Date(), format: .wav) else {
            return "录音保存失败"
        }

        do {
            let text = try await Transcriber.probe(fileURL: url, localeID: config.localeID)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "识别成功，但没听到字（刚才可能没人说话）" : "识别到：\(trimmed)"
        } catch {
            Log.error("识别自检失败：\(error.localizedDescription)")
            return "识别失败：\(error.localizedDescription)"
        }
    }

    func openClipsFolder() {
        NSWorkspace.shared.open(Paths.clipsDir)
    }

    func copyDiagnostics() {
        let text = """
        VoiceSummon 诊断 \(AppVersion.diagnostic)
        \(permissionSummary)
        状态：\(status) / \(sessionState)
        缓冲：\(String(format: "%.1f", audio.bufferedSeconds))s
        最近日志：
        \(Log.recentText)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func keepAwakeIfNeeded() {
        guard config.preventSleep, sleepActivity == nil else { return }
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: .idleSystemSleepDisabled,
            reason: "VoiceSummon 正在监听关键词"
        )
        Log.info("已阻止系统休眠")
    }

    private func allowSleep() {
        if let token = sleepActivity {
            ProcessInfo.processInfo.endActivity(token)
            sleepActivity = nil
            Log.info("恢复系统休眠")
        }
    }
}
