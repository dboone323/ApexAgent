import Testing
import Foundation
import MetricKit
import SwiftUI
@testable import ApexAgentCore

@Suite("MetricDiagnosticsCenterTests", .serialized)
struct MetricDiagnosticsCenterTests {

    private func makeTempStorageURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApexAgentMetricTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("metric_diagnostics.json")
    }

    private static let environmentJSON = """
    {
      "regionFormat": "US",
      "osVersion": {"platform": "macOS", "number": "27.2", "buildNumber": "26C50"},
      "deviceType": "Mac16,1",
      "platformArchitecture": "arm64e",
      "lowPowerModeEnabled": false,
      "isTestFlightApp": false,
      "applicationVersion": "1.0.0",
      "applicationBuildVersion": "220",
      "bundleIdentifier": "com.apexsuite.ApexAgent",
      "signpostData": [],
      "states": []
    }
    """

    private static let emptyCallStackTreeJSON = """
    {"callStackThreads": [], "callStackPerThread": true, "binaryInfo": []}
    """

    @Test func ingestsRealCrashHangCPUAndDiskDiagnosticReportJSON() throws {
        let storageURL = makeTempStorageURL()
        defer { try? FileManager.default.removeItem(at: storageURL.deletingLastPathComponent()) }
        let center = MetricDiagnosticsCenter(storageURL: storageURL)

        let crashJSON = """
        {
          "timeRange": {"begin": 1000, "end": 1060},
          "environment": \(Self.environmentJSON),
          "crashDiagnostic": {
            "callStackTree": \(Self.emptyCallStackTreeJSON),
            "signal": 11,
            "exceptionCode": 1,
            "terminationCategory": "badAccess"
          }
        }
        """
        let crashPayload = try center.ingestDiagnosticJSON(Data(crashJSON.utf8))
        #expect(crashPayload.kind == .crash)
        #expect(crashPayload.signal == 11)
        #expect(crashPayload.exceptionCode == 1)
        #expect(crashPayload.terminationCategory == "badAccess")
        #expect(crashPayload.bundleIdentifier == "com.apexsuite.ApexAgent")
        #expect(crashPayload.applicationBuildVersion == "220")

        let hangJSON = """
        {
          "timeRange": {"begin": 2000, "end": 2010},
          "environment": \(Self.environmentJSON),
          "hangDiagnostic": {
            "callStackTree": \(Self.emptyCallStackTreeJSON),
            "hangDuration": {"value": 3.75, "unit": "s"}
          }
        }
        """
        let hangPayload = try center.ingestDiagnosticJSON(Data(hangJSON.utf8))
        #expect(hangPayload.kind == .hang)
        #expect(hangPayload.hangDurationSeconds == 3.75)

        let cpuJSON = """
        {
          "timeRange": {"begin": 3000, "end": 3120},
          "environment": \(Self.environmentJSON),
          "cpuExceptionDiagnostic": {
            "callStackTree": \(Self.emptyCallStackTreeJSON),
            "totalCPUTime": {"value": 92.5, "unit": "s"},
            "totalSampledTime": {"value": 120.0, "unit": "s"}
          }
        }
        """
        let cpuPayload = try center.ingestDiagnosticJSON(Data(cpuJSON.utf8))
        #expect(cpuPayload.kind == .cpuException)
        #expect(cpuPayload.cpuTimeSeconds == 92.5)

        let diskJSON = """
        {
          "timeRange": {"begin": 4000, "end": 4300},
          "environment": \(Self.environmentJSON),
          "diskWriteExceptionDiagnostic": {
            "callStackTree": \(Self.emptyCallStackTreeJSON),
            "totalBytesWritten": {"value": 1073741824, "unit": "B"}
          }
        }
        """
        let diskPayload = try center.ingestDiagnosticJSON(Data(diskJSON.utf8))
        #expect(diskPayload.kind == .diskWriteException)
        #expect(diskPayload.diskBytesWritten == 1_073_741_824)
    }

    @Test func ingestsRealDailyMetricReportJSONAndSubscriberPayloads() throws {
        let storageURL = makeTempStorageURL()
        defer { try? FileManager.default.removeItem(at: storageURL.deletingLastPathComponent()) }
        let center = MetricDiagnosticsCenter(storageURL: storageURL)

        let metricJSON = """
        {
          "timeRange": {"begin": 1000, "end": 87400},
          "environment": {
            "regionFormat": "US",
            "osVersion": {"platform": "macOS", "number": "27.2", "buildNumber": "26C50"},
            "deviceType": "Mac16,1",
            "platformArchitecture": "arm64e",
            "lowPowerModeEnabled": false,
            "isTestFlightApp": false,
            "bundleIdentifier": "com.apexsuite.ApexAgent",
            "applicationBuildVersion": "220",
            "latestApplicationVersion": "1.0.0",
            "includesMultipleApplicationVersions": false,
            "hasExceededStateLimit": false
          },
          "stateEntries": [],
          "intervalEntries": [
            {
              "states": [],
              "duration": {"value": 86400, "unit": "s"},
              "values": []
            }
          ]
        }
        """
        let metricPayload = try center.ingestMetricJSON(Data(metricJSON.utf8))
        #expect(metricPayload.kind == .dailyMetric)
        #expect(metricPayload.intervalEntries == 1)
        #expect(metricPayload.bundleIdentifier == "com.apexsuite.ApexAgent")

        // Exercise MXMetricManagerSubscriber callbacks with real MX payloads.
        center.didReceive([MXMetricPayload()])
        center.didReceive([MXDiagnosticPayload()])
        #expect(center.recentPayloads().count == 2)
    }

    @Test func atomicJSONPersistenceRoundTripAcrossInstances() throws {
        let storageURL = makeTempStorageURL()
        defer { try? FileManager.default.removeItem(at: storageURL.deletingLastPathComponent()) }

        let writer = MetricDiagnosticsCenter(storageURL: storageURL)
        let hangJSON = """
        {
          "timeRange": {"begin": 2000, "end": 2010},
          "environment": \(Self.environmentJSON),
          "hangDiagnostic": {
            "callStackTree": \(Self.emptyCallStackTreeJSON),
            "hangDuration": {"value": 4.25, "unit": "s"}
          }
        }
        """
        let recorded = try writer.ingestDiagnosticJSON(Data(hangJSON.utf8))
        #expect(FileManager.default.fileExists(atPath: storageURL.path))

        let reader = MetricDiagnosticsCenter(storageURL: storageURL)
        let loaded = reader.recentPayloads()
        #expect(loaded.count == 1)
        #expect(loaded.first?.id == recorded.id)
        #expect(loaded.first?.kind == .hang)
        #expect(loaded.first?.hangDurationSeconds == 4.25)

        reader.clear()
        let afterClear = MetricDiagnosticsCenter(storageURL: storageURL)
        #expect(afterClear.recentPayloads().isEmpty)
    }

    @Test func aggregateHealthSummaryMathAndStatusTransitions() {
        let emptySummary = FieldHealthSummary.compute(from: [])
        #expect(emptySummary.status == .pass)
        #expect(emptySummary.totalPayloads == 0)
        #expect(emptySummary.headline == "No field diagnostics recorded yet.")

        let dailyOnly = FieldHealthSummary.compute(from: [
            MetricDiagnosticPayload(kind: .dailyMetric, diskBytesWritten: 4096)
        ])
        #expect(dailyOnly.status == .pass)
        #expect(dailyOnly.dailyMetricCount == 1)
        #expect(dailyOnly.totalDiskBytesWritten == 4096)

        let warningSummary = FieldHealthSummary.compute(from: [
            MetricDiagnosticPayload(kind: .hang, hangDurationSeconds: 1.5),
            MetricDiagnosticPayload(kind: .hang, hangDurationSeconds: 4.0),
            MetricDiagnosticPayload(kind: .cpuException, cpuTimeSeconds: 80.0),
            MetricDiagnosticPayload(kind: .diskWriteException, diskBytesWritten: 1000)
        ])
        #expect(warningSummary.status == .warning)
        #expect(warningSummary.hangCount == 2)
        #expect(warningSummary.maxHangDurationSeconds == 4.0)
        #expect(warningSummary.cpuExceptionCount == 1)
        #expect(warningSummary.totalCPUExceptionSeconds == 80.0)
        #expect(warningSummary.diskWriteExceptionCount == 1)
        #expect(warningSummary.totalDiskBytesWritten == 1000)

        let failSummary = FieldHealthSummary.compute(from: [
            MetricDiagnosticPayload(kind: .hang, hangDurationSeconds: 1.5),
            MetricDiagnosticPayload(kind: .crash, terminationCategory: "badAccess", signal: 11)
        ])
        #expect(failSummary.status == .fail)
        #expect(failSummary.crashCount == 1)
        #expect(failSummary.headline.contains("1 crash"))
    }

    @Test @MainActor func fieldDiagnosticsModelAndDiagnosticsViewRender() {
        let storageURL = makeTempStorageURL()
        defer { try? FileManager.default.removeItem(at: storageURL.deletingLastPathComponent()) }
        let center = MetricDiagnosticsCenter(storageURL: storageURL)
        center.append([
            MetricDiagnosticPayload(kind: .hang, hangDurationSeconds: 2.0)
        ])

        let model = FieldDiagnosticsModel(center: center)
        model.refresh()
        #expect(model.summary.hangCount == 1)
        #expect(model.recent.count == 1)

        model.clear()
        #expect(model.summary.totalPayloads == 0)
        #expect(model.recent.isEmpty)

        let handle = ViewHost.hostWithHandle(DiagnosticsView())
        handle.pump(duration: 0.2)
        #expect(handle.hosting.frame.width > 0)
        #expect(handle.hosting.frame.height > 0)
    }
}
