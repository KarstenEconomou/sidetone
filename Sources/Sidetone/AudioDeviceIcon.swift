import AppKit
import CoreAudio
import SidetoneKit
import SwiftUI

@MainActor
enum AudioDeviceIcon {
    private static let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 64
        return cache
    }()

    static func image(for device: AudioDevice?, isInput: Bool) -> Image {
        if let url = device?.iconURL, url.isFileURL {
            if let image = cache.object(forKey: url as NSURL) {
                return Image(nsImage: image)
            }
            if let image = NSImage(contentsOf: url) {
                image.size = NSSize(width: 16, height: 16)
                cache.setObject(image, forKey: url as NSURL)
                return Image(nsImage: image)
            }
        }
        return Image(systemName: symbol(for: device, isInput: isInput))
    }

    private static func symbol(for device: AudioDevice?, isInput: Bool) -> String {
        guard let device else { return isInput ? "mic" : "speaker.wave.2" }
        if device.name.localizedCaseInsensitiveContains("AirPods Max") { return "airpodsmax" }
        if device.name.localizedCaseInsensitiveContains("AirPods Pro") { return "airpodspro" }
        if device.name.localizedCaseInsensitiveContains("AirPods") { return "airpods" }
        let terminal = isInput ? device.inputTerminalType : device.outputTerminalType
        switch terminal {
        case kAudioStreamTerminalTypeHeadphones, kAudioStreamTerminalTypeHeadsetMicrophone:
            return "headphones"
        case kAudioStreamTerminalTypeHDMI, kAudioStreamTerminalTypeDisplayPort:
            return "display"
        default: break
        }
        switch device.transportType {
        case kAudioDeviceTransportTypeBuiltIn
        where device.name.localizedCaseInsensitiveContains("MacBook"):
            return "laptopcomputer"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "display"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplay.audio"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate:
            return "waveform"
        default:
            return isInput ? "mic" : "speaker.wave.2"
        }
    }
}
