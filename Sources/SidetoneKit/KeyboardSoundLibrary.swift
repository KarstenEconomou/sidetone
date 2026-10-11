import AVFoundation
import AudioCore
import Foundation

struct KeyboardSoundLibrary: Sendable {
    struct Sounds: Decodable {
        let down: [String]
        let up: [String]
    }
    struct Pack: Decodable {
        let sounds: [String: Sounds]
    }
    private var keys: [KeyboardSwitch: [[UInt32]]] = [:]
    let sampleRate: Double

    static var resourceURL: URL? {
        Bundle.main.url(forResource: "KeyboardSounds", withExtension: nil)
            ?? Bundle.module.url(forResource: "KeyboardSounds", withExtension: nil)
    }

    init(engine: OpaquePointer, sampleRate: Double = 44_100) throws {
        guard sampleRate.isFinite, (8_000...192_000).contains(sampleRate) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.sampleRate = sampleRate
        guard let root = Self.resourceURL else { throw CocoaError(.fileNoSuchFile) }
        var next: UInt32 = 0
        for type in KeyboardSwitch.allCases {
            let directory = root.appendingPathComponent(type.rawValue)
            let pack = try JSONDecoder().decode(
                Pack.self, from: Data(contentsOf: directory.appendingPathComponent("config.json")))
            let files = Set(pack.sounds.values.flatMap { $0.down + $0.up }).sorted()
            var indices: [String: UInt32] = [:]
            for name in files {
                guard name == (name as NSString).lastPathComponent else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let buffer = try Self.prepareRecording(
                    at: directory.appendingPathComponent(name), sampleRate: sampleRate)
                guard let channels = buffer.floatChannelData,
                    buffer.format.channelCount == 1 || buffer.format.channelCount == 2
                else { throw CocoaError(.fileReadCorruptFile) }
                let frames = Int(buffer.frameLength)
                var stereo = [Float](repeating: 0, count: frames * 2)
                let right = buffer.format.channelCount == 2 ? 1 : 0
                for frame in 0..<frames {
                    stereo[frame * 2] = channels[0][frame]
                    stereo[frame * 2 + 1] = channels[right][frame]
                }
                let result = stereo.withUnsafeBufferPointer {
                    st_keyboard_load_sample(
                        engine, next, $0.baseAddress, buffer.frameLength, buffer.format.sampleRate)
                }
                guard result == 0 else { throw CocoaError(.fileReadCorruptFile) }
                indices[name] = next
                next += 1
            }
            keys[type] = (0..<128).flatMap { code -> [[UInt32]] in
                var name = KeyboardKey.names[UInt16(code)] ?? "default"
                if name == "backspace", pack.sounds[name] == nil { name = "del" }
                if name == "ctrlRight", pack.sounds[name] == nil { name = "ctrlLeft" }
                guard let sounds = pack.sounds[name] ?? pack.sounds["default"] else {
                    return [[], []]
                }
                return [
                    sounds.down.compactMap { indices[$0] }, sounds.up.compactMap { indices[$0] },
                ]
            }
        }
    }

    func choices(for stroke: KeyboardStroke, type: KeyboardSwitch) -> [UInt32] {
        guard stroke.keyCode < 128, let keys = keys[type] else { return [] }
        return keys[Int(stroke.keyCode) * 2 + (stroke.isDown ? 0 : 1)]
    }

    private static func prepareRecording(at url: URL, sampleRate: Double) throws -> AVAudioPCMBuffer
    {
        let file = try AVAudioFile(
            forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.length > 1, file.length <= 960_000,
            let source = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw CocoaError(.fileReadCorruptFile) }
        try file.read(into: source)
        guard source.frameLength > 1, let channels = source.floatChannelData,
            source.format.channelCount == 1 || source.format.channelCount == 2
        else { throw CocoaError(.fileReadCorruptFile) }
        let samples = (0..<Int(source.format.channelCount)).map {
            Array(UnsafeBufferPointer(start: channels[$0], count: Int(source.frameLength)))
        }
        let cleaned = try KeyboardSampleDenoiser(sampleRate: source.format.sampleRate).process(
            samples)
        for channel in cleaned.indices {
            channels[channel].update(from: cleaned[channel], count: cleaned[channel].count)
        }
        return try convert(source, to: sampleRate)
    }

    static func convert(_ input: AVAudioPCMBuffer, to rate: Double) throws -> AVAudioPCMBuffer {
        guard rate.isFinite, (8_000...192_000).contains(rate) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if input.format.sampleRate == rate { return input }
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: rate,
                channels: input.format.channelCount, interleaved: false),
            let converter = AVAudioConverter(from: input.format, to: format),
            let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096),
            let output = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(
                    ceil(Double(input.frameLength) * rate / input.format.sampleRate)) + 4096)
        else { throw CocoaError(.fileReadCorruptFile) }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        let source = SampleConversionInput(buffer: input)
        while true {
            var error: NSError?
            let status = converter.convert(to: chunk, error: &error) { _, state in
                let buffer = source.take()
                state.pointee = buffer == nil ? .endOfStream : .haveData
                return buffer
            }
            guard error == nil, status != .error, status != .inputRanDry,
                output.frameLength + chunk.frameLength <= output.frameCapacity,
                let destination = output.floatChannelData, let samples = chunk.floatChannelData
            else { throw error ?? CocoaError(.fileReadCorruptFile) as NSError }
            for channel in 0..<Int(format.channelCount) {
                destination[channel].advanced(by: Int(output.frameLength)).update(
                    from: samples[channel], count: Int(chunk.frameLength))
            }
            output.frameLength += chunk.frameLength
            if status == .endOfStream { break }
            guard chunk.frameLength > 0 else { throw CocoaError(.fileReadCorruptFile) }
        }
        guard output.frameLength > 1 else { throw CocoaError(.fileReadCorruptFile) }
        return output
    }
}

private final class SampleConversionInput: @unchecked Sendable {
    // A single synchronous conversion owns the buffer until conversion ends.
    private let lock = NSLock()
    private var buffer: AVAudioPCMBuffer?

    init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func take() -> AVAudioPCMBuffer? {
        lock.withLock {
            defer { buffer = nil }
            return buffer
        }
    }
}

struct KeyboardSampleSelector {
    private var previous = [UInt32](repeating: .max, count: 256)

    mutating func select(_ choices: [UInt32], vary: Bool) -> UInt32? {
        guard let first = choices.first, first < previous.count else { return nil }
        let sample: UInt32
        if vary, choices.count > 1 {
            let last = choices.firstIndex(of: previous[Int(first)])
            var index = Int.random(in: 0..<(choices.count - (last == nil ? 0 : 1)))
            if let last, index >= last { index += 1 }
            sample = choices[index]
        } else {
            sample = first
        }
        previous[Int(first)] = sample
        return sample
    }
}
