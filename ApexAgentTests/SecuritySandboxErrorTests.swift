import Testing
import Foundation
@testable import ApexAgentCore

@Suite("SecuritySandboxErrorTests") final class SecuritySandboxErrorTests {
    
    @Test func testErrorDescriptions() {
        let err1 = SecuritySandboxError.pathViolation("/usr/local/bin")
        #expect(err1.description.contains("outside the allowed workspace"))
        
        let err2 = SecuritySandboxError.symlinkTraversal("/tmp/link")
        #expect(err2.description.contains("contains symlinks"))
        
        let err3 = SecuritySandboxError.desktopFolderRestricted
        #expect(err3.description.contains("Desktop folder access is restricted"))
        
        let err4 = SecuritySandboxError.documentsFolderRestricted
        #expect(err4.description.contains("Documents folder access is restricted"))
        
        let err5 = SecuritySandboxError.downloadsFolderRestricted
        #expect(err5.description.contains("Downloads folder access is restricted"))
        
        let err6 = SecuritySandboxError.musicFolderRestricted
        #expect(err6.description.contains("Music folder access is restricted"))
    }
}
