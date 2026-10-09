import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Container Policy Auditor Security Tests")
struct ContainerPolicyAuditorTests {
    @Test("Audits compliant container configuration with full score")
    func compliantContainerAudit() {
        let snapshot = ContainerSnapshotRecord(
            id: "snap-1",
            name: "Initial Clean State",
            description: "Baseline container snapshot",
            containerId: "c-sandbox-01",
            createdAt: Date(timeIntervalSince1970: 1700000000),
            imageRef: "alpine:latest",
            sizeInBytes: 1024 * 1024 * 50,
            isolationLevel: .strict
        )

        let config = ContainerSecurityConfig(
            id: "c-sandbox-01",
            name: "Isolated Python Worker",
            isolationLevel: .strict,
            resourceQuota: ContainerResourceQuota(cpuCount: 4, memoryLimitBytes: 4 * 1024 * 1024 * 1024),
            mounts: [
                ContainerMountSpec(hostPath: "/Users/dev/ApexAgent/workspace", containerPath: "/workspace", isReadOnly: true)
            ],
            snapshots: [snapshot],
            allowHostNetwork: false,
            privileged: false
        )

        let report = ContainerPolicyAuditor.audit(configs: [config])
        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.violations.isEmpty)
        #expect(report.evaluatedContainers == 1)

        let md = report.toMarkdown()
        #expect(md.contains("PASS"))
        #expect(md.contains("100.0/100.0"))
    }

    @Test("Detects privileged container violation")
    func privilegedContainerAudit() {
        let config = ContainerSecurityConfig(
            id: "c-root-priv",
            name: "Privileged Admin Worker",
            privileged: true
        )

        let report = ContainerPolicyAuditor.audit(configs: [config])
        #expect(!report.passed)
        let hasPrivilegedViolation = report.violations.contains { $0.ruleId == "container_privileged_forbidden" }
        #expect(hasPrivilegedViolation)
    }

    @Test("Detects mount path traversal and sensitive directory mount")
    func mountPathTraversalAudit() {
        let config = ContainerSecurityConfig(
            id: "c-traversal",
            name: "Escaping Worker",
            mounts: [
                ContainerMountSpec(hostPath: "/workspace/../../etc/passwd", containerPath: "/etc/passwd"),
                ContainerMountSpec(hostPath: "~/.ssh/id_rsa", containerPath: "/keys/id_rsa")
            ]
        )

        let report = ContainerPolicyAuditor.audit(configs: [config])
        #expect(!report.passed)
        let hasTraversal = report.violations.contains { $0.ruleId == "mount_path_traversal" }
        #expect(hasTraversal)
        let hasSensitive = report.violations.contains { $0.ruleId == "mount_sensitive_system_path" }
        #expect(hasSensitive)
    }

    @Test("Detects root filesystem mount and host network exposure")
    func rootMountAndNetworkAudit() {
        let config = ContainerSecurityConfig(
            id: "c-root-mount",
            name: "Root Exposed Worker",
            mounts: [ContainerMountSpec(hostPath: "/", containerPath: "/host-root")],
            allowHostNetwork: true
        )

        let report = ContainerPolicyAuditor.audit(configs: [config])
        #expect(!report.passed)
        let hasRoot = report.violations.contains { $0.ruleId == "mount_root_forbidden" }
        #expect(hasRoot)
        let hasNet = report.violations.contains { $0.ruleId == "container_host_network_exposure" }
        #expect(hasNet)
    }

    @Test("Detects snapshot containerId mismatch and empty name")
    func snapshotIntegrityAudit() {
        let snapBadContainer = ContainerSnapshotRecord(
            id: "snap-rogue",
            name: "Rogue Snapshot",
            description: "Mismatched container binding",
            containerId: "foreign-container-99"
        )
        let snapEmptyName = ContainerSnapshotRecord(
            id: "snap-empty",
            name: "   ",
            description: "Missing name",
            containerId: "c-valid"
        )

        let config = ContainerSecurityConfig(
            id: "c-valid",
            name: "Target Container",
            snapshots: [snapBadContainer, snapEmptyName]
        )

        let report = ContainerPolicyAuditor.audit(configs: [config])
        #expect(!report.passed)
        let hasMismatch = report.violations.contains { $0.ruleId == "snapshot_container_mismatch" }
        #expect(hasMismatch)
        let hasEmpty = report.violations.contains { $0.ruleId == "snapshot_empty_name" }
        #expect(hasEmpty)
    }

    @Test("Detects out of bounds CPU and memory quotas")
    func resourceQuotaAudit() {
        let config = ContainerSecurityConfig(
            id: "c-overallocated",
            name: "Resource Hog",
            resourceQuota: ContainerResourceQuota(
                cpuCount: 32, // Exceeds 8 cores max
                memoryLimitBytes: 64 * 1024 * 1024 * 1024 // Exceeds 16GB
            )
        )

        let violations = ContainerPolicyAuditor.auditContainer(config)
        let hasCpu = violations.contains { $0.ruleId == "container_quota_cpu_out_of_bounds" }
        #expect(hasCpu)
        let hasMem = violations.contains { $0.ruleId == "container_quota_memory_out_of_bounds" }
        #expect(hasMem)
    }
}
