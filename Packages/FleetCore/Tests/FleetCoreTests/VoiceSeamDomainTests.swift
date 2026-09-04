import XCTest
@testable import FleetCore

/// R10-T4 — VoiceTranscript / VoiceAuthorization / VoiceError domain tests.
final class VoiceSeamDomainTests: XCTestCase {

    func testTranscriptCarriesTextAndFinality() {
        let final = VoiceTranscript(text: "hello fleet", isFinal: true)
        XCTAssertEqual(final.text, "hello fleet")
        XCTAssertTrue(final.isFinal)

        let partial = VoiceTranscript(text: "hello fle", isFinal: false)
        XCTAssertFalse(partial.isFinal)
        XCTAssertNotEqual(final, partial)
    }

    func testAuthorizationStatesDistinct() {
        let all: Set<VoiceAuthorization> = [.undetermined, .authorized, .denied]
        XCTAssertEqual(all.count, 3)
    }

    func testErrorDescriptionsNonSecret() {
        XCTAssertTrue(VoiceError.recognizerUnavailable.description.contains("unavailable"))
        XCTAssertTrue(VoiceError.alreadyListening.description.contains("listening"))
        XCTAssertTrue(VoiceError.captureFailed("mic busy").description.contains("mic busy"))
        XCTAssertTrue(VoiceError.unsupported.description.contains("not available"))
        // Equality (typed errors, no string matching at call sites).
        XCTAssertEqual(VoiceError.captureFailed("a"), VoiceError.captureFailed("a"))
        XCTAssertNotEqual(VoiceError.unsupported, VoiceError.recognizerUnavailable)
    }

    /// The fail-closed default: every surface throws/undetermined — voice is
    /// never silently faked when no engine is wired.
    func testUnsupportedTranscriberFailsClosed() async {
        let seam = UnsupportedVoiceTranscriber()
        let await1 = await seam.authorizationStatus()
        XCTAssertEqual(await1, .undetermined)
        let await2 = await seam.requestAuthorization()
        XCTAssertEqual(await2, .undetermined)
        do {
            _ = try await seam.transcribe()
            XCTFail("transcribe should throw unsupported")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .unsupported)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
        do {
            try await seam.speak(text: "hi")
            XCTFail("speak should throw unsupported")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .unsupported)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
        XCTAssertFalse(seam.isSpeaking)
        await seam.stopSpeaking() // no-op, must not crash
        await seam.stopTranscribing() // no-op, must not crash
    }
}
