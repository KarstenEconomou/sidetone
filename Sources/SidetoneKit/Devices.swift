import Foundation

public struct AudioDevice: Identifiable, Equatable, Sendable {
    public let id: UInt32
    public let uid: String
    public let name: String
    public let inputChannels: Int
    public let outputChannels: Int
    public let sampleRate: Double
    public let bufferFrames: Int
    public let minBufferFrames: Int
    public let maxBufferFrames: Int
    public let isDefaultInput: Bool
    public let isDefaultOutput: Bool
    public let outputDataSource: UInt32
    public let outputJackState: UInt32
    public let outputLeftChannel: UInt32
    public let outputRightChannel: UInt32

    public init(
        id: UInt32, uid: String, name: String, inputChannels: Int = 0,
        outputChannels: Int = 0, sampleRate: Double = 48000, bufferFrames: Int = 64,
        minBufferFrames: Int = 32, maxBufferFrames: Int = 1024,
        isDefaultInput: Bool = false, isDefaultOutput: Bool = false,
        outputDataSource: UInt32 = 0, outputJackState: UInt32 = 0,
        outputLeftChannel: UInt32 = 0, outputRightChannel: UInt32? = nil
    ) {
        self.id = id
        self.uid = uid
        self.name = name
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
        self.sampleRate = sampleRate
        self.bufferFrames = bufferFrames
        self.minBufferFrames = minBufferFrames
        self.maxBufferFrames = maxBufferFrames
        self.isDefaultInput = isDefaultInput
        self.isDefaultOutput = isDefaultOutput
        self.outputDataSource = outputDataSource
        self.outputJackState = outputJackState
        self.outputLeftChannel = outputLeftChannel
        self.outputRightChannel = outputRightChannel ?? (outputChannels > 1 ? 1 : 0)
    }
}

public struct AudioRoute: Equatable, Sendable {
    public let input: AudioDevice
    public let output: AudioDevice

    public func hasSameIdentity(as other: AudioRoute) -> Bool {
        input.uid == other.input.uid && output.uid == other.output.uid
            && output.outputDataSource == other.output.outputDataSource
            && output.outputJackState == other.output.outputJackState
            && output.outputLeftChannel == other.output.outputLeftChannel
            && output.outputRightChannel == other.output.outputRightChannel
    }
}

public enum RouteSelection {
    public static func resolve(settings: MonitorSettings, devices: [AudioDevice]) -> AudioRoute? {
        let input = devices.first { device in
            device.inputChannels > settings.inputChannel
                && (settings.inputUID.map { $0 == device.uid } ?? device.isDefaultInput)
        }
        let output = devices.first { device in
            device.outputChannels > 0
                && (settings.outputUID.map { $0 == device.uid } ?? device.isDefaultOutput)
        }
        guard let input, let output else { return nil }
        return AudioRoute(input: input, output: output)
    }

    public static func canResume(previous: AudioRoute?, next: AudioRoute?) -> Bool {
        guard let previous, let next else { return false }
        return previous.hasSameIdentity(as: next)
    }
}
