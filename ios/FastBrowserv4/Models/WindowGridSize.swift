import Foundation

/// The available multi-window tiling layouts. Every size uses the same
/// isolated browser cell; only the window count and grid shape change.
enum WindowGridSize: Int, CaseIterable, Identifiable, Equatable {
    case four = 4
    case six = 6
    case eight = 8
    case nine = 9
    case twelve = 12
    case sixteen = 16

    var id: Int { rawValue }

    var rows: Int {
        switch self {
        case .four, .six, .eight: return 2
        case .nine, .twelve: return 3
        case .sixteen: return 4
        }
    }

    var columns: Int {
        switch self {
        case .four: return 2
        case .six, .nine: return 3
        case .eight, .twelve: return 4
        case .sixteen: return 4
        }
    }

    /// User-facing orientation. The eight-window option is intentionally
    /// named 4×2 (four across, two down) to match the requested layout.
    var label: String {
        switch self {
        case .eight: return "4×2"
        default: return "\(rows)×\(columns)"
        }
    }

    /// All even-sized grids support dual-site. The 3×3 grid also supports
    /// it, but with the center window (index 4) automatically disabled so
    /// the remaining 8 windows split evenly into 4 A/B lane pairs.
    var supportsDualSite: Bool { rawValue.isMultiple(of: 2) || self == .nine }

    /// Index of the cell that becomes "Unused" in dual-site mode.
    /// Only the 3×3 grid has one (the geometric center at index 4).
    var disabledIndexInDualSite: Int? { self == .nine ? 4 : nil }
}
