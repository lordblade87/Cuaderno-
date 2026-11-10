import PencilKit

/// Convierte un trazo a mano alzada en línea, triángulo, rectángulo, círculo o elipse.
enum ShapeRecognizer {

    static func recognize(_ stroke: PKStroke) -> PKStroke? {
        var pts: [CGPoint] = []
        for p in stroke.path {
            pts.append(p.location.applying(stroke.transform))
        }
        guard let o = outline(pts) else { return nil }
        return make(o, from: stroke)
    }

    /// Devuelve el contorno de la figura reconocida, o nil si no es ninguna.
    static func outline(_ input: [CGPoint]) -> [CGPoint]? {
        var pts = input
        guard pts.count >= 3, let lastP = pts.last else { return nil }

        // Saca los puntos del final, donde el lápiz quedó quieto
        var j = pts.count - 1
        while j > 0 && dist(pts[j - 1], lastP) < 5 { j -= 1 }
        if j < pts.count - 1 { pts.removeSubrange((j + 1)...) }
        guard pts.count >= 2 else { return nil }

        let box = bounds(pts)
        let diag = hypot(box.width, box.height)
        guard diag > 15 else { return nil }

        var length: CGFloat = 0
        for i in 1..<pts.count { length += dist(pts[i - 1], pts[i]) }
        guard length > 0 else { return nil }

        let first = pts[0]
        let last = pts[pts.count - 1]

        // Línea recta
        if dist(first, last) / length > 0.9 {
            return polygon([first, last], closed: false)
        }

        // A partir de acá solo figuras cerradas
        guard dist(first, last) < max(diag * 0.3, 20) else { return nil }

        var closed = pts
        closed.append(first)
        var corners = rdp(closed, eps: diag * 0.08)
        if corners.count > 1 { corners.removeLast() }
        corners = dropFlat(corners)

        if corners.count == 4 && axisAligned(corners) {
            let r = bounds(corners)
            let rect = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                        CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
            return polygon(rect, closed: true)
        }
        if corners.count == 3 || corners.count == 4 {
            return polygon(corners, closed: true)
        }

        // Círculo / elipse
        let cx = box.midX, cy = box.midY
        let rx = max(box.width / 2, 1), ry = max(box.height / 2, 1)
        var err: CGFloat = 0
        for p in pts { err += abs(hypot((p.x - cx) / rx, (p.y - cy) / ry) - 1) }
        err /= CGFloat(pts.count)
        guard err < 0.22 else { return nil }

        let ratio = rx / ry
        if ratio > 0.85 && ratio < 1.18 {
            let r = (rx + ry) / 2
            return ellipse(CGPoint(x: cx, y: cy), r, r)
        }
        return ellipse(CGPoint(x: cx, y: cy), rx, ry)
    }

    // MARK: Construcción de trazos

    private static func polygon(_ poly: [CGPoint], closed: Bool) -> [CGPoint] {
        var seq = poly
        if closed, let f = poly.first { seq.append(f) }
        var out: [CGPoint] = []
        for i in 0..<(seq.count - 1) {
            let a = seq[i], b = seq[i + 1]
            let n = max(2, Int(dist(a, b) / 3))
            out.append(a)
            out.append(a) // punto repetido = esquina filosa
            for k in 1..<n {
                let t = CGFloat(k) / CGFloat(n)
                out.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        if let l = seq.last { out += [l, l, l] }
        return out
    }

    private static func ellipse(_ c: CGPoint, _ rx: CGFloat, _ ry: CGFloat) -> [CGPoint] {
        var out: [CGPoint] = []
        let n = 96
        for i in 0...n {
            let a = CGFloat(i) / CGFloat(n) * 2 * .pi - .pi / 2
            out.append(CGPoint(x: c.x + rx * cos(a), y: c.y + ry * sin(a)))
        }
        return out
    }

    static func make(_ points: [CGPoint], from s: PKStroke) -> PKStroke {
        let ref = s.path[s.path.count / 2]
        var t: TimeInterval = 0
        var list: [PKStrokePoint] = []
        for p in points {
            list.append(PKStrokePoint(location: p, timeOffset: t, size: ref.size, opacity: ref.opacity,
                                      force: ref.force, azimuth: ref.azimuth, altitude: ref.altitude))
            t += 0.004
        }
        let path = PKStrokePath(controlPoints: list, creationDate: s.path.creationDate)
        return PKStroke(ink: s.ink, path: path, transform: .identity, mask: nil)
    }

    // MARK: Geometría

    private static func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private static func bounds(_ pts: [CGPoint]) -> CGRect {
        let xs = pts.map { $0.x }, ys = pts.map { $0.y }
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 0, minY = ys.min() ?? 0, maxY = ys.max() ?? 0
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func lineDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        if len < 0.001 { return dist(p, a) }
        return abs(dy * p.x - dx * p.y + b.x * a.y - b.y * a.x) / len
    }

    /// Ramer–Douglas–Peucker: deja solo los vértices importantes.
    private static func rdp(_ pts: [CGPoint], eps: CGFloat) -> [CGPoint] {
        guard pts.count > 2, let a = pts.first, let b = pts.last else { return pts }
        var maxD: CGFloat = 0
        var index = 0
        for i in 1..<(pts.count - 1) {
            let d = lineDistance(pts[i], a, b)
            if d > maxD { maxD = d; index = i }
        }
        if maxD > eps {
            let left = rdp(Array(pts[0...index]), eps: eps)
            let right = rdp(Array(pts[index...]), eps: eps)
            return Array(left.dropLast()) + right
        }
        return [a, b]
    }

    /// Saca vértices casi planos (ángulo mayor a 150°).
    private static func dropFlat(_ corners: [CGPoint]) -> [CGPoint] {
        var pts = corners
        var changed = true
        while changed && pts.count > 3 {
            changed = false
            let n = pts.count
            for i in 0..<n {
                let a = pts[(i - 1 + n) % n], b = pts[i], c = pts[(i + 1) % n]
                let v1 = CGPoint(x: a.x - b.x, y: a.y - b.y)
                let v2 = CGPoint(x: c.x - b.x, y: c.y - b.y)
                let l = hypot(v1.x, v1.y) * hypot(v2.x, v2.y)
                guard l > 0.001 else { continue }
                let cosA = max(-1, min(1, (v1.x * v2.x + v1.y * v2.y) / l))
                if acos(cosA) * 180 / .pi > 150 {
                    pts.remove(at: i)
                    changed = true
                    break
                }
            }
        }
        return pts
    }

    private static func axisAligned(_ c: [CGPoint]) -> Bool {
        for i in 0..<c.count {
            let a = c[i], b = c[(i + 1) % c.count]
            var ang = abs(atan2(b.y - a.y, b.x - a.x) * 180 / .pi).truncatingRemainder(dividingBy: 90)
            if ang > 45 { ang = 90 - ang }
            if ang > 15 { return false }
        }
        return true
    }
}
