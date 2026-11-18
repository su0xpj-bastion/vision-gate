import CoreGraphics
import CoreML
import Foundation

/// One gate: a named quality bar on one on-device feature, with the numbers behind the verdict.
public struct GateResult: Codable {
    public let name: String
    public let feature: String
    public let passed: Bool
    public let detail: String
    /// Metrics tools/baseline.py compares across builds (e.g. max error, accuracy, PSNR, ms).
    public let metrics: [String: Double]
}

public struct Gate {
    public let name: String
    public let feature: String
    public let run: () throws -> GateResult
}

public enum Gates {
    static func result(_ name: String, _ feature: String, _ ok: Bool, _ detail: String, _ m: [String: Double]) -> GateResult {
        GateResult(name: name, feature: feature, passed: ok, detail: detail, metrics: m)
    }
    static func f(_ x: Double, _ d: Int = 2) -> String { String(format: "%.\(d)f", x) }

    // Budgets.
    public static let tiltTolerance = 0.3            // degrees
    public static let cropCoverage = 0.98            // fraction of the subject kept
    public static let trackCenterError = 0.06        // normalised
    public static let ocrExactRate = 0.98
    public static let lookReferenceDB = 60.0         // shipped float model vs Swift reference
    public static let lookInt8DB = 40.0              // int8 vs float
    public static let lookUnitsDB = 60.0             // CPU vs GPU / Neural Engine

    static let horizons: [(Double, CGImage)] = Golden.horizonAngles.map { ($0, Golden.horizon(degrees: $0, seed: UInt64(abs($0) * 10 + 3))) }
    static let subjects: [(CGImage, Box)] = (1...12).map { Golden.subject(seed: UInt64($0)) }
    static let clip = Golden.clip()

    static func level(_ t: Double?) -> Double { t ?? 0 }

    public static let all: [Gate] = [
        // MARK: auto-straighten
        Gate(name: "straighten.accuracy", feature: "auto-straighten") {
            let errs = try horizons.map { abs(level(try AutoStraighten.tilt($0.1)) - $0.0) }
            let m = errs.max() ?? 0
            return result("straighten.accuracy", "auto-straighten", m <= tiltTolerance,
                          "max tilt error \(f(m))° over \(errs.count) horizons (budget \(tiltTolerance)°)", ["max_error_deg": m])
        },
        Gate(name: "straighten.leaves-level-alone", feature: "auto-straighten") {
            // A level photo must not be "fixed": no correction, or one too small to see.
            var worst = 0.0
            for (i, a) in Golden.nearLevelAngles.enumerated() {
                worst = max(worst, abs(try AutoStraighten.correction(Golden.horizon(degrees: a, seed: UInt64(50 + i))) ?? 0))
            }
            return result("straighten.leaves-level-alone", "auto-straighten", worst <= 0.5,
                          "largest correction offered for a level photo \(f(worst))°", ["level_correction_deg": worst])
        },
        Gate(name: "straighten.closed-loop", feature: "auto-straighten") {
            // Apply the correction, measure again: the result must be level.
            var worst = 0.0
            for (truth, img) in horizons where abs(truth) <= 4 {
                guard let c = try AutoStraighten.correction(img) else { throw GateFailure("no horizon at \(truth)°") }
                worst = max(worst, abs(level(try AutoStraighten.tilt(AutoStraighten.rotated(img, degrees: c)))))
            }
            return result("straighten.closed-loop", "auto-straighten", worst <= 0.5, "worst tilt after straightening \(f(worst))°",
                          ["residual_deg": worst])
        },
        Gate(name: "straighten.robustness", feature: "auto-straighten") {
            // Metamorphic: a re-encode, a resize or an exposure change must not move the answer.
            var worst = 0.0
            for (truth, img) in horizons.prefix(6) {
                for v in [Golden.jpeg(img, quality: 0.6), Golden.scaled(img, 0.5), Golden.exposed(img, ev: 0.7)] {
                    worst = max(worst, abs(level(try AutoStraighten.tilt(v)) - truth))
                }
            }
            return result("straighten.robustness", "auto-straighten", worst <= tiltTolerance,
                          "worst error across JPEG 60 / half size / +0.7 EV: \(f(worst))°", ["variant_max_error_deg": worst])
        },
        Gate(name: "straighten.orientation", feature: "auto-straighten") {
            // A portrait-sensor photo: pixels stored sideways, EXIF says how to show them.
            var worst = 0.0
            for (truth, img) in horizons.prefix(4) {
                let t = level(try AutoStraighten.tilt(Golden.storedRotated(img), orientation: Golden.storedOrientation))
                worst = max(worst, abs(t - truth))
            }
            return result("straighten.orientation", "auto-straighten", worst <= tiltTolerance,
                          "worst error on EXIF-rotated photos \(f(worst))°", ["oriented_max_error_deg": worst])
        },

        // MARK: smart crop
        Gate(name: "crop.subject-kept", feature: "smart crop") {
            var kept = 0, total = 0, worst = 1.0
            for (img, truth) in subjects {
                for aspect in [9.0 / 16, 1, 2.39] {
                    let c = try SmartCrop.crop(img, aspect: aspect).covers(truth)
                    worst = min(worst, c)
                    total += 1
                    if c >= cropCoverage { kept += 1 }
                }
            }
            let rate = Double(kept) / Double(total)
            return result("crop.subject-kept", "smart crop", rate >= 0.95,
                          "\(kept)/\(total) crops keep ≥\(Int(cropCoverage * 100))% of the subject (9:16, 1:1, 2.39:1); worst \(f(worst))",
                          ["kept_rate": rate, "worst_coverage": worst])
        },
        Gate(name: "crop.orientation", feature: "smart crop") {
            var kept = 0
            for (img, truth) in subjects.prefix(6) where try SmartCrop.crop(Golden.storedRotated(img), aspect: 9.0 / 16,
                                                                            orientation: Golden.storedOrientation).covers(truth) >= cropCoverage {
                kept += 1
            }
            return result("crop.orientation", "smart crop", kept == 6, "\(kept)/6 EXIF-rotated photos cropped onto the subject",
                          ["oriented_kept": Double(kept)])
        },

        // MARK: video
        Gate(name: "video.shot-cuts", feature: "shot detection") {
            let cuts = ShotCuts.cuts(clip.frames)
            return result("video.shot-cuts", "shot detection", cuts == clip.cuts, "detected \(cuts), truth \(clip.cuts)",
                          ["false_or_missed": Double(Set(cuts).symmetricDifference(clip.cuts).count)])
        },
        Gate(name: "video.tracking", feature: "subject tracking") {
            let boxes = try SubjectTracker.track(clip.frames, initial: clip.boxes[0])
            let errs = zip(boxes, clip.boxes).map { hypot($0.center.0 - $1.center.0, $0.center.1 - $1.center.1) }
            let within = Double(errs.filter { $0 <= trackCenterError }.count) / Double(errs.count)
            let afterCut = errs[clip.cuts[0]...].max() ?? 1
            return result("video.tracking", "subject tracking", within >= 0.9 && afterCut <= trackCenterError * 1.5,
                          "\(Int(within * 100))% of frames within \(trackCenterError) of the subject; worst after the cut \(f(afterCut, 3))",
                          ["within_rate": within, "worst_after_cut": afterCut, "mean_error": errs.reduce(0, +) / Double(errs.count)])
        },

        // MARK: titles
        Gate(name: "titles.exact", feature: "title OCR") {
            var right = 0, total = 0, misses: [String] = []
            for (i, t) in Golden.titles.enumerated() {
                for bg in 0..<3 {
                    for size in [32.0, 64.0] {
                        var img = Golden.title(t, font: Golden.fonts[(i + bg) % Golden.fonts.count], size: CGFloat(size), background: bg, seed: UInt64(i * 7 + bg))
                        if bg == 2 { img = Golden.jpeg(img, quality: 0.5) }   // a heavily compressed export
                        let got = try Titles.read(img).joined(separator: " ")
                        total += 1
                        if got == t { right += 1 } else if misses.count < 3 { misses.append("'\(t)'→'\(got)'") }
                    }
                }
            }
            let rate = Double(right) / Double(total)
            return result("titles.exact", "title OCR", rate >= ocrExactRate, "\(right)/\(total) titles read exactly \(misses)",
                          ["exact_rate": rate])
        },
        Gate(name: "titles.no-hallucination", feature: "title OCR") {
            var found: [String] = []
            for s in 0..<8 { found += try Titles.read(Golden.noText(seed: UInt64(s))) }
            return result("titles.no-hallucination", "title OCR", found.isEmpty, "text read from 8 text-free frames: \(found.prefix(3))",
                          ["false_texts": Double(found.count)])
        },

        // MARK: duplicates
        Gate(name: "library.duplicates", feature: "duplicate grouping") {
            let bases: [CGImage] = [horizons[0].1, subjects[0].0, Golden.title("Opening Night", font: "Georgia", size: 56, background: 1, seed: 1),
                                    clip.frames[5], clip.frames[30]]
            var imgs: [CGImage] = [], truth: [[Int]] = []
            for b in bases {
                let start = imgs.count
                imgs += [b, Golden.jpeg(b, quality: 0.8), Golden.scaled(b, 0.5), Golden.exposed(b, ev: 0.5)]
                truth.append(Array(start..<imgs.count))
            }
            let got = try Duplicates.groups(imgs)
            return result("library.duplicates", "duplicate grouping", got == truth, "\(got.count) groups, truth \(truth.count): \(got.map { $0.count })",
                          ["groups": Double(got.count)])
        },

        // MARK: Core ML look
        Gate(name: "look.reference", feature: "Core ML look") {
            let x = Look.input(subjects[1].0), ref = try Look.reference(x)
            let cpu = Look.psnr(try Look.run(try Look.model(.float32, units: .cpuOnly), x), ref)
            return result("look.reference", "Core ML look", cpu >= lookReferenceDB, "float32 model vs Swift reference: \(f(cpu, 1)) dB",
                          ["float_vs_reference_db": min(cpu, 200)])
        },
        Gate(name: "look.color-contract", feature: "Core ML look") {
            // The app's pixel -> tensor conversion, checked against tensors built by hand: a model and
            // its reference agree even when both get BGR, so only a known colour exposes a swap.
            var worst = Double.infinity, worstName = ""
            let n = Look.size, plane = n * n
            for (name, rgb) in [("red", [0.9, 0.1, 0.1]), ("green", [0.1, 0.8, 0.2]), ("blue", [0.15, 0.2, 0.85])] {
                let c = Golden.context(n, n)
                c.setFillColor(Golden.col(rgb + [1]))
                c.fill(CGRect(x: 0, y: 0, width: n, height: n))
                var truth = [Float](repeating: 0, count: 3 * plane)
                for ch in 0..<3 { for i in 0..<plane { truth[ch * plane + i] = Float((rgb[ch] * 255).rounded() / 255) } }
                let got = try Look.run(try Look.model(.float32, units: .cpuOnly), Look.input(c.makeImage()!))
                let p = Look.psnr(got, try Look.reference(truth))
                if p < worst { worst = p; worstName = name }
            }
            return result("look.color-contract", "Core ML look", worst >= 40, "solid colours through the app's input path: worst \(worstName) \(f(worst, 1)) dB",
                          ["color_contract_db": min(worst, 200)])
        },
        Gate(name: "look.int8-drift", feature: "Core ML look") {
            var worst = Double.infinity
            for (img, _) in subjects.prefix(4) {
                let x = Look.input(img)
                worst = min(worst, Look.psnr(try Look.run(try Look.model(.int8, units: .cpuOnly), x), try Look.run(try Look.model(.float32, units: .cpuOnly), x)))
            }
            return result("look.int8-drift", "Core ML look", worst >= lookInt8DB, "shipped int8 vs float32: worst \(f(worst, 1)) dB (budget \(Int(lookInt8DB)))",
                          ["int8_vs_float_db": min(worst, 200)])
        },
        Gate(name: "look.compute-units", feature: "Core ML look") {
            let x = Look.input(subjects[2].0)
            let cpu = try Look.run(try Look.model(.int8, units: .cpuOnly), x)
            let all = try Look.run(try Look.model(.int8, units: .all), x)
            let gpu = try Look.run(try Look.model(.int8, units: .cpuAndGPU), x)
            let worst = min(Look.psnr(cpu, all), Look.psnr(cpu, gpu))
            return result("look.compute-units", "Core ML look", worst >= lookUnitsDB, "CPU vs GPU / Neural Engine: \(f(worst, 1)) dB",
                          ["units_db": min(worst, 200)])
        },

        // MARK: cross-cutting
        Gate(name: "parity.cpu-vs-accelerated", feature: "all Vision features") {
            var worstTilt = 0.0, worstFocus = 0.0, textDiff = 0
            for (_, img) in horizons.prefix(4) {
                worstTilt = max(worstTilt, abs(level(try AutoStraighten.tilt(img, cpuOnly: true)) - level(try AutoStraighten.tilt(img))))
            }
            for (img, _) in subjects.prefix(4) {
                let a = try SmartCrop.focus(img, cpuOnly: true), b = try SmartCrop.focus(img)
                worstFocus = max(worstFocus, hypot(a.0 - b.0, a.1 - b.1))
            }
            for t in Golden.titles.prefix(4) {
                let img = Golden.title(t, font: "Georgia", size: 48, background: 1, seed: 2)
                if try Titles.read(img, cpuOnly: true) != Titles.read(img) { textDiff += 1 }
            }
            let ok = worstTilt <= 0.1 && worstFocus <= 0.03 && textDiff == 0
            return result("parity.cpu-vs-accelerated", "all Vision features", ok,
                          "tilt Δ \(f(worstTilt))°, focus Δ \(f(worstFocus, 3)), titles differing \(textDiff)",
                          ["tilt_delta_deg": worstTilt, "focus_delta": worstFocus])
        },
        Gate(name: "determinism.repeat", feature: "all features") {
            let h = horizons[2].1, s = subjects[3].0, t = Golden.title("Day 14", font: "Futura-Medium", size: 48, background: 2, seed: 4)
            let x = Look.input(s), m = try Look.model(.int8)
            let same = try AutoStraighten.tilt(h) == AutoStraighten.tilt(h)
                && (try SmartCrop.focus(s)) == (try SmartCrop.focus(s))
                && (try Titles.read(t)) == (try Titles.read(t))
                && (try Look.run(m, x)) == (try Look.run(m, x))
            return result("determinism.repeat", "all features", same, same ? "identical on repeat" : "a feature changed its answer on the same input", [:])
        },
        Gate(name: "perf.budgets", feature: "all features") {
            func ms(_ n: Int = 5, _ f: () throws -> Void) rethrows -> Double {
                try f()
                var ts: [Double] = []
                for _ in 0..<n { let t = Date(); try f(); ts.append(Date().timeIntervalSince(t) * 1000) }
                return ts.sorted()[n * 9 / 10]
            }
            let h = horizons[0].1, s = subjects[0].0, t = Golden.title("Opening Night", font: "Georgia", size: 56, background: 0, seed: 1)
            let x = Look.input(s), m = try Look.model(.int8)
            let budgets: [(String, Double, Double)] = [
                ("horizon_ms", try ms { _ = try AutoStraighten.tilt(h) }, 250),
                ("saliency_ms", try ms { _ = try SmartCrop.focus(s) }, 250),
                ("ocr_ms", try ms { _ = try Titles.read(t) }, 1500),
                ("look_ms", try ms { _ = try Look.run(m, x) }, 200),
            ]
            let over = budgets.filter { $0.1 > $0.2 }
            return result("perf.budgets", "all features", over.isEmpty,
                          budgets.map { "\($0.0.replacingOccurrences(of: "_ms", with: "")) \(Int($0.1)) ms/\(Int($0.2))" }.joined(separator: ", "),
                          Dictionary(uniqueKeysWithValues: budgets.map { ($0.0, $0.1) }))
        },
    ]

    public static var names: [String] { all.map { $0.name } }

    public static func run(_ names: [String] = []) -> [GateResult] {
        all.filter { names.isEmpty || names.contains($0.name) }.map { g in
            do { return try g.run() } catch {
                return GateResult(name: g.name, feature: g.feature, passed: false, detail: "error: \(error)", metrics: [:])
            }
        }
    }

    /// Fault -> gates that must fail with it on, and no others.
    public static let expectedFailures: [Fault: Set<String>] = [
        .ignoresOrientation: ["crop.orientation"],
        .horizonSignFlipped: ["straighten.closed-loop"],
        .saliencyRowsFlipped: ["crop.subject-kept", "video.tracking"],
        .visionBoxNotFlipped: ["video.tracking"],
        .trackerNotResetAtCut: ["video.tracking"],
        .ocrFastPath: ["titles.exact"],
        .duplicateThresholdLoose: ["library.duplicates"],
        .int2ModelShipped: ["look.int8-drift"],
        .modelInputBGR: ["look.color-contract"],
    ]
}

public struct GateFailure: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}
