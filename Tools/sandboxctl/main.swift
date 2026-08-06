// sandboxctl — entitled verification harness for the Apple Container sandbox.
//
// The xctest agent can never carry com.apple.security.virtualization, so the
// container boot path is unprovable from unit tests. This tiny CLI links the
// real ApexAgentCore ContainerManager, and after being ad-hoc signed with
// ApexAgent.entitlements it boots the sandbox for real:
//
//   swift build --product sandboxctl
//   codesign --force --sign - --entitlements ApexAgent/ApexAgent.entitlements .build/debug/sandboxctl
//   .build/debug/sandboxctl
//
// Exit 0 + "APEX_SANDBOX_OK" on stdout = full VM boot + guest exec verified.
// Any failure prints the ContainerManager error and exits nonzero.

import Foundation
import ApexAgentCore

@main
struct SandboxCtl {
    static func main() async {
        let manager = await ContainerManager.shared
        do {
            print("[sandboxctl] starting container (image: \(await manager.appleContainerImage))…")
            try await manager.startContainer()
            print("[sandboxctl] state: \(await manager.stateDescription)")

            // Probe 1: guest root as cwd ("/" always exists in the guest).
            let (output, code) = try await manager.exec("echo APEX_SANDBOX_OK")
            print("[sandboxctl] exec exit=\(code) output=\(output)")

            try await manager.stopContainer()
            print("[sandboxctl] stopped. state: \(await manager.stateDescription)")

            if output.contains("APEX_SANDBOX_OK") && code == 0 {
                print("APEX_SANDBOX_OK")
                exit(0)
            } else {
                print("[sandboxctl] FAIL: unexpected exec result")
                exit(2)
            }
        } catch {
            print("[sandboxctl] FAIL: \(error.localizedDescription)")
            let ns = error as NSError
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
                print("[sandboxctl] underlying: \(underlying)")
            }
            exit(1)
        }
    }
}
