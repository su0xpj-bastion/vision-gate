import CoreML
import VisionGate
import XCTest

/// One XCTest per gate, so Xcode, Jenkins and Xcode Cloud list each feature's quality bar by name.
/// Runs on macOS and on the iOS Simulator (`xcodebuild test -scheme vision-gate -destination ...`).
final class GateTests: XCTestCase {
    func gate(_ name: String) throws {
        let r = Gates.run([name]).first!
        let a = XCTAttachment(string: "\(r.detail)\n\(r.metrics)")
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        if !Gates.judged(name) {
            throw XCTSkip("\(name) is device-only: the Simulator runs a different Vision path (it reported: \(r.detail))")
        }
        XCTAssertTrue(r.passed, "\(name): \(r.detail)")
    }

    func test_straighten_accuracy() throws { try gate("straighten.accuracy") }
    func test_straighten_leaves_level_alone() throws { try gate("straighten.leaves-level-alone") }
    func test_straighten_closed_loop() throws { try gate("straighten.closed-loop") }
    func test_straighten_robustness() throws { try gate("straighten.robustness") }
    func test_straighten_orientation() throws { try gate("straighten.orientation") }
    func test_crop_subject_kept() throws { try gate("crop.subject-kept") }
    func test_crop_orientation() throws { try gate("crop.orientation") }
    func test_video_shot_cuts() throws { try gate("video.shot-cuts") }
    func test_video_tracking() throws { try gate("video.tracking") }
    func test_titles_exact() throws { try gate("titles.exact") }
    func test_titles_no_hallucination() throws { try gate("titles.no-hallucination") }
    func test_library_duplicates() throws { try gate("library.duplicates") }
    func test_look_reference() throws { try gate("look.reference") }
    func test_look_color_contract() throws { try gate("look.color-contract") }
    func test_look_int8_drift() throws { try gate("look.int8-drift") }
    func test_look_compute_units() throws { try gate("look.compute-units") }
    func test_parity_cpu_vs_accelerated() throws { try gate("parity.cpu-vs-accelerated") }
    func test_determinism_repeat() throws { try gate("determinism.repeat") }
    func test_perf_budgets() throws { try gate("perf.budgets") }
}

/// Client faults are in-process switches: each must fail exactly its pinned gates.
final class FaultMatrixTests: XCTestCase {
    func testEveryFaultIsCaughtByExactlyItsGates() {
        for fault in Fault.allCases {
            let saved = Fault.active
            Fault.active = [fault]
            defer { Fault.active = saved }
            // perf.budgets is timing, not correctness: on a loaded CI VM it can trip during any run.
            // On the Simulator only the gates it can judge are compared (see Gates.deviceOnly).
            let failed = Set(Gates.run().filter { !$0.passed && $0.name != "perf.budgets" && Gates.judged($0.name) }.map { $0.name })
            XCTAssertEqual(failed, (Gates.expectedFailures[fault] ?? []).filter(Gates.judged), "\(fault)")
        }
    }
}

/// On-device cost per feature with XCTest metrics (baselines are recorded per device in Xcode).
final class FeaturePerformanceTests: XCTestCase {
    func testLookInferenceInt8() throws {
        let m = try Look.model(.int8)
        let x = Look.input(Golden.subject(seed: 1).0)
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()]) { _ = try? Look.run(m, x) }
    }

    func testTitleOCR() {
        let img = Golden.title("Opening Night", font: "Georgia", size: 56, background: 1, seed: 1)
        measure(metrics: [XCTClockMetric(), XCTCPUMetric()]) { _ = try? Titles.read(img) }
    }
}
