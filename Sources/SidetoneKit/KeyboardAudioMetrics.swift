import AudioCore

public struct KeyboardAudioMetrics: Equatable, Sendable {
    public var outputRate = 0.0
    public var outputFrames = 0
    public var callbacks: UInt64 = 0
    public var maxCallbackMs = 0.0
    public var maxQueueMs = 0.0
    public var deadlineMisses: UInt64 = 0
    public var enqueued: UInt64 = 0
    public var queueDrops: UInt64 = 0
    public var voiceDrops: UInt64 = 0
    public var staleDrops: UInt64 = 0
    public var clippedFrames: UInt64 = 0
    public var peakVoices = 0
    public var stalled = false

    init() {}

    init(_ value: STKeyboardTelemetry) {
        outputRate = value.outputRate
        outputFrames = Int(value.outputBufferFrames)
        callbacks = value.callbacks
        maxCallbackMs = value.maxCallbackMs
        maxQueueMs = value.maxQueueMs
        deadlineMisses = value.deadlineMisses
        enqueued = value.enqueued
        queueDrops = value.queueDrops
        voiceDrops = value.voiceDrops
        staleDrops = value.staleDrops
        clippedFrames = value.clippedFrames
        peakVoices = Int(value.peakVoices)
        stalled = value.stalled != 0
    }
}
