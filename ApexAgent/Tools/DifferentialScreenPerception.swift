import Foundation
import FoundationModels
import AppKit
import CoreGraphics
import ScreenCaptureKit

struct DifferentialScreenPerception: Tool {
    let orchestrator: AgentOrchestrator
    
    let name = "screen_diff"
    let description = "Captures only the changed regions of the screen since the last call. Returns Base64-encoded PNG of bounding box of changed regions, plus description. First call returns full screen."
    
    @Generable struct Arguments: Decodable {
        let displayIndex: Int?
        let resetCache: Bool?
    }
    
    nonisolated(unsafe) private static var previousFrame: CGImage? = nil
    
    func call(arguments: Arguments) async throws -> String {
        guard #available(macOS 14.0, *) else {
            return "{\"error\": \"Requires macOS 14.0+\"}"
        }
        
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            return "{\"error\": \"No display found\"}"
        }
        
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.pixelFormat = kCVPixelFormatType_32BGRA
        
        let screenImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        
        if arguments.resetCache == true || DifferentialScreenPerception.previousFrame == nil {
            DifferentialScreenPerception.previousFrame = screenImage
            let b64 = cgImageToBase64PNG(screenImage)
            return """
            {
                "changed": true,
                "region": "full_screen",
                "image_base64": "\(b64)",
                "description": "Full screen captured."
            }
            """
        }
        
        guard let prevImage = DifferentialScreenPerception.previousFrame else {
            return "{\"error\": \"Unexpected missing previous frame\"}"
        }
        DifferentialScreenPerception.previousFrame = screenImage
        
        let changedRect = Self.computeBoundingBoxDifference(frame1: prevImage, frame2: screenImage)
        
        guard let rect = changedRect else {
            return """
            {
                "changed": false,
                "region": "none",
                "image_base64": "",
                "description": "No significant changes detected."
            }
            """
        }
        
        guard let cropped = screenImage.cropping(to: rect) else {
            return "{\"error\": \"Failed to crop image\"}"
        }
        
        let b64 = cgImageToBase64PNG(cropped)
        return """
        {
            "changed": true,
            "region": "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))",
            "image_base64": "\(b64)",
            "description": "Screen region changed."
        }
        """
    }
    
    public static func computeBoundingBoxDifference(frame1: CGImage, frame2: CGImage) -> CGRect? {
        let w = frame2.width
        let h = frame2.height
        
        let context1 = CGContext(data: nil, width: 100, height: 75, bitsPerComponent: 8, bytesPerRow: 100, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        context1?.draw(frame1, in: CGRect(x: 0, y: 0, width: 100, height: 75))
        let gray1 = context1?.makeImage()
        
        let context2 = CGContext(data: nil, width: 100, height: 75, bitsPerComponent: 8, bytesPerRow: 100, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        context2?.draw(frame2, in: CGRect(x: 0, y: 0, width: 100, height: 75))
        let gray2 = context2?.makeImage()
        
        guard let g1 = gray1, let g2 = gray2,
              let data1 = g1.dataProvider?.data,
              let data2 = g2.dataProvider?.data else {
            return nil
        }
        
        let ptr1 = CFDataGetBytePtr(data1)
        let ptr2 = CFDataGetBytePtr(data2)
        
        var minX = 100
        var minY = 75
        var maxX = -1
        var maxY = -1
        
        for y in 0..<75 {
            for x in 0..<100 {
                let offset = y * 100 + x
                let val1 = Int(ptr1![offset])
                let val2 = Int(ptr2![offset])
                if abs(val1 - val2) > 15 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        
        guard minX <= maxX && minY <= maxY else {
            return nil
        }
        
        let scaleX = CGFloat(w) / 100.0
        let scaleY = CGFloat(h) / 75.0
        
        let realX = CGFloat(minX) * scaleX - 20
        let realY = CGFloat(minY) * scaleY - 20
        let realW = CGFloat(maxX - minX + 1) * scaleX + 40
        let realH = CGFloat(maxY - minY + 1) * scaleY + 40
        
        let finalX = max(0, realX)
        let finalY = max(0, realY)
        let finalW = min(CGFloat(w) - finalX, realW)
        let finalH = min(CGFloat(h) - finalY, realH)
        
        return CGRect(x: finalX, y: finalY, width: finalW, height: finalH)
    }
    
    private func cgImageToBase64PNG(_ image: CGImage) -> String {
        let bitmapRep = NSBitmapImageRep(cgImage: image)
        guard let data = bitmapRep.representation(using: .png, properties: [:]) else { return "" }
        return data.base64EncodedString()
    }
}
