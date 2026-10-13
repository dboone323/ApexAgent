// TurnLoopWatchdog.swift
// Batch 125: Inter-agent turn loop watchdog preventing cyclic @mention
// ping-pong loops and runaway multi-agent recursion in collaborative Spaces.

import Foundation

public enum TurnLoopViolation: Error, LocalizedError, Equatable {
    case maxDepthExceeded(depth: Int, maxAllowed: Int)
    case cyclicLoopDetected(cycle: [UUID])
    case runawayPingPong(botA: UUID, botB: UUID, repetitions: Int)

    public var errorDescription: String? {
        switch self {
        case .maxDepthExceeded(let depth, let maxAllowed):
            return "Turn loop max depth exceeded: depth \(depth) > max \(maxAllowed)"
        case .cyclicLoopDetected(let cycle):
            return "Cyclic @mention loop detected: \(cycle.map(\.uuidString).joined(separator: " -> "))"
        case .runawayPingPong(let botA, let botB, let repetitions):
            return "Runaway ping-pong loop detected between \(botA.uuidString) and \(botB.uuidString) (\(repetitions) repetitions)"
        }
    }
}

public actor TurnLoopWatchdog {
    public static let shared = TurnLoopWatchdog()
    public static let defaultMaxDepth: Int = 8
    public static let defaultPingPongThreshold: Int = 3

    private var turnChains: [UUID: [UUID]] = [:]
    private var maxDepth: Int
    private var pingPongThreshold: Int

    public init(
        maxDepth: Int = TurnLoopWatchdog.defaultMaxDepth,
        pingPongThreshold: Int = TurnLoopWatchdog.defaultPingPongThreshold
    ) {
        self.maxDepth = maxDepth
        self.pingPongThreshold = pingPongThreshold
    }

    public func recordTurn(spaceId: UUID, fromBotId: UUID?, toBotId: UUID) throws {
        let chain = turnChains[spaceId] ?? []
        if chain.count + 1 > maxDepth {
            throw TurnLoopViolation.maxDepthExceeded(depth: chain.count + 1, maxAllowed: maxDepth)
        }

        let proposed = chain + [toBotId]

        // Check runaway ping-pong: if the last 2*pingPongThreshold - 1 elements alternate between botA and botB
        let neededPingPongCount = 2 * pingPongThreshold - 1
        if proposed.count >= neededPingPongCount && pingPongThreshold >= 2 {
            let suffix = Array(proposed.suffix(neededPingPongCount))
            let botA = suffix[0]
            let botB = suffix[1]
            if botA != botB {
                var isAlternating = true
                for i in 0..<neededPingPongCount {
                    let expected = (i % 2 == 0) ? botA : botB
                    if suffix[i] != expected {
                        isAlternating = false
                        break
                    }
                }
                if isAlternating {
                    throw TurnLoopViolation.runawayPingPong(botA: botA, botB: botB, repetitions: pingPongThreshold)
                }
            }
        }

        // Check cyclic loop: if chain.contains(toBotId) and the subchain from the first occurrence of toBotId repeats (at least twice)
        if chain.contains(toBotId) {
            let firstIndex = chain.firstIndex(of: toBotId)!
            let fromFirst = Array(proposed[firstIndex...])
            if fromFirst.count >= 4 {
                for L in 2...(fromFirst.count / 2) {
                    let cycle = Array(fromFirst[0..<L])
                    let secondCycle = Array(fromFirst[L..<(2 * L)])
                    if cycle == secondCycle && Set(cycle).count >= 3 {
                        throw TurnLoopViolation.cyclicLoopDetected(cycle: cycle)
                    }
                }
            }

            if proposed.count >= 6 {
                for L in 3...(proposed.count / 2) {
                    let suffix = Array(proposed.suffix(2 * L))
                    let c1 = Array(suffix[0..<L])
                    let c2 = Array(suffix[L..<(2 * L)])
                    if c1 == c2 && Set(c1).count >= 3 {
                        throw TurnLoopViolation.cyclicLoopDetected(cycle: c1)
                    }
                }
            }
        }

        turnChains[spaceId] = proposed
    }

    public func turnCount(spaceId: UUID) -> Int {
        return turnChains[spaceId]?.count ?? 0
    }

    public func reset(spaceId: UUID) {
        turnChains.removeValue(forKey: spaceId)
    }

    public func resetAll() {
        turnChains.removeAll()
    }
}
