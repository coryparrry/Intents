import Foundation

/// A shared, monotonic time axis. Crowded event boundaries receive extra space;
/// the remaining time ranges share the remaining width in proportion to duration.
struct WorkflowTimelineScale {
    let extent: Double
    let width: Double
    let times: [Double]
    let positions: [Double]

    /// Builds a piecewise-linear axis from valid unique boundaries, reserving minimum spacing while retaining proportional time ranges.
    init(boundaries: [Double], extent: Double, width: Double) {
        self.extent = extent.isFinite && extent > 0 ? extent : 0
        self.width = width.isFinite && width > 0 ? width : 0
        guard self.extent > 0, self.width > 0 else {
            times = [0]
            positions = [0]
            return
        }
        let times = Set(boundaries.filter { $0.isFinite && $0 >= 0 && $0 <= extent } + [0, extent]).sorted()
        let weights = zip(times, times.dropFirst()).map { ($1 - $0) / extent }
        // Dense traces still fit. Never reserve more than half the viewport for
        // minimum spacing; genuine long operations keep the remaining space.
        let minimum = min(16, width / (2 * Double(weights.count)))
        var remainingWidth = width
        var remainingWeight = 1.0
        var lengths = Array(repeating: 0.0, count: weights.count)
        let shortestFirst = weights.indices.sorted { weights[$0] < weights[$1] }
        for index in shortestFirst {
            let proportionalWidth = weights[index] / remainingWeight * remainingWidth
            guard proportionalWidth < minimum else { break }
            lengths[index] = minimum
            remainingWidth -= minimum
            remainingWeight -= weights[index]
        }
        var positions = [0.0]
        var position = 0.0
        for index in weights.indices {
            let length = lengths[index] > 0 ? lengths[index] : weights[index] / remainingWeight * remainingWidth
            position += length
            positions.append(position)
        }
        positions[positions.count - 1] = width
        self.times = times
        self.positions = positions
    }

    /// Maps a time to its clamped axis position, returning zero for nonfinite input or an empty axis.
    func position(at time: Double) -> Double {
        interpolate(time, from: times, to: positions)
    }

    /// Maps an axis position back to clamped time, returning zero for nonfinite input or an empty axis.
    func time(at position: Double) -> Double {
        interpolate(position, from: positions, to: times)
    }

    /// Finds the enclosing source interval by binary search and linearly interpolates, clamping outside its endpoints.
    private func interpolate(_ value: Double, from source: [Double], to destination: [Double]) -> Double {
        guard value.isFinite, source.count > 1 else { return 0 }
        if value <= source[0] { return destination[0] }
        if value >= source[source.count - 1] { return destination[destination.count - 1] }
        var low = 0
        var high = source.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if source[middle] <= value { low = middle } else { high = middle }
        }
        let fraction = (value - source[low]) / (source[high] - source[low])
        return destination[low] + fraction * (destination[high] - destination[low])
    }
}

/// Display coordinates for one validated span on the shared timeline scale.
struct WorkflowTimelineInterval {
    let displayOffset: Double
    let displayWidth: Double

    /// Projects a valid span onto the shared axis, using a small marker for instants and zero width for invalid intervals.
    init(start: Double, end: Double, scale: WorkflowTimelineScale) {
        guard start.isFinite, end.isFinite, start >= 0, end >= start,
              end <= scale.extent, scale.extent > 0, scale.width > 0 else {
            displayOffset = 0
            displayWidth = 0
            return
        }
        let left = scale.position(at: start)
        let right = scale.position(at: end)
        // Nonzero spans use the shared axis exactly, preserving sequential
        // boundaries and true parent/child overlap. Only instants need a marker.
        displayWidth = start == end ? min(2, scale.width) : max(0, right - left)
        displayOffset = min(left, scale.width - displayWidth)
    }
}
