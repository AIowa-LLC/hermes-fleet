import XCTest
import FleetUI
import FleetCore

/// Dogfood finding 2 (chat-list polish) — a session preview is stored verbatim
/// by the gateway, so it can carry the client's own attachment/control markup
/// and the user's machine topology. The chat list derives a HUMAN-READABLE
/// display line from that string.
///
/// Contract under test, stated as behavior (never as an implementation):
/// - ordinary text passes through untouched;
/// - a collapsed large paste renders its counters, never its file path;
/// - lower-case `@file:` / `@folder:` control refs render the referenced
///   name, and the text that follows them survives;
/// - `@url:` / `@diff` / `@File:` are NOT attachment markup (verbatim);
/// - internal Hermes attachment/paste paths never reach the screen, quoted,
///   absolute, home-relative, or relative (`desktop-attachments/`);
/// - malformed / empty markup is neutralised without a crash and without
///   leaking the raw vocabulary;
/// - several refs in one preview all render;
/// - derivation is PRESENTATION-ONLY: `SessionSummary` is never mutated.
final class SessionPreviewTextTests: XCTestCase {

    // MARK: - Collapsed large paste (control markup)

    func testPastedContentPlaceholderRendersCountersNotTheFilePath() {
        let raw = "[Pasted text #1: 120 lines → /home/dev/.hermes/pastes/paste_1_091500.txt]"
        let text = SessionPreviewText.humanReadable(raw)
        XCTAssertEqual(text, "Pasted text #1 · 120 lines")
        XCTAssertFalse(text.contains("pastes"), "the paste file path must never render")
        XCTAssertFalse(text.contains(".hermes"), "no internal Hermes path may render")
        XCTAssertFalse(text.contains("/home/dev"), "no absolute path may render")
    }

    func testPastedContentPlaceholderHandlesSingularLineCount() {
        XCTAssertEqual(
            SessionPreviewText.humanReadable("[Pasted text #7: 1 line → /root/.hermes/pastes/paste_7.txt]"),
            "Pasted text #7 · 1 line")
    }

    func testUnterminatedPastePlaceholderStillHidesItsPath() {
        let text = SessionPreviewText.humanReadable(
            "[Pasted text #3: 40 lines → /root/.hermes/pastes/paste_3.txt")
        XCTAssertFalse(text.contains("pastes"), "an unterminated placeholder must not leak its path")
        XCTAssertFalse(text.contains("/root/"), "no absolute path may render")
        XCTAssertTrue(text.contains("40 lines"), "the paste counter must survive")
    }

    // MARK: - Normal text

    func testNormalTextPassesThroughUnchanged() {
        let raw = "Discussing the reconnect/replay design."
        XCTAssertEqual(SessionPreviewText.humanReadable(raw), raw)
    }

    func testUnknownOrUpperCasedDirectivesArePreserved() {
        // `@url:` / `@diff` are not attachment markup, and the control
        // vocabulary is lower-case: an upper-cased `@File:` is ordinary text.
        let raw = "see @url:https://example.com and @diff and @File:Notes.md"
        XCTAssertEqual(SessionPreviewText.humanReadable(raw), raw)
    }

    // MARK: - Attachment reference plus following text

    func testAttachmentReferenceRendersNameAndKeepsFollowingText() {
        XCTAssertEqual(
            SessionPreviewText.humanReadable("review @file:attachments/notes.md before merging"),
            "review notes.md before merging")
    }

    func testFolderReferenceAndQuotedWindowsPathRenderTheirName() {
        XCTAssertEqual(
            SessionPreviewText.humanReadable("look in @folder:Packages/FleetUI/ now"),
            "look in FleetUI now")
        XCTAssertEqual(
            SessionPreviewText.humanReadable("@file:`C:\\Users\\alice\\Documents\\report.txt` please"),
            "report.txt please")
    }

    /// The physical-device form: the marker is followed by a space and a
    /// backtick-quoted relative Hermes path containing spaces.
    func testQuotedRelativeHermesAttachmentIsHumanReadable() {
        let raw = "@file: `.hermes/attachments/Pasted content (12.3 KB)` ..."
        let text = SessionPreviewText.humanReadable(raw)
        XCTAssertEqual(text, "Pasted content (12.3 KB) ...")
        XCTAssertFalse(text.contains("@file:"), "the control vocabulary must never render")
        XCTAssertFalse(text.contains(".hermes/attachments"), "no internal path may render")
    }

    /// The same form WITHOUT quote delimiters — the gateway may omit them and
    /// the internal relative path must still never reach the chat list.
    func testUnquotedRelativeHermesAttachmentIsHumanReadable() {
        let raw = "@file: .hermes/attachments/Pasted content (12.3 KB) ..."
        let text = SessionPreviewText.humanReadable(raw)
        XCTAssertEqual(text, "Pasted content (12.3 KB) ...")
        XCTAssertFalse(text.contains("@file:"), "the control vocabulary must never render")
        XCTAssertFalse(text.contains(".hermes/attachments"), "no internal path may render")
    }

    /// Whitespace tolerance: the marker may be followed by tabs or repeated
    /// spaces before the value.
    func testOptionalWhitespaceAfterMarkerIsTolerated() {
        XCTAssertEqual(
            SessionPreviewText.humanReadable("review @file:   notes.md now"),
            "review notes.md now")
    }

    // MARK: - Malformed / unknown refs

    func testEmptyReferenceIsDroppedWithoutLeakingMarkup() {
        let text = SessionPreviewText.humanReadable("broken ref @file:")
        XCTAssertEqual(text, "broken ref")
        XCTAssertFalse(text.contains("@file:"), "the raw ref vocabulary must never render")
    }

    func testPreviewThatIsOnlyMarkupRendersEmpty() {
        XCTAssertEqual(SessionPreviewText.humanReadable("@file:"), "")
    }

    func testMalformedReferenceMidSentenceKeepsTheSentenceReadable() {
        let text = SessionPreviewText.humanReadable("broken ref @file: here")
        XCTAssertEqual(text, "broken ref here")
        XCTAssertFalse(text.contains("@file:"))
    }

    // MARK: - Multiple references

    func testMultipleReferencesAllRender() {
        XCTAssertEqual(
            SessionPreviewText.humanReadable("compare @file:a/one.txt with @file:b/two.txt"),
            "compare one.txt with two.txt")
        XCTAssertEqual(
            SessionPreviewText.humanReadable(
                "[Pasted text #1: 5 lines → /root/.hermes/pastes/p1.txt] then @file:notes.md"),
            "Pasted text #1 · 5 lines then notes.md")
    }

    // MARK: - Bare internal paths (no marker)

    func testBareInternalAttachmentPathRendersOnlyItsName() {
        XCTAssertEqual(
            SessionPreviewText.humanReadable("staged /root/.hermes/attachments/photo.png for you"),
            "staged photo.png for you")
    }

    func testBareBacktickQuotedInternalAttachmentPathRendersOnlyItsName() {
        let raw = "staged `~/.hermes/attachments/secret.png` for review"
        let text = SessionPreviewText.humanReadable(raw)
        XCTAssertFalse(text.contains("attachments"), "no internal path may render")
        XCTAssertFalse(text.contains(".hermes"), "no internal Hermes path may render")
        XCTAssertFalse(text.contains("~"), "no home-relative path may render")
        XCTAssertTrue(text.contains("secret.png"), "the referenced name must survive")
    }

    func testRelativeDesktopAttachmentsPathRendersOnlyItsName() {
        let text = SessionPreviewText.humanReadable("attached desktop-attachments/report.pdf for you")
        XCTAssertEqual(text, "attached report.pdf for you")
        XCTAssertFalse(text.contains("desktop-attachments"), "no internal marker may render")
    }

    // MARK: - Fail-safe edges

    func testEmptyInputRendersEmpty() {
        XCTAssertEqual(SessionPreviewText.humanReadable(""), "")
    }

    func testLoneAtSignAndPlainPunctuationArePreserved() {
        XCTAssertEqual(SessionPreviewText.humanReadable("email me @ noon"), "email me @ noon")
    }

    // MARK: - Presentation-only

    func testDerivationNeverMutatesTheStoredSummary() {
        let raw = "@file:attachments/notes.md"
        let summary = SessionSummary(id: "s1", title: "Notes", preview: raw)
        _ = SessionPreviewText.humanReadable(summary.preview)
        XCTAssertEqual(summary.preview, raw, "the stored payload must stay untouched")
    }
}