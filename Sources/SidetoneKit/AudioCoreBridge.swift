import AudioCore
import CoreAudio
import Foundation

extension AudioDevice {
    static func availableDevices() -> [AudioDevice] {
        var raw = [STDevice](repeating: STDevice(), count: Int(st_devices(nil, 0)))
        let count = raw.withUnsafeMutableBufferPointer {
            st_devices($0.baseAddress, UInt32($0.count))
        }
        return raw.prefix(min(Int(count), raw.count)).map(AudioDevice.init).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    init(_ raw: STDevice) {
        self.init(
            id: raw.id,
            uid: decodeCString(raw.uid),
            name: decodeCString(raw.name),
            inputChannels: Int(raw.inputChannels),
            outputChannels: Int(raw.outputChannels),
            sampleRate: raw.sampleRate,
            bufferFrames: Int(raw.bufferFrames),
            minBufferFrames: Int(raw.minBufferFrames),
            maxBufferFrames: Int(raw.maxBufferFrames),
            isDefaultInput: raw.isDefaultInput != 0,
            isDefaultOutput: raw.isDefaultOutput != 0,
            outputDataSource: raw.outputDataSource,
            outputJackState: raw.outputJackState,
            outputLeftChannel: raw.outputLeftChannel,
            outputRightChannel: raw.outputRightChannel,
            iconURL: deviceIconURL(raw.id), transportType: raw.transportType,
            inputTerminalType: raw.inputChannels > 0
                ? deviceTerminalType(raw.id, scope: kAudioObjectPropertyScopeInput) : 0,
            outputTerminalType: raw.outputChannels > 0
                ? deviceTerminalType(raw.id, scope: kAudioObjectPropertyScopeOutput) : 0
        )
    }
}

private func deviceIconURL(_ id: AudioDeviceID) -> URL? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyIcon, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectHasProperty(id, &address) else { return nil }
    var value: Unmanaged<CFURL>?
    var size = UInt32(MemoryLayout.size(ofValue: value))
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
        let value
    else { return nil }
    let url = value.takeRetainedValue() as URL
    return url.isFileURL ? url : nil
}

private func deviceTerminalType(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> UInt32 {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams, mScope: scope,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
        return 0
    }
    var streams = [AudioStreamID](
        repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &streams) == noErr else {
        return 0
    }
    for stream in streams {
        address = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyTerminalType, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var terminal: UInt32 = 0
        size = UInt32(MemoryLayout.size(ofValue: terminal))
        if AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &terminal) == noErr,
            terminal != 0, terminal != kAudioStreamTerminalTypeUnknown
        {
            return terminal
        }
    }
    return 0
}

extension AudioMetrics {
    init(_ raw: STTelemetry) {
        running = raw.running != 0
        restartReasons = AudioRestartReason(rawValue: raw.needsRestart)
        inputRate = raw.inputRate
        outputRate = raw.outputRate
        inputFrames = Int(raw.inputBufferFrames)
        outputFrames = Int(raw.outputBufferFrames)
        estimatedLatencyMs = raw.estimatedLatencyMs
        queueLatencyMs = raw.queueLatencyMs
        inputDeviceLatencyMs = raw.inputDeviceLatencyMs
        outputDeviceLatencyMs = raw.outputDeviceLatencyMs
        resamplerLatencyMs = raw.resamplerLatencyMs
        suppressionLatencyMs = raw.suppressionLatencyMs
        peakInput = raw.peakInput
        peakOutput = raw.peakOutput
        maxCallbackMs = raw.maxCallbackMs
        maxDSPMs = raw.maxDSPMs
        driftPPM = raw.driftPPM
        inputCallbacks = raw.inputCallbacks
        outputCallbacks = raw.outputCallbacks
        underruns = raw.underruns
        overruns = raw.overruns
        deadlineMisses = raw.deadlineMisses
        clippedSamples = raw.clippedSamples
        hardwareOverloads = raw.hardwareOverloads
    }
}

extension STConfiguration {
    init(route: AudioRoute, settings: MonitorSettings) {
        self.init(
            inputDevice: route.input.id,
            outputDevice: route.output.id,
            inputChannel: UInt32(settings.inputChannel),
            bufferFrames: UInt32(settings.bufferFrames)
        )
    }
}

extension STRouteIdentity {
    init(_ route: AudioRoute) {
        self.init()
        withUnsafeMutableBytes(of: &inputUID) {
            $0.copyBytes(from: route.input.uid.utf8.prefix($0.count - 1))
        }
        withUnsafeMutableBytes(of: &outputUID) {
            $0.copyBytes(from: route.output.uid.utf8.prefix($0.count - 1))
        }
        outputDataSource = route.output.outputDataSource
        outputJackState = route.output.outputJackState
        outputLeftChannel = route.output.outputLeftChannel
        outputRightChannel = route.output.outputRightChannel
    }
}

extension STParameters {
    init(_ settings: MonitorSettings) {
        self.init(
            gainDB: Float(settings.gainDB),
            profile: settings.profile.engineValue,
            highPassHz: Float(settings.highPassHz),
            eqFrequencyHz: Float(settings.eqFrequencyHz),
            eqGainDB: Float(settings.eqGainDB),
            eqQ: Float(settings.eqQ),
            compression: settings.compression ? 1 : 0,
            noiseSuppression: settings.noiseSuppression ? 1 : 0,
            suppressionStrength: Float(settings.noiseSuppressionStrength / 100)
        )
    }
}

private func decodeCString<T>(_ buffer: T) -> String {
    withUnsafeBytes(of: buffer) {
        String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
    }
}
