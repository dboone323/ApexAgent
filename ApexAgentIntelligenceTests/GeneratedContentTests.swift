import Testing
import FoundationModels
@testable import ApexAgentCore

@Suite("GeneratedContentTests") final class GeneratedContentTests {
    
    @Test func testToJSONObjectTypes() {
        let stringContent = GeneratedContent(kind: .string("Test Content"))
        #expect(stringContent.toJSONObject() as? String == "Test Content")
        
        let numberContent = GeneratedContent(kind: .number(12.34))
        #expect(numberContent.toJSONObject() as? Double == 12.34)
        
        let boolContent = GeneratedContent(kind: .bool(true))
        #expect(boolContent.toJSONObject() as? Bool == true)
        
        let arrayContent = GeneratedContent(kind: .array([
            GeneratedContent(kind: .string("A")),
            GeneratedContent(kind: .string("B"))
        ]))
        let arrayObj = arrayContent.toJSONObject() as? [Any]
        #expect(arrayObj?.count == 2)
        #expect(arrayObj?[0] as? String == "A")
    }
}
