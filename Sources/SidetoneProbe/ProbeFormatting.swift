import AudioCore
import Foundation

extension STDevice {
    var probeDescription: String {
        """
        DEVICE id=\(id) name=\(decodeCString(name)) \
        input=\(inputChannels) output=\(outputChannels) rate=\(sampleRate) \
        buffer=\(bufferFrames) range=\(minBufferFrames)...\(maxBufferFrames) \
        uid=\(decodeCString(uid))
        """
    }
}

extension STTelemetry {
    func hasErrors(since previous: Self) -> Bool {
        inputCallbacks <= previous.inputCallbacks || underruns > previous.underruns
            || overruns > previous.overruns || deadlineMisses > previous.deadlineMisses
            || hardwareOverloads > previous.hardwareOverloads
    }

    func probeDescription(cycle: Int, elapsed: Double) -> String {
        String(
            format: """
                RUN cycle=%d time=%.1f rate=%.0f/%.0f frames=%u/%u callbacks=%llu/%llu \
                underruns=%llu overruns=%llu deadlines=%llu clip=%llu \
                input_peak=%.6f output_peak=%.6f estimated_ms=%.3f queue_ms=%.3f \
                callback_max_ms=%.4f dsp_max_ms=%.4f drift_ppm=%.2f restart=%u hardware_overloads=%llu
                """,
            cycle, elapsed, inputRate, outputRate, inputBufferFrames, outputBufferFrames,
            inputCallbacks, outputCallbacks, underruns, overruns, deadlineMisses, clippedSamples,
            peakInput, peakOutput, estimatedLatencyMs, queueLatencyMs, maxCallbackMs, maxDSPMs,
            driftPPM, needsRestart, hardwareOverloads
        )
    }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

private func decodeCString<T>(_ value: T) -> String {
    withUnsafeBytes(of: value) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
}
