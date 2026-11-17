import Foundation

public enum ControlCommand: Equatable {
    case wifiOn
    case wifiOff
    case wifiStatus
}

/// Loopback-only admin commands from the menu app. One command per line.
public enum ControlParser {
    public static func parse(_ line: String) -> ControlCommand? {
        switch line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "wifi on":
            return .wifiOn
        case "wifi off":
            return .wifiOff
        case "wifi status":
            return .wifiStatus
        default:
            return nil
        }
    }
}