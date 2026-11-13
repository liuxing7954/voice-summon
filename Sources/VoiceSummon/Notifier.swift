import Foundation
import UserNotifications

struct NotificationPayload {
    let keyword: String
    let text: String
    let date: Date
    let clipURL: URL?
    let clipSeconds: Double
    let matchWay: String
    /// 公网可播放的录音链接（没有就是 nil）。
    var clipLink: URL? = nil

    var title: String { "🔔 有人叫你：\(keyword)" }

    var detailText: String {
        var lines: [String] = []
        lines.append("关键词：\(keyword)\(matchWay == "原文" ? "" : "（\(matchWay)命中）")")
        lines.append("时间：\(date.clockText)")
        if let clipURL {
            lines.append("录音：\(Int(clipSeconds)) 秒 · \(clipURL.lastPathComponent)")
        }
        if let clipLink {
            lines.append("")
            lines.append("[▶️ 点这里听录音](\(clipLink.absoluteString))")
        }
        lines.append("")
        lines.append("听到的内容：")
        lines.append(text.isEmpty ? "（无文本）" : text)
        return lines.joined(separator: "\n")
    }
}

enum Notifier {
    enum NotifyError: LocalizedError {
        case badConfig(String)
        case http(Int, String)
        case network(String)
        case local(String)

        var errorDescription: String? {
            switch self {
            case .badConfig(let reason): return "配置不完整：\(reason)"
            case .http(let code, let body):
                let brief = body.count > 160 ? String(body.prefix(160)) + "…" : body
                return "HTTP \(code)：\(brief)"
            case .network(let reason): return "网络错误：\(reason)"
            case .local(let reason): return "本机通知：\(reason)"
            }
        }
    }

    struct Result {
        var delivered: [String] = []
        var errors: [String] = []
    }

    /// 并发推送到所有启用的渠道，每个渠道失败重试一次。
    static func broadcast(_ payload: NotificationPayload, channels: [Channel]) async -> Result {
        var result = Result()
        let active = channels.filter(\.enabled)
        guard !active.isEmpty else {
            result.errors.append("没有启用的通知渠道")
            return result
        }

        await withTaskGroup(of: (String, String?).self) { group in
            for channel in active {
                group.addTask {
                    do {
                        try await send(payload, to: channel)
                        return (channel.displayName, nil)
                    } catch {
                        // 重试一次，抖动的网络不至于漏消息。
                        try? await Task.sleep(nanoseconds: 800_000_000)
                        do {
                            try await send(payload, to: channel)
                            return (channel.displayName, nil)
                        } catch {
                            return (channel.displayName, error.localizedDescription)
                        }
                    }
                }
            }
            for await (name, error) in group {
                if let error {
                    result.errors.append("\(name)：\(error)")
                } else {
                    result.delivered.append(name)
                }
            }
        }
        return result
    }

    static func send(_ payload: NotificationPayload, to channel: Channel) async throws {
        switch channel.kind {
        case .bark: try await sendBark(payload, channel: channel)
        case .serverChan: try await sendServerChan(payload, channel: channel)
        case .telegram: try await sendTelegram(payload, channel: channel)
        case .wecomBot: try await sendWecom(payload, channel: channel)
        case .webhook: try await sendWebhook(payload, channel: channel)
        case .macNotification: try await sendLocal(payload)
        }
    }

    // MARK: - Bark

    private static func sendBark(_ payload: NotificationPayload, channel: Channel) async throws {
        guard !channel.token.isEmpty else { throw NotifyError.badConfig("Bark 缺少 device key") }
        var base = channel.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = "https://api.day.app" }
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: "\(base)/\(channel.token)") else {
            throw NotifyError.badConfig("Bark 地址不合法")
        }

        var body: [String: Any] = [
            "title": payload.title,
            "body": payload.detailText,
            "group": "VoiceSummon",
            "sound": "bell",
            "level": channel.barkLevel.isEmpty ? "active" : channel.barkLevel,
            "isArchive": 1,
            "autoCopy": 0
        ]
        if let link = payload.clipLink {
            body["url"] = link.absoluteString
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await perform(request)
        try validate(response, data: data)
    }

    // MARK: - Server 酱

    private static func sendServerChan(_ payload: NotificationPayload, channel: Channel) async throws {
        guard !channel.token.isEmpty else { throw NotifyError.badConfig("Server 酱缺少 SendKey") }
        var base = channel.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = "https://sctapi.ftqq.com" }
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: "\(base)/\(channel.token).send") else {
            throw NotifyError.badConfig("Server 酱地址不合法")
        }

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "title", value: payload.title),
            URLQueryItem(name: "desp", value: payload.detailText)
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await perform(request)
        try validate(response, data: data)
    }

    // MARK: - Telegram

    private static func sendTelegram(_ payload: NotificationPayload, channel: Channel) async throws {
        guard !channel.token.isEmpty else { throw NotifyError.badConfig("Telegram 缺少 bot token") }
        guard !channel.chatID.isEmpty else { throw NotifyError.badConfig("Telegram 缺少 chat_id") }

        let text = "\(payload.title)\n\n\(payload.detailText)"
        let message = [
            "chat_id": channel.chatID,
            "text": String(text.prefix(3900)),
            "disable_web_page_preview": true
        ] as [String: Any]

        var messageRequest = URLRequest(url: URL(string: "https://api.telegram.org/bot\(channel.token)/sendMessage")!)
        messageRequest.httpMethod = "POST"
        messageRequest.timeoutInterval = 15
        messageRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        messageRequest.httpBody = try JSONSerialization.data(withJSONObject: message)
        let (messageData, messageResponse) = try await perform(messageRequest)
        try validate(messageResponse, data: messageData)

        guard let clipURL = payload.clipURL, let audio = try? Data(contentsOf: clipURL) else { return }

        var form = MultipartForm()
        form.addField("chat_id", channel.chatID)
        form.addField("caption", "\(payload.keyword) · \(payload.date.clockText)")
        form.addField("title", clipURL.lastPathComponent)
        form.addFile("audio", filename: clipURL.lastPathComponent, mime: mimeType(for: clipURL), contents: audio)

        var audioRequest = URLRequest(url: URL(string: "https://api.telegram.org/bot\(channel.token)/sendAudio")!)
        audioRequest.httpMethod = "POST"
        audioRequest.timeoutInterval = 60
        audioRequest.setValue("multipart/form-data; boundary=\(form.boundary)", forHTTPHeaderField: "Content-Type")
        audioRequest.httpBody = form.finalize()
        let (audioData, audioResponse) = try await perform(audioRequest)
        try validate(audioResponse, data: audioData)
    }


    // MARK: - 企业微信机器人

    /// 企业微信群机器人：文本一条 + 音频文件一条。文件要先 upload_media 换 media_id。
    private static func sendWecom(_ payload: NotificationPayload, channel: Channel) async throws {
        guard !channel.token.isEmpty else {
            throw NotifyError.badConfig("企业微信机器人缺少 Webhook Key（群设置 → 群机器人 → 复制 Webhook 里 key= 后面那段）")
        }
        var base = channel.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = "https://qyapi.weixin.qq.com" }
        while base.hasSuffix("/") { base.removeLast() }

        // 1. 文字
        guard let sendURL = URL(string: "\(base)/cgi-bin/webhook/send?key=\(channel.token)") else {
            throw NotifyError.badConfig("企业微信地址不合法")
        }
        let textBody: [String: Any] = [
            "msgtype": "text",
            "text": ["content": "\(payload.title)\n\(payload.detailText)"]
        ]
        var textRequest = URLRequest(url: sendURL)
        textRequest.httpMethod = "POST"
        textRequest.timeoutInterval = 15
        textRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        textRequest.httpBody = try JSONSerialization.data(withJSONObject: textBody)
        let (textData, textResponse) = try await perform(textRequest)
        try validate(textResponse, data: textData)
        try checkWecomPayload(textData)

        // 2. 音频文件
        guard let clipURL = payload.clipURL, let audio = try? Data(contentsOf: clipURL) else { return }
        guard let uploadURL = URL(string: "\(base)/cgi-bin/webhook/upload_media?key=\(channel.token)&type=file") else {
            return
        }

        var form = MultipartForm()
        form.addFile("media", filename: clipURL.lastPathComponent, mime: mimeType(for: clipURL), contents: audio)

        var uploadRequest = URLRequest(url: uploadURL)
        uploadRequest.httpMethod = "POST"
        uploadRequest.timeoutInterval = 60
        uploadRequest.setValue("multipart/form-data; boundary=\(form.boundary)", forHTTPHeaderField: "Content-Type")
        uploadRequest.httpBody = form.finalize()
        let (uploadData, uploadResponse) = try await perform(uploadRequest)
        try validate(uploadResponse, data: uploadData)

        guard let json = try? JSONSerialization.jsonObject(with: uploadData) as? [String: Any],
              let mediaID = json["media_id"] as? String else {
            throw NotifyError.http(uploadResponse.statusCode, String(data: uploadData, encoding: .utf8) ?? "上传没拿到 media_id")
        }

        // 3. 发文件消息
        let fileBody: [String: Any] = ["msgtype": "file", "file": ["media_id": mediaID]]
        var fileRequest = URLRequest(url: sendURL)
        fileRequest.httpMethod = "POST"
        fileRequest.timeoutInterval = 15
        fileRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        fileRequest.httpBody = try JSONSerialization.data(withJSONObject: fileBody)
        let (fileData, fileResponse) = try await perform(fileRequest)
        try validate(fileResponse, data: fileData)
        try checkWecomPayload(fileData)
    }

    /// 企业微信 HTTP 200 也可能是业务错误，errcode != 0 就是失败。
    private static func checkWecomPayload(_ data: Data) throws {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let code = json["errcode"] as? Int, code != 0 {
            let message = json["errmsg"] as? String ?? "未知错误"
            throw NotifyError.badConfig("企业微信返回 \(code)：\(message)")
        }
    }

    // MARK: - 自定义 Webhook

    private static func sendWebhook(_ payload: NotificationPayload, channel: Channel) async throws {
        let endpoint = channel.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty, let url = URL(string: endpoint) else {
            throw NotifyError.badConfig("Webhook 地址为空或不合法")
        }

        var form = MultipartForm()
        form.addField("keyword", payload.keyword)
        form.addField("text", payload.text)
        form.addField("time", ISO8601DateFormatter().string(from: payload.date))
        form.addField("match_way", payload.matchWay)
        form.addField("via_pinyin", payload.matchWay == "原文" ? "0" : "1")
        if !channel.token.isEmpty {
            form.addField("token", channel.token)
        }
        if let clipURL = payload.clipURL, let audio = try? Data(contentsOf: clipURL) {
            form.addFile("audio", filename: clipURL.lastPathComponent, mime: mimeType(for: clipURL), contents: audio)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("multipart/form-data; boundary=\(form.boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finalize()

        let (data, response) = try await perform(request)
        try validate(response, data: data)
    }

    // MARK: - 本机通知

    @discardableResult
    static func requestLocalAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    private static func sendLocal(_ payload: NotificationPayload) async throws {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            break
        case .denied:
            throw NotifyError.local("被系统关掉了，去「系统设置 → 通知 → VoiceSummon」打开")
        case .notDetermined:
            let granted = await requestLocalAuthorization()
            guard granted else {
                throw NotifyError.local("还没授权，去「系统设置 → 通知」里打开")
            }
        @unknown default:
            break
        }

        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.detailText
        content.sound = .default
        if let clipURL = payload.clipURL,
           let attachment = try? UNNotificationAttachment(identifier: "clip", url: clipURL, options: nil) {
            content.attachments = [attachment]
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)

        do {
            try await center.add(request)
            Log.info("本机通知已投递：\(payload.title)")
        } catch {
            Log.error("本机通知投递失败：\(error.localizedDescription)")
            throw NotifyError.local(error.localizedDescription)
        }
    }

    // MARK: - 工具

    private static func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw NotifyError.network("响应不是 HTTP")
            }
            return (data, http)
        } catch let error as NotifyError {
            throw error
        } catch {
            throw NotifyError.network(error.localizedDescription)
        }
    }

    private static func validate(_ response: HTTPURLResponse, data: Data) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw NotifyError.http(response.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m4a": return "audio/mp4"
        case "wav": return "audio/wav"
        case "caf": return "audio/x-caf"
        default: return "application/octet-stream"
        }
    }
}
