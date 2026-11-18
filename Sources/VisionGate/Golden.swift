import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// Deterministic test images with known answers. No downloaded datasets: every image is drawn
/// from a seed, so the golden set is reproducible on any Mac, iPhone simulator or CI runner.
public struct Rng {
    var s: UInt64
    public init(_ seed: UInt64) { s = seed &* 0x9E3779B97F4A7C15 | 1 }
    public mutating func next() -> Double {
        s ^= s << 13; s ^= s >> 7; s ^= s << 17
        return Double(s % 1_000_000) / 1_000_000
    }
}

/// A rectangle in 0...1 units with the origin at the TOP-left (UIKit/SwiftUI convention).
/// Vision reports bottom-left origin; converting is the classic bug this repo guards.
public struct Box: Codable, Equatable {
    public var x, y, w, h: Double
    public init(_ x: Double, _ y: Double, _ w: Double, _ h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
    public var area: Double { max(0, w) * max(0, h) }
    public func intersection(_ o: Box) -> Box {
        let x0 = max(x, o.x), y0 = max(y, o.y), x1 = min(x + w, o.x + o.w), y1 = min(y + h, o.y + o.h)
        return Box(x0, y0, max(0, x1 - x0), max(0, y1 - y0))
    }
    public func iou(_ o: Box) -> Double { let i = intersection(o).area; return i / max(1e-9, area + o.area - i) }
    /// Fraction of `o` inside self.
    public func covers(_ o: Box) -> Double { intersection(o).area / max(1e-9, o.area) }
    public var center: (Double, Double) { (x + w / 2, y + h / 2) }
}

public enum Golden {
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    static func col(_ v: [Double]) -> CGColor { CGColor(colorSpace: srgb, components: v.map { CGFloat($0) })! }

    public static func context(_ w: Int, _ h: Int) -> CGContext {
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Draw in top-left coordinates like every UI framework.
        c.translateBy(x: 0, y: CGFloat(h))
        c.scaleBy(x: 1, y: -1)
        return c
    }

    // MARK: horizon (auto-straighten)

    /// Tilts a user would want fixed. Vision does not report tilts under about 1 degree, so those are
    /// tested separately as "leave a level photo alone" (nearLevelAngles).
    public static let horizonAngles: [Double] = [-8, -6, -4, -3, -2, 2, 3, 4, 6, 8]
    public static let nearLevelAngles: [Double] = [0, 0.4, -0.4]

    /// A landscape whose horizon is tilted `degrees`, in the sign convention VNHorizonObservation.angle uses.
    public static func horizon(degrees: Double, seed: UInt64, w: Int = 1024, h: Int = 768) -> CGImage {
        var r = Rng(seed)
        let c = context(w, h)
        let big = CGFloat(max(w, h)) * 2
        c.saveGState()
        c.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2 + CGFloat(r.next() - 0.5) * 80)
        c.rotate(by: CGFloat(degrees * .pi / 180))   // in flipped (top-left) coordinates this tilts the horizon by +degrees as Vision measures it
        // Sky
        c.setFillColor(col([0.45, 0.65, 0.92, 1]))
        c.fill(CGRect(x: -big, y: -big, width: 2 * big, height: big))
        // Sea and land with bands parallel to the horizon
        for i in 0..<40 {
            let g = 0.25 + 0.25 * r.next()
            c.setFillColor(col([0.1 + 0.1 * r.next(), g, 0.35 + 0.2 * r.next(), 1]))
            c.fill(CGRect(x: -big, y: CGFloat(i) * 12, width: 2 * big, height: 12))
        }
        c.restoreGState()
        // A few clouds (not aligned with the horizon)
        for _ in 0..<5 {
            c.setFillColor(col([1, 1, 1, 0.7]))
            c.fillEllipse(in: CGRect(x: r.next() * Double(w), y: r.next() * Double(h) * 0.25, width: 120, height: 36))
        }
        return c.makeImage()!
    }

    // MARK: saliency (smart crop)

    /// Low-contrast textured backdrop and one vivid subject at a known place.
    public static func subject(seed: UInt64, w: Int = 1024, h: Int = 768) -> (CGImage, Box) {
        var r = Rng(seed)
        let c = context(w, h)
        for y in stride(from: 0, to: h, by: 16) {
            for x in stride(from: 0, to: w, by: 16) {
                let v = 0.55 + 0.06 * r.next()
                c.setFillColor(col([v, v * 0.98, v * 0.95, 1]))
                c.fill(CGRect(x: x, y: y, width: 16, height: 16))
            }
        }
        let side = 140 + r.next() * 80
        let bx = 40 + r.next() * (Double(w) - side - 80), by = 40 + r.next() * (Double(h) - side - 80)
        c.setFillColor(col([0.9, 0.12, 0.1, 1]))
        c.fillEllipse(in: CGRect(x: bx, y: by, width: side, height: side))
        c.setFillColor(col([1, 0.85, 0.1, 1]))
        c.fillEllipse(in: CGRect(x: bx + side * 0.3, y: by + side * 0.3, width: side * 0.4, height: side * 0.4))
        return (c.makeImage()!, Box(bx / Double(w), by / Double(h), side / Double(w), side / Double(h)))
    }

    // MARK: video (tracking + shot cuts)

    public struct Clip {
        public let frames: [CGImage]
        /// Ground-truth subject box per frame (top-left origin).
        public let boxes: [Box]
        /// Index of the first frame of each new shot.
        public let cuts: [Int]
    }

    /// Two shots. A subject moves across a textured scene; at `cut` the scene and subject position change.
    public static func clip(frames n: Int = 48, cut: Int = 24, w: Int = 640, h: Int = 360) -> Clip {
        var frames: [CGImage] = [], boxes: [Box] = []
        for i in 0..<n {
            let shot = i < cut ? 0 : 1
            var r = Rng(UInt64(100 + shot))
            let c = context(w, h)
            let tone = shot == 0 ? [0.3, 0.45, 0.35] : [0.5, 0.35, 0.3]
            for y in stride(from: 0, to: h, by: 20) {
                for x in stride(from: 0, to: w, by: 20) {
                    let v = r.next() * 0.25
                    c.setFillColor(col([tone[0] + v, tone[1] + v, tone[2] + v, 1]))
                    c.fill(CGRect(x: x, y: y, width: 20, height: 20))
                }
            }
            let t = Double(shot == 0 ? i : i - cut) / Double(shot == 0 ? cut : n - cut)
            let side = 64.0
            let (sx, sy) = shot == 0 ? (60 + t * 420, 80 + 120 * sin(t * .pi)) : (500 - t * 380, 220 - t * 120)
            // A checkered subject: corners for the tracker to hold on to.
            for k in 0..<16 {
                let on = (k / 4 + k % 4) % 2 == 0
                c.setFillColor(col(on ? [0.95, 0.95, 0.2, 1] : [0.1, 0.1, 0.5, 1]))
                c.fill(CGRect(x: sx + Double(k % 4) * 16, y: sy + Double(k / 4) * 16, width: 16, height: 16))
            }
            frames.append(c.makeImage()!)
            boxes.append(Box(sx / Double(w), sy / Double(h), side / Double(w), side / Double(h)))
        }
        return Clip(frames: frames, boxes: boxes, cuts: [cut])
    }

    // MARK: titles (OCR)

    public static let titles = [
        "Opening Night", "Chapter 2: The Coast", "Directed by Ana Ruiz", "Lisbon, 1998", "THE END",
        "Shot on iPhone", "Day 14", "Behind the Scenes", "Rough Cut v3", "Color Grade 2026",
    ]
    public static let fonts = ["Helvetica-Bold", "Georgia", "Menlo-Regular", "AvenirNext-DemiBold", "Futura-Medium"]

    /// A title card: text over a solid, gradient or busy background.
    public static func title(_ text: String, font: String, size: CGFloat, background: Int, seed: UInt64, w: Int = 960, h: Int = 540) -> CGImage {
        var r = Rng(seed)
        let c = context(w, h)
        switch background % 3 {
        case 0:
            c.setFillColor(col([0.08, 0.08, 0.1, 1]))
            c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        case 1:
            for y in 0..<h {
                let t = Double(y) / Double(h)
                c.setFillColor(col([0.1 + 0.3 * t, 0.15, 0.4 - 0.2 * t, 1]))
                c.fill(CGRect(x: 0, y: y, width: w, height: 1))
            }
        default:
            for y in stride(from: 0, to: h, by: 24) {
                for x in stride(from: 0, to: w, by: 24) {
                    c.setFillColor(col([0.1 + 0.3 * r.next(), 0.1 + 0.3 * r.next(), 0.1 + 0.3 * r.next(), 1]))
                    c.fill(CGRect(x: x, y: y, width: 24, height: 24))
                }
            }
        }
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(font as CFString, size, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(colorSpace: srgb, components: [1, 1, 1, 1])!,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let bounds = CTLineGetBoundsWithOptions(line, [])
        // CoreText draws bottom-up: flip back for this one call.
        c.saveGState()
        c.translateBy(x: 0, y: CGFloat(h))
        c.scaleBy(x: 1, y: -1)
        c.textPosition = CGPoint(x: (CGFloat(w) - bounds.width) / 2, y: CGFloat(h) * 0.42)
        CTLineDraw(line, c)
        c.restoreGState()
        return c.makeImage()!
    }

    /// A background with no text at all (OCR must return nothing).
    public static func noText(seed: UInt64) -> CGImage { title("", font: "Helvetica", size: 10, background: 2, seed: seed) }

    /// Bold colour stripes: a fifth kind of picture for the duplicate set.
    public static func stripes(seed: UInt64, w: Int = 1024, h: Int = 768) -> CGImage {
        var r = Rng(seed)
        let c = context(w, h)
        var x = 0.0
        while x < Double(w) {
            let bw = 30 + r.next() * 90
            c.setFillColor(col([r.next(), r.next(), r.next(), 1]))
            c.fill(CGRect(x: x, y: 0, width: bw, height: Double(h)))
            x += bw
        }
        return c.makeImage()!
    }

    // MARK: re-encoding helpers (robustness variants)

    public static func jpeg(_ img: CGImage, quality: Double) -> CGImage {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(dest)
        let src = CGImageSourceCreateWithData(data, nil)!
        return CGImageSourceCreateImageAtIndex(src, 0, nil)!
    }

    public static func scaled(_ img: CGImage, _ s: Double) -> CGImage {
        let w = Int(Double(img.width) * s), h = Int(Double(img.height) * s)
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.interpolationQuality = .high
        c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return c.makeImage()!
    }

    /// Multiply light by 2^ev (an exposure change), in sRGB-encoded space (approximate, clamped).
    public static func exposed(_ img: CGImage, ev: Double) -> CGImage {
        let w = img.width, h = img.height
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: srgb,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = c.data!.assumingMemoryBound(to: UInt8.self)
        let k = pow(2, ev / 2.2)
        for i in 0..<(w * h * 4) where i % 4 != 3 { p[i] = UInt8(min(255, Double(p[i]) * k)) }
        return c.makeImage()!
    }

    /// The same picture stored rotated a quarter turn, as a sensor in portrait writes it.
    /// Displaying it correctly needs EXIF orientation `.left` (8), which is what `Golden.storedOrientation` says.
    public static let storedOrientation = CGImagePropertyOrientation.left

    public static func storedRotated(_ img: CGImage) -> CGImage {
        let w = img.height, h = img.width
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.translateBy(x: 0, y: CGFloat(h))
        c.rotate(by: -.pi / 2)
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return c.makeImage()!
    }
}
