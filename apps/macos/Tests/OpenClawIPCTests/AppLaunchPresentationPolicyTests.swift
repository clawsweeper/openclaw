import AppKit
import CryptoKit
import Testing
@testable import OpenClaw

struct AppLaunchRuntimePlanTests {
    @Test func `signed app bootstrap forwards only arguments after the installer marker`() throws {
        let resources = URL(fileURLWithPath: "/tmp/OpenClaw.app/Contents/Resources", isDirectory: true)
        let invocation = try #require(ElevationInstallerBootstrap.invocation(
            arguments: ["OpenClaw", "--elevation-installer", "verify", "--archive", "artifact.zip"],
            resourceURL: resources))

        #expect(invocation.scriptURL == resources.appendingPathComponent("mac-elevation-host.sh"))
        #expect(invocation.arguments == ["verify", "--archive", "artifact.zip"])
        #expect(ElevationInstallerBootstrap.invocation(
            arguments: ["OpenClaw", "verify", "--elevation-installer"],
            resourceURL: resources) == nil)
        #expect(ElevationInstallerBootstrap.invocation(
            arguments: ["OpenClaw", "--elevation-installer"],
            resourceURL: nil) == nil)
    }

    @Test func `normal launches allow automatic presentation`() {
        let policy = AppLaunchRuntimePlan(arguments: ["OpenClaw"])

        #expect(policy.mode == .interactive)
        #expect(!policy.attachOnly)
        #expect(policy.allowsAutomaticPresentation)
        #expect(policy.allowsGatewayUIKeychainAccess)
        #expect(policy.allowsUpdater)
        #expect(policy.allowsDockIcon)
        #expect(policy.allowsInteractiveServices)
        #expect(policy.shouldAutoOpenChat(arguments: ["OpenClaw", "--chat"]))
        #expect(policy.shouldAutoOpenDashboard(arguments: ["OpenClaw", "--dashboard"]))
    }

    @Test func `background-only wins over automatic presentation flags`() {
        let arguments = ["OpenClaw", "--attach-only", "--background-only", "--chat", "--dashboard"]
        let policy = AppLaunchRuntimePlan(arguments: arguments)

        #expect(policy.mode == .background)
        #expect(policy.attachOnly)
        #expect(!policy.allowsAutomaticPresentation)
        #expect(!policy.allowsGatewayUIKeychainAccess)
        #expect(policy.allowsUpdater)
        #expect(policy.allowsDockIcon)
        #expect(policy.allowsInteractiveServices)
        #expect(!policy.shouldAutoOpenChat(arguments: arguments))
        #expect(!policy.shouldAutoOpenDashboard(arguments: arguments))
    }

    @Test func `elevation host owns the complete unattended startup plan`() {
        let arguments = ["OpenClaw", "--elevation-host", "--chat", "--dashboard"]
        let policy = AppLaunchRuntimePlan(arguments: arguments)

        #expect(policy.mode == .elevationHost)
        #expect(policy.attachOnly)
        #expect(policy.isElevationHost)
        #expect(!policy.allowsAutomaticPresentation)
        #expect(!policy.allowsGatewayUIKeychainAccess)
        #expect(!policy.allowsUpdater)
        #expect(!policy.allowsDockIcon)
        #expect(!policy.allowsInteractiveServices)
        #expect(!policy.shouldAutoOpenChat(arguments: arguments))
        #expect(!policy.shouldAutoOpenDashboard(arguments: arguments))
        #expect(DockIconManager.activationPolicy(
            launchPlan: policy,
            userWantsDockHidden: false,
            hasVisibleWindows: true) == .accessory)
    }

    @Test func `attach-only does not change presentation behavior`() {
        let arguments = ["OpenClaw", "--attach-only", "--dashboard"]
        let policy = AppLaunchRuntimePlan(arguments: arguments)

        #expect(policy.mode == .interactive)
        #expect(policy.attachOnly)
        #expect(policy.allowsAutomaticPresentation)
        #expect(policy.allowsGatewayUIKeychainAccess)
        #expect(policy.shouldAutoOpenDashboard(arguments: arguments))
    }

    @Test func `background launch never calls the prompt bearing activation key loader`() {
        var loadCount = 0
        let key = GatewayConnection.activationBindingKey(
            launchPolicy: AppLaunchRuntimePlan(arguments: ["OpenClaw", "--background-only"]),
            loadOrCreate: {
                loadCount += 1
                return SymmetricKey(size: .bits256)
            })

        #expect(key == nil)
        #expect(loadCount == 0)
    }

    @Test func `interactive launch retains the activation binding key`() {
        var loadCount = 0
        let key = GatewayConnection.activationBindingKey(
            launchPolicy: AppLaunchRuntimePlan(arguments: ["OpenClaw"]),
            loadOrCreate: {
                loadCount += 1
                return SymmetricKey(size: .bits256)
            })

        #expect(key != nil)
        #expect(loadCount == 1)
    }
}
