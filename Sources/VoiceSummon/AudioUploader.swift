import Foundation

/// 把录音传到一个公网地址，换回一个能直接播放的链接。
///
/// 默认用 litterbox（catbox.moe 的临时桶）：免注册、返回纯文本 URL、
/// 默认 72 小时自动过期。音频在微信/浏览器里点开就能播。
enum AudioUploader {
    /// 一个上传目标。不同站点的字段名不一样，这里各自带一套。
    struct Target: Codable, Equatable {
        var url: String
        var field: String
        var extra: [String: String] = [:]
        var headers: [String: String] = [:]

        init(url: String, field: String, extra: [String: String] = [:], headers: [String: String] = [:]) {
            self.url = url
            self.field = field
            self.extra = extra
            self.headers = headers
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
            field = try container.decodeIfPresent(String.self, forKey: .field) ?? "file"
            extra = try container.decodeIfPresent([String: String].self, forKey: .extra) ?? [:]
            headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        }
    }

    struct Config: Codable, Equatable {
        var enabled: Bool = true
        /// 过期时间，litterbox 支持 1h / 12h / 24h / 72h。
        var expiry: String = "72h"
        /// 按顺序试，前一个失败就换下一个。全部失败才算失败。
        var targets: [Target] = [
            // 自建（国内直连，秒级），放在第一位
            Target(url: AudioUploader.builtinEndpoint, field: "file", extra: [:]),
            // 公网兜底
            Target(url: "https://litterbox.catbox.moe/resources/internals/api.php",
                   field: "fileToUpload",
                   extra: ["reqtype": "fileupload", "time": "72h"]),
            Target(url: "https://catbox.moe/user/api.php",
                   field: "fileToUpload",
                   extra: ["reqtype": "fileupload"])
        ]
    }

    enum UploadError: LocalizedError {
        case badEndpoint
        case emptyFile
        case badResponse(String)

        var errorDescription: String? {
            switch self {
            case .badEndpoint: return "上传地址为空或不合法"
            case .emptyFile: return "录音文件是空的"
            case .badResponse(let detail): return "上传失败：\(detail)"
            }
        }
    }

    /// 依次尝试所有目标，任何一个拿到链接就返回。
    static func upload(_ fileURL: URL, config: Config) async throws -> URL {
        guard !config.targets.isEmpty else { throw UploadError.badEndpoint }

        var lastError: Error = UploadError.badEndpoint
        for target in config.targets {
            do {
                return try await upload(fileURL, target: target)
            } catch {
                lastError = error
                Log.warn("上传失败 \(target.url)：\(error.localizedDescription)")
            }
        }
        throw lastError
    }

    /// 自建上传口（挂在 notify 域名下的 /vs-audio）。
    static let builtinEndpoint = "https://notify.v2.wobuqu.icu/vs-audio/upload"
    static let builtinToken = "df029bc8ff97b77478c44d3deabd7ebb"

    private static func upload(_ fileURL: URL, target: Target) async throws -> URL {
        guard !target.url.isEmpty, let endpoint = URL(string: target.url) else {
            throw UploadError.badEndpoint
        }
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            throw UploadError.emptyFile
        }

        var form = MultipartForm()
        for (key, value) in target.extra {
            form.addField(key, value)
        }
        form.addFile(target.field.isEmpty ? "file" : target.field,
                     filename: fileURL.lastPathComponent,
                     mime: mimeType(for: fileURL),
                     contents: data)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("multipart/form-data; boundary=\(form.boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        for (key, value) in target.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = form.finalize()

        let (body, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let text = (String(data: body, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard (200..<300).contains(status) else {
            throw UploadError.badResponse("HTTP \(status) \(text.prefix(80))")
        }

        if text.lowercased().hasPrefix("http"), let link = URL(string: text) {
            return link
        }

        // 兼容返回 JSON 的服务：{"url":"..."} / {"data":[{"url":"..."}]} / {"data":{"url":"..."}}
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let raw = json["url"] as? String, let link = URL(string: raw) {
                return link
            }
            if let data = json["data"] as? [String: Any], let raw = data["url"] as? String {
                // tmpfiles 返回的是网页地址，换成直链域名
                let direct = raw.replacingOccurrences(of: "tmpfiles.org/", with: "tmpfiles.org/dl/")
                if let link = URL(string: direct) { return link }
            }
            if let list = json["data"] as? [[String: Any]],
               let raw = list.first?["url"] as? String,
               let link = URL(string: raw) {
                return link
            }
        }

        throw UploadError.badResponse("没解析出链接：\(text.prefix(80))")
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
