import ApplicationServices
import XCTest
@testable import TypeWhisper

@MainActor
final class TargetAppCorrectionLearningServiceTests: XCTestCase {
    func testElectronAccessibilityObservationRestoresStateItEnabled() throws {
        let target = electronTarget()
        var setValues: [Bool] = []
        let controller = ChromiumAccessibilityObservationController(
            resolveApplication: { _, _ in target },
            isElectronApplication: { _ in true },
            readManualAccessibility: { _ in (.success, false) },
            setManualAccessibility: { _, enabled in
                setValues.append(enabled)
                return .success
            },
            validateApplication: { _ in true }
        )

        let lease = try XCTUnwrap(
            controller.beginObservation(bundleIdentifier: target.bundleIdentifier)
        )
        XCTAssertEqual(setValues, [true])

        lease.end()
        lease.end()

        XCTAssertEqual(setValues, [true, false])
    }

    func testElectronAccessibilityObservationDoesNotOwnAlreadyEnabledState() {
        let target = electronTarget()
        var setValues: [Bool] = []
        let controller = ChromiumAccessibilityObservationController(
            resolveApplication: { _, _ in target },
            isElectronApplication: { _ in true },
            readManualAccessibility: { _ in (.success, true) },
            setManualAccessibility: { _, enabled in
                setValues.append(enabled)
                return .success
            }
        )

        XCTAssertNil(controller.beginObservation(bundleIdentifier: target.bundleIdentifier))
        XCTAssertTrue(setValues.isEmpty)
    }

    func testElectronAccessibilityObservationUsesRequestedProcessIdentifier() throws {
        let target = electronTarget()
        var resolvedBundleIdentifiers: [String] = []
        var resolvedProcessIdentifiers: [pid_t?] = []
        let controller = ChromiumAccessibilityObservationController(
            resolveApplication: { bundleIdentifier, processIdentifier in
                resolvedBundleIdentifiers.append(bundleIdentifier)
                resolvedProcessIdentifiers.append(processIdentifier)
                return processIdentifier == target.processIdentifier ? target : nil
            },
            isElectronApplication: { _ in true },
            readManualAccessibility: { _ in (.success, false) },
            setManualAccessibility: { _, _ in .success },
            validateApplication: { _ in true }
        )

        let lease = try XCTUnwrap(
            controller.beginObservation(
                bundleIdentifier: target.bundleIdentifier,
                processIdentifier: target.processIdentifier
            )
        )
        lease.end()

        XCTAssertEqual(resolvedBundleIdentifiers, [target.bundleIdentifier])
        XCTAssertEqual(resolvedProcessIdentifiers, [target.processIdentifier])
    }

    func testElectronAccessibilityObservationFallsBackWhenAttributeIsUnsupported() {
        let target = electronTarget()
        var setValues: [Bool] = []
        let controller = ChromiumAccessibilityObservationController(
            resolveApplication: { _, _ in target },
            isElectronApplication: { _ in true },
            readManualAccessibility: { _ in (.attributeUnsupported, nil) },
            setManualAccessibility: { _, enabled in
                setValues.append(enabled)
                return .success
            }
        )

        XCTAssertNil(controller.beginObservation(bundleIdentifier: target.bundleIdentifier))
        XCTAssertTrue(setValues.isEmpty)
    }

    func testChromiumBrowserAccessibilityObservationEnablesManualAccessibility() throws {
        let target = ChromiumAccessibilityObservationController.RunningApplicationTarget(
            processIdentifier: 43,
            bundleIdentifier: SupportedMeetingBrowser.chrome,
            bundleURL: URL(fileURLWithPath: "/Applications/Google Chrome.app")
        )
        var setValues: [Bool] = []
        let controller = ChromiumAccessibilityObservationController(
            resolveApplication: { _, _ in target },
            isElectronApplication: { _ in false },
            readManualAccessibility: { _ in (.success, false) },
            setManualAccessibility: { _, enabled in
                setValues.append(enabled)
                return .success
            },
            validateApplication: { _ in true }
        )

        let lease = try XCTUnwrap(
            controller.beginObservation(bundleIdentifier: target.bundleIdentifier)
        )
        lease.end()

        XCTAssertEqual(setValues, [true, false])
    }

    func testNativeApplicationDoesNotRequestManualAccessibility() {
        let target = ChromiumAccessibilityObservationController.RunningApplicationTarget(
            processIdentifier: 44,
            bundleIdentifier: "com.apple.Notes",
            bundleURL: URL(fileURLWithPath: "/System/Applications/Notes.app")
        )
        var readCount = 0
        let controller = ChromiumAccessibilityObservationController(
            resolveApplication: { _, _ in target },
            isElectronApplication: { _ in false },
            readManualAccessibility: { _ in
                readCount += 1
                return (.success, false)
            },
            setManualAccessibility: { _, _ in .success }
        )

        XCTAssertNil(controller.beginObservation(bundleIdentifier: target.bundleIdentifier))
        XCTAssertEqual(readCount, 0)
    }

    func testElectronAccessibilityObservationDoesNotRestoreReplacedProcess() throws {
        let target = electronTarget()
        var setValues: [Bool] = []
        var isSameApplication = true
        let controller = ChromiumAccessibilityObservationController(
            resolveApplication: { _, _ in target },
            isElectronApplication: { _ in true },
            readManualAccessibility: { _ in (.success, false) },
            setManualAccessibility: { _, enabled in
                setValues.append(enabled)
                return .success
            },
            validateApplication: { _ in isSameApplication }
        )

        let lease = try XCTUnwrap(
            controller.beginObservation(bundleIdentifier: target.bundleIdentifier)
        )
        isSameApplication = false
        lease.end()

        XCTAssertEqual(setValues, [true])
    }

    func testMissingBaselineCompletesUnsupportedAttemptWithoutLearning() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        let service = TargetAppCorrectionLearningService(
            textInsertionService: TextInsertionService(),
            textDiffService: TextDiffService(),
            dictionaryService: dictionaryService,
            persistLatestAttempt: false
        )

        let result = await service.trackInsertion(insertedText: "Korrektur", baseline: nil)

        XCTAssertEqual(result.snapshot.outcome, .unsupportedTextObservation)
        XCTAssertEqual(result.snapshot.learnedCorrectionCount, 0)
        XCTAssertEqual(service.latestAttempt, result.snapshot)
        XCTAssertTrue(result.learnedCorrections.isEmpty)
        XCTAssertEqual(dictionaryService.correctionsCount, 0)
    }

    private func electronTarget() -> ChromiumAccessibilityObservationController.RunningApplicationTarget {
        ChromiumAccessibilityObservationController.RunningApplicationTarget(
            processIdentifier: 42,
            bundleIdentifier: "com.example.electron",
            bundleURL: URL(fileURLWithPath: "/Applications/Electron Target.app")
        )
    }

    func testLearnsSingleConfidentReplacementAfterCommitSignal() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let element = AXUIElementCreateSystemWide()
        let textInsertionService = TextInsertionService()
        textInsertionService.focusedTextElementOverride = { element }

        var observations = [
            "Please use the word"
        ]
        textInsertionService.focusedTextStateOverride = { _ in
            let value = observations.removeFirst()
            return (value: value, selectedText: nil, selectedRange: NSRange(location: value.count, length: 0))
        }

        let commitEmitter = CommitEmitterBox()
        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        let service = TargetAppCorrectionLearningService(
            textInsertionService: textInsertionService,
            textDiffService: TextDiffService(),
            dictionaryService: dictionaryService,
            pollSchedule: [.seconds(5)],
            makeCommitObserver: commitObserver(capturing: commitEmitter)
        )
        let baseline = TextInsertionService.FocusedTextObservation(
            element: element,
            value: "Please use teh word",
            selectedText: nil,
            selectedRange: NSRange(location: 19, length: 0)
        )

        let task = Task { @MainActor in
            await service.trackInsertion(insertedText: "teh", baseline: baseline)
        }
        for _ in 0..<1000 where !commitEmitter.isReady {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(commitEmitter.isReady)
        commitEmitter.emit(.returnKey)
        let learned = await task.value

        XCTAssertEqual(learned.snapshot.outcome, .learned)
        XCTAssertEqual(learned.snapshot.commitSignal, .returnKey)
        XCTAssertEqual(learned.learnedCorrections.count, 1)
        XCTAssertEqual(learned.learnedCorrections.first?.original, "teh")
        XCTAssertEqual(learned.learnedCorrections.first?.replacement, "the")
        XCTAssertEqual(dictionaryService.correctionsCount, 1)
    }

    func testLearnsReportedTextEditCorrectionAfterTransientObservationAndReturn() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let element = AXUIElementCreateSystemWide()
        let textInsertionService = TextInsertionService()
        textInsertionService.focusedTextElementOverride = { element }
        var captureCount = 0
        textInsertionService.focusedTextStateOverride = { _ in
            captureCount += 1
            guard captureCount > 1 else { return nil }
            let value = "Beeper\n"
            return (value: value, selectedText: nil, selectedRange: NSRange(location: value.count, length: 0))
        }

        let commitEmitter = CommitEmitterBox()
        var sleepCount = 0
        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        let service = TargetAppCorrectionLearningService(
            textInsertionService: textInsertionService,
            textDiffService: TextDiffService(),
            dictionaryService: dictionaryService,
            pollSchedule: [.milliseconds(0), .milliseconds(0)],
            sleep: { _ in
                sleepCount += 1
                if sleepCount == 2 {
                    commitEmitter.emit(.returnKey)
                }
            },
            makeCommitObserver: commitObserver(capturing: commitEmitter)
        )
        let baseline = TextInsertionService.FocusedTextObservation(
            element: element,
            value: "Biper",
            selectedText: nil,
            selectedRange: NSRange(location: 5, length: 0)
        )

        let result = await service.trackInsertion(insertedText: "Biper", baseline: baseline)

        XCTAssertEqual(result.snapshot.outcome, .learned)
        XCTAssertEqual(result.snapshot.commitSignal, .returnKey)
        XCTAssertEqual(result.learnedCorrections.first?.original, "Biper")
        XCTAssertEqual(result.learnedCorrections.first?.replacement, "Beeper")
        XCTAssertEqual(dictionaryService.correctionsCount, 1)
    }

    func testSkipsSentenceRewriteAfterCommitSignal() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let element = AXUIElementCreateSystemWide()
        let textInsertionService = TextInsertionService()
        textInsertionService.focusedTextElementOverride = { element }

        var observations = [
            "Rewrite every token now"
        ]
        textInsertionService.focusedTextStateOverride = { _ in
            let value = observations.removeFirst()
            return (value: value, selectedText: nil, selectedRange: NSRange(location: value.count, length: 0))
        }

        let commitEmitter = CommitEmitterBox()
        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        let service = TargetAppCorrectionLearningService(
            textInsertionService: textInsertionService,
            textDiffService: TextDiffService(),
            dictionaryService: dictionaryService,
            pollSchedule: [.seconds(5)],
            makeCommitObserver: commitObserver(capturing: commitEmitter)
        )
        let baseline = TextInsertionService.FocusedTextObservation(
            element: element,
            value: "Please use teh word",
            selectedText: nil,
            selectedRange: NSRange(location: 19, length: 0)
        )

        let task = Task { @MainActor in
            await service.trackInsertion(insertedText: baseline.value, baseline: baseline)
        }
        for _ in 0..<1000 where !commitEmitter.isReady {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(commitEmitter.isReady)
        commitEmitter.emit(.returnKey)
        let learned = await task.value

        XCTAssertEqual(learned.snapshot.outcome, .ambiguousEdit)
        XCTAssertTrue(learned.learnedCorrections.isEmpty)
        XCTAssertEqual(dictionaryService.correctionsCount, 0)
    }

    func testTrackInsertionResultCapturesManualCorrectionAfterCommitSignal() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let element = AXUIElementCreateSystemWide()
        let textInsertionService = TextInsertionService()
        textInsertionService.focusedTextElementOverride = { element }

        var observations = [
            "Bitte schreibe Korrekturen."
        ]
        textInsertionService.focusedTextStateOverride = { _ in
            let value = observations.removeFirst()
            return (value: value, selectedText: nil, selectedRange: NSRange(location: value.count, length: 0))
        }

        let commitEmitter = CommitEmitterBox()
        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        let service = TargetAppCorrectionLearningService(
            textInsertionService: textInsertionService,
            textDiffService: TextDiffService(),
            dictionaryService: dictionaryService,
            pollSchedule: [.seconds(5)],
            makeCommitObserver: commitObserver(capturing: commitEmitter)
        )
        let baseline = TextInsertionService.FocusedTextObservation(
            element: element,
            value: "Bitte schreibe Korrektur.",
            selectedText: nil,
            selectedRange: NSRange(location: 25, length: 0)
        )

        let task = Task { @MainActor in
            await service.trackInsertionResult(insertedText: "Korrektur.", baseline: baseline)
        }
        for _ in 0..<1000 where !commitEmitter.isReady {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(commitEmitter.isReady)
        commitEmitter.emit(.returnKey)
        let result = await task.value

        XCTAssertEqual(result.correctionObservation?.correctedInsertedText, "Korrekturen.")
        XCTAssertEqual(result.correctionObservation?.commitSignal, .returnKey)
    }

    func testTrackInsertionResultCapturesRewriteWithoutDictionaryLearning() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let element = AXUIElementCreateSystemWide()
        let textInsertionService = TextInsertionService()
        textInsertionService.focusedTextElementOverride = { element }
        textInsertionService.focusedTextStateOverride = { _ in
            let value = "Neue bessere Version."
            return (value: value, selectedText: nil, selectedRange: NSRange(location: value.count, length: 0))
        }

        let commitEmitter = CommitEmitterBox()
        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        let service = TargetAppCorrectionLearningService(
            textInsertionService: textInsertionService,
            textDiffService: TextDiffService(),
            dictionaryService: dictionaryService,
            pollSchedule: [.seconds(5)],
            makeCommitObserver: commitObserver(capturing: commitEmitter)
        )
        let baseline = TextInsertionService.FocusedTextObservation(
            element: element,
            value: "Alte Version.",
            selectedText: nil,
            selectedRange: NSRange(location: 13, length: 0)
        )

        let task = Task { @MainActor in
            await service.trackInsertionResult(insertedText: "Alte Version.", baseline: baseline)
        }
        for _ in 0..<1000 where !commitEmitter.isReady {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(commitEmitter.isReady)
        commitEmitter.emit(.returnKey)
        let result = await task.value

        XCTAssertEqual(result.correctionObservation?.correctedInsertedText, "Neue bessere Version.")
        XCTAssertTrue(result.learnedCorrections.isEmpty)
        XCTAssertEqual(dictionaryService.correctionsCount, 0)
    }

    func testCorrectedInsertedTextTrimsTheCompleteReconstructedCorrection() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }
        let service = TargetAppCorrectionLearningService(
            textInsertionService: TextInsertionService(),
            textDiffService: TextDiffService(),
            dictionaryService: DictionaryService(appSupportDirectory: appSupportDirectory),
            pollSchedule: []
        )

        XCTAssertEqual(
            service.correctedInsertedText(
                insertedText: "  wrong value  ",
                baselineText: "Before  wrong value  After",
                editedText: "Before  right value  After"
            ),
            "right value"
        )
    }

    func testSkipsInsertedTextRemovalAfterCommitSignal() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let element = AXUIElementCreateSystemWide()
        let textInsertionService = TextInsertionService()
        textInsertionService.focusedTextElementOverride = { element }

        var observations = [
            "Please use word"
        ]
        textInsertionService.focusedTextStateOverride = { _ in
            let value = observations.removeFirst()
            return (value: value, selectedText: nil, selectedRange: NSRange(location: value.count, length: 0))
        }

        let commitEmitter = CommitEmitterBox()
        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        let service = TargetAppCorrectionLearningService(
            textInsertionService: textInsertionService,
            textDiffService: TextDiffService(),
            dictionaryService: dictionaryService,
            pollSchedule: [.seconds(5)],
            makeCommitObserver: commitObserver(capturing: commitEmitter)
        )
        let baseline = TextInsertionService.FocusedTextObservation(
            element: element,
            value: "Please use teh word",
            selectedText: nil,
            selectedRange: NSRange(location: 19, length: 0)
        )

        let task = Task { @MainActor in
            await service.trackInsertion(insertedText: "teh", baseline: baseline)
        }
        for _ in 0..<1000 where !commitEmitter.isReady {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(commitEmitter.isReady)
        commitEmitter.emit(.returnKey)
        let learned = await task.value

        XCTAssertEqual(learned.snapshot.outcome, .ambiguousEdit)
        XCTAssertTrue(learned.learnedCorrections.isEmpty)
        XCTAssertEqual(dictionaryService.correctionsCount, 0)
    }

    func testTimeoutDoesNotLearnWithoutCommitSignal() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let element = AXUIElementCreateSystemWide()
        let textInsertionService = TextInsertionService()
        textInsertionService.focusedTextElementOverride = { element }

        var observations = [
            "Please use the word",
            "Please use the word"
        ]
        textInsertionService.focusedTextStateOverride = { _ in
            let value = observations.removeFirst()
            return (value: value, selectedText: nil, selectedRange: NSRange(location: value.count, length: 0))
        }

        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        let service = TargetAppCorrectionLearningService(
            textInsertionService: textInsertionService,
            textDiffService: TextDiffService(),
            dictionaryService: dictionaryService,
            pollSchedule: [.milliseconds(0), .milliseconds(0)],
            makeCommitObserver: noopCommitObserver
        )
        let baseline = TextInsertionService.FocusedTextObservation(
            element: element,
            value: "Please use teh word",
            selectedText: nil,
            selectedRange: NSRange(location: 19, length: 0)
        )

        let learned = await service.trackInsertion(insertedText: "teh", baseline: baseline)

        XCTAssertEqual(learned.snapshot.outcome, .noCommitBeforeTimeout)
        XCTAssertTrue(learned.learnedCorrections.isEmpty)
        XCTAssertEqual(dictionaryService.correctionsCount, 0)
    }

    func testLearnsLatestConfidentReplacementWhenFocusLeavesSameElement() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let element = AXUIElementCreateSystemWide()
        let textInsertionService = TextInsertionService()
        let otherElement = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        var focusLeft = false
        textInsertionService.focusedTextElementOverride = {
            focusLeft ? otherElement : element
        }

        var captureCount = 0
        textInsertionService.focusedTextStateOverride = { _ in
            captureCount += 1
            if captureCount == 1 {
                let value = "Please use the word"
                return (value: value, selectedText: nil, selectedRange: NSRange(location: value.count, length: 0))
            }
            focusLeft = true
            return nil
        }

        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        let service = TargetAppCorrectionLearningService(
            textInsertionService: textInsertionService,
            textDiffService: TextDiffService(),
            dictionaryService: dictionaryService,
            pollSchedule: [.milliseconds(0), .milliseconds(0)],
            makeCommitObserver: noopCommitObserver
        )
        let baseline = TextInsertionService.FocusedTextObservation(
            element: element,
            value: "Please use teh word",
            selectedText: nil,
            selectedRange: NSRange(location: 19, length: 0)
        )

        let learned = await service.trackInsertion(insertedText: "teh", baseline: baseline)

        XCTAssertEqual(learned.snapshot.outcome, .learned)
        XCTAssertEqual(learned.snapshot.commitSignal, .focusChanged)
        XCTAssertEqual(learned.learnedCorrections.first?.original, "teh")
        XCTAssertEqual(learned.learnedCorrections.first?.replacement, "the")
        XCTAssertEqual(dictionaryService.correctionsCount, 1)
    }

    func testSkipsMissingTextStateWithoutFocusChangeAfterCandidate() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let element = AXUIElementCreateSystemWide()
        let textInsertionService = TextInsertionService()
        textInsertionService.focusedTextElementOverride = { element }

        var captureCount = 0
        textInsertionService.focusedTextStateOverride = { _ in
            captureCount += 1
            if captureCount == 1 {
                let value = "Please use the word"
                return (value: value, selectedText: nil, selectedRange: NSRange(location: value.count, length: 0))
            }
            return nil
        }

        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        let service = TargetAppCorrectionLearningService(
            textInsertionService: textInsertionService,
            textDiffService: TextDiffService(),
            dictionaryService: dictionaryService,
            pollSchedule: [.milliseconds(0), .milliseconds(0)],
            makeCommitObserver: noopCommitObserver
        )
        let baseline = TextInsertionService.FocusedTextObservation(
            element: element,
            value: "Please use teh word",
            selectedText: nil,
            selectedRange: NSRange(location: 19, length: 0)
        )

        let learned = await service.trackInsertion(insertedText: "teh", baseline: baseline)

        XCTAssertEqual(learned.snapshot.outcome, .noCommitBeforeTimeout)
        XCTAssertTrue(learned.learnedCorrections.isEmpty)
        XCTAssertEqual(dictionaryService.correctionsCount, 0)
    }

    func testSkipsUnavailableFocusComparisonAfterCandidate() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let element = AXUIElementCreateSystemWide()
        let textInsertionService = TextInsertionService()
        var focusAvailable = true
        textInsertionService.focusedTextElementOverride = {
            focusAvailable ? element : nil
        }

        var captureCount = 0
        textInsertionService.focusedTextStateOverride = { _ in
            captureCount += 1
            if captureCount == 1 {
                let value = "Please use the word"
                return (value: value, selectedText: nil, selectedRange: NSRange(location: value.count, length: 0))
            }
            focusAvailable = false
            return nil
        }

        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        let service = TargetAppCorrectionLearningService(
            textInsertionService: textInsertionService,
            textDiffService: TextDiffService(),
            dictionaryService: dictionaryService,
            pollSchedule: [.milliseconds(0), .milliseconds(0)],
            makeCommitObserver: noopCommitObserver
        )
        let baseline = TextInsertionService.FocusedTextObservation(
            element: element,
            value: "Please use teh word",
            selectedText: nil,
            selectedRange: NSRange(location: 19, length: 0)
        )

        let learned = await service.trackInsertion(insertedText: "teh", baseline: baseline)

        XCTAssertEqual(learned.snapshot.outcome, .noCommitBeforeTimeout)
        XCTAssertTrue(learned.learnedCorrections.isEmpty)
        XCTAssertEqual(dictionaryService.correctionsCount, 0)
    }

    func testSkipsFocusElementChangesAndMissingTextState() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let baselineElement = AXUIElementCreateSystemWide()
        let otherElement = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let baseline = TextInsertionService.FocusedTextObservation(
            element: baselineElement,
            value: "teh",
            selectedText: nil,
            selectedRange: NSRange(location: 3, length: 0)
        )

        let changedFocusInsertionService = TextInsertionService()
        changedFocusInsertionService.focusedTextElementOverride = { otherElement }
        changedFocusInsertionService.focusedTextStateOverride = { _ in
            (value: "the", selectedText: nil, selectedRange: NSRange(location: 3, length: 0))
        }
        let changedFocusDictionary = DictionaryService(appSupportDirectory: appSupportDirectory.appendingPathComponent("changed-focus"))
        let changedFocusService = TargetAppCorrectionLearningService(
            textInsertionService: changedFocusInsertionService,
            textDiffService: TextDiffService(),
            dictionaryService: changedFocusDictionary,
            pollSchedule: [.milliseconds(0)],
            makeCommitObserver: noopCommitObserver
        )

        let changedFocusLearned = await changedFocusService.trackInsertion(insertedText: "teh", baseline: baseline)
        XCTAssertEqual(changedFocusLearned.snapshot.outcome, .unsupportedTextObservation)
        XCTAssertEqual(changedFocusLearned.snapshot.commitSignal, .focusChanged)
        XCTAssertTrue(changedFocusLearned.learnedCorrections.isEmpty)

        let missingStateInsertionService = TextInsertionService()
        missingStateInsertionService.focusedTextElementOverride = { baselineElement }
        missingStateInsertionService.focusedTextStateOverride = { _ in nil }
        let missingStateDictionary = DictionaryService(appSupportDirectory: appSupportDirectory.appendingPathComponent("missing-state"))
        let missingStateService = TargetAppCorrectionLearningService(
            textInsertionService: missingStateInsertionService,
            textDiffService: TextDiffService(),
            dictionaryService: missingStateDictionary,
            pollSchedule: [.milliseconds(0)],
            makeCommitObserver: noopCommitObserver
        )

        let missingStateLearned = await missingStateService.trackInsertion(insertedText: "teh", baseline: baseline)
        XCTAssertEqual(missingStateLearned.snapshot.outcome, .noCommitBeforeTimeout)
        XCTAssertTrue(missingStateLearned.learnedCorrections.isEmpty)
    }

    func testClearsStaleSuggestionsWhenEditIsUndoneBeforeCommit() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let element = AXUIElementCreateSystemWide()
        let textInsertionService = TextInsertionService()
        textInsertionService.focusedTextElementOverride = { element }

        var observations = [
            "Please use the word",
            "Please use teh word",
            "Please use teh word"
        ]
        textInsertionService.focusedTextStateOverride = { _ in
            let value = observations.removeFirst()
            return (value: value, selectedText: nil, selectedRange: NSRange(location: value.count, length: 0))
        }

        let commitEmitter = CommitEmitterBox()
        var sleepCount = 0
        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        let service = TargetAppCorrectionLearningService(
            textInsertionService: textInsertionService,
            textDiffService: TextDiffService(),
            dictionaryService: dictionaryService,
            pollSchedule: [.milliseconds(0), .milliseconds(0), .milliseconds(0)],
            sleep: { _ in
                sleepCount += 1
                if sleepCount == 3 {
                    commitEmitter.emit(.returnKey)
                }
            },
            makeCommitObserver: commitObserver(capturing: commitEmitter)
        )
        let baseline = TextInsertionService.FocusedTextObservation(
            element: element,
            value: "Please use teh word",
            selectedText: nil,
            selectedRange: NSRange(location: 19, length: 0)
        )

        let learned = await service.trackInsertion(insertedText: "teh", baseline: baseline)

        XCTAssertEqual(learned.snapshot.outcome, .noEdit)
        XCTAssertTrue(learned.learnedCorrections.isEmpty)
        XCTAssertEqual(dictionaryService.correctionsCount, 0)
    }

    func testSkipsUnmappableLargeDuplicateCaseAndPunctuationOnlyEdits() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let element = AXUIElementCreateSystemWide()
        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        dictionaryService.addEntry(type: .correction, original: "teh", replacement: "the")

        let service = TargetAppCorrectionLearningService(
            textInsertionService: TextInsertionService(),
            textDiffService: TextDiffService(),
            dictionaryService: dictionaryService,
            pollSchedule: [.milliseconds(0)],
            makeCommitObserver: noopCommitObserver
        )
        let baseline = TextInsertionService.FocusedTextObservation(
            element: element,
            value: "Please use teh word",
            selectedText: nil,
            selectedRange: NSRange(location: 19, length: 0)
        )

        XCTAssertTrue(service.highConfidenceCorrectionSuggestions(
            insertedText: "not present",
            baselineText: baseline.value,
            editedText: "Please use the word"
        ).isEmpty)

        XCTAssertTrue(service.highConfidenceCorrectionSuggestions(
            insertedText: baseline.value,
            baselineText: baseline.value,
            editedText: "Completely different rewrite with many words"
        ).isEmpty)

        XCTAssertTrue(service.highConfidenceCorrectionSuggestions(
            insertedText: "teh",
            baselineText: baseline.value,
            editedText: "Please use Teh word"
        ).isEmpty)

        XCTAssertTrue(service.highConfidenceCorrectionSuggestions(
            insertedText: "teh.",
            baselineText: "Please use teh. word",
            editedText: "Please use teh word"
        ).isEmpty)

        let duplicateInsertionService = TextInsertionService()
        duplicateInsertionService.focusedTextElementOverride = { element }
        duplicateInsertionService.focusedTextStateOverride = { _ in
            (value: "Please use the word", selectedText: nil, selectedRange: NSRange(location: 19, length: 0))
        }
        let duplicateCommitEmitter = CommitEmitterBox()
        var duplicateSleepCount = 0
        let duplicateService = TargetAppCorrectionLearningService(
            textInsertionService: duplicateInsertionService,
            textDiffService: TextDiffService(),
            dictionaryService: dictionaryService,
            pollSchedule: [.milliseconds(0), .milliseconds(0)],
            sleep: { _ in
                duplicateSleepCount += 1
                if duplicateSleepCount == 2 {
                    duplicateCommitEmitter.emit(.returnKey)
                }
            },
            makeCommitObserver: commitObserver(capturing: duplicateCommitEmitter)
        )

        let duplicateLearned = await duplicateService.trackInsertion(insertedText: "teh", baseline: baseline)
        XCTAssertEqual(duplicateLearned.snapshot.outcome, .duplicateCorrection)
        XCTAssertTrue(duplicateLearned.learnedCorrections.isEmpty)
        XCTAssertEqual(dictionaryService.correctionsCount, 1)
    }

    func testCancelsStaleTrackingBeforeLearning() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let element = AXUIElementCreateSystemWide()
        let textInsertionService = TextInsertionService()
        textInsertionService.focusedTextElementOverride = { element }
        textInsertionService.focusedTextStateOverride = { _ in
            (value: "Please use the word", selectedText: nil, selectedRange: NSRange(location: 19, length: 0))
        }

        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        let service = TargetAppCorrectionLearningService(
            textInsertionService: textInsertionService,
            textDiffService: TextDiffService(),
            dictionaryService: dictionaryService,
            pollSchedule: [.seconds(60)],
            makeCommitObserver: noopCommitObserver
        )
        let baseline = TextInsertionService.FocusedTextObservation(
            element: element,
            value: "Please use teh word",
            selectedText: nil,
            selectedRange: NSRange(location: 19, length: 0)
        )

        let task = Task { @MainActor in
            await service.trackInsertion(insertedText: "teh", baseline: baseline)
        }
        await Task.yield()
        task.cancel()

        let learned = await task.value
        XCTAssertEqual(learned.snapshot.outcome, .cancelled)
        XCTAssertTrue(learned.learnedCorrections.isEmpty)
        XCTAssertEqual(dictionaryService.correctionsCount, 0)
    }

    func testLearnsSafeCandidateWhenTextObservationDisappearsAtCommit() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let element = AXUIElementCreateSystemWide()
        let textInsertionService = TextInsertionService()
        textInsertionService.focusedTextElementOverride = { element }
        var captureCount = 0
        textInsertionService.focusedTextStateOverride = { _ in
            captureCount += 1
            guard captureCount == 1 else { return nil }
            let value = "Please use the word"
            return (value: value, selectedText: nil, selectedRange: NSRange(location: value.count, length: 0))
        }

        let commitEmitter = CommitEmitterBox()
        var sleepCount = 0
        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        let service = TargetAppCorrectionLearningService(
            textInsertionService: textInsertionService,
            textDiffService: TextDiffService(),
            dictionaryService: dictionaryService,
            pollSchedule: [.milliseconds(0), .milliseconds(0)],
            sleep: { _ in
                sleepCount += 1
                if sleepCount == 2 {
                    commitEmitter.emit(.tabKey)
                }
            },
            makeCommitObserver: commitObserver(capturing: commitEmitter)
        )
        let baseline = TextInsertionService.FocusedTextObservation(
            element: element,
            value: "Please use teh word",
            selectedText: nil,
            selectedRange: NSRange(location: 19, length: 0)
        )

        let result = await service.trackInsertion(insertedText: "teh", baseline: baseline)

        XCTAssertEqual(result.snapshot.outcome, .learned)
        XCTAssertEqual(result.snapshot.commitSignal, .tabKey)
        XCTAssertEqual(result.learnedCorrections.first?.replacement, "the")
    }

    func testLearnsForKeypadEnterTabAndActiveApplicationCommitSignals() async throws {
        let rootDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(rootDirectory) }

        for signal in [
            TargetAppCorrectionCommitSignal.keypadEnterKey,
            .tabKey,
            .activeApplicationChanged
        ] {
            let element = AXUIElementCreateSystemWide()
            let textInsertionService = TextInsertionService()
            textInsertionService.focusedTextElementOverride = { element }
            textInsertionService.focusedTextStateOverride = { _ in
                let value = "Please use the word"
                return (value: value, selectedText: nil, selectedRange: NSRange(location: value.count, length: 0))
            }

            let commitEmitter = CommitEmitterBox()
            let dictionaryService = DictionaryService(
                appSupportDirectory: rootDirectory.appendingPathComponent(signal.rawValue)
            )
            let service = TargetAppCorrectionLearningService(
                textInsertionService: textInsertionService,
                textDiffService: TextDiffService(),
                dictionaryService: dictionaryService,
                pollSchedule: [.milliseconds(0)],
                sleep: { _ in commitEmitter.emit(signal) },
                makeCommitObserver: commitObserver(capturing: commitEmitter)
            )
            let baseline = TextInsertionService.FocusedTextObservation(
                element: element,
                value: "Please use teh word",
                selectedText: nil,
                selectedRange: NSRange(location: 19, length: 0)
            )

            let result = await service.trackInsertion(insertedText: "teh", baseline: baseline)

            XCTAssertEqual(result.snapshot.outcome, .learned, "Unexpected outcome for \(signal)")
            XCTAssertEqual(result.snapshot.commitSignal, signal)
            XCTAssertEqual(result.learnedCorrections.count, 1)
        }
    }

    func testReportsFailedWhenDictionaryStorageFails() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let element = AXUIElementCreateSystemWide()
        let textInsertionService = TextInsertionService()
        textInsertionService.focusedTextElementOverride = { element }
        textInsertionService.focusedTextStateOverride = { _ in
            let value = "Please use the word"
            return (value: value, selectedText: nil, selectedRange: NSRange(location: value.count, length: 0))
        }
        let commitEmitter = CommitEmitterBox()
        let service = TargetAppCorrectionLearningService(
            textInsertionService: textInsertionService,
            textDiffService: TextDiffService(),
            dictionaryService: DictionaryService(appSupportDirectory: appSupportDirectory),
            pollSchedule: [.milliseconds(0)],
            sleep: { _ in commitEmitter.emit(.returnKey) },
            makeCommitObserver: commitObserver(capturing: commitEmitter),
            learnCorrections: { _ in
                DictionaryCorrectionLearningResult(
                    learnedCorrections: [],
                    duplicateCount: 0,
                    failed: true
                )
            }
        )
        let baseline = TextInsertionService.FocusedTextObservation(
            element: element,
            value: "Please use teh word",
            selectedText: nil,
            selectedRange: NSRange(location: 19, length: 0)
        )

        let result = await service.trackInsertion(insertedText: "teh", baseline: baseline)

        XCTAssertEqual(result.snapshot.outcome, .failed)
        XCTAssertTrue(result.learnedCorrections.isEmpty)
    }

    func testLatestAttemptPersistsWithoutTextContent() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }
        let suiteName = "TargetAppCorrectionLearningServiceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let timestamp = Date(timeIntervalSince1970: 1_750_000_000)

        let service = TargetAppCorrectionLearningService(
            textInsertionService: TextInsertionService(),
            textDiffService: TextDiffService(),
            dictionaryService: DictionaryService(appSupportDirectory: appSupportDirectory),
            pollSchedule: [],
            makeCommitObserver: noopCommitObserver,
            defaults: defaults,
            persistLatestAttempt: true,
            now: { timestamp }
        )
        let baseline = TextInsertionService.FocusedTextObservation(
            element: AXUIElementCreateSystemWide(),
            value: "private baseline phrase",
            selectedText: nil,
            selectedRange: NSRange(location: 23, length: 0)
        )

        let result = await service.trackInsertion(insertedText: "private insertion", baseline: baseline)
        let storedData = try XCTUnwrap(defaults.data(
            forKey: UserDefaultsKeys.targetAppCorrectionLearningLatestAttempt
        ))
        let storedJSON = try XCTUnwrap(String(data: storedData, encoding: .utf8))

        XCTAssertEqual(result.snapshot.outcome, .noCommitBeforeTimeout)
        XCTAssertFalse(storedJSON.contains("private"))
        XCTAssertFalse(storedJSON.contains("bundle"))

        let reloadedService = TargetAppCorrectionLearningService(
            textInsertionService: TextInsertionService(),
            textDiffService: TextDiffService(),
            dictionaryService: DictionaryService(appSupportDirectory: appSupportDirectory),
            pollSchedule: [],
            makeCommitObserver: noopCommitObserver,
            defaults: defaults
        )
        XCTAssertEqual(reloadedService.latestAttempt, result.snapshot)

        let diagnosticData = try JSONEncoder().encode(DiagnosticCorrectionLearningInfo(
            enabled: true,
            lastAttempt: result.snapshot
        ))
        let diagnosticJSON = try XCTUnwrap(String(data: diagnosticData, encoding: .utf8))
        XCTAssertFalse(diagnosticJSON.contains("private"))
        XCTAssertFalse(diagnosticJSON.contains("bundle"))
    }

    func testCancelledOlderAttemptDoesNotOverwriteNewerOutcome() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let element = AXUIElementCreateSystemWide()
        let baseline = TextInsertionService.FocusedTextObservation(
            element: element,
            value: "teh",
            selectedText: nil,
            selectedRange: NSRange(location: 3, length: 0)
        )
        let textInsertionService = TextInsertionService()
        textInsertionService.focusedTextElementOverride = { element }
        textInsertionService.focusedTextStateOverride = { _ in nil }
        let service = TargetAppCorrectionLearningService(
            textInsertionService: textInsertionService,
            textDiffService: TextDiffService(),
            dictionaryService: DictionaryService(appSupportDirectory: appSupportDirectory),
            pollSchedule: [.seconds(60)],
            makeCommitObserver: noopCommitObserver
        )

        let olderTask = Task { @MainActor in
            await service.trackInsertion(insertedText: "teh", baseline: baseline)
        }
        await Task.yield()

        let newerResult = await service.trackInsertion(insertedText: "", baseline: baseline)
        olderTask.cancel()
        let olderResult = await olderTask.value

        XCTAssertEqual(newerResult.snapshot.outcome, .unsupportedTextObservation)
        XCTAssertEqual(olderResult.snapshot.outcome, .cancelled)
        XCTAssertEqual(service.latestAttempt, newerResult.snapshot)
    }

    func testCommitObserverMapsReturnEnterAndTabKeys() {
        XCTAssertEqual(TargetAppCorrectionCommitObserver.commitSignal(forKeyCode: 0x24), .returnKey)
        XCTAssertEqual(TargetAppCorrectionCommitObserver.commitSignal(forKeyCode: 0x4C), .keypadEnterKey)
        XCTAssertEqual(TargetAppCorrectionCommitObserver.commitSignal(forKeyCode: 0x30), .tabKey)
        XCTAssertNil(TargetAppCorrectionCommitObserver.commitSignal(forKeyCode: 0x31))
    }

    private func noopCommitObserver(
        onCommit _: @escaping @MainActor (TargetAppCorrectionCommitSignal) -> Void
    ) -> TargetAppCorrectionCommitObserving {
        TestTargetAppCorrectionCommitObserver()
    }

    private func commitObserver(
        capturing box: CommitEmitterBox
    ) -> (@escaping @MainActor (TargetAppCorrectionCommitSignal) -> Void) -> TargetAppCorrectionCommitObserving {
        { onCommit in
            box.emit = { signal in
                onCommit(signal)
            }
            box.isReady = true
            return TestTargetAppCorrectionCommitObserver()
        }
    }
}

@MainActor
private final class CommitEmitterBox {
    var emit: (TargetAppCorrectionCommitSignal) -> Void = { _ in }
    var isReady = false
}

@MainActor
private final class TestTargetAppCorrectionCommitObserver: TargetAppCorrectionCommitObserving {
    func start() {}
    func stop() {}
}

@MainActor
final class IntentCorrectionReviewTests: XCTestCase {
    private func withReview(
        baselineText: String = "Meet Vedan today",
        editedText: String = "Meet Vedant today",
        insertedText: String = "Meet Vedan today",
        reviewTimeout: Duration = .seconds(30),
        body: @MainActor (TargetAppCorrectionLearningService, DictionaryService, URL, UserDefaults) async throws -> Void
    ) async throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        let suite = "IntentCorrectionReviewTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: TargetAppCorrectionLearningService.localEnabledKey)
        defer { TestSupport.remove(directory); defaults.removePersistentDomain(forName: suite) }
        let element = AXUIElementCreateSystemWide()
        let insertion = TextInsertionService()
        insertion.focusedTextElementOverride = { element }
        insertion.focusedTextStateOverride = { _ in (editedText, nil, NSRange(location: editedText.utf16.count, length: 0)) }
        let dictionary = DictionaryService(appSupportDirectory: directory)
        let service = TargetAppCorrectionLearningService(
            textInsertionService: insertion, textDiffService: TextDiffService(), dictionaryService: dictionary,
            pollSchedule: [.seconds(5)], makeCommitObserver: { onCommit in
                Task { @MainActor in onCommit(.returnKey) }
                return TestTargetAppCorrectionCommitObserver()
            }, defaults: defaults, persistLatestAttempt: false, reviewBeforeSaving: true, reviewTimeout: reviewTimeout
        )
        let baseline = TextInsertionService.FocusedTextObservation(element: element, value: baselineText, selectedText: nil, selectedRange: NSRange(location: baselineText.utf16.count, length: 0))
        _ = await service.trackInsertion(insertedText: insertedText, baseline: baseline)
        defer { service.dismissReview() }
        try await body(service, dictionary, directory, defaults)
    }

    func testConfirmationPersistenceBoundariesEditDeleteAndUndo() async throws {
        try await withReview { service, dictionary, directory, _ in
            let pending = try XCTUnwrap(service.pendingCorrection)
            XCTAssertEqual(service.latestAttempt?.outcome, .awaitingReview)
            XCTAssertEqual(dictionary.correctionsCount, 0)
            XCTAssertEqual(dictionary.applyCorrections(to: "Vedan"), "Vedan")
            service.rememberCorrection(id: UUID())
            XCTAssertEqual(dictionary.correctionsCount, 0)
            service.rememberCorrection(id: pending.id)
            XCTAssertEqual(dictionary.applyCorrections(to: "Vedan, not Vedanna."), "Vedant, not Vedanna.")
            XCTAssertEqual(DictionaryService(appSupportDirectory: directory).applyCorrections(to: "Vedan"), "Vedant")
            let entry = try XCTUnwrap(dictionary.corrections.first)
            XCTAssertEqual(entry.source, .autoLearned)
            XCTAssertTrue(dictionary.userDataSyncEntries(keepLearnedCorrectionsLocal: true).isEmpty)
            dictionary.updateEntry(entry, original: "Vedan", replacement: "Vedanth", caseSensitive: false)
            XCTAssertEqual(dictionary.applyCorrections(to: "Vedan"), "Vedanth")
            service.undoReviewedCorrections()
            XCTAssertEqual(dictionary.correctionsCount, 1, "Undo must protect a subsequently edited rule")
            dictionary.deleteEntry(entry)
            XCTAssertEqual(dictionary.applyCorrections(to: "Vedan"), "Vedan")
        }
        try await withReview { service, dictionary, _, _ in
            service.rememberCorrection(id: try XCTUnwrap(service.pendingCorrection).id)
            service.undoReviewedCorrections()
            XCTAssertEqual(dictionary.correctionsCount, 0)
        }
    }

    func testDismissDisableAndConflictingRulesNeverSaveOrOverwrite() async throws {
        try await withReview { service, dictionary, _, defaults in
            let id = try XCTUnwrap(service.pendingCorrection).id
            defaults.set(false, forKey: TargetAppCorrectionLearningService.localEnabledKey)
            service.rememberCorrection(id: id)
            XCTAssertEqual(dictionary.correctionsCount, 0)
            service.dismissReview()
            defaults.set(true, forKey: TargetAppCorrectionLearningService.localEnabledKey)
            service.rememberCorrection(id: id)
            XCTAssertEqual(dictionary.correctionsCount, 0)
        }
        try await withReview { service, dictionary, _, _ in
            dictionary.addEntry(type: .correction, original: "Vedan", replacement: "Existing")
            service.rememberCorrection(id: try XCTUnwrap(service.pendingCorrection).id)
            XCTAssertEqual(dictionary.applyCorrections(to: "Vedan"), "Existing")
            XCTAssertTrue(service.reviewedCorrections.isEmpty)
        }
    }

    func testUnrelatedRewriteNumericDuplicateAndCaseChangesProduceNoCandidate() async throws {
        for edited in ["Write something else entirely", "Meet Vedan tomorrow", "Meet VEDAN today", "Meet Vedan today and tomorrow"] {
            try await withReview(editedText: edited, insertedText: "Vedan") { service, dictionary, _, _ in
                XCTAssertNil(service.pendingCorrection)
                XCTAssertEqual(dictionary.correctionsCount, 0)
            }
        }
        try await withReview(baselineText: "Pay 15 today", editedText: "Pay 50 today", insertedText: "Pay 15 today") { service, _, _, _ in
            XCTAssertNil(service.pendingCorrection)
        }
        try await withReview(baselineText: "Vedan and Vedan", editedText: "Vedant and Vedan", insertedText: "Vedan") { service, _, _, _ in
            XCTAssertNil(service.pendingCorrection)
        }
    }

    func testReturnNewlineOutsideInsertedSpanStillOffersSpellingReview() async throws {
        try await withReview(baselineText: "Meet Rohan today.\n", editedText: "Meet Rohaan today.\n\n", insertedText: "Meet Rohan today.") { service, dictionary, _, _ in
            XCTAssertEqual(service.pendingCorrection?.original, "Rohan")
            XCTAssertEqual(service.pendingCorrection?.replacement, "Rohaan")
            XCTAssertEqual(dictionary.correctionsCount, 0)
        }
        try await withReview(baselineText: "Meet Rohan today.\nOther text", editedText: "Meet Rohaan today.\nUnrelated edit\n", insertedText: "Meet Rohan today.") { service, dictionary, _, _ in
            XCTAssertNil(service.pendingCorrection)
            XCTAssertEqual(dictionary.correctionsCount, 0)
        }
    }

    func testExpiredAndSupersededCandidatesCannotBeRemembered() async throws {
        try await withReview(reviewTimeout: .milliseconds(10)) { service, dictionary, _, _ in
            let id = try XCTUnwrap(service.pendingCorrection).id
            try await Task.sleep(for: .milliseconds(40))
            XCTAssertNil(service.pendingCorrection)
            service.rememberCorrection(id: id)
            XCTAssertEqual(dictionary.correctionsCount, 0)
        }
        try await withReview { service, dictionary, _, _ in
            let id = try XCTUnwrap(service.pendingCorrection).id
            _ = await service.trackInsertion(insertedText: "New take", baseline: nil)
            service.rememberCorrection(id: id)
            XCTAssertNil(service.pendingCorrection)
            XCTAssertEqual(dictionary.correctionsCount, 0)
        }
    }

    func testVerifiedInsertionRequiresExactSelectionAndUniqueOccurrence() {
        let element = AXUIElementCreateSystemWide()
        func observation(_ value: String, _ selection: NSRange?) -> TextInsertionService.FocusedTextObservation {
            .init(element: element, value: value, selectedText: nil, selectedRange: selection)
        }
        let before = observation("Prefix old suffix", NSRange(location: 7, length: 3))
        XCTAssertTrue(TargetAppCorrectionLearningService.verifiedInsertion(insertedText: "Vedan", before: before, after: observation("Prefix Vedan suffix", nil)))
        XCTAssertFalse(TargetAppCorrectionLearningService.verifiedInsertion(insertedText: "Vedan", before: before, after: observation("Other Vedan text", nil)))
        XCTAssertFalse(TargetAppCorrectionLearningService.verifiedInsertion(insertedText: "Vedan", before: nil, after: observation("Vedan", nil)))
        XCTAssertTrue(TargetAppCorrectionLearningService.verifiedInsertion(insertedText: "Vedan", before: observation("Vedan ", NSRange(location: 6, length: 0)), after: observation("Vedan Vedan", nil)))
    }
}

@MainActor
final class SettledEditDetectionTests: XCTestCase {
    private struct Frame {
        var text: String?
        var selection: NSRange? = NSRange(location: 0, length: 0)
        var sameFocus = true
        var pinnedText: String? = nil
    }

    private func runLearningSequence(
        original: String = "Meet Rohan today.", takes: [[Frame]],
        onFrame: (@MainActor (Int, Int, TargetAppCorrectionLearningService, DictionaryService, UserDefaults) -> Void)? = nil,
        body: @MainActor (TargetAppCorrectionLearningService, DictionaryService, UserDefaults) throws -> Void
    ) async throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        let suite = "LearningSequence.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: TargetAppCorrectionLearningService.localEnabledKey)
        defer { TestSupport.remove(directory); defaults.removePersistentDomain(forName: suite) }
        let dictionary = DictionaryService(appSupportDirectory: directory)
        let insertion = TextInsertionService()
        let element = AXUIElementCreateSystemWide(), other = AXUIElementCreateApplication(1)
        var take = 0, index = -1
        var time = Date(timeIntervalSince1970: 1_000)
        insertion.focusedTextElementOverride = { index < 0 || takes[take][index].sameFocus ? element : other }
        insertion.focusedTextStateOverride = { target in
            guard index >= 0 else { return (original, nil, NSRange(location: original.utf16.count, length: 0)) }
            let frame = takes[take][index]
            guard let value = !frame.sameFocus && target == element ? frame.pinnedText : frame.text else { return nil }
            return (value, nil, frame.selection)
        }
        var service: TargetAppCorrectionLearningService!
        service = TargetAppCorrectionLearningService(textInsertionService: insertion, textDiffService: TextDiffService(), dictionaryService: dictionary,
            pollSchedule: (1...(takes.map(\.count).max() ?? 1)).map { .seconds($0) },
            sleep: { _ in
                index = min(index + 1, takes[take].count - 1)
                time += 1
                onFrame?(take, index, service, dictionary, defaults)
            }, defaults: defaults, persistLatestAttempt: false, observeSettledEdits: true, now: { time })
        for current in takes.indices {
            take = current; index = -1
            let baseline = TextInsertionService.FocusedTextObservation(element: element, value: original, selectedText: nil,
                selectedRange: NSRange(location: original.utf16.count, length: 0), ownedInsertionRange: NSRange(location: 0, length: original.utf16.count))
            _ = await service.trackInsertion(insertedText: original, baseline: baseline)
        }
        try body(service, dictionary, defaults)
    }

    func testRepeatedMultiCorrectionLearnsBeforeObservationEndsAndFeedsFreshText() async throws {
        let frames = Array(repeating: Frame(text: "Ask Rohaan and Vedant today!"), count: 6)
        try await runLearningSequence(original: "Ask Rohan and Vedan today.", takes: [frames, frames], onFrame: { take, frame, _, dictionary, _ in
            if take == 0 { XCTAssertEqual(dictionary.correctionsCount, 0) }
            if take == 1 && frame == 4 { XCTAssertEqual(dictionary.correctionsCount, 2, "Feedback must not wait for the two-minute timeout") }
        }) { _, dictionary, _ in
            XCTAssertEqual(dictionary.previewCorrections(to: "Vedan called Rohan yesterday."), "Vedant called Rohaan yesterday.")
            XCTAssertEqual(Set(dictionary.enabledTerms()), Set(["Rohaan", "Vedant"]))
        }
    }

    func testOneTakeManySnapshotsIsOnlyOneObservation() async throws {
        try await runLearningSequence(takes: [Array(repeating: Frame(text: "Meet Rohaan today."), count: 15)]) { service, dictionary, _ in
            XCTAssertEqual(service.detectedEdits.count, 1)
            XCTAssertEqual(dictionary.correctionsCount, 0)
        }
    }

    func testFailedAutomaticSaveKeepsEvidenceUnconsumedForRetry() async throws {
        let frames = Array(repeating: Frame(text: "Meet Rohaan today."), count: 5)
        try await runLearningSequence(takes: [frames, frames], onFrame: { _, _, _, dictionary, _ in
            dictionary.learningSaveOverride = { throw NSError(domain: "SyntheticSaveFailure", code: 1) }
        }) { service, dictionary, _ in
            XCTAssertEqual(dictionary.correctionsCount, 0)
            XCTAssertTrue(service.detectedEdits.allSatisfy { $0.consumedCandidateKeys?.isEmpty ?? true })
            XCTAssertTrue(service.reviewedCorrections.isEmpty)
            XCTAssertTrue(service.reviewMessage?.contains("Could not save") == true)
            dictionary.learningSaveOverride = nil
            service.rememberDetectedEdit(id: try XCTUnwrap(service.detectedEdits.last).id)
            XCTAssertEqual(dictionary.correctionsCount, 1)
        }
    }

    func testRevertingSecondTakeWithdrawsProvisionalMemoryAndRestoresEvidence() async throws {
        let settled = Array(repeating: Frame(text: "Meet Rohaan today."), count: 5)
        let reverted = settled + Array(repeating: Frame(text: "Meet Rohan today."), count: 4)
        try await runLearningSequence(takes: [settled, reverted], onFrame: { take, frame, _, dictionary, _ in
            if take == 1 && frame == 4 { XCTAssertEqual(dictionary.correctionsCount, 1) }
        }) { service, dictionary, _ in
            XCTAssertEqual(dictionary.correctionsCount, 0)
            XCTAssertTrue(dictionary.enabledTerms().isEmpty)
            XCTAssertTrue(service.reviewedCorrections.isEmpty)
            XCTAssertFalse(dictionary.isLearningDismissed(original: "Rohan", replacement: "Rohaan"))
            XCTAssertEqual(service.detectedEdits.count, 1)
            XCTAssertTrue(service.detectedEdits[0].consumedCandidateKeys?.isEmpty ?? true)
        }
        try await runLearningSequence(takes: [settled, reverted, settled]) { _, dictionary, _ in
            XCTAssertEqual(dictionary.correctionsCount, 1, "A later independent correction may confirm the lesson")
        }
    }

    func testConflictingSpellingsAbstainAndAutomaticOffStillAllowsRemember() async throws {
        let a = Array(repeating: Frame(text: "Meet Rohaan today."), count: 5)
        let b = Array(repeating: Frame(text: "Meet Rohann today."), count: 5)
        try await runLearningSequence(takes: [a, b, a]) { _, dictionary, _ in
            XCTAssertEqual(dictionary.correctionsCount, 0)
        }
        try await runLearningSequence(takes: [a, a], onFrame: { _, _, _, _, defaults in
            defaults.set(false, forKey: TargetAppCorrectionLearningService.automaticLearningKey)
        }) { service, dictionary, _ in
            XCTAssertEqual(dictionary.correctionsCount, 0)
            service.rememberDetectedEdit(id: try XCTUnwrap(service.detectedEdits.first).id)
            XCTAssertEqual(dictionary.correctionsCount, 1)
        }
    }

    func testCommonWordLearningIsVocabularyOnlyAcrossIndependentTakes() async throws {
        let frames = Array(repeating: Frame(text: "Try Kivi today."), count: 5)
        try await runLearningSequence(original: "Try kiwi today.", takes: [frames, frames]) { service, dictionary, _ in
            XCTAssertEqual(dictionary.termsCount, 1)
            XCTAssertEqual(dictionary.correctionsCount, 0)
            XCTAssertEqual(dictionary.previewCorrections(to: "Buy kiwi fruit."), "Buy kiwi fruit.")
            service.undoReviewedCorrections()
            XCTAssertTrue(dictionary.enabledTerms().isEmpty)
        }
    }

    func testQuickFocusExitCanConfirmPreviouslyObservedCorrection() async throws {
        let frames = [Frame(text: "Other field", sameFocus: false, pinnedText: "Meet Rohaan today.")]
        try await runLearningSequence(takes: [frames, frames]) { _, dictionary, _ in
            XCTAssertEqual(dictionary.correctionsCount, 1)
        }
    }

    private func runFrames(
        before: String = "", inserted: String = "Meet Rohan today.", selection: NSRange = NSRange(location: 0, length: 0),
        frames: [Frame], onFrame: (@MainActor (Int, TargetAppCorrectionLearningService) -> Void)? = nil,
        body: @MainActor (TargetAppCorrectionLearningService, DictionaryService, UserDefaults) throws -> Void
    ) async throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        let suite = "SettledEditDetectionTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: TargetAppCorrectionLearningService.localEnabledKey)
        defer { TestSupport.remove(directory); defaults.removePersistentDomain(forName: suite) }
        let element = AXUIElementCreateSystemWide()
        let other = AXUIElementCreateApplication(1)
        let insertion = TextInsertionService()
        var index = -1
        var time = Date(timeIntervalSince1970: 1_000)
        insertion.focusedTextElementOverride = { index < 0 || frames[index].sameFocus ? element : other }
        insertion.focusedTextStateOverride = { target in
            guard index >= 0 else { return nil }
            let frame = frames[index]
            let text = target == element && !frame.sameFocus ? frame.pinnedText : frame.text
            guard let text else { return nil }
            return (text, nil, frame.selection)
        }
        let dictionary = DictionaryService(appSupportDirectory: directory)
        var service: TargetAppCorrectionLearningService!
        service = TargetAppCorrectionLearningService(textInsertionService: insertion, textDiffService: TextDiffService(), dictionaryService: dictionary,
            pollSchedule: frames.indices.map { .seconds($0 + 1) }, sleep: { _ in
                index += 1
                time += 1
                onFrame?(index, service)
            }, makeCommitObserver: { _ in XCTFail("Settled detection must not install a Return/commit observer"); return TestTargetAppCorrectionCommitObserver() },
            defaults: defaults, persistLatestAttempt: false, observeSettledEdits: true, settleSeconds: 3, now: { time })
        var post = before
        post.replaceSubrange(try XCTUnwrap(Range(selection, in: before)), with: inserted)
        let pre = TextInsertionService.FocusedTextObservation(element: element, value: before, selectedText: nil, selectedRange: selection)
        let after = TextInsertionService.FocusedTextObservation(element: element, value: post, selectedText: nil, selectedRange: NSRange(location: selection.location + inserted.utf16.count, length: 0))
        let baseline = try XCTUnwrap(TargetAppCorrectionLearningService.verifiedInsertionObservation(insertedText: inserted, before: pre, after: after))
        _ = await service.trackInsertion(insertedText: inserted, baseline: baseline)
        try body(service, dictionary, defaults)
    }

    func testSpellingDetectedWithoutReturnAndQueuePersistsWithoutLearning() async throws {
        try await runFrames(frames: Array(repeating: Frame(text: "Meet Rohaan today."), count: 5)) { service, dictionary, defaults in
            XCTAssertEqual(service.detectedEdits.count, 1)
            XCTAssertEqual(service.detectedEdits.first?.original, "Meet Rohan today.")
            XCTAssertEqual(service.detectedEdits.first?.edited, "Meet Rohaan today.")
            XCTAssertEqual(dictionary.correctionsCount, 0)
            XCTAssertNil(service.pendingCorrection)
            let data = try XCTUnwrap(defaults.data(forKey: TargetAppCorrectionLearningService.detectedEditsKey))
            XCTAssertEqual(try JSONDecoder().decode([TargetAppCorrectionLearningService.DetectedEdit].self, from: data), service.detectedEdits)
        }
    }

    func testIntermediateTypingAndReversionLeaveNoCapture() async throws {
        try await runFrames(frames: [Frame(text: "Meet Roha today."), Frame(text: "Meet Rohaa today."), Frame(text: "Meet Rohaan today."), Frame(text: "Meet Rohan today."), Frame(text: "Meet Rohan today.")]) { service, _, _ in
            XCTAssertTrue(service.detectedEdits.isEmpty)
        }
        try await runFrames(frames: Array(repeating: Frame(text: "Meet Rohaan today."), count: 4) + Array(repeating: Frame(text: "Meet Rohan today."), count: 4)) { service, _, _ in
            XCTAssertTrue(service.detectedEdits.isEmpty, "Undo must withdraw an already captured edit")
        }
    }

    func testLaterCorrectionReplacesEarlierCaptureInsteadOfDuplicatingIt() async throws {
        try await runFrames(frames: Array(repeating: Frame(text: "Meet Rohaan today."), count: 4) + Array(repeating: Frame(text: "Meet Rohaaan today."), count: 4)) { service, _, _ in
            XCTAssertEqual(service.detectedEdits.count, 1)
            XCTAssertEqual(service.detectedEdits.first?.edited, "Meet Rohaaan today.")
        }
    }

    func testKnownInsertionPositionSeparatesDuplicatePassagesAndOutsideEdits() async throws {
        let before = "Meet Rohan today.\n\nSuffix"
        let range = NSRange(location: 19, length: 0)
        try await runFrames(before: before, selection: range, frames: Array(repeating: Frame(text: "Meet Rohan today.\n\nMeet Rohaan today.Suffix"), count: 5)) { service, _, _ in
            XCTAssertEqual(service.detectedEdits.count, 1)
        }
        try await runFrames(before: before, selection: range, frames: Array(repeating: Frame(text: "Meet Rohaan today.\n\nMeet Rohan today.Suffix"), count: 5)) { service, _, _ in
            XCTAssertTrue(service.detectedEdits.isEmpty, "Editing the earlier identical sentence must not be attributed to our insertion")
        }
    }

    func testSentenceRewriteAndNumberEditAreDetectedButNeverSavedAsRules() async throws {
        for text in ["Please arrange another meeting.", "Meet Rohan on 15 October.", ""] {
            try await runFrames(frames: Array(repeating: Frame(text: text), count: 5)) { service, dictionary, _ in
                XCTAssertEqual(service.detectedEdits.count, 1)
                XCTAssertEqual(dictionary.correctionsCount, 0)
            }
        }
    }

    func testTransientUnreadabilityResetsStabilityAndFocusChangeDoesNotReadNewField() async throws {
        try await runFrames(frames: [Frame(text: "Meet Rohaan today."), Frame(text: nil)] + Array(repeating: Frame(text: "Meet Rohaan today."), count: 4)) { service, _, _ in
            XCTAssertEqual(service.detectedEdits.count, 1)
        }
        try await runFrames(frames: [Frame(text: "Meet Rohaan today."), Frame(text: "Other field", sameFocus: false)]) { service, _, _ in
            XCTAssertTrue(service.detectedEdits.isEmpty)
        }
    }

    func testQuickFocusExitReadsFinalOldFieldWithoutReturnOrWaiting() async throws {
        try await runFrames(frames: [Frame(text: "Meet Roha today."), Frame(text: "New field content", sameFocus: false, pinnedText: "Meet Rohaan today.")]) { service, _, _ in
            XCTAssertEqual(service.detectedEdits.count, 1)
            XCTAssertEqual(service.detectedEdits.first?.edited, "Meet Rohaan today.")
        }
        try await runFrames(frames: [Frame(text: "Meet Rohaan today."), Frame(text: "New field content", sameFocus: false, pinnedText: "Meet Rohan today.")]) { service, _, _ in
            XCTAssertTrue(service.detectedEdits.isEmpty)
        }
    }

    func testDisableAndDiscardDuringObservationDoNotRecapture() async throws {
        try await runFrames(frames: Array(repeating: Frame(text: "Meet Rohaan today."), count: 8), onFrame: { index, service in
            if index == 4 { service.clearDetectedEdits() }
        }) { service, _, _ in XCTAssertTrue(service.detectedEdits.isEmpty) }
        try await runFrames(frames: Array(repeating: Frame(text: "Meet Rohaan today."), count: 8), onFrame: { index, service in
            if index == 2 { service.stopDetection() }
        }) { service, _, _ in XCTAssertTrue(service.detectedEdits.isEmpty) }
    }

    func testSelectionInProgressAndLargeEditsAreNotStored() async throws {
        try await runFrames(frames: Array(repeating: Frame(text: "Meet Rohaan today.", selection: NSRange(location: 5, length: 6)), count: 5)) { service, _, _ in XCTAssertTrue(service.detectedEdits.isEmpty) }
        try await runFrames(frames: Array(repeating: Frame(text: String(repeating: "x", count: 2_001)), count: 5)) { service, _, _ in XCTAssertTrue(service.detectedEdits.isEmpty) }
    }

    func testUnicodeInsertionRangeAndUnchangedDocumentAnchors() {
        let element = AXUIElementCreateSystemWide()
        let before = TextInsertionService.FocusedTextObservation(element: element, value: "🙂 Prefix END", selectedText: nil, selectedRange: NSRange(location: 10, length: 0))
        let after = TextInsertionService.FocusedTextObservation(element: element, value: "🙂 Prefix RohanEND", selectedText: nil, selectedRange: nil)
        let baseline = TargetAppCorrectionLearningService.verifiedInsertionObservation(insertedText: "Rohan", before: before, after: after)
        XCTAssertNotNil(baseline)
        if let baseline {
            XCTAssertEqual(TargetAppCorrectionLearningService.editedPassage(insertedText: "Rohan", baseline: baseline, editedValue: "🙂 Prefix RohaanEND"), "Rohaan")
            XCTAssertNil(TargetAppCorrectionLearningService.editedPassage(insertedText: "Rohan", baseline: baseline, editedValue: "Changed RohaanEND"))
        }
    }
}
