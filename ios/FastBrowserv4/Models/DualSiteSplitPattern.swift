import Foundation

/// Visual distribution of Site A and Site B across an even-sized browser grid.
enum DualSiteSplitPattern: String, CaseIterable, Identifiable, Equatable {
    case horizontal
    case vertical
    case checkerboard

    var id: String { rawValue }

    var label: String {
        switch self {
        case .horizontal: return "Horizontal (Left / Right)"
        case .vertical: return "Vertical (Top / Bottom)"
        case .checkerboard: return "Checkerboard"
        }
    }

    var systemImage: String {
        switch self {
        case .horizontal: return "rectangle.split.2x1"
        case .vertical: return "rectangle.split.1x2"
        case .checkerboard: return "checkerboard.rectangle"
        }
    }

    /// Returns 0 for Site A, 1 for Site B, or -1 for a disabled cell.
    ///
    /// Even-sized grids split exactly in half. The 3×3 grid marks its
    /// center (index 4) as disabled (-1); the remaining 8 cells split
    /// into 4 Site A + 4 Site B using the same pattern logic, with
    /// `half = 9 / 2 = 4` (integer division) as the natural threshold.
    func targetSiteIndex(for index: Int, in grid: WindowGridSize) -> Int {
        guard grid.supportsDualSite, index >= 0, index < grid.rawValue else { return 0 }

        // 3×3 center window is unused in dual-site mode.
        if grid == .nine, index == 4 { return -1 }

        let row = index / grid.columns
        let column = index % grid.columns
        let half = grid.rawValue / 2

        switch self {
        case .horizontal:
            let columnMajorIndex = column * grid.rows + row
            return columnMajorIndex < half ? 0 : 1
        case .vertical:
            return index < half ? 0 : 1
        case .checkerboard:
            return (row + column) % 2
        }
    }
}
