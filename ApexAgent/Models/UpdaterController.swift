import Foundation
import Sparkle

@MainActor
class UpdaterController: NSObject, ObservableObject {
    static let shared = UpdaterController()
    
    private var updaterController: SPUStandardUpdaterController?
    
    override init() {
        super.init()
        // Prevent Sparkle from starting and showing dialogs during unit tests
        if NSClassFromString("XCTestCase") != nil || 
           ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil ||
           ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        // Initialize the Sparkle updater controller
        self.updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }
    
    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }
}
