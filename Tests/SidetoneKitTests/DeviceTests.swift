import SidetoneKit
import Testing

@Suite("Audio route safety")
struct DeviceTests {
    let microphone = AudioDevice(id: 1, uid: "mic", name: "Microphone", inputChannels: 2, isDefaultInput: true)
    let headphones = AudioDevice(id: 2, uid: "iem", name: "Headphones", outputChannels: 2, isDefaultOutput: true)
    let speakers = AudioDevice(id: 3, uid: "speakers", name: "Speakers", outputChannels: 2)

    @Test func defaultsResolveByDirection() throws {
        let route = try #require(RouteSelection.resolve(settings: MonitorSettings(), devices: [microphone, headphones, speakers]))
        #expect(route.input.uid == "mic")
        #expect(route.output.uid == "iem")
    }

    @Test func unavailableSavedOutputDoesNotFallBackToSpeakers() {
        var settings = MonitorSettings()
        settings.outputUID = "missing-iem"
        #expect(RouteSelection.resolve(settings: settings, devices: [microphone, headphones, speakers]) == nil)
    }

    @Test func explicitSelectionOverridesDefault() throws {
        var settings = MonitorSettings()
        settings.outputUID = "speakers"
        let route = try #require(RouteSelection.resolve(settings: settings, devices: [microphone, headphones, speakers]))
        #expect(route.output.uid == "speakers")
    }

    @Test func invalidInputChannelWaitsForCompatibleDevice() {
        var settings = MonitorSettings()
        settings.inputChannel = 2
        #expect(RouteSelection.resolve(settings: settings, devices: [microphone, headphones]) == nil)
    }

    @Test func sameUIDCanRecoverAfterDeviceIDChanges() throws {
        let original = try #require(RouteSelection.resolve(settings: MonitorSettings(), devices: [microphone, headphones]))
        let reconnected = AudioDevice(id: 42, uid: "iem", name: "Headphones", outputChannels: 2, isDefaultOutput: true)
        let next = RouteSelection.resolve(settings: MonitorSettings(), devices: [microphone, reconnected])
        #expect(RouteSelection.canResume(previous: original, next: next))
        #expect(!RouteSelection.canResume(previous: original, next: nil))
    }

    @Test func aNewDefaultOutputRequiresUserAction() throws {
        let original = try #require(RouteSelection.resolve(settings: MonitorSettings(), devices: [microphone, headphones]))
        let nextDefault = AudioDevice(id: 3, uid: "speakers", name: "Speakers", outputChannels: 2, isDefaultOutput: true)
        let next = RouteSelection.resolve(settings: MonitorSettings(), devices: [microphone, nextDefault])
        #expect(!RouteSelection.canResume(previous: original, next: next))
    }

    @Test func removingHeadphonesOnSameDeviceRequiresUserAction() throws {
        let plugged = AudioDevice(id: 2, uid: "built-in", name: "Output", outputChannels: 2,
                                  isDefaultOutput: true, outputDataSource: 10, outputJackState: 2)
        let unplugged = AudioDevice(id: 2, uid: "built-in", name: "Output", outputChannels: 2,
                                    isDefaultOutput: true, outputDataSource: 11, outputJackState: 1)
        let previous = try #require(RouteSelection.resolve(settings: MonitorSettings(), devices: [microphone, plugged]))
        let next = RouteSelection.resolve(settings: MonitorSettings(), devices: [microphone, unplugged])
        #expect(!RouteSelection.canResume(previous: previous, next: next))
    }
}
