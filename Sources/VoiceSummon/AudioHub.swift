import AVFoundation
import Foundation


/// 远场增强：二阶高通去低频轰鸣 + 自适应噪声底 + 自动增益。
///
/// 只在音频线程调用，不需要锁。思路是：
/// - 跟踪房间底噪（只往下跟，避免把噪声当成信号抬上去）；
/// - 判断这一段像不像语音（RMS 明显高于底噪）；
/// - 像语音就把电平推到识别器最舒服的区间（-26dBFS 左右），最多 24dB；
/// - 不像语音就回到 1 倍，别把空调声放大成噪音。
final class AudioEnhancer {
    var isEnabled = true
    /// 最大放大倍数，默认 +24dB。
    var maxGain: Float = 16

    private var gain: Float = 1
    private var noiseFloor: Float = 0.0003
    private var sampleRate: Double = 48_000
    private var targetRMS: Float = 0.06

    // 二阶高通（RBJ butterworth）状态
    private var b0: Float = 1, b1: Float = 0, b2: Float = 0
    private var a1: Float = 0, a2: Float = 0
    private var x1: [Float] = [], x2: [Float] = []
    private var y1: [Float] = [], y2: [Float] = []

    func prepare(format: AVAudioFormat) {
        sampleRate = format.sampleRate
        let channels = max(Int(format.channelCount), 1)
        x1 = Array(repeating: 0, count: channels)
        x2 = x1
        y1 = x1
        y2 = x1
        configureHighPass(cutoff: 140)
    }

    private func configureHighPass(cutoff: Double) {
        let q = 0.707
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let cosw = cos(w0)
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        b0 = Float((1 + cosw) / 2 / a0)
        b1 = Float(-(1 + cosw) / a0)
        b2 = b0
        a1 = Float(-2 * cosw / a0)
        a2 = Float((1 - alpha) / a0)
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard isEnabled, let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0, channels <= x1.count else { return }

        var sum: Float = 0
        var peak: Float = 0
        for channel in 0..<channels {
            let samples = data[channel]
            for index in 0..<frames {
                let value = samples[index]
                sum += value * value
                let magnitude = abs(value)
                if magnitude > peak { peak = magnitude }
            }
        }
        let rms = (sum / Float(frames * channels)).squareRoot()

        // 底噪跟踪：变安静时跟得快，变吵时跟得很慢（别把持续的噪声学成底噪）
        if rms < noiseFloor {
            noiseFloor = noiseFloor * 0.95 + rms * 0.05
        } else {
            noiseFloor = noiseFloor * 0.9995 + rms * 0.0005
        }
        noiseFloor = min(max(noiseFloor, 0.00015), 0.02)

        // 只要比底噪高 1.5 倍就算「可能有人在说话」，3 米外的小声也够得着
        let isSpeech = rms > max(noiseFloor * 1.5, 0.0004)
        let desired: Float = (isSpeech && rms > 1e-5)
            ? min(maxGain, max(1, targetRMS / rms))
            : 1

        // 降增益要快（有人突然大声，别削波），升增益中速（别把底噪抽上来）
        let rate: Float = desired < gain ? 0.5 : 0.2
        gain += (desired - gain) * rate

        // 瞬时保护：这一帧的峰值决定最多能乘多少，绝不削波
        let safeGain = min(gain, 0.95 / max(peak, 1e-6))

        for channel in 0..<channels {
            let samples = data[channel]
            var px1 = x1[channel], px2 = x2[channel]
            var py1 = y1[channel], py2 = y2[channel]
            for index in 0..<frames {
                let x = samples[index]
                let y = b0 * x + b1 * px1 + b2 * px2 - a1 * py1 - a2 * py2
                px2 = px1; px1 = x
                py2 = py1; py1 = y
                let amplified = y * safeGain
                samples[index] = max(-0.98, min(0.98, amplified))
            }
            x1[channel] = px1; x2[channel] = px2
            y1[channel] = py1; y2[channel] = py2
        }
    }

    var currentGain: Float { gain }
}

/// 麦克风采集 + 滚动环形缓冲。
///
/// 设计要点：
/// - tap 回调在音频线程，所有共享状态用 NSLock 保护，保证主线程随时可以切片。
/// - 缓冲按「帧位置」索引，不用墙钟时间，命中时刻和切片区间天然对齐。
/// - 每块 buffer 拷贝一份，避免音频线程复用底层内存导致数据被覆盖。
final class AudioHub {
    enum AudioError: LocalizedError {
        case noInputDevice
        case engineStartFailed(String)

        var errorDescription: String? {
            switch self {
            case .noInputDevice: return "没有可用的麦克风输入"
            case .engineStartFailed(let reason): return "音频引擎启动失败：\(reason)"
            }
        }
    }

    private struct Chunk {
        let start: AVAudioFramePosition
        let buffer: AVAudioPCMBuffer
    }

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var chunks: [Chunk] = []
    private var head = 0
    private var framesWritten: AVAudioFramePosition = 0
    private var capacityFrames: AVAudioFramePosition = 0
    private var sourceFormat: AVAudioFormat?
    private var tapInstalled = false
    private var historySeconds: Double = 30
    private let enhancer = AudioEnhancer()
    var farFieldBoost = true {
        didSet { enhancer.isEnabled = farFieldBoost }
    }
    var maxBoostDB: Double = 24 {
        didSet { enhancer.maxGain = Float(pow(10, maxBoostDB / 20)) }
    }
    /// 当前实际放大倍数，界面上显示用。
    var enhancerGain: Float { enhancer.currentGain }
    private var lastLevelSent = Date.distantPast
    private var configurationObserver: NSObjectProtocol?
    private var lastRebuild = Date.distantPast

    /// 每来一块音频回调一次（音频线程）。识别器在这里 append。
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// 电平表，0...1。已在音频线程节流到约 12Hz。
    var onLevel: ((Float) -> Void)?
    /// 设备插拔/切换导致链路重建失败时的提示。
    var onError: ((String) -> Void)?

    var isRunning: Bool { engine.isRunning }
    var format: AVAudioFormat? { sourceFormat }

    /// 当前已经写入了多少帧（命中时记下这个值当锚点）。
    var currentFrame: AVAudioFramePosition {
        lock.lock()
        defer { lock.unlock() }
        return framesWritten
    }

    var bufferedSeconds: Double {
        lock.lock()
        defer { lock.unlock() }
        guard let format, format.sampleRate > 0 else { return 0 }
        return Double(framesWritten - (chunks[safe: head]?.start ?? framesWritten)) / format.sampleRate
    }

    func start(historySeconds: Double, deviceUID: String? = nil) throws {
        guard !engine.isRunning else { return }

        if let uid = deviceUID, !uid.isEmpty, AudioDeviceManager.defaultInputUID() != uid {
            AudioDeviceManager.setDefaultInput(uid: uid)
            // 系统切换输入设备是异步的，给它一点时间再读格式
            usleep(300_000)
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioError.noInputDevice
        }
        guard format.commonFormat == .pcmFormatFloat32 else {
            throw AudioError.engineStartFailed("不支持的采样格式 \(format.commonFormat.rawValue)")
        }

        sourceFormat = format
        enhancer.prepare(format: format)
        enhancer.isEnabled = farFieldBoost
        enhancer.maxGain = Float(pow(10, maxBoostDB / 20))
        self.historySeconds = historySeconds
        observeConfigurationChanges()
        lock.lock()
        capacityFrames = AVAudioFramePosition(historySeconds * format.sampleRate)
        chunks.removeAll(keepingCapacity: true)
        head = 0
        framesWritten = 0
        lock.unlock()

        if tapInstalled {
            input.removeTap(onBus: 0)
            tapInstalled = false
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.ingest(buffer)
        }
        tapInstalled = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            throw AudioError.engineStartFailed(error.localizedDescription)
        }
        Log.info("音频采集启动：\(Int(format.sampleRate))Hz / \(format.channelCount)ch，缓冲 \(Int(historySeconds))s")
    }

    func stop() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning { engine.stop() }
        lock.lock()
        chunks.removeAll(keepingCapacity: false)
        head = 0
        framesWritten = 0
        lock.unlock()
        onLevel?(0)
    }

    // MARK: - 写入

    private func ingest(_ buffer: AVAudioPCMBuffer) {
        guard let copy = buffer.detachedCopy() else { return }

        // 远场增强在拷贝上做：存进缓冲的和送去识别的都是增强后的音频。
        enhancer.process(copy)

        lock.lock()
        chunks.append(Chunk(start: framesWritten, buffer: copy))
        framesWritten += AVAudioFramePosition(copy.frameLength)
        while head < chunks.count - 1, framesWritten - chunks[head].start > capacityFrames {
            head += 1
        }
        if head > 64 {
            chunks.removeFirst(head)
            head = 0
        }
        lock.unlock()

        onBuffer?(copy)

        let now = Date()
        if now.timeIntervalSince(lastLevelSent) > 0.08 {
            lastLevelSent = now
            onLevel?(AudioHub.rms(of: copy))
        }
    }

    // MARK: - 切片

    /// 取出 [startFrame, endFrame) 区间的音频，返回源采样格式的连续 buffer。
    /// 区间超出缓冲范围时自动夹到可用范围内。
    func extract(from startFrame: AVAudioFramePosition, to endFrame: AVAudioFramePosition) -> AVAudioPCMBuffer? {
        guard let format = sourceFormat else { return nil }

        lock.lock()
        defer { lock.unlock() }

        guard let oldest = chunks[safe: head]?.start, endFrame > startFrame else { return nil }
        let start = max(startFrame, oldest)
        let end = min(endFrame, framesWritten)
        guard end > start else { return nil }

        let total = AVAudioFrameCount(end - start)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total) else { return nil }

        var cursor = start
        var written: AVAudioFrameCount = 0
        var index = head
        while index < chunks.count, cursor < end {
            let chunk = chunks[index]
            defer { index += 1 }

            let chunkEnd = chunk.start + AVAudioFramePosition(chunk.buffer.frameLength)
            if chunkEnd <= cursor { continue }

            let localStart = AVAudioFrameCount(cursor - chunk.start)
            let need = AVAudioFrameCount(end - cursor)
            let count = min(chunk.buffer.frameLength - localStart, need)
            guard count > 0 else { continue }

            copy(from: chunk.buffer, offset: localStart, count: count, into: output, at: written)
            written += count
            cursor += AVAudioFramePosition(count)
        }

        guard written > 0 else { return nil }
        output.frameLength = written
        return output
    }

    private func copy(from source: AVAudioPCMBuffer,
                      offset: AVAudioFrameCount,
                      count: AVAudioFrameCount,
                      into destination: AVAudioPCMBuffer,
                      at destOffset: AVAudioFrameCount) {
        guard let src = source.floatChannelData, let dst = destination.floatChannelData else { return }
        let channels = Int(source.format.channelCount)
        let bytes = Int(count) * MemoryLayout<Float>.size

        if source.format.isInterleaved {
            memcpy(dst[0].advanced(by: Int(destOffset) * channels),
                   src[0].advanced(by: Int(offset) * channels),
                   bytes * channels)
        } else {
            for channel in 0..<channels {
                memcpy(dst[channel].advanced(by: Int(destOffset)),
                       src[channel].advanced(by: Int(offset)),
                       bytes)
            }
        }
    }

    /// 插拔耳机、切换输入设备会让 engine 失效，这里自动重建采集链路。
    private func observeConfigurationChanges() {
        guard configurationObserver == nil else { return }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let now = Date()
            guard now.timeIntervalSince(self.lastRebuild) > 1.5 else { return }
            self.lastRebuild = now

            Log.warn("音频设备发生变化，重建采集链路")
            let seconds = self.historySeconds
            self.stop()
            do {
                try self.start(historySeconds: seconds)
            } catch {
                Log.error("重建采集失败：\(error.localizedDescription)")
                self.onError?("音频设备切换后重建失败：\(error.localizedDescription)")
            }
        }
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return 0 }

        var sum: Float = 0
        for channel in 0..<channels {
            let samples = data[channel]
            for index in 0..<frames {
                let value = samples[index]
                sum += value * value
            }
        }
        let mean = sum / Float(frames * channels)
        return min(1, (mean.squareRoot()) * 8)
    }
}

extension AVAudioPCMBuffer {
    /// 深拷贝一份独立的 buffer（共享不了底层内存）。
    func detachedCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength

        let channels = Int(format.channelCount)
        let frames = Int(frameLength)

        if let source = floatChannelData, let destination = copy.floatChannelData {
            if format.isInterleaved {
                memcpy(destination[0], source[0], frames * channels * MemoryLayout<Float>.size)
            } else {
                for channel in 0..<channels {
                    memcpy(destination[channel], source[channel], frames * MemoryLayout<Float>.size)
                }
            }
            return copy
        }

        if let source = int16ChannelData, let destination = copy.int16ChannelData {
            if format.isInterleaved {
                memcpy(destination[0], source[0], frames * channels * MemoryLayout<Int16>.size)
            } else {
                for channel in 0..<channels {
                    memcpy(destination[channel], source[channel], frames * MemoryLayout<Int16>.size)
                }
            }
            return copy
        }

        return nil
    }
}

/// 输入设备列表/切换。切换走系统默认输入，切完需要重启采集。
enum AudioDeviceManager {
    struct Device: Identifiable, Hashable {
        let id: AudioDeviceID
        let name: String
        let uid: String
    }

    static func inputs() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids.compactMap { id in
            guard inputChannels(of: id) > 0,
                  let name = stringProperty(id, kAudioObjectPropertyName),
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return Device(id: id, name: name, uid: uid)
        }
    }

    static func defaultInputUID() -> String? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr else {
            return nil
        }
        return inputs().first(where: { $0.id == deviceID })?.uid
    }

    @discardableResult
    static func setDefaultInput(uid: String) -> Bool {
        guard let device = inputs().first(where: { $0.uid == uid }) else { return false }
        var deviceID = device.id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &deviceID)
        if status == noErr { Log.info("输入设备切换为：\(device.name)") }
        return status == noErr
    }

    private static func inputChannels(of device: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}
