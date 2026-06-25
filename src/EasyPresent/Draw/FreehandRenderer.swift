import AppKit

/// Renders smooth freehand paths using Catmull-Rom spline interpolation.
enum FreehandRenderer {

    /// Generates a smoothed NSBezierPath from raw input points using Catmull-Rom subdivision.
    /// Falls back to simple line segments if fewer than 4 points are available.
    static func smoothedPath(from rawPoints: [CGPoint]) -> NSBezierPath {
        let points = movingAverage(rawPoints, windowRadius: 2)
        let path = NSBezierPath()
        guard !points.isEmpty else { return path }

        if points.count < 3 {
            path.move(to: points[0])
            for i in 1..<points.count {
                path.line(to: points[i])
            }
            return path
        }

        // Use Catmull-Rom → Bézier conversion
        path.move(to: points[0])

        for i in 0..<points.count - 1 {
            let p0 = points[max(i - 1, 0)]
            let p1 = points[i]
            let p2 = points[min(i + 1, points.count - 1)]
            let p3 = points[min(i + 2, points.count - 1)]

            // Catmull-Rom to cubic Bézier control points
            // Using alpha=0.5 (centripetal parameterization) for smoother curves
            let cp1 = CGPoint(
                x: p1.x + (p2.x - p0.x) / 6.0,
                y: p1.y + (p2.y - p0.y) / 6.0
            )
            let cp2 = CGPoint(
                x: p2.x - (p3.x - p1.x) / 6.0,
                y: p2.y - (p3.y - p1.y) / 6.0
            )

            path.curve(to: p2, controlPoint1: cp1, controlPoint2: cp2)
        }

        return path
    }

    /// Symmetric moving-average over a window of `2*radius+1` samples.
    /// Endpoints are preserved so the stroke doesn't pull inward at start/end.
    static func movingAverage(_ points: [CGPoint], windowRadius: Int) -> [CGPoint] {
        guard windowRadius > 0, points.count > 2 else { return points }
        var smoothed: [CGPoint] = []
        smoothed.reserveCapacity(points.count)
        for i in 0..<points.count {
            if i == 0 || i == points.count - 1 {
                smoothed.append(points[i])
                continue
            }
            let lo = max(0, i - windowRadius)
            let hi = min(points.count - 1, i + windowRadius)
            var sx: CGFloat = 0, sy: CGFloat = 0
            for j in lo...hi { sx += points[j].x; sy += points[j].y }
            let n = CGFloat(hi - lo + 1)
            smoothed.append(CGPoint(x: sx / n, y: sy / n))
        }
        return smoothed
    }
}
