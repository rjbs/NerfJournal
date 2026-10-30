import SwiftUI
import NerfCore

// The SwiftUI color for each category color. Lives in the app rather than
// NerfCore so the shared package has no UI dependency. The nerf CLI resolves
// the same system colors by name in its Palette.
extension CategoryColor {
    var swatch: Color {
        switch self {
        case .blue:   return .blue
        case .red:    return .red
        case .green:  return .green
        case .orange: return .orange
        case .purple: return .purple
        case .pink:   return .pink
        case .teal:   return .teal
        case .yellow: return .yellow
        }
    }
}

// Once Category moved into NerfCore it stopped shadowing a same-named type in
// another framework the app imports, so every bare mention became ambiguous.
// This module-level alias restores the unqualified name for the app's sources.
// -- claude, 2026-10-17
typealias Category = NerfCore.Category
