import Foundation

/// 关键词匹配。
///
/// 用户的诉求是「音对就行，不用字对」，所以这里分三级：
/// 1. 原文包含（最稳）；
/// 2. 同音：转拼音比，带声调先比一遍，再忽略声调比一遍（张伟 / 张玮 / 张维）；
/// 3. 近音：在无声调拼音上做模糊音归一（zh→z、ch→c、sh→s、n/r→l、f→h、去后鼻音），
///    这样「张」和「臧」、「李」和「尼」、「飞」和「黑」也能撞上。
/// 单字也走发音匹配（「熠/艺」「季/记」「潇/小」），误报靠档位和静默期控制。
struct KeywordMatcher {
    enum MatchWay: String {
        case literal
        case tonal
        case toneless
        case fuzzy

        var label: String {
            switch self {
            case .literal: return "原文"
            case .tonal: return "同音"
            case .toneless: return "同音异调"
            case .fuzzy: return "近音"
            }
        }
    }

    struct Hit {
        let keyword: String
        let way: MatchWay

        var viaPinyin: Bool { way != .literal }
    }

    private struct Item {
        let keyword: String
        let plain: String
        let tonal: String?
        let toneless: String?
        let fuzzy: String?
        let syllables: Int
    }

    private let items: [Item]
    private let level: MatchLevel

    init(keywords: [String], level: MatchLevel) {
        self.level = level
        self.items = keywords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { keyword in
                let tonal = TextNormalizer.pinyinSyllables(keyword, tonal: true)
                let toneless = TextNormalizer.pinyinSyllables(keyword, tonal: false)
                return Item(
                    keyword: keyword,
                    plain: TextNormalizer.plain(keyword),
                    tonal: tonal,
                    toneless: toneless,
                    fuzzy: toneless.map { TextNormalizer.fuzzySyllables($0) },
                    syllables: toneless.map { $0.split(separator: " ").count } ?? 0
                )
            }
    }

    var isEmpty: Bool { items.isEmpty }

    /// 在识别文本里找第一个命中的关键词。只看尾部一段，避免旧内容反复触发。
    func match(in text: String, tailLength: Int = 80) -> Hit? {
        guard !items.isEmpty else { return nil }
        let tail = String(text.suffix(tailLength))
        let plain = TextNormalizer.plain(tail)
        guard !plain.isEmpty else { return nil }

        for item in items where !item.plain.isEmpty {
            if plain.contains(item.plain) {
                return Hit(keyword: item.keyword, way: .literal)
            }
        }

        guard level != .exact else { return nil }

        let tonalText = TextNormalizer.pinyinSyllables(tail, tonal: true)
        let tonelessText = TextNormalizer.pinyinSyllables(tail, tonal: false)

        if let tonalText {
            let padded = " \(tonalText) "
            for item in items {
                guard let keyword = item.tonal else { continue }
                if padded.contains(" \(keyword) ") {
                    return Hit(keyword: item.keyword, way: .tonal)
                }
            }
        }

        if let tonelessText {
            let padded = " \(tonelessText) "
            for item in items {
                guard let keyword = item.toneless else { continue }
                if padded.contains(" \(keyword) ") {
                    return Hit(keyword: item.keyword, way: .toneless)
                }
            }
        }

        guard level == .fuzzy, let tonelessText else { return nil }

        let padded = " \(TextNormalizer.fuzzySyllables(tonelessText)) "
        for item in items {
            guard let keyword = item.fuzzy else { continue }
            if padded.contains(" \(keyword) ") {
                return Hit(keyword: item.keyword, way: .fuzzy)
            }
        }

        return nil
    }
}

enum TextNormalizer {
    /// 小写 + 只保留字母、数字、汉字。标点和空格全部丢掉。
    static func plain(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || isCJK(scalar) {
                result.append(scalar)
            }
        }
        return String(result)
    }

    /// 转成拼音，音节之间用单个空格分隔。`tonal` 为 false 时去掉声调。
    /// 英文/数字原样保留，这样中英混合关键词也能匹配。
    static func pinyinSyllables(_ text: String, tonal: Bool = true) -> String? {
        let mutable = NSMutableString(string: text) as CFMutableString
        guard CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false) else { return nil }
        if !tonal {
            guard CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false) else { return nil }
        }

        let lowered = (mutable as String).lowercased().precomposedStringWithCanonicalMapping
        var components: [String] = []
        for piece in lowered.split(separator: " ") {
            let cleaned = piece.unicodeScalars.filter {
                CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
            }
            if !cleaned.isEmpty {
                components.append(String(String.UnicodeScalarView(cleaned)))
            }
        }
        return components.isEmpty ? nil : components.joined(separator: " ")
    }

    /// 无声调拼音上的模糊音归一：平翘舌不分、n/r 混 l、f 混 h、前后鼻音不分。
    static func fuzzySyllables(_ tonelessPinyin: String) -> String {
        tonelessPinyin
            .split(separator: " ")
            .map { fuzzySyllable(String($0)) }
            .joined(separator: " ")
    }

    private static let initials = [
        "zh", "ch", "sh",
        "b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h",
        "j", "q", "x", "r", "z", "c", "s", "y", "w"
    ]

    private static func fuzzySyllable(_ syllable: String) -> String {
        var initial = ""
        var final = syllable

        for candidate in initials where syllable.hasPrefix(candidate) {
            initial = candidate
            final = String(syllable.dropFirst(candidate.count))
            break
        }

        switch initial {
        case "zh": initial = "z"
        case "ch": initial = "c"
        case "sh": initial = "s"
        case "n", "r": initial = "l"
        case "f": initial = "h"
        default: break
        }

        for nasal in ["ang", "eng", "ing", "ong"] where final.hasSuffix(nasal) {
            final = String(final.dropLast())
            break
        }

        return initial + final.replacingOccurrences(of: "ü", with: "u")
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x3040...0x30FF:
            return true
        default:
            return false
        }
    }
}
