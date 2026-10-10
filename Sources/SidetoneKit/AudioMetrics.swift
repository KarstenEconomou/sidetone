import AudioCore

public struct AudioRestartReason: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let io = Self(rawValue: UInt32(ST_RESTART_IO))
    public static let outputRoute = Self(rawValue: UInt32(ST_RESTART_OUTPUT_ROUTE))
}

public struct AudioMetrics: Sendable {
    public var running = false
    public var restartReasons: AudioRestartReason = []
    public var inputRate = 0.0
    public var outputRate = 0.0
    public var inputFrames = 0
    public var outputFrames = 0
    public var estimatedLatencyMs = 0.0
    public var queueLatencyMs = 0.0
    public var inputDeviceLatencyMs = 0.0
    public var outputDeviceLatencyMs = 0.0
    public var resamplerLatencyMs = 0.0
    public var peakInput = 0.0
    public var peakOutput = 0.0
    public var maxCallbackMs = 0.0
    public var maxDSPMs = 0.0
    public var driftPPM = 0.0
    public var inputCallbacks: UInt64 = 0
    public var outputCallbacks: UInt64 = 0
    public var underruns: UInt64 = 0
    public var overruns: UInt64 = 0
    public var deadlineMisses: UInt64 = 0
    public var clippedSamples: UInt64 = 0
    public var hardwareOverloads: UInt64 = 0

    public init() {}

    public var inputBufferDurationMs: Double {
        inputRate > 0 ? Double(inputFrames) / inputRate * 1000 : 0
    }

    public var outputBufferDurationMs: Double {
        outputRate > 0 ? Double(outputFrames) / outputRate * 1000 : 0
    }
}
