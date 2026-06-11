import CoreGraphics

/// Request Screen Recording once at startup. NON-FATAL — unlike Accessibility, AeroSpace works
/// without it: `list-tree` falls back to AX titles when it's missing. macOS shows the prompt
/// only the first time and remembers the choice afterward.
@MainActor func requestScreenRecordingPermissionNonFatal() {
    if !CGPreflightScreenCaptureAccess() {
        _ = CGRequestScreenCaptureAccess()
    }
}
