import AudioCore
import AVFoundation
import Foundation

func fixedString<T>(_ value: T) -> String {
    withUnsafeBytes(of: value) { bytes in
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
}

@main struct Probe {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--help") {
            print("""
            SidetoneProbe [--run --input ID --output ID] [--seconds 10] [--cycles 1]
                          [--frames 64] [--gain -60] [--profiles] [--log PATH]
            With no arguments, list devices. --run captures the microphone and plays it
            through the selected output. Gain is limited to -60 through -12 dB.
            Audio is never saved. --log saves only numeric diagnostic values.
            """)
            return
        }
        func option(_ name: String) -> String? {
            guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
            return args[index + 1]
        }
        let logURL = option("--log").map { URL(fileURLWithPath: $0) }
        func report(_ line: String) {
            print(line)
            if let logURL {
                let data = Data((line + "\n").utf8)
                if !FileManager.default.fileExists(atPath: logURL.path) {
                    _ = FileManager.default.createFile(atPath: logURL.path, contents: nil)
                }
                if let file = try? FileHandle(forWritingTo: logURL) {
                    defer { try? file.close() }
                    _ = try? file.seekToEnd()
                    try? file.write(contentsOf: data)
                }
            }
        }
        var devices = [STDevice](repeating: STDevice(), count: 128)
        let count = devices.withUnsafeMutableBufferPointer { st_devices($0.baseAddress, UInt32($0.count)) }
        devices = Array(devices.prefix(Int(min(count, 128))))
        for device in devices {
            report("DEVICE id=\(device.id) name=\(fixedString(device.name)) input=\(device.inputChannels) output=\(device.outputChannels) rate=\(device.sampleRate) buffer=\(device.bufferFrames) range=\(device.minBufferFrames)...\(device.maxBufferFrames) uid=\(fixedString(device.uid))")
        }
        guard args.contains("--run") else { return }
        guard let input = option("--input").flatMap(UInt32.init),
              let output = option("--output").flatMap(UInt32.init),
              devices.contains(where: { $0.id == input && $0.inputChannels > 0 }),
              devices.contains(where: { $0.id == output && $0.outputChannels > 0 }) else {
            report("ERROR: Supply --input ID and --output ID from the device list.")
            exit(2)
        }
        let permitted = await AVCaptureDevice.requestAccess(for: .audio)
        guard permitted else { report("ERROR: Microphone permission is denied."); exit(3) }
        guard let engine = st_engine_create() else { report("ERROR: Cannot create the engine."); exit(4) }
        defer { st_engine_destroy(engine) }
        let seconds = min(max(Double(option("--seconds") ?? "10") ?? 10, 1), 86400)
        let cycles = min(max(Int(option("--cycles") ?? "1") ?? 1, 1), 1000)
        let frames = UInt32(option("--frames") ?? "64") ?? 64
        let gain = min(max(Float(option("--gain") ?? "-60") ?? -60, -60), -12)
        let selectedInput = devices.first { $0.id == input }!
        let selectedOutput = devices.first { $0.id == output }!
        let identity = STRouteIdentity(inputUID: selectedInput.uid, outputUID: selectedOutput.uid,
                                       outputDataSource: selectedOutput.outputDataSource,
                                       outputJackState: selectedOutput.outputJackState)
        var parameters = STParameters(gainDB: gain, profile: 0, highPassHz: 80,
                                     eqFrequencyHz: 2200, eqGainDB: 0, eqQ: 0.7, compression: 0)
        st_engine_set_parameters(engine, parameters)
        var failed = false
        for cycle in 1...cycles {
            let config = STConfiguration(inputDevice: input, outputDevice: output,
                                         inputChannel: 0, bufferFrames: frames)
            guard st_engine_start_checked(engine, config, identity) == 0 else {
                report("ERROR: \(String(cString: st_engine_error(engine)))")
                failed = true
                break
            }
            let start = Date()
            var previous = STTelemetry()
            repeat {
                // Only the control task waits. Audio callbacks run on Core Audio threads.
                try? await Task.sleep(for: .seconds(min(1, seconds)))
                let value = st_engine_telemetry(engine)
                report(String(format: "RUN cycle=%d time=%.1f rate=%.0f/%.0f frames=%u/%u callbacks=%llu/%llu underruns=%llu overruns=%llu deadlines=%llu clip=%llu input_peak=%.6f output_peak=%.6f estimated_ms=%.3f queue_ms=%.3f callback_max_ms=%.4f dsp_max_ms=%.4f drift_ppm=%.2f restart=%u hardware_overloads=%llu", cycle, Date().timeIntervalSince(start), value.inputRate, value.outputRate, value.inputBufferFrames, value.outputBufferFrames, value.inputCallbacks, value.outputCallbacks, value.underruns, value.overruns, value.deadlineMisses, value.clippedSamples, value.peakInput, value.peakOutput, value.estimatedLatencyMs, value.queueLatencyMs, value.maxCallbackMs, value.maxDSPMs, value.driftPPM, value.needsRestart, value.hardwareOverloads))
                if value.outputCallbacks <= previous.outputCallbacks || value.needsRestart != 0 {
                    failed = true
                }
                if Date().timeIntervalSince(start) > 2 &&
                    (value.inputCallbacks <= previous.inputCallbacks ||
                     value.underruns > previous.underruns || value.overruns > previous.overruns ||
                     value.deadlineMisses > previous.deadlineMisses || value.hardwareOverloads > previous.hardwareOverloads) {
                    failed = true
                }
                previous = value
                if args.contains("--profiles") {
                    parameters.profile = UInt32(Int(Date().timeIntervalSince(start)) % 3)
                    parameters.compression = parameters.profile == 2 ? 1 : 0
                    st_engine_set_parameters(engine, parameters)
                }
            } while Date().timeIntervalSince(start) < seconds
            st_engine_stop(engine)
            if st_engine_telemetry(engine).running != 0 { failed = true }
        }
        report(failed ? "FAIL: Inspect the diagnostic log." : "PASS: Audio callbacks and repeated start/stop completed.")
        if failed { exit(5) }
    }
}
