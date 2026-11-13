import AppKit
import Foundation
import os

/// 全局路径。所有产物都落在 ~/Library/Application Support/VoiceSummon 下。
enum Paths {
    static let support: URL = {
        // 自测/调试可以用 VOICESUMMON_HOME 指到临时目录，避免把真实配置和录音写坏。
        if let override = ProcessInfo.processInfo.environment["VOICESUMMON_HOME"], !override.isEmpty {
            let dir = URL(fileURLWithPath: override, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("VoiceSummon", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var configFile: URL { support.appendingPathComponent("config.json") }
    static var logFile: URL { support.appendingPathComponent("voicesummon.log") }

    static var clipsDir: URL {
        let dir = support.appendingPathComponent("Clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// 轻量日志：os_log + 内存环形 + 落盘。菜单里能看到最近记录。
enum Log {
    private static let logger = Logger(subsystem: "com.fujiang.voicesummon", category: "runtime")
    private static let lock = NSLock()
    private static var buffer: [String] = []
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) { write("INFO", message) }
    static func warn(_ message: String) { write("WARN", message) }
    static func error(_ message: String) { write("ERR ", message) }

    static var recent: [String] {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    static var recentText: String {
        recent.suffix(80).joined(separator: "\n")
    }

    private static func write(_ level: String, _ message: String) {
        logger.log("\(level, privacy: .public) \(message, privacy: .public)")
        let line = "\(stamp.string(from: Date())) [\(level)] \(message)"
        lock.lock()
        buffer.append(line)
        if buffer.count > 300 { buffer.removeFirst(buffer.count - 300) }
        lock.unlock()

        if let data = (line + "\n").data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: Paths.logFile) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: Paths.logFile)
            }
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension Date {
    var clockText: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: self)
    }

    var fileStamp: String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: self)
    }
}

/// 版本信息：版本号 + 构建号 + 构建时间，右下角一直显示，方便确认装的是不是最新版。
enum AppVersion {
    static let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    static let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    static let builtAt = Bundle.main.infoDictionary?["VSBuildTime"] as? String ?? "本地构建"

    static var display: String { "v\(short) (\(build)) · \(builtAt)" }

    static var diagnostic: String { "\(display) · \(Bundle.main.bundlePath)" }
}

/// 把包里的 voicesummon 脚本注册到 PATH 里的目录（优先 /usr/local/bin，不行就 ~/.local/bin）。
enum CommandInstaller {
    static let name = "voicesummon"

    @discardableResult
    static func installIfNeeded() -> String? {
        guard let source = Bundle.main.url(forResource: name, withExtension: nil) else {
            Log.warn("app 包里没有 CLI 脚本，跳过注册")
            return nil
        }
        guard let payload = try? Data(contentsOf: source), !payload.isEmpty else { return nil }

        let candidates = ["/usr/local/bin", NSHomeDirectory() + "/.local/bin"]
        for directory in candidates {
            let destination = URL(fileURLWithPath: directory).appendingPathComponent(name)

            if let existing = try? Data(contentsOf: destination), existing == payload {
                return destination.path
            }

            var isDirectory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory) {
                // ~/.local/bin 不存在就建一个（/usr/local/bin 不建，没权限）
                if directory.hasPrefix(NSHomeDirectory()) {
                    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                }
            }
            guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            guard FileManager.default.isWritableFile(atPath: directory) else { continue }

            do {
                try? FileManager.default.removeItem(at: destination)
                try payload.write(to: destination, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
                Log.info("CLI 已注册：\(destination.path)")
                return destination.path
            } catch {
                Log.warn("CLI 写入 \(directory) 失败：\(error.localizedDescription)")
            }
        }

        Log.warn("没找到可写的 PATH 目录，CLI 需要手动装")
        return nil
    }
}

/// 权限相关的小工具。
enum Permissions {
    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    static func openSpeechSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
    }

    static func openNotificationSettings() {
        open("x-apple.systempreferences:com.apple.preference.notifications")
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// multipart/form-data 构造器，Notifier 和上传器共用。
struct MultipartForm {
    let boundary = "----VoiceSummon\(UUID().uuidString)"
    private var body = Data()

    mutating func addField(_ name: String, _ value: String) {
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        body.appendUTF8("\(value)\r\n")
    }

    mutating func addFile(_ name: String, filename: String, mime: String, contents: Data) {
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        body.appendUTF8("Content-Type: \(mime)\r\n\r\n")
        body.append(contents)
        body.appendUTF8("\r\n")
    }

    mutating func finalize() -> Data {
        body.appendUTF8("--\(boundary)--\r\n")
        return body
    }
}

extension Data {
    mutating func appendUTF8(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
