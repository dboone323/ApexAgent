import SwiftUI

struct StyledSegment: Identifiable {
    let id = UUID()
    let text: String
    var foregroundColor: Color = .primary
    var isBold: Bool = false
}

struct ANSIColorParser {
    static func parse(_ text: String) -> [StyledSegment] {
        var segments: [StyledSegment] = []
        let scanner = Scanner(string: text)
        scanner.charactersToBeSkipped = nil
        
        var currentText = ""
        var foregroundColor = Color.primary
        var isBold = false
        
        func commitSegment() {
            if !currentText.isEmpty {
                segments.append(StyledSegment(text: currentText, foregroundColor: foregroundColor, isBold: isBold))
                currentText = ""
            }
        }
        
        while !scanner.isAtEnd {
            if let upToEsc = scanner.scanUpToString("\u{001B}") {
                currentText += upToEsc
            }
            
            if scanner.scanString("\u{001B}") != nil {
                commitSegment()
                
                if scanner.scanString("[") != nil {
                    if let codesStr = scanner.scanUpToString("m") {
                        _ = scanner.scanString("m") // Consume 'm'
                        let codes = codesStr.components(separatedBy: ";").compactMap { Int($0) }
                        
                        if codes.isEmpty {
                            foregroundColor = .primary
                            isBold = false
                        } else {
                            for code in codes {
                                switch code {
                                case 0:
                                    foregroundColor = .primary
                                    isBold = false
                                case 1:
                                    isBold = true
                                case 22:
                                    isBold = false
                                // Standard colors
                                case 30: foregroundColor = .black
                                case 31: foregroundColor = .red
                                case 32: foregroundColor = .green
                                case 33: foregroundColor = .yellow
                                case 34: foregroundColor = .blue
                                case 35: foregroundColor = .purple
                                case 36: foregroundColor = .cyan
                                case 37: foregroundColor = .white
                                // Bright colors
                                case 90: foregroundColor = .gray
                                case 91: foregroundColor = .red
                                case 92: foregroundColor = .green
                                case 93: foregroundColor = .yellow
                                case 94: foregroundColor = .blue
                                case 95: foregroundColor = .purple
                                case 96: foregroundColor = .cyan
                                case 97: foregroundColor = .white
                                // Reset foreground
                                case 39: foregroundColor = .primary
                                default: break
                                }
                            }
                        }
                    } else {
                        currentText += "\u{001B}["
                    }
                } else {
                    currentText += "\u{001B}"
                }
            }
        }
        commitSegment()
        return segments
    }
}
