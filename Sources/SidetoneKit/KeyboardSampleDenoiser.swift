import Accelerate
import Foundation

struct KeyboardSampleDenoiser {
    private enum Tuning {
        static let windowDuration = 0.012
        static let minimumGain: Float = 0.125
        static let noiseMultiplier: Float = 3
        static let quietEnergyRange: Range<Float> = 0.000_01..<0.025
        static let protectedEnergyRatio: Float = 0.25
        static let gainRelease: Float = 0.6
        static let minimumFlatness = 0.01
        static let minimumBandEnergyRatio = 0.0001
        static let noiseBandLimit = 12_000.0
    }

    private struct Spectrum {
        var real: [Float]
        var imaginary: [Float]
    }

    private struct AnalysisFrame {
        let power: [Float]
        let energy: Float
        let activeSamples: Int
    }

    private struct NoiseProfile {
        let power: [Float]
        let peakEnergy: Float
    }

    private let frameLength: Int
    private let hopLength: Int
    private let noiseBand: Range<Int>
    private let window: [Float]
    private let forward: vDSP.DiscreteFourierTransform<Float>
    private let inverse: vDSP.DiscreteFourierTransform<Float>

    init(sampleRate: Double) throws {
        guard sampleRate.isFinite, (8_000...192_000).contains(sampleRate) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let length = 1 << Int(log2(sampleRate * Tuning.windowDuration).rounded())
        frameLength = length
        hopLength = length / 4
        noiseBand =
            1..<min(length / 2, Int(Tuning.noiseBandLimit * Double(length) / sampleRate) + 1)
        window = (0..<length).map { 0.5 - 0.5 * cos(2 * .pi * Float($0) / Float(length)) }
        forward = try vDSP.DiscreteFourierTransform(
            count: length, direction: .forward, transformType: .complexComplex, ofType: Float.self)
        inverse = try vDSP.DiscreteFourierTransform(
            count: length, direction: .inverse, transformType: .complexComplex, ofType: Float.self)
    }

    // The loader calls this before sample-rate conversion and output start.
    func process(_ channels: [[Float]]) throws -> [[Float]] {
        guard (1...2).contains(channels.count), let count = channels.first?.count,
            count <= 960_000,
            channels.allSatisfy({ channel in
                channel.count == count && channel.allSatisfy { $0.isFinite && abs($0) <= 16 }
            })
        else { throw CocoaError(.fileReadCorruptFile) }
        guard count >= frameLength * 3, let profile = noiseProfile(channels) else {
            return channels
        }
        return reconstruct(channels, profile: profile)
    }

    private func noiseProfile(_ channels: [[Float]]) -> NoiseProfile? {
        let count = channels[0].count
        let frames = stride(from: 0, through: count - frameLength, by: hopLength).map { start in
            let power = spectrumPower(channels.map { spectrum($0, start: start) })
            let active = (start..<(start + frameLength)).reduce(0) { count, frame in
                count + (channels.contains { abs($0[frame]) > 0.000_001 } ? 1 : 0)
            }
            return AnalysisFrame(power: power, energy: spectralEnergy(power), activeSamples: active)
        }
        guard let peak = frames.lazy.map(\.energy).max(), peak > 0 else { return nil }
        let quiet = frames.filter {
            $0.activeSamples >= frameLength * 3 / 4
                && Tuning.quietEnergyRange.contains($0.energy / peak)
        }.sorted { $0.energy < $1.energy }.prefix(max(3, frames.count / 5))
        guard quiet.count >= 3 else { return nil }

        var noise = [Float](repeating: 0, count: frameLength / 2 + 1)
        for frame in quiet {
            for bin in noise.indices { noise[bin] += frame.power[bin] / Float(quiet.count) }
        }
        noise = smooth(noise)
        guard hasBroadbandNoise(noise) else { return nil }
        return NoiseProfile(power: noise, peakEnergy: peak)
    }

    private func hasBroadbandNoise(_ power: [Float]) -> Bool {
        let band = power[noiseBand]
        let bandEnergy = band.reduce(0.0) { $0 + Double($1) }
        guard bandEnergy > 0,
            2 * bandEnergy >= Double(spectralEnergy(power)) * Tuning.minimumBandEnergyRatio
        else { return false }
        let mean = bandEnergy / Double(band.count)
        let meanLog =
            band.reduce(0.0) { sum, value in
                sum + log(max(Double(value), Double.leastNormalMagnitude))
            } / Double(band.count)
        // A low geometric-to-arithmetic mean ratio indicates a tonal decay.
        return exp(meanLog) / mean >= Tuning.minimumFlatness
    }

    private func reconstruct(_ channels: [[Float]], profile: NoiseProfile) -> [[Float]] {
        let count = channels[0].count
        var output = channels.map { _ in [Float](repeating: 0, count: count) }
        var weight = [Float](repeating: 0, count: count)
        var previousGain = [Float](repeating: Tuning.minimumGain, count: profile.power.count)
        // Padded edge windows give each sample the full overlap weight.
        for start in stride(from: hopLength - frameLength, to: count, by: hopLength) {
            let spectra = channels.map { spectrum($0, start: start) }
            let power = spectrumPower(spectra)
            let gain = gains(power, profile: profile, previous: previousGain)
            previousGain = gain
            let offsets = max(0, -start)..<min(frameLength, count - start)
            for channel in channels.indices {
                let filtered = filteredSamples(spectra[channel], gain: gain)
                for offset in offsets {
                    output[channel][start + offset] += filtered[offset] * window[offset]
                }
            }
            for offset in offsets {
                weight[start + offset] += window[offset] * window[offset]
            }
        }
        for channel in output.indices {
            for frame in 0..<count { output[channel][frame] /= weight[frame] }
        }
        return output
    }

    private func gains(_ power: [Float], profile: NoiseProfile, previous: [Float]) -> [Float] {
        let transientGain = min(
            1, spectralEnergy(power) / (profile.peakEnergy * Tuning.protectedEnergyRatio))
        let smoothedPower = smooth(power)
        var gain = power.indices.map { bin in
            let residual = max(
                0, 1 - Tuning.noiseMultiplier * profile.power[bin] / max(smoothedPower[bin], 1e-20))
            return max(Tuning.minimumGain, transientGain, sqrt(residual))
        }
        gain = smooth(gain)
        for bin in gain.indices {
            // Gain rises at once for an impact and falls over several windows.
            gain[bin] = max(
                gain[bin], previous[bin] * Tuning.gainRelease + gain[bin] * (1 - Tuning.gainRelease)
            )
        }
        return gain
    }

    private func filteredSamples(_ spectrum: Spectrum, gain: [Float]) -> [Float] {
        var spectrum = spectrum
        for bin in 0..<frameLength {
            let scale = gain[min(bin, frameLength - bin)] / Float(frameLength)
            spectrum.real[bin] *= scale
            spectrum.imaginary[bin] *= scale
        }
        var samples = [Float](repeating: 0, count: frameLength)
        var imaginary = samples
        inverse.transform(
            inputReal: spectrum.real, inputImaginary: spectrum.imaginary,
            outputReal: &samples, outputImaginary: &imaginary)
        return samples
    }

    private func spectrum(_ samples: [Float], start: Int) -> Spectrum {
        let input = (0..<frameLength).map { offset in
            samples.indices.contains(start + offset) ? samples[start + offset] * window[offset] : 0
        }
        let zero = [Float](repeating: 0, count: frameLength)
        var real = zero
        var imaginary = zero
        forward.transform(
            inputReal: input, inputImaginary: zero, outputReal: &real, outputImaginary: &imaginary)
        return Spectrum(real: real, imaginary: imaginary)
    }

    private func spectrumPower(_ spectra: [Spectrum]) -> [Float] {
        (0...frameLength / 2).map { bin in
            spectra.reduce(Float(0)) { sum, spectrum in
                sum + spectrum.real[bin] * spectrum.real[bin]
                    + spectrum.imaginary[bin] * spectrum.imaginary[bin]
            } / Float(spectra.count)
        }
    }

    private func spectralEnergy(_ power: [Float]) -> Float {
        // Only DC and Nyquist lack a separate conjugate bin.
        2 * power.reduce(0, +) - power[0] - power[power.count - 1]
    }

    private func smooth(_ values: [Float]) -> [Float] {
        values.indices.map { index in
            (values[max(0, index - 1)] + 2 * values[index]
                + values[min(values.count - 1, index + 1)]) * 0.25
        }
    }
}
