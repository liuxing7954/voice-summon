import AppKit
import AVFoundation
import Foundation

// 纯逻辑自测：关键词匹配 / 同音匹配 / 音频切片转码 / webhook 推送格式。
// 编译：swiftc Sources/… Tests/SelfTest/main.swift

var failures = 0

func check(_ condition: Bool, _ name: String, detail: String = "") {
    if condition {
        print("  ✅ \(name)")
    } else {
        print("  ❌ \(name) \(detail)")
        failures += 1
    }
}

// MARK: - 1. 归一化

print("== 文本归一化 ==")
check(TextNormalizer.plain("张伟，你好！") == "张伟你好", "去标点", detail: TextNormalizer.plain("张伟，你好！"))
check(TextNormalizer.plain("  Alice-01 ") == "alice01", "大小写与空格", detail: TextNormalizer.plain("  Alice-01 "))
let pinyin = TextNormalizer.pinyinSyllables("张伟") ?? "nil"
check(pinyin == "zhāng wěi", "带调拼音", detail: pinyin)
let toneless = TextNormalizer.pinyinSyllables("张伟", tonal: false) ?? "nil"
check(toneless == "zhang wei", "无声调拼音", detail: toneless)
let mixed = TextNormalizer.pinyinSyllables("Alice 张伟") ?? "nil"
check(mixed == "alice zhāng wěi", "中英混合拼音", detail: mixed)

// MARK: - 2. 关键词匹配

print("== 关键词匹配 ==")
let matcher = KeywordMatcher(keywords: ["张伟", "老板", "Alice"], level: .homophone)

check(matcher.match(in: "喂，张伟你赶紧下来一趟")?.keyword == "张伟", "直接命中")
check(matcher.match(in: "张玮在不在") != nil, "同音命中（玮）", detail: "\(String(describing: matcher.match(in: "张玮在不在")))")
check(matcher.match(in: "李总说老板马上到")?.keyword == "老板", "句中命中")
check(matcher.match(in: "alice 你在干嘛")?.keyword == "Alice", "英文大小写")
check(matcher.match(in: "今天中午吃什么") == nil, "不该命中")

let strictMatcher = KeywordMatcher(keywords: ["张伟"], level: .exact)
check(strictMatcher.match(in: "张玮在不在") == nil, "关掉同音后不误报")

let toned = KeywordMatcher(keywords: ["张伟"], level: .homophone)
check(toned.match(in: "张维来了") != nil, "跨声调同音兜底（维）")
let singleChar = KeywordMatcher(keywords: ["喂"], level: .fuzzy)
check(singleChar.match(in: "这个位置很好") != nil, "单字会撞同音（位/喂）——拼音匹配的必然代价")
check(singleChar.match(in: "今天天气不错") == nil, "单字不会无缘无故触发")

// 近音档：平翘舌、n/l、前后鼻音
let fuzzyMatcher = KeywordMatcher(keywords: ["张伟"], level: .fuzzy)
check(fuzzyMatcher.match(in: "臧伟来了") != nil, "近音：平翘舌不分（张/臧）")
let homophoneMatcher = KeywordMatcher(keywords: ["张伟"], level: .homophone)
check(homophoneMatcher.match(in: "臧伟来了") == nil, "同音档不吃平翘舌")
let liMatcher = KeywordMatcher(keywords: ["李娜"], level: .fuzzy)
check(liMatcher.match(in: "尼那在吗") != nil, "近音：n/l 不分（李/尼）")
let nasalMatcher = KeywordMatcher(keywords: ["英华"], level: .fuzzy)
check(nasalMatcher.match(in: "因华来了") != nil, "近音：前后鼻音不分（英/因）")
check(fuzzyMatcher.match(in: "今天中午吃什么") == nil, "近音档不胡乱触发")

// 单字关键词：用户实际用的「季 / 潇 / 熠」，说「小艺」要能中
let yiMatcher = KeywordMatcher(keywords: ["熠"], level: .homophone)
check(yiMatcher.match(in: "小艺在吗") != nil, "单字同音：熠 / 艺")
let xiaoMatcher = KeywordMatcher(keywords: ["潇"], level: .homophone)
check(xiaoMatcher.match(in: "小艺在吗") != nil, "单字跨调：潇 / 小")
let jiMatcher = KeywordMatcher(keywords: ["季"], level: .fuzzy)
check(jiMatcher.match(in: "记一下这个") != nil, "单字近音：季 / 记")
check(yiMatcher.match(in: "今天天气不错") == nil, "单字不胡乱触发")
let trio = KeywordMatcher(keywords: ["季", "潇", "熠"], level: .fuzzy)
let trioHit = trio.match(in: "小艺帮我看看这个")
check(trioHit != nil, "三单字同池：小艺命中", detail: String(describing: trioHit?.keyword))

let longText = String(repeating: "嗯", count: 200)
check(matcher.match(in: longText + "张伟") != nil, "只看尾部窗口仍能命中")

// MARK: - 3. 音频切片与转码

print("== 音频处理 ==")
let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
let frames = AVAudioFrameCount(48_000 * 3)
let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frames)!
source.frameLength = frames
for channel in 0..<2 {
    let data = source.floatChannelData![channel]
    for index in 0..<Int(frames) {
        let t = Double(index) / 48_000.0
        data[index] = Float(sin(2 * .pi * 440 * t) * 0.3)
    }
}

do {
    let converted = try ClipExporter.convert(source, to: ClipExporter.targetFormat)
    check(converted.format.sampleRate == 16_000, "重采样到 16k")
    check(converted.format.channelCount == 1, "下混到单声道")
    check(abs(Double(converted.frameLength) - 48_000) < 2_000, "帧数基本一致", detail: "\(converted.frameLength)")

    let m4a = try ClipExporter.save(source, keyword: "张伟", date: Date(), format: .m4a)
    check(FileManager.default.fileExists(atPath: m4a.path), "m4a 落盘", detail: m4a.path)
    let m4aFile = try AVAudioFile(forReading: m4a)
    check(abs(m4aFile.fileFormat.sampleRate - 16_000) < 1, "m4a 采样率", detail: "\(m4aFile.fileFormat.sampleRate)")
    check(m4aFile.length > 40_000, "m4a 时长约 3 秒", detail: "\(m4aFile.length)")
    let m4aSize = ((try? FileManager.default.attributesOfItem(atPath: m4a.path)[.size]) as? Int) ?? 0
    check(m4aSize > 5_000, "m4a 体积合理", detail: "\(m4aSize) bytes")

    let wav = try ClipExporter.save(source, keyword: "老板", date: Date(), format: .wav)
    let wavFile = try AVAudioFile(forReading: wav)
    check(wavFile.length > 40_000, "wav 时长约 3 秒", detail: "\(wavFile.length)")

    print("  样本文件：")
    print("    \(m4a.path)")
    print("    \(wav.path)")
} catch {
    print("  ❌ 音频处理异常：\(error.localizedDescription)")
    failures += 1
}

// MARK: - 3.5 远场增强

print("== 远场增强 ==")
let monoFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: 2048)!
mono.frameLength = 2048

func fill(_ buffer: AVAudioPCMBuffer, amplitude: Float, frequency: Double = 440) {
    let samples = buffer.floatChannelData![0]
    for index in 0..<Int(buffer.frameLength) {
        samples[index] = Float(sin(2 * .pi * frequency * Double(index) / 48_000.0)) * amplitude
    }
}

func rmsOf(_ buffer: AVAudioPCMBuffer) -> Float {
    let samples = buffer.floatChannelData![0]
    var sum: Float = 0
    for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
    return (sum / Float(buffer.frameLength)).squareRoot()
}

let enhancer = AudioEnhancer()
enhancer.prepare(format: monoFormat)
enhancer.maxGain = 16

var quietRMS: Float = 0
for _ in 0..<40 {
    fill(mono, amplitude: 0.002)
    enhancer.process(mono)
    quietRMS = rmsOf(mono)
}
let quietBefore: Float = 0.002 / 1.414
check(quietRMS > quietBefore * 4, "小声被放大", detail: "before≈\(String(format: "%.4f", quietBefore)) after=\(String(format: "%.4f", quietRMS))")

// 大声音：全新的增强器，不应该放大，也不应该削波
let loudEnhancer = AudioEnhancer()
loudEnhancer.prepare(format: monoFormat)
loudEnhancer.maxGain = 16
var loudRMS: Float = 0
for _ in 0..<40 {
    fill(mono, amplitude: 0.6)
    loudEnhancer.process(mono)
    loudRMS = rmsOf(mono)
}
check(loudRMS < 0.5, "大声不放大不削波", detail: "\(String(format: "%.3f", loudRMS))")

// 从小声突然变大声：前几帧别炸
var transitionPeak: Float = 0
for _ in 0..<20 {
    fill(mono, amplitude: 0.002)
    enhancer.process(mono)
}
for _ in 0..<5 {
    fill(mono, amplitude: 0.6)
    enhancer.process(mono)
    transitionPeak = max(transitionPeak, rmsOf(mono))
}
check(transitionPeak < 0.8, "小声切大声不炸", detail: "\(String(format: "%.3f", transitionPeak))")

var silenceRMS: Float = 0
for _ in 0..<40 {
    fill(mono, amplitude: 0.0002)
    enhancer.process(mono)
    silenceRMS = rmsOf(mono)
}
check(silenceRMS < 0.001, "静音不放大底噪", detail: "\(String(format: "%.5f", silenceRMS))")

print("== 输入设备 ==")
let devices = AudioDeviceManager.inputs()
check(!devices.isEmpty, "能枚举到麦克风", detail: devices.map(\.name).joined(separator: ", "))
print("   当前默认：\(AudioDeviceManager.defaultInputUID() ?? "未知")")
for device in devices { print("   - \(device.name)") }

// MARK: - 4. webhook 推送

print("== webhook 推送 ==")
let clip = try? ClipExporter.save(source, keyword: "test", date: Date(), format: .m4a)
let payload = NotificationPayload(
    keyword: "张伟",
    text: "喂张伟你下来一下",
    date: Date(),
    clipURL: clip,
    clipSeconds: 30,
    matchWay: "同音"
)
let channel = Channel(
    kind: .webhook,
    enabled: true,
    endpoint: "http://127.0.0.1:8765/hook",
    token: "selftest-token",
    chatID: ""
)

let result = await Notifier.broadcast(payload, channels: [channel])
check(result.errors.isEmpty, "webhook 推送成功", detail: result.errors.joined(separator: "; "))
check(result.delivered == ["Webhook"], "返回已投递渠道", detail: result.delivered.joined(separator: ","))

// MARK: - 5. 配置读写

print("== 配置读写 ==")
var config = AppConfig()
config.keywords = ["张伟", "老板"]
config.preRoll = 12
config.channels = [Channel(kind: .bark, enabled: true, endpoint: "", token: "abc", chatID: "")]
ConfigStore.save(config)
let reloaded = ConfigStore.load()
check(reloaded.keywords == ["张伟", "老板"], "关键词持久化")
check(reloaded.preRoll == 12, "窗口参数持久化")
check(reloaded.channels.first?.token == "abc", "渠道参数持久化")
check(reloaded.requiredHistorySeconds >= 22, "缓冲时长 = 前后窗口 + 余量", detail: "\(reloaded.requiredHistorySeconds)")
check(reloaded.matchLevel == .fuzzy, "匹配强度持久化")

// 老配置（只有 fuzzyPinyin 布尔）还能读
let legacyJSON = #"{"keywords":["张伟"],"fuzzyPinyin":false,"preRoll":20}"#.data(using: .utf8)!
if let decoded = try? JSONDecoder().decode(AppConfig.self, from: legacyJSON) {
    check(decoded.matchLevel == .exact, "老配置迁移（关同音 → 严格）")
    check(decoded.keywords == ["张伟"] && decoded.preRoll == 20, "老配置字段不丢")
} else {
    check(false, "老配置迁移", detail: "解码失败")
}

print("")
if failures == 0 {
    print("全部通过 ✅")
} else {
    print("失败 \(failures) 项 ❌")
    exit(1)
}
