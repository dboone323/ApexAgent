import Foundation
import ScreenCaptureKit
import AppKit
import CoreMedia

@MainActor
class ScreenStreamer: NSObject, SCStreamDelegate, SCStreamOutput {
    static let shared = ScreenStreamer()
    
    private var stream: SCStream?
    private(set) var circularBuffer: [NSImage] = []
    private let maxBufferCount = 5
    private let captureQueue = DispatchQueue(label: "com.apexagent.screen.capture")
    
    func startCapture() async {
        guard stream == nil else { return }
        
        do {
            // 1. Get shareable content
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                print("No displays found for screen capture.")
                return
            }
            
            // 2. Create filter and configuration
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = 1024 // Scale down to optimize memory
            config.height = 768
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // Capture 1 frame per second
            config.queueDepth = 3
            
            // 3. Create stream
            let activeStream = SCStream(filter: filter, configuration: config, delegate: self)
            try activeStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
            
            try await activeStream.startCapture()
            self.stream = activeStream
            print("ScreenCaptureKit streaming started.")
        } catch {
            print("Failed to start ScreenCaptureKit stream: \(error.localizedDescription)")
        }
    }
    
    func stopCapture() {
        guard let activeStream = stream else { return }
        activeStream.stopCapture { _ in }
        stream = nil
        print("ScreenCaptureKit streaming stopped.")
    }
    
    func getLatestFrame() -> NSImage? {
        return circularBuffer.last
    }
    
    // MARK: - SCStreamOutput
    
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvImageBuffer: imageBuffer)
        let context = CIContext(options: nil)
        
        guard let cgImage = context.createCGImage(ciImage, from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(imageBuffer), height: CVPixelBufferGetHeight(imageBuffer))) else {
            return
        }
        
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        
        DispatchQueue.main.async {
            let streamer = ScreenStreamer.shared
            streamer.circularBuffer.append(nsImage)
            if streamer.circularBuffer.count > streamer.maxBufferCount {
                streamer.circularBuffer.removeFirst()
            }
        }
    }
    
    // MARK: - SCStreamDelegate
    
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("ScreenCaptureKit stream stopped with error: \(error.localizedDescription)")
        DispatchQueue.main.async {
            ScreenStreamer.shared.stream = nil
        }
    }
}
