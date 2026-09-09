import XCTest
@testable import ApexAgentCore

@MainActor
final class DiscordGatewayTests: XCTestCase {

    func testDiscordButtonComponentsApprovalRowGeneration() {
        let buttons = DiscordButtonComponent.makeApprovalRow(stageId: "stage_test_123")
        XCTAssertEqual(buttons.count, 3)

        XCTAssertEqual(buttons[0].label, "Approve")
        XCTAssertEqual(buttons[0].customId, "approve_stage_stage_test_123")
        XCTAssertEqual(buttons[0].style, 3) // success

        XCTAssertEqual(buttons[1].label, "Reject")
        XCTAssertEqual(buttons[1].customId, "reject_stage_stage_test_123")
        XCTAssertEqual(buttons[1].style, 4) // danger

        XCTAssertEqual(buttons[2].label, "Details")
        XCTAssertEqual(buttons[2].customId, "details_stage_stage_test_123")
        XCTAssertEqual(buttons[2].style, 2) // secondary
    }

    func testIdentifyPayloadEncoding() throws {
        let client = DiscordGatewayClient()
        client.configure(botToken: "Bot.SampleDiscordToken.ABC123XYZ")

        let payloadData = try client.createIdentifyPayload()
        let json = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any]

        XCTAssertEqual(json?["op"] as? Int, DiscordOpCode.identify.rawValue)
        let d = json?["d"] as? [String: Any]
        XCTAssertEqual(d?["token"] as? String, "Bot.SampleDiscordToken.ABC123XYZ")
    }

    func testHeartbeatPayloadEncoding() throws {
        let client = DiscordGatewayClient()
        let heartbeatData = try client.createHeartbeatPayload(sequence: 42)
        let json = try JSONSerialization.jsonObject(with: heartbeatData) as? [String: Any]

        XCTAssertEqual(json?["op"] as? Int, DiscordOpCode.heartbeat.rawValue)
        XCTAssertEqual(json?["d"] as? Int, 42)
    }

    func testIncomingHelloAndHeartbeatAckPayloads() throws {
        let client = DiscordGatewayClient()
        client.connect()
        XCTAssertTrue(client.isConnected)

        // 1. Process OpCode 10 (Hello)
        let helloData = try JSONEncoder().encode(DiscordHelloData(heartbeatInterval: 41250))
        let helloResult = client.handleIncomingPayload(op: .hello, data: helloData)
        XCTAssertEqual(helloResult, "Configured heartbeat interval: 41250ms")

        // 2. Process OpCode 11 (Heartbeat ACK)
        let ackResult = client.handleIncomingPayload(op: .heartbeatAck, data: Data())
        XCTAssertEqual(ackResult, "Heartbeat ACK recorded")
        XCTAssertNotNil(client.lastHeartbeatAckReceived)

        client.disconnect()
        XCTAssertFalse(client.isConnected)
    }

    func testIncomingMessageDispatchPayload() throws {
        let client = DiscordGatewayClient()
        let sampleMsg = DiscordGatewayMessage(
            id: "msg_998877",
            channelId: "chan_112233",
            content: "@ApexAgent review PR #42",
            authorName: "DeveloperDan",
            isBot: false
        )
        let msgData = try JSONEncoder().encode(sampleMsg)
        let dispatchResult = client.handleIncomingPayload(op: .dispatch, data: msgData)

        XCTAssertEqual(dispatchResult, "Dispatched message: @ApexAgent review PR #42")
        XCTAssertEqual(client.receivedMessages.count, 1)
        XCTAssertEqual(client.receivedMessages.first?.authorName, "DeveloperDan")
    }
}
