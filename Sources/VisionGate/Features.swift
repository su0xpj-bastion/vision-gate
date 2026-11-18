import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// Integration bugs, switched on with VG_FAULTS=a,b. None is a bug in Vision or Core ML: each is
/// a mistake an app makes around them, which is where on-device ML features actually break.
public enum Fault: String, CaseIterable {
    case ignoresOrientation      // passes .up instead of the photo's EXIF orientation
    case horizonSignFlipped      // rotates by +tilt instead of -tilt: "straighten" doubles the tilt
    case saliencyRowsFlipped     // reads the saliency heatmap bottom-up
    case visionBoxNotFlipped     // uses Vision's bottom-left boxes as if they were top-left
    case trackerNotResetAtCut    // keeps a lost tracker running across a shot cut
    case ocrFastPath             // .fast recognition for titles (drops case and punctuation)
    case duplicateThresholdLoose // groups shots that only share a location
    case int2ModelShipped        // the 2-bit model went out instead of the int8 one
    case modelInputBGR           // feeds BGR into an RGB model

    public static var active: Set<Fault> = {
        Set((ProcessInfo.processInfo.environment["VG_FAULTS"] ?? "").split(separator: ",").compactMap { Fault(rawValue: String($0)) })
    }()
    public static func on(_ f: Fault) -> Bool { active.contains(f) }
}

/// Runs Vision requests. `cpuOnly` forces the CPU path, for CPU-vs-GPU/Neural Engine parity checks.
enum VN {
    static func perform(_ r: VNImageBasedRequest, _ img: CGImage, _ o: CGImagePropertyOrientation, cpuOnly: Bool) throws {
        r.usesCPUOnly = cpuOnly
        try VNImageRequestHandler(cgImage: img, orientation: Fault.on(.ignoresOrientation) ? .up : o, options: [:]).perform([r])
    }

    /// Vision boxes have a bottom-left origin; the app works top-left.
    static func topLeft(_ r: CGRect) -> Box {
        Box(Double(r.minX), Fault.on(.visionBoxNotFlipped) ? Double(r.minY) : Double(1 - r.maxY), Double(r.width), Double(r.height))
    }

    static func bottomLeft(_ b: Box) -> CGRect { CGRect(x: b.x, y: 1 - b.y - b.h, width: b.w, height: b.h) }
}

/// Auto-straighten: measure the horizon's tilt, rotate by the opposite angle.
public enum AutoStraighten {
    /// Horizon tilt in degrees (VNHorizonObservation convention). Vision reports nothing for a
    /// horizon within about half a degree of level, so nil means "level or no horizon".
    public static func tilt(_ img: CGImage, orientation: CGImagePropertyOrientation = .up, cpuOnly: Bool = false) throws -> Double? {
        let r = VNDetectHorizonRequest()
        try VN.perform(r, img, orientation, cpuOnly: cpuOnly)
        return (r.results?.first as? VNHorizonObservation).map { Double($0.angle) * 180 / .pi }
    }

    /// Degrees to rotate the image so the horizon is level.
    public static func correction(_ img: CGImage, orientation: CGImagePropertyOrientation = .up) throws -> Double? {
        try tilt(img, orientation: orientation).map { Fault.on(.horizonSignFlipped) ? $0 : -$0 }
    }

    /// Rotate by `degrees` (same convention) about the centre, scaled up so no empty corners show.
    public static func rotated(_ img: CGImage, degrees: Double) -> CGImage {
        let w = img.width, h = img.height, t = degrees * .pi / 180
        let s = cos(abs(t)) + max(Double(w) / Double(h), Double(h) / Double(w)) * sin(abs(t))
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: Golden.srgb,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.interpolationQuality = .high
        c.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
        // CGContext y runs up, so a positive Vision angle is a negative context rotation.
        c.rotate(by: CGFloat(-t))
        c.scaleBy(x: CGFloat(s), y: CGFloat(s))
        c.draw(img, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        return c.makeImage()!
    }
}

/// Smart crop / reframe: put the crop on the saliency peak (where a viewer looks).
public enum SmartCrop {
    /// Attention focus in display coordinates (0...1, top-left), from the saliency heatmap peak.
    public static func focus(_ img: CGImage, orientation: CGImagePropertyOrientation = .up, cpuOnly: Bool = false) throws -> (Double, Double) {
        let r = VNGenerateAttentionBasedSaliencyImageRequest()
        try VN.perform(r, img, orientation, cpuOnly: cpuOnly)
        guard let pb = (r.results?.first as? VNSaliencyImageObservation)?.pixelBuffer else { return (0.5, 0.5) }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb) / 4
        let p = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: Float.self)
        var best: Float = -1, bx = 0, by = 0
        for y in 0..<h { for x in 0..<w where p[y * row + x] > best { best = p[y * row + x]; bx = x; by = y } }
        let fy = (Double(by) + 0.5) / Double(h)
        // The heatmap's first row is the top of the image.
        return ((Double(bx) + 0.5) / Double(w), Fault.on(.saliencyRowsFlipped) ? 1 - fy : fy)
    }

    /// Largest crop of `aspect` (width / height, in pixels) centred on the focus, kept inside the frame.
    public static func crop(_ img: CGImage, aspect: Double, orientation: CGImagePropertyOrientation = .up) throws -> Box {
        let rotated = [.left, .right, .leftMirrored, .rightMirrored].contains(orientation) && !Fault.on(.ignoresOrientation)
        let dw = Double(rotated ? img.height : img.width), dh = Double(rotated ? img.width : img.height)
        let f = try focus(img, orientation: orientation)
        var w = 1.0, h = 1.0
        if aspect > dw / dh { h = (dw / aspect) / dh } else { w = (dh * aspect) / dw }
        return Box(min(max(0, f.0 - w / 2), 1 - w), min(max(0, f.1 - h / 2), 1 - h), w, h)
    }
}

/// Shot boundaries from colour histograms (64 bins), chi-square distance between consecutive frames.
public enum ShotCuts {
    public static let threshold = 0.5

    static func histogram(_ img: CGImage) -> [Double] {
        let w = 64, h = 36
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: Golden.srgb,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = c.data!.assumingMemoryBound(to: UInt8.self)
        var hist = [Double](repeating: 0, count: 64)
        for i in 0..<(w * h) { hist[Int(p[i * 4]) / 64 * 16 + Int(p[i * 4 + 1]) / 64 * 4 + Int(p[i * 4 + 2]) / 64] += 1 }
        return hist.map { $0 / Double(w * h) }
    }

    public static func distance(_ a: CGImage, _ b: CGImage) -> Double {
        zip(histogram(a), histogram(b)).reduce(0) { $0 + ($1.0 + $1.1 > 0 ? pow($1.0 - $1.1, 2) / ($1.0 + $1.1) : 0) }
    }

    public static func cuts(_ frames: [CGImage]) -> [Int] {
        frames.indices.dropFirst().filter { distance(frames[$0 - 1], frames[$0]) > threshold }
    }
}

/// Follow a subject through a clip (for reframing). At a cut, or when the tracker loses
/// confidence, re-acquire the subject from saliency instead of trusting a stale box.
public enum SubjectTracker {
    public static func track(_ frames: [CGImage], initial: Box) throws -> [Box] {
        var boxes = [initial]
        let cuts = Set(ShotCuts.cuts(frames))
        var handler = VNSequenceRequestHandler()
        var last = VNDetectedObjectObservation(boundingBox: VN.bottomLeft(initial))
        for i in 1..<frames.count {
            var box: Box?
            if !(cuts.contains(i) && !Fault.on(.trackerNotResetAtCut)) {
                let r = VNTrackObjectRequest(detectedObjectObservation: last)
                r.trackingLevel = .accurate
                try handler.perform([r], on: frames[i])
                if let o = r.results?.first as? VNDetectedObjectObservation, o.confidence > 0.3 || Fault.on(.trackerNotResetAtCut) {
                    last = o
                    box = VN.topLeft(o.boundingBox)
                }
            }
            if box == nil {
                // Re-acquire: same size, centred on where attention goes in the new shot.
                let f = try SmartCrop.focus(frames[i])
                let prev = boxes[i - 1]
                let b = Box(min(max(0, f.0 - prev.w / 2), 1 - prev.w), min(max(0, f.1 - prev.h / 2), 1 - prev.h), prev.w, prev.h)
                handler = VNSequenceRequestHandler()
                last = VNDetectedObjectObservation(boundingBox: VN.bottomLeft(b))
                box = b
            }
            boxes.append(box!)
        }
        return boxes
    }
}

/// Burned-in titles and lower thirds, read back for search, captions and a legibility gate.
public enum Titles {
    public static func read(_ img: CGImage, cpuOnly: Bool = false) throws -> [String] {
        let r = VNRecognizeTextRequest()
        r.recognitionLevel = Fault.on(.ocrFastPath) ? .fast : .accurate
        // Titles are names and codes ("Rough Cut v3"), not prose: no autocorrect.
        r.usesLanguageCorrection = false
        try VN.perform(r, img, .up, cpuOnly: cpuOnly)
        return ((r.results as? [VNRecognizedTextObservation]) ?? []).compactMap { $0.topCandidates(1).first?.string }
    }
}

/// Group near-duplicates (re-exports, resized or regraded copies) by Vision feature-print distance.
public enum Duplicates {
    public static var threshold: Float { Fault.on(.duplicateThresholdLoose) ? 10 : 7 }

    public static func prints(_ imgs: [CGImage]) throws -> [VNFeaturePrintObservation] {
        try imgs.map { img in
            let r = VNGenerateImageFeaturePrintRequest()
            try VN.perform(r, img, .up, cpuOnly: false)
            return r.results!.first as! VNFeaturePrintObservation
        }
    }

    public static func distances(_ fps: [VNFeaturePrintObservation]) throws -> [[Float]] {
        try fps.map { a in try fps.map { b in var d: Float = 0; try a.computeDistance(&d, to: b); return d } }
    }

    /// Connected components under the threshold, each group sorted, groups sorted by first index.
    public static func groups(_ imgs: [CGImage]) throws -> [[Int]] {
        let fps = try prints(imgs)
        var parent = Array(imgs.indices)
        func root(_ i: Int) -> Int { var i = i; while parent[i] != i { i = parent[i] }; return i }
        for i in imgs.indices {
            for j in imgs.indices where j > i {
                var d: Float = 0
                try fps[i].computeDistance(&d, to: fps[j])
                if d < threshold { parent[root(j)] = root(i) }
            }
        }
        return Dictionary(grouping: imgs.indices, by: root).values.map { $0.sorted() }.sorted { $0[0] < $1[0] }
    }
}
