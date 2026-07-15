import Testing
import Foundation
@testable import ApexAgentCore

@Suite("StateGraphTests") final class StateGraphTests {
    
    @Test func testStateGraphStateThrowingTypedAccessors() throws {
        var state = StateGraphState()
        state.values["stringValue"] = "Hello"
        state.values["intValue"] = 42
        state.values["boolValue"] = true
        
        // Test correct retrievals
        let str: String = try state.get("stringValue")
        #expect(str == "Hello")
        
        let val: Int = try state.get("intValue")
        #expect(val == 42)
        
        let flag: Bool = try state.get("boolValue")
        #expect(flag)
        
        // Test optional correct retrievals
        let optStr: String? = try state.getOptional("stringValue")
        #expect(optStr == "Hello")
        
        let missingOpt: String? = try state.getOptional("nonexistent")
        #expect(missingOpt == nil)
        
        // Test nonexistent key throws keyNotFound
        do {
            _ = try state.get("nonexistent") as String
            Issue.record("Expected state.get to throw an error")
        } catch let stateError as StateGraphStateError {
            if case .keyNotFound(let key) = stateError {
                #expect(key == "nonexistent")
            } else {
                Issue.record("Expected keyNotFound error, got \(stateError)")
            }
        } catch {
            Issue.record("Expected StateGraphStateError, got \(error)")
        }
        
        // Test type mismatch throws typeMismatch
        do {
            _ = try state.get("intValue") as String
            Issue.record("Expected state.get to throw an error")
        } catch let stateError as StateGraphStateError {
            if case .typeMismatch(let expected, let actual) = stateError {
                let expectedIsString = expected == String.self
                #expect(expectedIsString)
                let actualIsInt = actual == Int.self
                #expect(actualIsInt)
            } else {
                Issue.record("Expected typeMismatch error, got \(stateError)")
            }
        } catch {
            Issue.record("Expected StateGraphStateError, got \(error)")
        }
    }
}
