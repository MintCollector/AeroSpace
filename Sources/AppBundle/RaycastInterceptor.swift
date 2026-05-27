import AppKit

enum RaycastInterceptor {
    private static let raycastBundleId = "com.raycast.macos"

    @MainActor private static var previousActivatedBundleId: String? = nil
    @MainActor private static var preRaycastBundleId: String? = nil

    @MainActor
    static func handleActivation(_ nsApp: NSRunningApplication) -> Bool {
        let bundleId = nsApp.bundleIdentifier
        defer { previousActivatedBundleId = bundleId }

        if bundleId == raycastBundleId {
            preRaycastBundleId = previousActivatedBundleId
            return false
        }

        guard previousActivatedBundleId == raycastBundleId else {
            return false
        }

        if bundleId == preRaycastBundleId {
            return false
        }

        if let bundleURL = nsApp.bundleURL {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", bundleURL.path]
            try? process.run()
        }
        return true
    }
}
