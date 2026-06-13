import Foundation
import Sparkle

@MainActor
class UpdaterController: NSObject, ObservableObject {
    static let shared = UpdaterController()
    
    private var updaterController: SPUStandardUpdaterController?
    
    override init() {
        super.init()
        // Initialize the Sparkle updater controller
        self.updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }
    
    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }
}
