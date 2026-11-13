import Foundation
import Network

/// 一个极简的本地 HTTP 请求解析（只处理 POST/GET + Content-Length）。
struct LocalHTTPRequest {
    let method: String
    let path: String
    let body: Data

    static func parse(_ data: Data) -> LocalHTTPRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let headerText = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        var contentLength = 0
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            if pair.count == 2, pair[0].lowercased() == "content-length" {
                contentLength = Int(pair[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }

        let bodyStart = headerEnd.upperBound
        let available = data.count - bodyStart
        guard available >= contentLength else { return nil }

        return LocalHTTPRequest(
            method: String(parts[0]).uppercased(),
            path: String(parts[1]),
            body: data.subdata(in: bodyStart..<(bodyStart + contentLength))
        )
    }
}

/// 本地控制接口：只监听 127.0.0.1，给终端和 agent 用。
///
///   curl 127.0.0.1:18990/status
///   curl -X POST 127.0.0.1:18990/stop
final class LocalAPI {
    static let shared = LocalAPI()
    static let port: UInt16 = 18990

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.fujiang.voicesummon.api")

    func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(
                host: .ipv4(.loopback),
                port: NWEndpoint.Port(rawValue: LocalAPI.port)!
            )
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    Log.error("本地接口失败：\(error.localizedDescription)")
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
            Log.info("本地接口已开：http://127.0.0.1:\(LocalAPI.port)")
        } catch {
            Log.error("本地接口启动失败：\(error.localizedDescription)")
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 131_072) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data { accumulated.append(data) }

            if let request = LocalHTTPRequest.parse(accumulated) {
                self.respond(connection, request)
            } else if error == nil, !isComplete, accumulated.count < 1_048_576 {
                self.read(connection, buffer: accumulated)
            } else {
                connection.cancel()
            }
        }
    }

    private func respond(_ connection: NWConnection, _ request: LocalHTTPRequest) {
        Task { @MainActor in
            let (status, payload) = LocalAPI.route(request)
            let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]))
                ?? Data("{}".utf8)
            let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Bad Request")\r\n"
                + "Content-Type: application/json; charset=utf-8\r\n"
                + "Content-Length: \(json.count)\r\n"
                + "Connection: close\r\n\r\n"
            var response = Data(head.utf8)
            response.append(json)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    // MARK: - 路由

    @MainActor
    private static func route(_ request: LocalHTTPRequest) -> (Int, [String: Any]) {
        let app = AppState.shared
        let path = request.path.split(separator: "?").first.map(String.init) ?? request.path

        switch (request.method, path) {
        case ("GET", "/"), ("GET", "/status"):
            return (200, statusPayload(app))

        case ("GET", "/keywords"):
            return (200, ["ok": true, "keywords": app.config.keywords])

        case ("GET", "/hits"):
            let hits = app.hits.prefix(10).map { hit -> [String: Any] in
                [
                    "keyword": hit.keyword,
                    "text": hit.text,
                    "time": hit.date.clockText,
                    "matchWay": hit.matchWay,
                    "status": hit.status,
                    "clip": hit.clipURL?.path ?? ""
                ]
            }
            return (200, ["ok": true, "hits": Array(hits)])

        case ("POST", "/start"):
            app.start()
            return (200, ["ok": true, "running": app.isRunning])

        case ("POST", "/stop"):
            app.stop()
            return (200, ["ok": true, "running": app.isRunning])

        case ("POST", "/toggle"):
            app.toggle()
            return (200, ["ok": true, "running": app.isRunning])

        case ("POST", "/test-notify"):
            Task { _ = await app.sendTestNotification() }
            return (200, ["ok": true, "message": "测试通知已触发"])

        case ("POST", "/keywords"):
            guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
                return (400, ["ok": false, "error": "body 要是 JSON，比如 {\"add\":[\"张伟\"]}"])
            }
            let added = object["add"] as? [String] ?? []
            let removed = object["remove"] as? [String] ?? []
            added.forEach { app.addKeyword($0) }
            removed.forEach { app.removeKeyword($0) }
            return (200, ["ok": true, "keywords": app.config.keywords, "added": added, "removed": removed])

        case ("POST", "/config"):
            guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
                return (400, ["ok": false, "error": "body 要是 JSON"])
            }
            var changed: [String] = []

            if let value = number(object["cooldown"]) { app.config.cooldown = value; changed.append("cooldown") }
            if let value = number(object["preRoll"]) { app.config.preRoll = value; changed.append("preRoll") }
            if let value = number(object["postRoll"]) { app.config.postRoll = value; changed.append("postRoll") }
            if let value = number(object["maxBoostDB"]) { app.config.maxBoostDB = value; changed.append("maxBoostDB") }
            if let value = object["matchLevel"] as? String, let level = MatchLevel(rawValue: value) {
                app.config.matchLevel = level
                changed.append("matchLevel")
            }
            if let value = object["localeID"] as? String { app.config.localeID = value; changed.append("localeID") }
            if let value = object["farFieldBoost"] as? Bool { app.config.farFieldBoost = value; changed.append("farFieldBoost") }
            if let value = object["onDeviceRecognition"] as? Bool { app.config.onDeviceRecognition = value; changed.append("onDeviceRecognition") }
            if let value = object["audioUpload"] as? Bool { app.config.audioUpload.enabled = value; changed.append("audioUpload") }

            return (200, ["ok": true, "changed": changed, "config": statusPayload(app)])

        default:
            return (404, ["ok": false, "error": "没有这个接口：\(request.method) \(path)"])
        }
    }

    @MainActor
    private static func statusPayload(_ app: AppState) -> [String: Any] {
        [
            "ok": true,
            "running": app.isRunning,
            "version": AppVersion.display,
            "engine": app.engineInfo,
            "status": app.status,
            "keywords": app.config.keywords,
            "matchLevel": app.config.matchLevel.rawValue,
            "cooldown": app.config.cooldown,
            "preRoll": app.config.preRoll,
            "postRoll": app.config.postRoll,
            "farFieldBoost": app.config.farFieldBoost,
            "maxBoostDB": app.config.maxBoostDB,
            "gain": Double(app.gainFactor),
            "liveText": String(app.liveText.suffix(80)),
            "hits": app.hits.count,
            "api": "http://127.0.0.1:\(LocalAPI.port)"
        ]
    }

    private static func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String { return Double(string) }
        return nil
    }
}
