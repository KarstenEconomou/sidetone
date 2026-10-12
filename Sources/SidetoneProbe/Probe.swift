import AVFoundation
import AudioCore
import Foundation

@main
struct Probe {
    static func main() async {
        let options: ProbeOptions
        let log: FileHandle?
        do {
            options = try ProbeOptions(arguments: Array(CommandLine.arguments.dropFirst()))
            if options.help {
                print(
                    """
                    SidetoneProbe [--run --input ID --output ID] [--seconds 10] [--cycles 1]
                                  [--frames 64] [--gain -60] [--profiles] [--suppression] [--log PATH]
                    With no arguments, list devices. --run captures the microphone and plays it
                    through the selected output. Gain is limited to -60 through -12 dB.
                    Audio is never saved. --log saves only numeric diagnostic values.
                    """)
                return
            }
            log = try openLog(path: options.logPath)
        } catch {
            print("ERROR: \(error.localizedDescription)")
            exit(2)
        }
        defer { try? log?.close() }
        func report(_ line: String) {
            print(line)
            try? log?.write(contentsOf: Data((line + "\n").utf8))
        }
        let devices = availableDevices()
        for device in devices { report(device.probeDescription) }
        guard options.run else { return }
        guard let inputID = options.inputID, let outputID = options.outputID,
            let input = devices.first(where: { $0.id == inputID && $0.inputChannels > 0 }),
            let output = devices.first(where: { $0.id == outputID && $0.outputChannels > 0 })
        else {
            report("ERROR: Supply --input ID and --output ID from the device list.")
            exit(2)
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            report("ERROR: Microphone permission is denied.")
            exit(3)
        }
        guard let engine = st_engine_create() else {
            report("ERROR: Cannot create the engine.")
            exit(4)
        }
        defer { st_engine_destroy(engine) }
        let identity = STRouteIdentity(
            inputUID: input.uid, outputUID: output.uid,
            outputDataSource: output.outputDataSource,
            outputJackState: output.outputJackState,
            outputLeftChannel: output.outputLeftChannel,
            outputRightChannel: output.outputRightChannel)
        let configuration = STConfiguration(
            inputDevice: input.id, outputDevice: output.id,
            inputChannel: 0, bufferFrames: options.frames)
        var parameters = STParameters(
            gainDB: options.gainDB, profile: 0, highPassHz: 80,
            eqFrequencyHz: 2200, eqGainDB: 0, eqQ: 0.7, compression: 0,
            noiseSuppression: options.suppression ? 1 : 0, suppressionStrength: 0.85)
        st_engine_set_parameters(engine, parameters)
        let clock = ContinuousClock()
        var failed = false
        for cycle in 1...options.cycles {
            guard st_engine_start_checked(engine, configuration, identity) == 0 else {
                report("ERROR: \(String(cString: st_engine_error(engine)))")
                failed = true
                break
            }
            let start = clock.now
            let deadline = start.advanced(by: .seconds(options.seconds))
            var previous = STTelemetry()
            repeat {
                // Only the control task waits. Core Audio runs the audio callbacks.
                try? await Task.sleep(for: .seconds(min(1, options.seconds)))
                let elapsed = start.duration(to: clock.now).seconds
                let value = st_engine_telemetry(engine)
                report(value.probeDescription(cycle: cycle, elapsed: elapsed))
                if value.outputCallbacks <= previous.outputCallbacks || value.needsRestart != 0 {
                    failed = true
                }
                if elapsed > 2 && value.hasErrors(since: previous) { failed = true }
                previous = value
                if options.profiles {
                    parameters.profile = UInt32(Int(elapsed) % 3)
                    parameters.compression = parameters.profile == 2 ? 1 : 0
                    st_engine_set_parameters(engine, parameters)
                }
            } while clock.now < deadline
            st_engine_stop(engine)
            if st_engine_telemetry(engine).running != 0 { failed = true }
        }
        report(
            failed
                ? "FAIL: Inspect the diagnostic log."
                : "PASS: Audio callbacks and repeated start/stop completed.")
        if failed { exit(5) }
    }

    private static func availableDevices() -> [STDevice] {
        var devices = [STDevice](repeating: STDevice(), count: Int(st_devices(nil, 0)))
        let count = devices.withUnsafeMutableBufferPointer {
            st_devices($0.baseAddress, UInt32($0.count))
        }
        return Array(devices.prefix(min(Int(count), devices.count)))
    }

    private static func openLog(path: String?) throws -> FileHandle? {
        guard let path else { return nil }
        if !FileManager.default.fileExists(atPath: path) {
            guard FileManager.default.createFile(atPath: path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
            }
        }
        let file = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        do { try file.seekToEnd() } catch {
            try? file.close()
            throw error
        }
        return file
    }
}
