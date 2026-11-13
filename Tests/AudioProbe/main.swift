import AVFoundation
import Foundation

// 真实麦克风链路自检：启动采集 → 滚动缓冲 → 命中锚点切片 → 转码落盘。

let hub = AudioHub()
var levelSamples: [Float] = []
var bufferCount = 0
let lock = NSLock()

hub.onBuffer = { _ in
    lock.lock()
    bufferCount += 1
    lock.unlock()
}
hub.onLevel = { level in
    lock.lock()
    levelSamples.append(level)
    lock.unlock()
}
hub.onError = { print("hub error: \($0)") }

do {
    try hub.start(historySeconds: 12)
} catch {
    print("❌ 启动失败：\(error.localizedDescription)")
    exit(1)
}

guard let format = hub.format else {
    print("❌ 拿不到输入格式")
    exit(1)
}
print("✅ 采集启动：\(Int(format.sampleRate))Hz / \(format.channelCount)ch、interleaved=\(format.isInterleaved)")

Thread.sleep(forTimeInterval: 4)

let buffered = hub.bufferedSeconds
let anchor = hub.currentFrame
print("缓冲时长：\(String(format: "%.2f", buffered))s，锚点帧：\(anchor)")
print("远场增益：×\(String(format: "%.1f", hub.enhancerGain))")

Thread.sleep(forTimeInterval: 1.2)

let sampleRate = format.sampleRate
let pre = Double(sampleRate) * 2.0
let post = Double(sampleRate) * 1.0
guard let clip = hub.extract(from: anchor - AVAudioFramePosition(pre), to: anchor + AVAudioFramePosition(post)) else {
    print("❌ 切片为空")
    exit(1)
}
print("✅ 切片：\(clip.frameLength) 帧 / 期望 \(Int(pre + post)) 帧")

do {
    let url = try ClipExporter.save(clip, keyword: "麦克风自检", date: Date(), format: .m4a)
    let file = try AVAudioFile(forReading: url)
    let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int) ?? 0
    print("✅ 落盘：\(url.path)")
    print("   \(String(format: "%.2f", Double(file.length) / 16_000))s / \(size) bytes")

    // 把切出来的音频能量算一下，确认不是纯静音（环境安静时可能接近 0，属于正常）
    let readBack = try AVAudioFile(forReading: url)
    let buffer = AVAudioPCMBuffer(pcmFormat: readBack.processingFormat, frameCapacity: AVAudioFrameCount(readBack.length))!
    try readBack.read(into: buffer)
    var peak: Float = 0
    if let data = buffer.floatChannelData?[0] {
        for index in 0..<Int(buffer.frameLength) {
            peak = max(peak, abs(data[index]))
        }
    }
    print("   峰值：\(String(format: "%.4f", peak))（房间安静时接近 0 是正常的）")
} catch {
    print("❌ 落盘失败：\(error.localizedDescription)")
    exit(1)
}

lock.lock()
let count = bufferCount
let levels = levelSamples
lock.unlock()

print("回调次数：\(count)，电平样本：\(levels.count)，最大电平：\(String(format: "%.3f", levels.max() ?? 0))")

print("结束时增益：×\(String(format: "%.1f", hub.enhancerGain))")
hub.stop()
print(count > 10 ? "✅ 音频链路通过" : "❌ 回调太少，采集可能没工作")
