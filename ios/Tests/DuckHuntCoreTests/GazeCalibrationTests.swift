import Foundation
import Testing
@testable import DuckHuntCore

@Suite("Native gaze calibration")
struct GazeCalibrationTests {
    /// A 6.1" iPhone. Accuracy is asserted in millimetres because that is the unit the
    /// held-out gate rejects on and the unit the user is shown after calibrating.
    private static let display = PhysicalDisplay(
        widthMillimetres: 70.8,
        heightMillimetres: 147.6,
        cameraOffsetXMillimetres: 0,
        cameraOffsetYMillimetres: 65
    )

    /// Points that coincide with no calibration dot, so accuracy is read where the fit was
    /// never anchored.
    private static let probes = [
        Point2D(x: 0.20, y: 0.35),
        Point2D(x: 0.80, y: 0.15),
        Point2D(x: 0.65, y: 0.90),
        Point2D(x: 0.35, y: 0.62),
        Point2D(x: 0.12, y: 0.88),
        Point2D(x: 0.88, y: 0.44),
    ]

    /// The shipped gate tolerates 15mm of held-out error on a real face. A synthetic user
    /// whose only distortion is linear has to land far inside that: the sole systematic
    /// error left is the ridge prior shrinking the slope, worth about 3mm at the edges.
    private static let requiredAccuracyMillimetres = 5.0

    /// Linear remaps between true screen position and the geometric estimate, each one a
    /// plausible way for the ARKit front end to be wrong.
    enum Distortion: Sendable, CaseIterable {
        /// A gain error on ARKit's eye-in-head rotation plus a fixed kappa offset.
        case gainAndOffset
        /// Horizontal and vertical exchanged. No per-axis gain can undo this, only a full
        /// 2x2 remap, which is exactly what both axes weighting both features buys.
        case axisSwap
        /// A 25 degree roll about the screen centre: the device axis convention rotated.
        case rotation

        func apply(to target: Point2D) -> RawGazeSample {
            switch self {
            case .gainAndOffset:
                return RawGazeSample(
                    horizontal: 1.08 * target.x + 0.03 * target.y - 0.055,
                    vertical: 0.94 * target.y - 0.02 * target.x + 0.042
                )
            case .axisSwap:
                return RawGazeSample(
                    horizontal: 0.97 * target.y + 0.03,
                    vertical: 1.05 * target.x - 0.02
                )
            case .rotation:
                let angle = 25 * Double.pi / 180
                let x = target.x - 0.5
                let y = target.y - 0.5
                return RawGazeSample(
                    horizontal: x * cos(angle) - y * sin(angle) + 0.5,
                    vertical: x * sin(angle) + y * cos(angle) + 0.5
                )
            }
        }
    }

    /// One tracking frame's admissibility inputs, and whether the gate should keep it.
    struct GateFrame: Sendable, CustomStringConvertible {
        let label: String
        let blink: Double
        let headSpeed: Double
        let viewingDistance: Double
        let isUsable: Bool

        var description: String { label }
    }

    private static let gateFrames = [
        GateFrame(label: "resting", blink: 0.04, headSpeed: 0.08, viewingDistance: 0.38, isUsable: true),
        GateFrame(
            label: "lids at the limit",
            blink: GazeSampleGate.maximumBlink,
            headSpeed: 0.08,
            viewingDistance: 0.38,
            isUsable: true
        ),
        GateFrame(
            label: "drift at the limit",
            blink: 0.04,
            headSpeed: GazeSampleGate.maximumHeadSpeedRadiansPerSecond,
            viewingDistance: 0.38,
            isUsable: true
        ),
        GateFrame(
            label: "nearest usable",
            blink: 0.04,
            headSpeed: 0.08,
            viewingDistance: GazeSampleGate.viewingDistanceRange.lowerBound,
            isUsable: true
        ),
        GateFrame(
            label: "furthest usable",
            blink: 0.04,
            headSpeed: 0.08,
            viewingDistance: GazeSampleGate.viewingDistanceRange.upperBound,
            isUsable: true
        ),
        GateFrame(label: "mid-blink", blink: 0.86, headSpeed: 0.08, viewingDistance: 0.38, isUsable: false),
        GateFrame(label: "head still turning", blink: 0.04, headSpeed: 1.4, viewingDistance: 0.38, isUsable: false),
        GateFrame(label: "phone at the nose", blink: 0.04, headSpeed: 0.08, viewingDistance: 0.16, isUsable: false),
        GateFrame(label: "phone at arm's length", blink: 0.04, headSpeed: 0.08, viewingDistance: 0.92, isUsable: false),
        GateFrame(label: "blink not a number", blink: .nan, headSpeed: 0.08, viewingDistance: 0.38, isUsable: false),
        GateFrame(label: "head speed unbounded", blink: 0.04, headSpeed: .infinity, viewingDistance: 0.38, isUsable: false),
        GateFrame(label: "distance not a number", blink: 0.04, headSpeed: 0.08, viewingDistance: .nan, isUsable: false),
    ]

    // MARK: - The dot set

    @Test("Every calibration dot is a distinct on-screen target")
    func anchorsAreDistinctOnScreenTargets() {
        let anchors = GazeCalibration.standardAnchors

        // The calibrator keys its samples by anchor. Two dots sharing a display point used
        // to collapse into one key, silently discarding a target the user had looked at.
        #expect(Set(anchors.map(\.displayPoint)).count == anchors.count)
        #expect(Set(anchors).count == anchors.count)
        #expect(anchors.allSatisfy { (0 ... 1).contains($0.displayPoint.x) })
        #expect(anchors.allSatisfy { (0 ... 1).contains($0.displayPoint.y) })
    }

    @Test("The dot set both teaches and audits with enough dots to be worth trusting")
    func anchorRolesCoverTrainingAndValidation() {
        // Six is what the fit needs to be determined, four is what makes the audit mean
        // something. Below either number the calibrator refuses to produce a model at all.
        #expect(Self.trainingAnchors.count >= 6)
        #expect(Self.validationAnchors.count >= 4)
        #expect(
            Self.trainingAnchors.count + Self.validationAnchors.count
                == GazeCalibration.standardAnchors.count
        )
    }

    @Test("Audit dots are interleaved with training dots, not appended after them")
    func validationDotsAreInterleaved() throws {
        let roles = GazeCalibration.standardAnchors.map(\.role)
        let firstValidation = try #require(roles.firstIndex(of: .validation))
        let lastTraining = try #require(roles.lastIndex(of: .training))

        #expect(firstValidation < lastTraining)

        // Pose drift accumulates over the session. Every audit dot needs training dots on
        // both sides of it, or the audit only ever measures the end of the session.
        for index in roles.indices where roles[index] == .validation {
            #expect(roles[..<index].contains(.training))
            #expect(roles[(index + 1)...].contains(.training))
        }
    }

    // MARK: - Fitting

    @Test("A linear remap of the geometric estimate is recovered", arguments: Distortion.allCases)
    func recoversLinearRemap(distortion: Distortion) throws {
        let calibrator = filledCalibrator { distortion.apply(to: $0) }
        let model = try #require(calibrator.fit(display: Self.display))

        #expect(model.isValid)
        #expect(model.validationErrorMillimetres >= 0)
        #expect(model.validationErrorMillimetres < Self.requiredAccuracyMillimetres)

        for probe in Self.probes {
            let prediction = model.predict(distortion.apply(to: probe))
            #expect(Self.errorMillimetres(of: prediction, from: probe) < Self.requiredAccuracyMillimetres)
        }
    }

    @Test("Blinks inside a dot's samples do not move the fit")
    func blinkOutliersAreTrimmed() throws {
        let distortion = Distortion.gainAndOffset
        let calibrator = filledCalibrator(blinking: true) { distortion.apply(to: $0) }
        let anchor = try #require(GazeCalibration.standardAnchors.first)

        // The collector keeps everything it is handed; rejection is the fit's job.
        #expect(calibrator.sampleCount(for: anchor) == 30)
        #expect(calibrator.isSettled(for: anchor, display: Self.display))

        let model = try #require(calibrator.fit(display: Self.display))
        #expect(model.validationErrorMillimetres < Self.requiredAccuracyMillimetres)

        for probe in Self.probes {
            let prediction = model.predict(distortion.apply(to: probe))
            #expect(Self.errorMillimetres(of: prediction, from: probe) < Self.requiredAccuracyMillimetres)
        }
    }

    @Test("A distortion invisible on the training grid is caught by the held-out dots")
    func heldOutDotsCatchTrainingGridBlindSpot() throws {
        // `trainingGridBlindSpot` is zero wherever a coordinate is 0.05, 0.5 or 0.95, so
        // these two calibrators hold identical training data and differ only on the audit
        // dots. Whatever the second one does, it cannot blame its training samples.
        let clean = filledCalibrator(distortion: Self.undistorted)
        let blindSpot = filledCalibrator(distortion: Self.trainingGridBlindSpot)
        let control = try #require(clean.fit(display: Self.display))

        for anchor in GazeCalibration.standardAnchors where anchor.role == .training {
            let prediction = control.predict(Self.trainingGridBlindSpot(anchor.displayPoint))
            #expect(Self.errorMillimetres(of: prediction, from: anchor.displayPoint) < 4)
        }

        #expect(blindSpot.fit(display: Self.display) == nil)
    }

    @Test("Too few training dots cannot produce a model")
    func rejectsTooFewTrainingDots() {
        let anchors = Array(Self.trainingAnchors.prefix(5)) + Self.validationAnchors
        let calibrator = filledCalibrator(anchors: anchors, distortion: Self.undistorted)

        #expect(calibrator.fit(display: Self.display) == nil)
    }

    @Test("Too few audit dots cannot produce a model")
    func rejectsTooFewValidationDots() {
        let anchors = Self.trainingAnchors + Array(Self.validationAnchors.prefix(2))
        let calibrator = filledCalibrator(anchors: anchors, distortion: Self.undistorted)

        #expect(calibrator.fit(display: Self.display) == nil)
    }

    @Test("A dot the user barely looked at does not count toward coverage")
    func shortDotsDoNotCount() throws {
        let training = Array(Self.trainingAnchors.prefix(6))
        let validation = Array(Self.validationAnchors.prefix(3))
        let short = try #require(training.last)
        let baseline = Self.undistorted(short.displayPoint)

        var complete = filledCalibrator(
            anchors: Array(training.dropLast()) + validation,
            samplesPerAnchor: 12,
            distortion: Self.undistorted
        )
        var starved = complete
        for _ in 0 ..< 12 { complete.add(baseline, for: short) }
        for _ in 0 ..< 11 { starved.add(baseline, for: short) }

        #expect(complete.fit(display: Self.display) != nil)
        #expect(starved.sampleCount(for: short) == 11)
        #expect(starved.fit(display: Self.display) == nil)
    }

    @Test("Identical tracking data cannot explain thirteen different dots")
    func rejectsDegenerateInput() {
        var calibrator = GazeCalibrator()
        for anchor in GazeCalibration.standardAnchors {
            for _ in 0 ..< 20 {
                calibrator.add(RawGazeSample(horizontal: 0.31, vertical: 0.47), for: anchor)
            }
        }

        #expect(calibrator.fit(display: Self.display) == nil)
    }

    // MARK: - Per-dot sample quality

    @Test("A dot settles on the standard error of its mean, not on per-frame scatter")
    func settlingTracksStandardErrorOfTheMean() throws {
        let anchor = try #require(GazeCalibration.standardAnchors.first)

        // A user who barely moves: the mean is pinned to a fraction of a millimetre and
        // the dot is done as soon as the minimum frame count is in.
        var steady = GazeCalibrator()
        for index in 0 ..< 20 {
            let jitter = Double((index * 7) % 11 - 5) * 0.0006
            steady.add(RawGazeSample(horizontal: 0.42 + jitter, vertical: 0.63 - jitter), for: anchor)
        }
        let steadyUncertainty = try #require(
            steady.uncertaintyMillimetres(for: anchor, display: Self.display)
        )
        #expect(steadyUncertainty < 0.5)
        #expect(steady.isSettled(for: anchor, display: Self.display))

        // A real user on real hardware. Every one of these frames is about 12mm off the
        // dot on its own, which is simply what ARKit delivers at arm's length. The old
        // gate thresholded that per-frame scatter directly, so it could never be met and
        // every dot timed out. A handful of frames is not enough averaging to pin the
        // mean to 3mm...
        let brief = Self.calibrator(loaded: Self.scatterRing(frames: 16), for: anchor)
        let briefUncertainty = try #require(
            brief.uncertaintyMillimetres(for: anchor, display: Self.display)
        )
        #expect(briefUncertainty > 3.0)
        #expect(!brief.isSettled(for: anchor, display: Self.display))

        // ...but the identical noise does settle once enough frames are averaged. This is
        // the half that makes the gate reachable at all: a noisy user or a dim room costs
        // more frames instead of failing the session.
        let patient = Self.calibrator(loaded: Self.scatterRing(frames: 40), for: anchor)
        let patientUncertainty = try #require(
            patient.uncertaintyMillimetres(for: anchor, display: Self.display)
        )
        #expect(patientUncertainty < 3.0)
        #expect(patient.isSettled(for: anchor, display: Self.display))
        #expect(patientUncertainty < briefUncertainty)
    }

    @Test("Uncertainty falls as one over the square root of the frames averaged")
    func uncertaintyFallsWithTheSquareRootOfFrameCount() throws {
        let anchor = try #require(GazeCalibration.standardAnchors.first)

        // Both counts sit above the floor the calibrator puts under its retained sample
        // count, so the frames that reach the mean really do quadruple between them.
        let few = Self.calibrator(loaded: Self.scatterRing(frames: 25), for: anchor)
        let many = Self.calibrator(loaded: Self.scatterRing(frames: 100), for: anchor)
        let fewUncertainty = try #require(
            few.uncertaintyMillimetres(for: anchor, display: Self.display)
        )
        let manyUncertainty = try #require(
            many.uncertaintyMillimetres(for: anchor, display: Self.display)
        )

        // Quadrupling the frames has to at least halve the figure: that scaling is the
        // whole reason a standard error is a usable gate where raw scatter is not, since
        // it is the only thing that lets a fixed millimetre threshold be reached by
        // waiting. The upper bound is asserted too — falling faster than one over root n
        // would mean the trim is discarding real spread rather than averaging it away.
        #expect(manyUncertainty <= fewUncertainty / 1.9)
        #expect(manyUncertainty >= fewUncertainty / 2.1)
    }

    @Test("A dot below the minimum frame count reports no uncertainty and never settles")
    func shortDotsReportNoUncertainty() throws {
        let anchor = try #require(GazeCalibration.standardAnchors.first)
        var calibrator = GazeCalibrator()
        for _ in 0 ..< 11 {
            calibrator.add(RawGazeSample(horizontal: 0.42, vertical: 0.63), for: anchor)
        }

        // Eleven identical frames would read as zero uncertainty if the minimum were not
        // enforced, and the dot would settle on the strength of noise that had not been
        // sampled yet. Too few frames is unknown, not settled.
        #expect(calibrator.sampleCount(for: anchor) == 11)
        #expect(calibrator.uncertaintyMillimetres(for: anchor, display: Self.display) == nil)
        #expect(!calibrator.isSettled(for: anchor, display: Self.display))

        calibrator.add(RawGazeSample(horizontal: 0.42, vertical: 0.63), for: anchor)
        #expect(calibrator.uncertaintyMillimetres(for: anchor, display: Self.display) != nil)
        #expect(calibrator.isSettled(for: anchor, display: Self.display))
    }

    @Test("The same normalized scatter costs more in the axis with more millimetres per unit")
    func uncertaintyIsPhysicalRatherThanNormalized() throws {
        let anchor = try #require(GazeCalibration.standardAnchors.first)
        let swing = 0.06
        var across = GazeCalibrator()
        var down = GazeCalibrator()
        for index in 0 ..< 24 {
            let offset = swing * cos(2 * Double.pi * Double(index) / 24)
            across.add(RawGazeSample(horizontal: 0.5 + offset, vertical: 0.5), for: anchor)
            down.add(RawGazeSample(horizontal: 0.5, vertical: 0.5 + offset), for: anchor)
        }

        let acrossUncertainty = try #require(
            across.uncertaintyMillimetres(for: anchor, display: Self.display)
        )
        let downUncertainty = try #require(
            down.uncertaintyMillimetres(for: anchor, display: Self.display)
        )

        // Identical numbers in normalized units, different answers in millimetres. The
        // panel is a little over twice as tall as it is wide, so the vertical swing is
        // that much further in the only unit a gate can honestly threshold. A gate on
        // normalized scatter would have called these two dots equally good, and would
        // have been twice as strict horizontally as vertically on the same real error.
        let aspect = Self.display.heightMillimetres / Self.display.widthMillimetres
        #expect(aspect > 2)
        #expect(downUncertainty > acrossUncertainty)
        #expect(abs(downUncertainty / acrossUncertainty - aspect) < 0.01)

        // A square panel is the one case where the two axes really are interchangeable,
        // and it is the only case the old normalized gate got right.
        let square = PhysicalDisplay(
            widthMillimetres: 100,
            heightMillimetres: 100,
            cameraOffsetXMillimetres: 0,
            cameraOffsetYMillimetres: 40
        )
        let squareAcross = try #require(across.uncertaintyMillimetres(for: anchor, display: square))
        let squareDown = try #require(down.uncertaintyMillimetres(for: anchor, display: square))
        #expect(abs(squareDown - squareAcross) < 1e-9)
    }

    @Test("Discarding a dot's samples lets it be presented again from scratch")
    func discardSamplesClearsOneDot() throws {
        let anchors = GazeCalibration.standardAnchors
        let discarded = try #require(anchors.first)
        let kept = try #require(anchors.last)
        var calibrator = filledCalibrator(samplesPerAnchor: 20, distortion: Self.undistorted)

        #expect(calibrator.sampleCount(for: discarded) == 20)
        calibrator.discardSamples(for: discarded)

        #expect(calibrator.sampleCount(for: discarded) == 0)
        #expect(calibrator.uncertaintyMillimetres(for: discarded, display: Self.display) == nil)
        #expect(!calibrator.isSettled(for: discarded, display: Self.display))
        #expect(calibrator.sampleCount(for: kept) == 20)
    }

    @Test("A sample with no finite position is not collected")
    func nonFiniteSamplesAreIgnored() throws {
        let anchor = try #require(GazeCalibration.standardAnchors.first)
        var calibrator = GazeCalibrator()

        calibrator.add(RawGazeSample(horizontal: .nan, vertical: 0.5), for: anchor)
        calibrator.add(RawGazeSample(horizontal: 0.5, vertical: .infinity), for: anchor)
        calibrator.add(RawGazeSample(horizontal: 0.5, vertical: 0.5), for: anchor)

        #expect(calibrator.sampleCount(for: anchor) == 1)
    }

    // MARK: - Frame admission

    @Test("Coaching appears exactly when a frame is unusable", arguments: gateFrames)
    func gateCoachingMatchesAcceptance(frame: GateFrame) {
        let accepted = GazeSampleGate.accepts(
            blink: frame.blink,
            headSpeed: frame.headSpeed,
            viewingDistance: frame.viewingDistance
        )
        let coaching = GazeSampleGate.rejection(
            blink: frame.blink,
            headSpeed: frame.headSpeed,
            viewingDistance: frame.viewingDistance
        )

        #expect(accepted == frame.isUsable)
        #expect((coaching == nil) == accepted)
        if let coaching {
            #expect(!coaching.isEmpty)
        }
    }

    @Test("Near and far read differently, and distance is coached before anything else")
    func gateCoachingIsSpecific() throws {
        let near = try #require(GazeSampleGate.rejection(blink: 0.04, headSpeed: 0.08, viewingDistance: 0.12))
        let far = try #require(GazeSampleGate.rejection(blink: 0.04, headSpeed: 0.08, viewingDistance: 0.95))

        #expect(near != far)

        // Distance outranks the rest: every other reading is suspect until the face is in
        // range, so telling the user about their blink first would send them in circles.
        #expect(GazeSampleGate.rejection(blink: 0.95, headSpeed: 2.0, viewingDistance: 0.12) == near)
    }

    // MARK: - Persistence

    @Test("A persisted model round-trips without changing predictions")
    func modelRoundTripsThroughJSON() throws {
        let model = try #require(filledCalibrator(distortion: Self.undistorted).fit(display: Self.display))
        let decoded = try JSONDecoder().decode(GazeModel.self, from: JSONEncoder().encode(model))

        #expect(decoded.isValid)
        #expect(decoded.version == GazeModel.currentVersion)
        #expect(abs(decoded.validationErrorMillimetres - model.validationErrorMillimetres) < 1e-9)

        for probe in Self.probes {
            let sample = Self.undistorted(probe)
            let expected = model.predict(sample)
            let actual = decoded.predict(sample)
            #expect(abs(actual.x - expected.x) < 1e-12)
            #expect(abs(actual.y - expected.y) < 1e-12)
        }
    }

    @Test("A model persisted by an older build fails closed")
    func staleVersionFailsClosed() throws {
        let json = """
        {
          "version": 1,
          "validationErrorMillimetres": 4.2,
          "horizontalWeights": [0.02, 0.96, 0.0],
          "verticalWeights": [0.02, 0.0, 0.96]
        }
        """
        let model = try JSONDecoder().decode(GazeModel.self, from: Data(json.utf8))

        #expect(!model.isValid)
        #expect(model.predict(RawGazeSample(horizontal: 0.9, vertical: 0.1)) == Point2D(x: 0.5, y: 0.5))
    }

    @Test("A model with the wrong number of coefficients fails closed")
    func malformedCoefficientsFailClosed() throws {
        let json = """
        {
          "version": 2,
          "validationErrorMillimetres": 4.2,
          "horizontalWeights": [0.02, 0.96],
          "verticalWeights": [0.02, 0.0, 0.96, 0.11]
        }
        """
        let model = try JSONDecoder().decode(GazeModel.self, from: Data(json.utf8))

        #expect(!model.isValid)
        #expect(model.predict(RawGazeSample(horizontal: 0.9, vertical: 0.1)) == Point2D(x: 0.5, y: 0.5))
    }

    // MARK: - Physical display

    @Test("An unrecognised device falls back to a plausible phone")
    func unknownDeviceFallsBackToAPlausibleDisplay() {
        let fallback = PhysicalDisplay.fallback

        #expect(PhysicalDisplay.resolve(identifier: "iPhone999,9") == fallback)
        #expect(PhysicalDisplay.resolve(identifier: "") == fallback)
        #expect(fallback.widthMillimetres > 40)
        #expect(fallback.heightMillimetres > fallback.widthMillimetres)

        // The camera sits inside the active area, above its centre. Getting this sign or
        // magnitude wrong tilts every ray-plane intersection the same way.
        #expect(fallback.cameraOffsetYMillimetres > 0)
        #expect(fallback.cameraOffsetYMillimetres < fallback.heightMillimetres / 2)
        #expect(abs(fallback.cameraOffsetXMillimetres) < fallback.widthMillimetres / 2)
    }

    @Test("Every device in the screen table is physically plausible")
    func deviceTableIsPhysicallyPlausible() throws {
        let table = PhysicalDisplay.table
        #expect(table.count >= 25)

        for (identifier, display) in table {
            #expect(
                identifier.wholeMatch(of: /iPh?[a-zA-Z]+[0-9]+,[0-9]+/) != nil,
                "\(identifier) is not an Apple model identifier"
            )
            #expect(display.widthMillimetres < display.heightMillimetres, "\(identifier) is landscape")
            #expect((50.0 ... 90.0).contains(display.widthMillimetres), "\(identifier) width")
            #expect((100.0 ... 180.0).contains(display.heightMillimetres), "\(identifier) height")

            // Every TrueDepth iPhone is a tall 19.5:9-ish panel. A row that lands outside
            // this band is a transcription error, not a new form factor.
            let aspect = display.heightMillimetres / display.widthMillimetres
            #expect((1.95 ... 2.35).contains(aspect), "\(identifier) aspect \(aspect)")

            // The camera sits inside the active area, above centre. A negative or oversized
            // offset tilts every ray-plane intersection on that device the same way.
            #expect(display.cameraOffsetYMillimetres > 0, "\(identifier) camera offset sign")
            #expect(
                display.cameraOffsetYMillimetres < display.heightMillimetres / 2,
                "\(identifier) camera offset magnitude"
            )
            #expect(abs(display.cameraOffsetXMillimetres) < display.widthMillimetres / 2)
        }

        // A known device must resolve to its own row rather than silently falling back.
        let iPhone15Pro = try #require(table["iPhone16,1"])
        #expect(PhysicalDisplay.resolve(identifier: "iPhone16,1") == iPhone15Pro)
    }

    // MARK: - Fixtures

    private static let trainingAnchors = GazeCalibration.standardAnchors.filter { $0.role == .training }
    private static let validationAnchors = GazeCalibration.standardAnchors.filter { $0.role == .validation }

    /// A front end with no error left to correct.
    private static func undistorted(_ target: Point2D) -> RawGazeSample {
        RawGazeSample(horizontal: target.x, vertical: target.y)
    }

    /// A smooth distortion that vanishes at 0.05, 0.5 and 0.95, so it is exactly zero on
    /// the 3x3 training grid and only shows up between its rows and columns. This is the
    /// failure the held-out dots exist to catch: a fit that is perfect where it was taught
    /// and wrong everywhere the game will actually put a duck.
    private static func trainingGridBlindSpot(_ target: Point2D) -> RawGazeSample {
        RawGazeSample(
            horizontal: target.x + 4 * gridNull(target.x),
            vertical: target.y + 4 * gridNull(target.y)
        )
    }

    private static func gridNull(_ value: Double) -> Double {
        (value - 0.05) * (value - 0.5) * (value - 0.95)
    }

    private static func errorMillimetres(of prediction: Point2D, from target: Point2D) -> Double {
        let dx = (prediction.x - target.x) * display.widthMillimetres
        let dy = (prediction.y - target.y) * display.heightMillimetres
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Per-frame gaze scatter of the size ARKit actually delivers: roughly 2 degrees at
    /// 35cm, which is about 12mm on the display. On this 70.8 x 147.6mm panel the same
    /// physical error is 0.17 normalized horizontally but only 0.08 vertically.
    ///
    /// Laid out as a ring rather than a spray so that trimming to the closest 60% cannot
    /// shrink it: every frame sits essentially the same distance from the centre, so the
    /// only thing that can bring the standard error down is averaging more of them.
    private static func scatterRing(frames: Int) -> [RawGazeSample] {
        (0 ..< frames).map { index in
            let angle = 2 * Double.pi * Double(index) / Double(frames)
            return RawGazeSample(horizontal: 0.5 + 0.17 * cos(angle), vertical: 0.5 + 0.08 * sin(angle))
        }
    }

    private static func calibrator(
        loaded samples: [RawGazeSample],
        for anchor: CalibrationAnchor
    ) -> GazeCalibrator {
        var calibrator = GazeCalibrator()
        for sample in samples { calibrator.add(sample, for: anchor) }
        return calibrator
    }

    /// Fills a calibrator with one fixation per dot: the distortion's output plus a small
    /// deterministic jitter, so the trimmed mean has something to trim.
    private func filledCalibrator(
        anchors: [CalibrationAnchor] = GazeCalibration.standardAnchors,
        samplesPerAnchor: Int = 30,
        blinking: Bool = false,
        distortion: (Point2D) -> RawGazeSample
    ) -> GazeCalibrator {
        var calibrator = GazeCalibrator()
        for (anchorIndex, anchor) in anchors.enumerated() {
            let baseline = distortion(anchor.displayPoint)
            for sampleIndex in 0 ..< samplesPerAnchor {
                let jitter = Double((sampleIndex * 7 + anchorIndex * 3) % 11 - 5) * 0.0015
                let isBlink = blinking && sampleIndex % 7 == 3
                calibrator.add(
                    RawGazeSample(
                        horizontal: baseline.horizontal + jitter + (isBlink ? 0.35 : 0),
                        vertical: baseline.vertical - jitter + (isBlink ? -0.30 : 0)
                    ),
                    for: anchor
                )
            }
        }
        return calibrator
    }
}
