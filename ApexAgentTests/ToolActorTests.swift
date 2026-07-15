import Testing
import Foundation
@testable import ApexAgentCore

@ToolActor
private final class TestActorHelper {
    var stateValue = 0
    func increment() {
        stateValue += 1
    }
}

@Suite("ToolActorTests") final class ToolActorTests {
    
    @Test func testToolActorIsolation() async {
        let helper = TestActorHelper()
        await helper.increment()
        let value = await helper.stateValue
        #expect(value == 1)
    }
}
