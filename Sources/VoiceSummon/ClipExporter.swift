import AVFoundation
import Foundation

/// 把环形缓冲里切出来的原始音频统一转成 16k 单声道，落盘成 m4a / wav。
enum ClipExporter {
    enum ExportError: LocalizedError {
        case emptyAudio
        case conversionFailed
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .emptyAudio: return "裁切到的音频是空的"
            case .conversionFailed: return "音频重采样失败"
            case .writeFailed(let reason): return "音频写入失败：\(reason)"
            }
        }
    }

    /// 语音场景 16k 单声道足够，体积只有原始 48k 双声道的约 1/6。
    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    static func save(_ source: AVAudioPCMBuffer,
                     keyword: String,
                     date: Date,
                     format: ClipFormat) throws -> URL {
        let audio = try convert(source, to: targetFormat)
        let directory = Paths.clipsDir.appendingPathComponent(dayFolder(for: date), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let safeKeyword = keyword
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = "\(date.fileStamp)-\(safeKeyword.isEmpty ? "hit" : safeKeyword)"
        let url = directory.appendingPathComponent("\(base).\(format.fileExtension)")

        if format == .m4a {
            do {
                try write(audio, to: url, format: .m4a)
                return url
            } catch {
                Log.warn("m4a 写入失败，回退 wav：\(error.localizedDescription)")
                let wavURL = directory.appendingPathComponent("\(base).wav")
                try write(audio, to: wavURL, format: .wav)
                return wavURL
            }
        }

        try write(audio, to: url, format: .wav)
        return url
    }

    static func convert(_ input: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let source = input.format
        if source.sampleRate == format.sampleRate,
           source.channelCount == format.channelCount,
           source.commonFormat == format.commonFormat,
           source.isInterleaved == format.isInterleaved {
            return input
        }

        guard let converter = AVAudioConverter(from: source, to: format) else {
            throw ExportError.conversionFailed
        }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue

        let ratio = format.sampleRate / source.sampleRate
        let frames = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up))
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames + 4096) else {
            throw ExportError.conversionFailed
        }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if supplied {
                outStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }

        if let conversionError {
            throw ExportError.writeFailed(conversionError.localizedDescription)
        }
        if status == .error {
            throw ExportError.conversionFailed
        }
        guard output.frameLength > 0 else { throw ExportError.emptyAudio }
        return output
    }

    private static func write(_ buffer: AVAudioPCMBuffer, to url: URL, format: ClipFormat) throws {
        try? FileManager.default.removeItem(at: url)

        var settings: [String: Any]
        switch format {
        case .wav:
            settings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: targetFormat.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
        case .m4a:
            settings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: targetFormat.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 48_000
            ]
        }

        let file = try AVAudioFile(forWriting: url,
                                   settings: settings,
                                   commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        try file.write(from: buffer)
    }

    private static func dayFolder(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// 清理超过保留天数的录音目录。
    static func cleanup(keepDays: Int) {
        guard keepDays > 0 else { return }
        let calendar = Calendar.current
        guard let cutoff = calendar.date(byAdding: .day, value: -keepDays, to: Date()) else { return }
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: Paths.clipsDir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }

        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory == true else { continue }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            guard let day = formatter.date(from: entry.lastPathComponent) else { continue }
            if day < cutoff {
                try? manager.removeItem(at: entry)
                Log.info("清理旧录音目录：\(entry.lastPathComponent)")
            }
        }
    }
}
