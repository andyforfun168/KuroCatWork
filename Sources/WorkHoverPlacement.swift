import AppKit

/// Places an upright hover card in global screen coordinates, avoiding the protected cat head/body.
/// The same calculation accepts a synthetic visible frame for deterministic previews.
enum WorkHoverPlacement {
    static func frame(anchor: CGRect, avoiding pet: CGRect, preferredSize: CGSize,
                      visibleFrame: CGRect, margin: CGFloat = 14, gap: CGFloat = 6) -> CGRect {
        let inset = min(margin, max(0, min(visibleFrame.width, visibleFrame.height) / 4))
        let safe = visibleFrame.insetBy(dx: inset, dy: inset)
        let size = CGSize(width: min(max(1, preferredSize.width), safe.width),
                          height: min(max(1, preferredSize.height), safe.height))
        func clamp(_ r: CGRect) -> CGRect {
            CGRect(x: min(max(r.minX, safe.minX), safe.maxX - size.width),
                   y: min(max(r.minY, safe.minY), safe.maxY - size.height),
                   width: size.width, height: size.height)
        }
        let right = CGRect(x: anchor.maxX + gap,
                           y: anchor.midY - size.height / 2, width: size.width, height: size.height)
        let left = CGRect(x: anchor.minX - gap - size.width,
                          y: anchor.midY - size.height / 2, width: size.width, height: size.height)
        // Clamp only vertically first, preserving the requested side and avoiding the pet.
        for r in [right, left] where r.minX >= safe.minX && r.maxX <= safe.maxX {
            let bounded = clamp(r)
            if !bounded.intersects(pet) { return bounded }
        }
        let minY = CGRect(x: anchor.midX - size.width / 2, y: anchor.minY - gap - size.height,
                          width: size.width, height: size.height)
        let maxY = CGRect(x: anchor.midX - size.width / 2, y: anchor.maxY + gap,
                          width: size.width, height: size.height)
        // Tight spaces: choose the bounded candidate with the least overlap, then least movement.
        return [right, left, minY, maxY].map(clamp).enumerated().min { a, b in
            func score(_ r: CGRect, _ index: Int) -> CGFloat {
                let overlap = r.intersection(pet)
                let area = overlap.isNull ? 0 : overlap.width * overlap.height
                return area * 1000 + hypot(r.midX - anchor.midX, r.midY - anchor.midY) + CGFloat(index) * 0.001
            }
            return score(a.element, a.offset) < score(b.element, b.offset)
        }!.element
    }

    static func frameOnScreen(anchor: CGRect, avoiding pet: CGRect, preferredSize: CGSize) -> CGRect? {
        let center = CGPoint(x: anchor.midX, y: anchor.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) }
            ?? NSScreen.screens.max { a, b in
                func area(_ f: CGRect) -> CGFloat {
                    let r = f.intersection(anchor)
                    return r.isNull ? 0 : r.width * r.height
                }
                return area(a.frame) < area(b.frame)
            }
        guard let screen else { return nil }
        return frame(anchor: anchor, avoiding: pet, preferredSize: preferredSize,
                     visibleFrame: screen.visibleFrame)
    }
}
