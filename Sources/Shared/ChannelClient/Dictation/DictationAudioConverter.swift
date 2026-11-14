import AVFoundation
import Speech

/// Converts captured or recorded buffers to the analyzer's format and measures their level.
final class DictationAudioConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let format: AVAudioFormat

    init(from source: AVAudioFormat, to format: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: source, to: format) else {
            throw DictationError.unsupportedAudioFormat
        }
        self.converter = converter
        self.format = format
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> DictationAudioEvent? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        let supplied = SuppliedFlag()
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied.value {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied.value = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return .audio(AnalyzerInput(buffer: output), level: Self.level(of: buffer))
    }

    /// Maps the buffer's RMS from -50...-10 dBFS onto 0...1.
    static func level(of buffer: AVAudioPCMBuffer) -> Double {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var sum: Float = 0
        if let channels = buffer.floatChannelData {
            for index in 0..<frames { sum += channels[0][index] * channels[0][index] }
        } else if let channels = buffer.int16ChannelData {
            for index in 0..<frames {
                let sample = Float(channels[0][index]) / Float(Int16.max)
                sum += sample * sample
            }
        } else {
            return 0
        }
        let rms = (sum / Float(frames)).squareRoot()
        let decibels = 20 * log10(max(rms, 0.000_01))
        return Double(min(max((decibels + 50) / 40, 0), 1))
    }

    private final class SuppliedFlag: @unchecked Sendable { var value = false }
}
