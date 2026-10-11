import AVFoundation
import Foundation
import Testing

@testable import SidetoneKit

@Suite("Keyboard recording noise reduction")
struct KeyboardSampleDenoiserTests {
    @Test(arguments: [8_000.0, 44_100, 48_000, 192_000])
    func reducesHissAndKeepsTheImpact(sampleRate: Double) throws {
        let count = Int(sampleRate * 0.25)
        let impact = Int(sampleRate * 0.08)
        let decay = sampleRate * 0.006
        var state: UInt32 = 1
        let noisy: [Float] = (0..<count).map { frame in
            state = state &* 1_664_525 &+ 1_013_904_223
            let noise = (Float(state >> 8) / Float(1 << 24) * 2 - 1) * 0.006
            let time = Double(frame - impact)
            let key: Double =
                time >= 0
                ? 0.6 * exp(-time / decay) * cos(2 * .pi * 1800 * time / sampleRate) : 0
            return Float(key) + noise
        }
        let result = try KeyboardSampleDenoiser(sampleRate: sampleRate).process([noisy])[0]
        #expect(result.count == noisy.count)
        #expect(result.allSatisfy { $0.isFinite })
        let tail = Int(sampleRate * 0.18)..<count
        #expect(energy(result, in: tail) < energy(noisy, in: tail) * 0.1)
        let attack = impact..<(impact + Int(sampleRate * 0.005))
        let difference = zip(result, noisy).map(-)
        #expect(energy(difference, in: attack) < energy(noisy, in: attack) * 0.001)
        let originalPeak = try #require(noisy.indices.max { abs(noisy[$0]) < abs(noisy[$1]) })
        let filteredPeak = try #require(result.indices.max { abs(result[$0]) < abs(result[$1]) })
        #expect(abs(filteredPeak - originalPeak) <= 1)
    }

    @Test func preservesShortSoundsSilenceAndSoundsWithoutAQuietSection() throws {
        let filter = try KeyboardSampleDenoiser(sampleRate: 44_100)
        let short = (0..<626).map { Float(sin(Double($0) * 0.3)) * 0.2 }
        let silence = [Float](repeating: 0, count: 4410)
        let sustained = (0..<4410).map { Float(sin(Double($0) * 0.3)) * 0.2 }
        for input in [short, silence, sustained, []] {
            #expect(try filter.process([input]) == [input])
        }
    }

    @Test(arguments: [8_000.0, 44_100, 48_000, 192_000], [200.0, 2000, 18_000])
    func preservesCleanResonantDecays(sampleRate: Double, frequency: Double) throws {
        let frequency = min(frequency, sampleRate * 0.4)
        let samples = (0..<Int(sampleRate * 0.25)).map { frame -> Float in
            let time = Double(frame) / sampleRate - 0.02
            return time < 0 ? 0 : Float(0.5 * exp(-time / 0.025) * cos(2 * .pi * frequency * time))
        }
        let result = try KeyboardSampleDenoiser(sampleRate: sampleRate).process([samples])
        let unchanged = result == [samples]
        #expect(unchanged)
    }

    @Test func rejectsInvalidSamplesBeforeFiltering() throws {
        let filter = try KeyboardSampleDenoiser(sampleRate: 44_100)
        for invalid: Float in [.nan, .infinity, -.infinity, 17, .greatestFiniteMagnitude] {
            var samples = [Float](repeating: 0, count: 4410)
            samples[1000] = invalid
            #expect(throws: CocoaError.self) { try filter.process([samples]) }
        }
        for invalid: [[Float]] in [[], [[0], []], [[0], [0], [0]]] {
            #expect(throws: CocoaError.self) { try filter.process(invalid) }
        }
    }

    @Test func usesOneGainForBothStereoChannels() throws {
        let samples = try recording(pack: "holy_panda", file: "201.wav")
        let stereo = [samples, samples.map { -$0 * 0.5 }]
        let result = try KeyboardSampleDenoiser(sampleRate: 44_100).process(stereo)
        #expect(result.count == 2)
        #expect(result[0].count == samples.count)
        #expect(zip(result[0], result[1]).allSatisfy { abs($0 * 0.5 + $1) < 0.000_001 })
    }

    @Test(arguments: [("topre", "1.wav"), ("holy_panda", "201.wav")])
    func reducesHissInBundledRecordings(pack: String, file: String) throws {
        let samples = try recording(pack: pack, file: file)
        let result = try KeyboardSampleDenoiser(sampleRate: 44_100).process([samples])[0]
        let tail = samples.count * 3 / 4..<samples.count
        // First differences measure high-frequency noise in the recording tail.
        func difference(_ input: [Float]) -> [Float] {
            [0] + zip(input.dropFirst(), input).map(-)
        }
        #expect(energy(difference(result), in: tail) < energy(difference(samples), in: tail) * 0.35)
        let peak = try #require(samples.indices.max { abs(samples[$0]) < abs(samples[$1]) })
        #expect(abs(result[peak] - samples[peak]) < abs(samples[peak]) * 0.02)
    }

    private func energy(_ samples: [Float], in range: Range<Int>) -> Double {
        range.reduce(0) { $0 + Double(samples[$1]) * Double(samples[$1]) }
    }

    private func recording(pack: String, file: String) throws -> [Float] {
        let root = try #require(KeyboardSoundLibrary.resourceURL)
        let file = try AVAudioFile(
            forReading: root.appendingPathComponent(pack).appendingPathComponent(file),
            commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(
            AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = try #require(buffer.floatChannelData?[0])
        return Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
    }
}
