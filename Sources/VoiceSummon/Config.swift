import Foundation

enum ClipFormat: String, Codable, CaseIterable, Identifiable {
    case m4a
    case wav

    var id: String { rawValue }

    var title: String {
        switch self {
        case .m4a: return "m4a 压缩（推荐，体积小）"
        case .wav: return "wav 无损（体积大）"
        }
    }

    var fileExtension: String { rawValue }
}

/// 关键词匹配强度。用户不需要汉字对，只要发音对得上。
enum MatchLevel: String, Codable, CaseIterable, Identifiable {
    /// 识别出的汉字必须完全一样。
    case exact
    /// 发音相同即可：张伟 ≈ 张玮 ≈ 张维（声调可以不一样）。
    case homophone
    /// 声母韵母相近也算：zh≈z、ch≈c、sh≈s、n≈l、f≈h、前后鼻音不分。
    case fuzzy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .exact: return "严格"
        case .homophone: return "同音"
        case .fuzzy: return "近音"
        }
    }

    var detail: String {
        switch self {
        case .exact:
            return "识别文字要和关键词一模一样，最保守。"
        case .homophone:
            return "发音一样就算，不管用哪个字、哪个声调。推荐。"
        case .fuzzy:
            return "发音相近也算：张≈臧、李≈尼、飞≈黑、英≈因。最宽松，误报也最多。"
        }
    }
}

/// 一个通知渠道。字段按 kind 复用，界面上只显示当前 kind 需要的输入框。
struct Channel: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case bark
        case serverChan
        case telegram
        case wecomBot
        case webhook
        case macNotification

        var id: String { rawValue }

        var title: String {
            switch self {
            case .bark: return "Bark（iPhone 推送）"
            case .serverChan: return "Server 酱（微信）"
            case .telegram: return "Telegram Bot"
            case .wecomBot: return "企业微信机器人（能发录音）"
            case .webhook: return "自定义 Webhook"
            case .macNotification: return "本机通知"
            }
        }

        var shortTitle: String {
            switch self {
            case .bark: return "Bark"
            case .serverChan: return "Server酱"
            case .telegram: return "Telegram"
            case .wecomBot: return "企业微信"
            case .webhook: return "Webhook"
            case .macNotification: return "本机"
            }
        }

        /// 该渠道能不能带音频附件。
        var supportsAudio: Bool {
            switch self {
            case .telegram, .wecomBot, .webhook: return true
            case .bark, .serverChan, .macNotification: return false
            }
        }
    }

    var id: UUID = UUID()
    var kind: Kind = .bark
    var enabled: Bool = true
    var endpoint: String = ""
    var token: String = ""
    var chatID: String = ""
    /// Bark 的提醒级别：active / timeSensitive（穿透专注模式）/ critical（穿透静音）
    var barkLevel: String = "timeSensitive"

    init(id: UUID = UUID(),
         kind: Kind = .bark,
         enabled: Bool = true,
         endpoint: String = "",
         token: String = "",
         chatID: String = "",
         barkLevel: String = "timeSensitive") {
        self.id = id
        self.kind = kind
        self.enabled = enabled
        self.endpoint = endpoint
        self.token = token
        self.chatID = chatID
        self.barkLevel = barkLevel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .bark
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint) ?? ""
        token = try container.decodeIfPresent(String.self, forKey: .token) ?? ""
        chatID = try container.decodeIfPresent(String.self, forKey: .chatID) ?? ""
        barkLevel = try container.decodeIfPresent(String.self, forKey: .barkLevel) ?? "timeSensitive"
    }

    var displayName: String { kind.shortTitle }
}

struct AppConfig: Codable, Equatable {
    // 监听。内置一套「季潇熠」的变体，开箱即用；换人只要在面板里改。
    var keywords: [String] = [
        // 全名
        "季潇熠",
        // 识别器最常写成的同音写法
        "季小艺", "纪小艺", "记小艺", "季晓熠", "季肖逸", "季潇逸",
        // 只听到两个字时
        "季潇", "潇熠", "小艺",
        // 单字兜底
        "季", "潇", "熠"
    ]
    /// 匹配强度：严格 / 同音 / 近音。
    var matchLevel: MatchLevel = .fuzzy
    var localeID: String = "zh-CN"
    /// 远场增强：自动增益 + 高通，专门救 3 米外的小声说话。
    var farFieldBoost: Bool = true
    /// 最大增益（dB）。越大越能捞小声，但底噪也一起放大。
    var maxBoostDB: Double = 24
    /// 指定输入设备（空 = 跟随系统默认）。
    var inputDeviceUID: String = ""
    /// 强制本机识别（不联网）。关掉时优先走系统服务，识别更准。
    var onDeviceRecognition: Bool = false

    // 录音窗口
    var preRoll: Double = 5
    var postRoll: Double = 5
    /// 两次命中之间的静默期，防止同一句话反复触发。
    var cooldown: Double = 5
    var clipFormat: ClipFormat = .m4a

    // 其它
    var channels: [Channel] = [Channel(kind: .macNotification)]
    var autoStart: Bool = true
    var preventSleep: Bool = true
    var playSoundOnHit: Bool = true
    var keepDays: Int = 14
    /// 录音外链：传公网换一个能直接播放的 URL，通知里带上去。
    var audioUpload: AudioUploader.Config = AudioUploader.Config()

    /// 环形缓冲要比「前 + 后」窗口更长，留出调度抖动余量。
    var requiredHistorySeconds: Double {
        max(preRoll + postRoll + 10, 20)
    }
}

extension AppConfig {
    /// 手写解码：缺字段就用默认值，老配置升级时不会整份失效。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AppConfig()

        keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? fallback.keywords
        localeID = try container.decodeIfPresent(String.self, forKey: .localeID) ?? fallback.localeID
        farFieldBoost = try container.decodeIfPresent(Bool.self, forKey: .farFieldBoost) ?? fallback.farFieldBoost
        maxBoostDB = try container.decodeIfPresent(Double.self, forKey: .maxBoostDB) ?? fallback.maxBoostDB
        inputDeviceUID = try container.decodeIfPresent(String.self, forKey: .inputDeviceUID) ?? fallback.inputDeviceUID
        onDeviceRecognition = try container.decodeIfPresent(Bool.self, forKey: .onDeviceRecognition) ?? fallback.onDeviceRecognition
        preRoll = try container.decodeIfPresent(Double.self, forKey: .preRoll) ?? fallback.preRoll
        postRoll = try container.decodeIfPresent(Double.self, forKey: .postRoll) ?? fallback.postRoll
        cooldown = try container.decodeIfPresent(Double.self, forKey: .cooldown) ?? fallback.cooldown
        clipFormat = try container.decodeIfPresent(ClipFormat.self, forKey: .clipFormat) ?? fallback.clipFormat
        channels = try container.decodeIfPresent([Channel].self, forKey: .channels) ?? fallback.channels
        autoStart = try container.decodeIfPresent(Bool.self, forKey: .autoStart) ?? fallback.autoStart
        preventSleep = try container.decodeIfPresent(Bool.self, forKey: .preventSleep) ?? fallback.preventSleep
        playSoundOnHit = try container.decodeIfPresent(Bool.self, forKey: .playSoundOnHit) ?? fallback.playSoundOnHit
        keepDays = try container.decodeIfPresent(Int.self, forKey: .keepDays) ?? fallback.keepDays
        audioUpload = try container.decodeIfPresent(AudioUploader.Config.self, forKey: .audioUpload) ?? fallback.audioUpload

        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        if let level = try container.decodeIfPresent(MatchLevel.self, forKey: .matchLevel) {
            matchLevel = level
        } else if let legacyFuzzy = try legacy.decodeIfPresent(Bool.self, forKey: .fuzzyPinyin) {
            // 老版本只有「同音字也算」开关。
            matchLevel = legacyFuzzy ? .homophone : .exact
        } else {
            matchLevel = fallback.matchLevel
        }
    }

    private enum CodingKeys: String, CodingKey {
        case keywords, matchLevel, localeID, onDeviceRecognition
        case farFieldBoost, maxBoostDB, inputDeviceUID
        case preRoll, postRoll, cooldown, clipFormat
        case channels, autoStart, preventSleep, playSoundOnHit, keepDays, audioUpload
    }

    /// 老配置里的字段，只读不写。
    private enum LegacyKeys: String, CodingKey {
        case fuzzyPinyin
    }
}

enum ConfigStore {
    static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: Paths.configFile) else { return AppConfig() }
        do {
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            Log.error("配置解析失败，使用默认值：\(error.localizedDescription)")
            return AppConfig()
        }
    }

    static func save(_ config: AppConfig) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(config)
            try data.write(to: Paths.configFile, options: .atomic)
        } catch {
            Log.error("配置写入失败：\(error.localizedDescription)")
        }
    }
}
