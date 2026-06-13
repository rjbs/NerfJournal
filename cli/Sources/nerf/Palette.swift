import SwiftUI

// The CLI mirrors the app's CategoryColor.swatch palette by resolving the very
// same SwiftUI system colors the app draws with, so `nerf categories` reports the
// exact colors macOS renders in the UI rather than a hand-copied approximation.
// SwiftUI's Color.blue and NSColor.systemBlue resolve identically here, but going
// through the SwiftUI colors keeps the CLI tied to whatever the app actually uses.
// -- claude, 2026-06-13
enum Palette {
    static func color(named name: String) -> Color {
        switch name {
        case "blue":   return .blue
        case "red":    return .red
        case "green":  return .green
        case "orange": return .orange
        case "purple": return .purple
        case "pink":   return .pink
        case "teal":   return .teal
        case "yellow": return .yellow
        default:       return .gray
        }
    }

    static func rgb(named name: String) -> (r: Int, g: Int, b: Int) {
        let resolved = color(named: name).resolve(in: EnvironmentValues())
        func byte(_ v: Float) -> Int { Int((v * 255).rounded()) }
        return (byte(resolved.red), byte(resolved.green), byte(resolved.blue))
    }

    static func hex(named name: String) -> String {
        let (r, g, b) = rgb(named: name)
        return String(format: "#%02x%02x%02x", r, g, b)
    }

    // A filled circle in the color, using a 24-bit-color ANSI escape.
    static func swatch(named name: String) -> String {
        let (r, g, b) = rgb(named: name)
        return "\u{001B}[38;2;\(r);\(g);\(b)m●\u{001B}[0m"
    }
}
