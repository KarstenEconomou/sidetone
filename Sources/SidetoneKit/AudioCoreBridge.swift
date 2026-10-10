import AudioCore
import Foundation

extension AudioDevice {
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
            outputRightChannel: raw.outputRightChannel
        )
    }
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
            compression: settings.compression ? 1 : 0
        )
    }
}

private func decodeCString<T>(_ buffer: T) -> String {
    withUnsafeBytes(of: buffer) {
        String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
    }
}
