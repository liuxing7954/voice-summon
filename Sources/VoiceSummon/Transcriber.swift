import AVFoundation
import Foundation
import Speech

/// request 要在音频线程 append、在主线程换 session，这里做一次同步封装。
private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func current() -> SFSpeechAudioBufferRecognitionRequest? {
        lock.lock()
        defer { lock.unlock() }
        return request
    }

    func set(_ newValue: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        request = newValue
        lock.unlock()
    }
}

/// 传给音频线程的唯一对象：Sendable，只做 append，不读主线程状态。
final class AudioSink: @unchecked Sendable {
    fileprivate let box = RequestBox()

    func feed(_ buffer: AVAudioPCMBuffer) {
        box.current()?.append(buffer)
    }
}

/// 连续语音识别。
///
/// 系统识别服务单个会话有 1 分钟上限，所以这里做「滚动会话」：
/// 每 50 秒无缝换一个新 request，历史文本串起来供关键词匹配使用。
@MainActor
final class Transcriber {
    struct Options: Equatable {
        var localeID: String = "zh-CN"
        var onDevice: Bool = false
        var sessionSeconds: TimeInterval = 50
        /// 把这些词告诉识别器，人名/专有名词的识别率会明显提高。
        var contextualStrings: [String] = []
    }

    /// 识别文本（含最近的历史上下文），每次更新回调。
    var onTranscript: ((String) -> Void)?
    /// 致命/可恢复错误提示。
    var onError: ((String) -> Void)?
    /// 会话状态变化，用于界面显示。
    var onSessionState: ((String) -> Void)?

    /// 音频线程用的入口。
    let sink = AudioSink()
    private var box: RequestBox { sink.box }
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private var ticker: Timer?
    private var options = Options()
    private var running = false

    private var sessionStartedAt = Date.distantPast
    private var lastSessionEnd = Date.distantPast
    private var liveText = ""
    private var failures = 0
    private var lastFailureAt = Date.distantPast

    var currentText: String { liveText }

    /// 给界面看的可用性描述。
    private(set) var availability = "未知"
    private(set) var onDeviceReady = false

    // MARK: - 权限

    static var microphoneAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static var speechAuthorized: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    static func requestPermissions() async -> (mic: Bool, speech: Bool) {
        let mic = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        let speech = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        return (mic, speech)
    }

    // MARK: - 生命周期

    /// 返回 false 表示识别器没起来（语言不支持 / 服务不可用）。
    @discardableResult
    func start(options: Options) -> Bool {
        stop()
        self.options = options

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: options.localeID)) else {
            availability = "语言不支持"
            onError?("系统不支持语言 \(options.localeID)，请换一个（如 zh-CN / en-US）")
            return false
        }
        guard recognizer.isAvailable else {
            availability = "服务不可用"
            onError?("语音识别服务当前不可用（系统未就绪或未联网）")
            return false
        }
        self.recognizer = recognizer
        onDeviceReady = recognizer.supportsOnDeviceRecognition
        availability = onDeviceReady ? "本机识别可用" : "云端识别（本机语音包未安装）"
        if options.onDevice, !onDeviceReady {
            onError?("系统没有装 \(options.localeID) 的本机语音包，已自动回退云端识别")
        }
        running = true
        failures = 0
        liveText = ""

        openSession()

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
        Log.info("识别器启动：\(options.localeID)，本机识别=\(options.onDevice)")
        return true
    }

    func stop() {
        running = false
        ticker?.invalidate()
        ticker = nil

        box.set(nil)
        task?.cancel()
        task = nil
        recognizer = nil
        liveText = ""
        onSessionState?("已停止")
    }


    // MARK: - 会话

    private func openSession() {
        guard running, let recognizer else { return }

        box.set(nil)
        task?.cancel()
        task = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if !options.contextualStrings.isEmpty {
            request.contextualStrings = options.contextualStrings
        }
        if options.onDevice, recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        // 先挂上 request，再建 task，避免音频线程拿到空窗导致丢字。
        box.set(request)

        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                self?.handle(result: result, error: error)
            }
        }
        self.task = task
        sessionStartedAt = Date()
        lastSessionEnd = Date()
        onSessionState?(options.onDevice && recognizer.supportsOnDeviceRecognition ? "本机识别中" : "云端识别中")
    }

    /// 用一段录音文件跑一次完整识别，验证「语音识别」这条链路能不能用。
    /// 和实时链路用的是同一套系统服务，只是输入换成了文件。
    static func probe(fileURL: URL, localeID: String, timeout: TimeInterval = 20) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)) else {
            throw NSError(domain: "VoiceSummon", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "系统不支持语言 \(localeID)"])
        }
        guard recognizer.isAvailable else {
            throw NSError(domain: "VoiceSummon", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "语音识别服务当前不可用"])
        }

        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.shouldReportPartialResults = false

        return try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                    var finished = false
                    recognizer.recognitionTask(with: request) { result, error in
                        guard !finished else { return }
                        if let error {
                            finished = true
                            continuation.resume(throwing: error)
                            return
                        }
                        if let result, result.isFinal {
                            finished = true
                            continuation.resume(returning: result.bestTranscription.formattedString)
                        }
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            for try await value in group {
                group.cancelAll()
                if let value {
                    return value
                } else {
                    throw NSError(domain: "VoiceSummon", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey: "识别超时（\(Int(timeout)) 秒没有返回）"])
                }
            }
            throw NSError(domain: "VoiceSummon", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "识别没有返回结果"])
        }
    }

    private func tick() {
        guard running else { return }
        let elapsed = Date().timeIntervalSince(sessionStartedAt)
        if elapsed >= options.sessionSeconds {
            openSession()
        }
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        guard running else { return }

        if let result {
            failures = 0
            // 只发当前会话的文本，绝不把上一轮拼进来，否则同一个词会被反复匹配。
            liveText = result.bestTranscription.formattedString
            onTranscript?(liveText)

            if result.isFinal {
                openSession()
                return
            }
        }

        if let error {
            let nsError = error as NSError
            // 216: 请求被取消；1110: 没识别到语音。都属于正常滚动，不提示。
            // 另外「Recognition request was canceled」在不同系统上 code 不一样（301/216/203），
            // 我们自己的滚动重启也会触发，所以按文本兜一层，别让用户以为出事了。
            let message = error.localizedDescription.lowercased()
            let ignorable = message.contains("cancel")
                || (nsError.domain == "kAFAssistantErrorDomain" && (nsError.code == 216 || nsError.code == 1110))
            if ignorable { return }

            Log.warn("识别错误 \(nsError.domain)/\(nsError.code)：\(error.localizedDescription)")
            onError?("识别中断：\(error.localizedDescription)")

            failures += 1
            lastFailureAt = Date()
            let backoff = min(Double(failures) * 1.5, 8)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                guard let self, self.running else { return }
                self.openSession()
            }
        }
    }
}
