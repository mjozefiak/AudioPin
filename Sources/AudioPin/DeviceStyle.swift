import CoreAudio
import Foundation

/// SF Symbols and labels for device types.
enum DeviceStyle {
    static func symbol(name: String, transport: UInt32, direction: Direction) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpods.max" }
        if lower.contains("airpods pro") { return "airpods.pro" }
        if lower.contains("airpods") { return "airpods" }
        if transport.isContinuity || lower.contains("iphone") { return "iphone" }

        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "display"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate,
             kAudioDeviceTransportTypeAutoAggregate:
            return "waveform"
        case kAudioDeviceTransportTypeBuiltIn:
            if direction == .input { return "mic" }
            return lower.contains("studio") ? "macstudio" : "hifispeaker"
        default:
            return direction == .input ? "music.mic" : "hifispeaker"
        }
    }

    static func transportName(_ transport: UInt32) -> String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: String(localized: "Built-in")
        case kAudioDeviceTransportTypeUSB: "USB"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "Bluetooth"
        case kAudioDeviceTransportTypeHDMI: "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: "AirPlay"
        case kAudioDeviceTransportTypeThunderbolt: "Thunderbolt"
        case kAudioDeviceTransportTypeVirtual: String(localized: "Virtual")
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: String(localized: "Aggregate")
        case kAudioDeviceTransportTypeContinuityCaptureWired,
             kAudioDeviceTransportTypeContinuityCaptureWireless: "iPhone (Continuity)"
        case kAudioDeviceTransportTypePCI: "PCI"
        case kAudioDeviceTransportTypeFireWire: "FireWire"
        default: String(localized: "Other")
        }
    }

    /// "Last seen 2 hours ago", in the user's language.
    static func lastSeen(_ date: Date) -> String {
        let relative = date.formatted(.relative(presentation: .named))
        return String(localized: "Last seen \(relative)")
    }
}
