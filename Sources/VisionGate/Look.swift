import CoreGraphics
import CoreML
import Foundation

/// The "Look" Core ML model (colour grade + sharpen), its quantized builds, and a Swift reference
/// implementation of the same maths: the oracle the shipped model is checked against.
public enum Look {
    public static let size = 256

    public enum Build: String { case float32 = "Look", int8 = "LookInt8", int2 = "Look2bit" }

    public static var modelsDir: URL {
        if let d = ProcessInfo.processInfo.environment["VG_MODELS"] { return URL(fileURLWithPath: d) }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Models")
    }

    static var compiled: [String: URL] = [:]
    static let lock = NSLock()

    /// Load a build for a set of compute units (.cpuOnly, .cpuAndGPU, .all = may use the Neural Engine).
    public static func model(_ build: Build, units: MLComputeUnits = .all) throws -> MLModel {
        let b = build == .int8 && Fault.on(.int2ModelShipped) ? .int2 : build
        lock.lock()
        defer { lock.unlock() }
        let url: URL
        if let u = compiled[b.rawValue] {
            url = u
        } else {
            url = try MLModel.compileModel(at: modelsDir.appendingPathComponent("\(b.rawValue).mlmodel"))
            compiled[b.rawValue] = url
        }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = units
        return try MLModel(contentsOf: url, configuration: cfg)
    }

    /// 1x3x256x256 RGB in 0...1, channel-major (what the model expects).
    public static func input(_ img: CGImage) -> [Float] {
        let n = size
        let c = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: Golden.srgb,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.interpolationQuality = .high
        c.draw(img, in: CGRect(x: 0, y: 0, width: n, height: n))
        let p = c.data!.assumingMemoryBound(to: UInt8.self)
        var out = [Float](repeating: 0, count: 3 * n * n)
        let order = Fault.on(.modelInputBGR) ? [2, 1, 0] : [0, 1, 2]
        for i in 0..<(n * n) { for ch in 0..<3 { out[ch * n * n + i] = Float(p[i * 4 + order[ch]]) / 255 } }
        return out
    }

    public static func run(_ model: MLModel, _ x: [Float]) throws -> [Float] {
        let n = size
        let arr = try MLMultiArray(shape: [1, 3, NSNumber(value: n), NSNumber(value: n)], dataType: .float32)
        let ptr = arr.dataPointer.assumingMemoryBound(to: Float.self)
        for i in 0..<x.count { ptr[i] = x[i] }
        let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(multiArray: arr)]))
        guard let y = out.featureValue(for: "graded")?.multiArrayValue else { throw NSError(domain: "Look", code: 1) }
        var result = [Float](repeating: 0, count: y.count)
        if y.dataType == .float32 {
            let yp = y.dataPointer.assumingMemoryBound(to: Float.self)
            for i in 0..<y.count { result[i] = yp[i] }
        } else {
            for i in 0..<y.count { result[i] = y[i].floatValue }
        }
        return result
    }

    struct Weights: Codable { let grade: [[Float]]; let grade_bias: [Float]; let sharpen: [[[[Float]]]] }

    /// The same network in plain Swift: 1x1 grade + bias, 3x3 sharpen with zero padding, clip to 0...1.
    public static func reference(_ x: [Float]) throws -> [Float] {
        let w = try JSONDecoder().decode(Weights.self, from: Data(contentsOf: modelsDir.appendingPathComponent("look_weights.json")))
        let n = size, plane = n * n
        var g = [Float](repeating: 0, count: 3 * plane)
        for o in 0..<3 {
            for i in 0..<plane {
                g[o * plane + i] = w.grade[o][0] * x[i] + w.grade[o][1] * x[plane + i] + w.grade[o][2] * x[2 * plane + i] + w.grade_bias[o]
            }
        }
        var y = [Float](repeating: 0, count: 3 * plane)
        for o in 0..<3 {
            for r in 0..<n {
                for c in 0..<n {
                    var acc: Float = 0
                    for i in 0..<3 {
                        for kh in 0..<3 {
                            let rr = r + kh - 1
                            guard rr >= 0 && rr < n else { continue }
                            for kw in 0..<3 {
                                let cc = c + kw - 1
                                guard cc >= 0 && cc < n else { continue }
                                acc += w.sharpen[o][i][kh][kw] * g[i * plane + rr * n + cc]
                            }
                        }
                    }
                    y[o * plane + r * n + c] = min(1, max(0, acc))
                }
            }
        }
        return y
    }

    /// Peak signal-to-noise ratio for 0...1 signals; infinity when identical.
    public static func psnr(_ a: [Float], _ b: [Float]) -> Double {
        let mse = zip(a, b).reduce(0.0) { $0 + Double(($1.0 - $1.1) * ($1.0 - $1.1)) } / Double(a.count)
        return mse == 0 ? .infinity : 10 * log10(1 / mse)
    }
}
