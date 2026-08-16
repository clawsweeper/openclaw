import Darwin
import Foundation

struct ElevationInstallerBootstrap {
    static let argument = "--elevation-installer"
    static let resourceName = "mac-elevation-host.sh"

    struct Invocation: Equatable {
        let scriptURL: URL
        let arguments: [String]
    }

    static func invocation(arguments: [String], resourceURL: URL?) -> Invocation? {
        guard arguments.dropFirst().first == self.argument else { return nil }
        guard let resourceURL else { return nil }
        return Invocation(
            scriptURL: resourceURL.appendingPathComponent(self.resourceName, isDirectory: false),
            arguments: Array(arguments.dropFirst(2)))
    }

    static func runIfRequested(arguments: [String] = CommandLine.arguments, bundle: Bundle = .main) -> Int32? {
        guard arguments.dropFirst().first == self.argument else { return nil }
        guard let invocation = self.invocation(arguments: arguments, resourceURL: bundle.resourceURL) else {
            fputs("OpenClaw elevation installer resource is unavailable\n", stderr)
            return 2
        }
        do {
            let values = try invocation.scriptURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                fputs("OpenClaw elevation installer resource is not a regular signed resource\n", stderr)
                return 2
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [invocation.scriptURL.path] + invocation.arguments
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            fputs("OpenClaw elevation installer bootstrap failed: \(error.localizedDescription)\n", stderr)
            return 2
        }
    }
}

struct AppLaunchRuntimePlan: Equatable {
    enum Mode: Equatable {
        case interactive
        case background
        case elevationHost
    }

    let mode: Mode
    let attachOnly: Bool

    init(arguments: [String]) {
        if arguments.contains("--elevation-host") {
            self.mode = .elevationHost
            self.attachOnly = true
        } else {
            self.mode = arguments.contains("--background-only") ? .background : .interactive
            self.attachOnly = arguments.contains("--attach-only") || arguments.contains("--no-launchd")
        }
    }

    static var current: Self {
        Self(arguments: CommandLine.arguments)
    }

    var isElevationHost: Bool {
        self.mode == .elevationHost
    }

    var allowsAutomaticPresentation: Bool {
        self.mode == .interactive
    }

    /// GUI-owned Keychain items may present SecurityAgent when a newly signed build is not in an item's ACL.
    /// Background hosts keep that state cold; config and environment still own their primary Gateway route.
    var allowsGatewayUIKeychainAccess: Bool {
        self.mode == .interactive
    }

    var allowsUpdater: Bool {
        !self.isElevationHost
    }

    var allowsDockIcon: Bool {
        !self.isElevationHost
    }

    var allowsInteractiveServices: Bool {
        !self.isElevationHost
    }

    func shouldAutoOpenChat(arguments: [String]) -> Bool {
        self.allowsAutomaticPresentation &&
            (arguments.contains("--chat") || arguments.contains("--webchat"))
    }

    func shouldAutoOpenDashboard(arguments: [String]) -> Bool {
        self.allowsAutomaticPresentation && arguments.contains("--dashboard")
    }
}
