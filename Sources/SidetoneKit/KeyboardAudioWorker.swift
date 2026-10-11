import AudioCore
import Foundation

struct KeyboardAudioRequest: Sendable {
    let output: AudioDevice?
    let volumeDB: Double
    let revision: UInt64
    let volumeRevision: UInt64
}

struct KeyboardDeviceUpdate: Sendable {
    let devices: [AudioDevice]
    let running: Bool
    var metrics = KeyboardAudioMetrics()
}

protocol KeyboardAudioWorking: Sendable {
    func apply(_ request: KeyboardAudioRequest) async -> EngineResult
    func setVolume(_ volumeDB: Double, revision: UInt64) async
    func play(_ stroke: KeyboardStroke, settings: KeyboardSettings, revision: UInt64)
    func poll() async -> KeyboardDeviceUpdate
}

private final class KeyboardEngineHandle: @unchecked Sendable {
    // The worker owns control calls. Playback ends before a control call can stop or load audio.
    let pointer = st_keyboard_create()
    deinit { st_keyboard_destroy(pointer) }
}

private final class KeyboardPlayback: @unchecked Sendable {
    private let lock = NSLock()
    private var library: KeyboardSoundLibrary?
    private var engine: KeyboardEngineHandle?
    private var revision: UInt64 = 0
    private var selector = KeyboardSampleSelector()

    func prepare(library: KeyboardSoundLibrary, engine: KeyboardEngineHandle, revision: UInt64) {
        lock.withLock {
            self.library = library
            self.engine = engine
            self.revision = revision
            selector = KeyboardSampleSelector()
        }
    }

    func stop() {
        lock.withLock {
            engine = nil
            library = nil
        }
    }

    func play(_ stroke: KeyboardStroke, settings: KeyboardSettings, revision: UInt64) {
        lock.withLock {
            guard revision == self.revision, let engine, let library,
                let sample = selector.select(
                    library.choices(for: stroke, type: settings.switchType),
                    vary: settings.varySamples)
            else { return }
            st_keyboard_play(engine.pointer, sample)
        }
    }
}

actor KeyboardAudioWorker: KeyboardAudioWorking {
    private let engine = KeyboardEngineHandle()
    private nonisolated let playback = KeyboardPlayback()
    private var library: KeyboardSoundLibrary?
    private var revision: UInt64 = 0
    private var volumeRevision: UInt64 = 0

    func apply(_ request: KeyboardAudioRequest) -> EngineResult {
        guard request.revision >= revision else { return EngineResult(running: false, error: nil) }
        revision = request.revision
        playback.stop()
        st_keyboard_stop(engine.pointer)
        guard let output = request.output else { return EngineResult(running: false, error: nil) }
        guard let pointer = engine.pointer else {
            return EngineResult(running: false, error: "Could not create keyboard audio.")
        }
        guard output.sampleRate.isFinite, (8_000...192_000).contains(output.sampleRate) else {
            return EngineResult(running: false, error: "The output sample rate is not supported.")
        }
        do {
            if library?.sampleRate != output.sampleRate {
                library = nil
                library = try KeyboardSoundLibrary(engine: pointer, sampleRate: output.sampleRate)
            }
        } catch {
            return EngineResult(
                running: false, error: "Could not load the keyboard recordings. Reinstall Sidetone."
            )
        }
        setVolume(request.volumeDB, revision: request.volumeRevision)
        let result = output.uid.withCString { st_keyboard_start(pointer, output.id, $0) }
        if result == 0, let library {
            playback.prepare(library: library, engine: engine, revision: request.revision)
        }
        return EngineResult(
            running: result == 0,
            error: result == 0 ? nil : String(cString: st_keyboard_error(pointer)))
    }

    func setVolume(_ volumeDB: Double, revision: UInt64) {
        guard revision >= volumeRevision else { return }
        volumeRevision = revision
        st_keyboard_set_gain(engine.pointer, Float(volumeDB))
    }

    nonisolated func play(_ stroke: KeyboardStroke, settings: KeyboardSettings, revision: UInt64) {
        playback.play(stroke, settings: settings, revision: revision)
    }

    func poll() -> KeyboardDeviceUpdate {
        let devices = AudioDevice.availableDevices().filter { $0.outputChannels > 0 }
        return KeyboardDeviceUpdate(
            devices: devices, running: st_keyboard_running(engine.pointer) != 0,
            metrics: KeyboardAudioMetrics(st_keyboard_telemetry(engine.pointer)))
    }
}
