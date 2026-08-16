import CryptoKit
import Darwin
import Foundation
import Security

struct ElevationInstallerBootstrap {
    static let argument = "--elevation-installer"
    static let resourceName = "mac-elevation-host.sh"
    private static let expectedInstallerSHA256 = "fa3d899de9c1fe3136500a54e364b22bddb2b66e3e5814514aa734971d4b015d"
    private static let signingRequirement = "identifier \"ai.openclaw.mac\" and anchor apple generic and " +
        "certificate 1[field.1.2.840.113635.100.6.2.6] exists and " +
        "certificate leaf[field.1.2.840.113635.100.6.1.13] exists and " +
        "certificate leaf[subject.OU] = \"FWJYW4S8P8\""

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
            let installerData = try self.authenticatedInstallerData(
                bundleURL: bundle.bundleURL,
                installerURL: invocation.scriptURL)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-s", "--"] + invocation.arguments
            var environment = ProcessInfo.processInfo.environment
            environment["OPENCLAW_ELEVATION_BOOTSTRAP_APP"] = bundle.bundleURL.path
            environment["OPENCLAW_ELEVATION_INSTALLER_PATH"] = invocation.scriptURL.path
            process.environment = environment
            let input = Pipe()
            process.standardInput = input
            try process.run()
            input.fileHandleForWriting.write(installerData)
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            fputs("OpenClaw elevation installer bootstrap failed: \(error.localizedDescription)\n", stderr)
            return 2
        }
    }

    private static func authenticatedInstallerData(bundleURL: URL, installerURL: URL) throws -> Data {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            self.signingRequirement as CFString,
            SecCSFlags(),
            &requirement) == errSecSuccess,
            let requirement
        else { throw BootstrapError.invalidSigningRequirement }

        var staticCode: SecStaticCode?
        let validationFlags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode,
              SecStaticCodeCheckValidity(staticCode, validationFlags, requirement) == errSecSuccess
        else { throw BootstrapError.invalidBundleSignature }

        var runningCode: SecCode?
        var runningStaticCode: SecStaticCode?
        guard SecCodeCopySelf(SecCSFlags(), &runningCode) == errSecSuccess,
              let runningCode,
              SecCodeCheckValidity(runningCode, SecCSFlags(), requirement) == errSecSuccess,
              SecCodeCopyStaticCode(runningCode, SecCSFlags(), &runningStaticCode) == errSecSuccess,
              let runningStaticCode,
              let runningHash = self.codeDirectoryHash(for: runningStaticCode),
              let bundleHash = self.codeDirectoryHash(for: staticCode),
              runningHash == bundleHash
        else { throw BootstrapError.runningCodeMismatch }

        let loadedInstallerData = try Data(contentsOf: installerURL)
        // Detach from any Foundation file backing before hashing; the exact owned bytes below are piped to Bash.
        let installerData = loadedInstallerData.withUnsafeBytes { Data($0) }
        let actualHash = SHA256.hash(data: installerData).map { String(format: "%02x", $0) }.joined()
        guard actualHash == self.expectedInstallerSHA256 else { throw BootstrapError.installerHashMismatch }
        return installerData
    }

    private static func codeDirectoryHash(for code: SecStaticCode) -> Data? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(), &information) == errSecSuccess,
              let information
        else { return nil }
        return (information as NSDictionary)[kSecCodeInfoUnique] as? Data
    }

    private enum BootstrapError: LocalizedError {
        case invalidSigningRequirement
        case invalidBundleSignature
        case runningCodeMismatch
        case installerHashMismatch

        var errorDescription: String? {
            switch self {
            case .invalidSigningRequirement: "could not construct the Foundation signing requirement"
            case .invalidBundleSignature: "the app signature or sealed resources are invalid"
            case .runningCodeMismatch: "the running executable does not match the signed app bundle"
            case .installerHashMismatch: "the installer resource does not match its signed digest"
            }
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
