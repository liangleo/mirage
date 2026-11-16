import Foundation

/// What the menu app should do with the helper when a connection toggle flips.
public enum HelperAction: Equatable {
    case none
    case start
    case restart
    case stop
}

/// The helper is only useful while some connection wants it: Wi-Fi serving
/// (`--wifi`) or the USB/AOA bridge pointed at its loopback port. Flipping a
/// connection off must be able to stop it, never silently relaunch a helper
/// that keeps capturing the screen.
public enum HelperLifecycle {
    public static func actionOnWifiChange(
        enabled: Bool,
        usbEnabled: Bool,
        running: Bool
    ) -> HelperAction {
        if enabled {
            return running ? .restart : .start
        }
        guard !usbEnabled else { return .none }
        return running ? .stop : .none
    }

    public static func actionOnUsbChange(
        enabled: Bool,
        wasWifi: Bool,
        running: Bool
    ) -> HelperAction {
        if enabled {
            if !running { return .start }
            // Dropping `--wifi` changes the helper's bind address, so it must relaunch.
            return wasWifi ? .restart : .none
        }
        return running ? .stop : .none
    }
}