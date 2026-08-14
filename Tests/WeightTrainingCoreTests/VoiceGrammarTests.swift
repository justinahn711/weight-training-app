import XCTest
@testable import WeightTrainingCore

final class SpokenNumberTests: XCTestCase {

    private func number(_ phrase: String) -> Double? {
        SpokenNumber.parse(phrase.split(separator: " ").map(String.init))
    }

    /// Lifters say weights the short way, and a recogniser transcribes exactly
    /// that. Getting this wrong makes every useful gym utterance fail.
    func testGymShorthandForWeights() {
        XCTAssertEqual(number("one eighty five"), 185)
        XCTAssertEqual(number("two twenty five"), 225)
        XCTAssertEqual(number("one thirty five"), 135)
        XCTAssertEqual(number("three fifteen"), 315)
        XCTAssertEqual(number("one fifteen"), 115)
    }

    func testPlainNumbers() {
        XCTAssertEqual(number("forty five"), 45)
        XCTAssertEqual(number("ninety"), 90)
        XCTAssertEqual(number("twelve"), 12)
        XCTAssertEqual(number("eight"), 8)
        XCTAssertEqual(number("185"), 185)
    }

    func testLongForm() {
        XCTAssertEqual(number("two hundred"), 200)
        XCTAssertEqual(number("two hundred and twenty five"), 225)
        XCTAssertEqual(number("one hundred thirty five"), 135)
    }

    func testHalves() {
        let words = { (phrase: String) in phrase.split(separator: " ").map(String.init) }
        XCTAssertEqual(SpokenNumber.parseWithHalf(words("eight and a half")), 8.5)
        XCTAssertEqual(SpokenNumber.parseWithHalf(words("eight point five")), 8.5)
        XCTAssertEqual(SpokenNumber.parseWithHalf(words("nine and a half")), 9.5)
        XCTAssertEqual(SpokenNumber.parseWithHalf(words("eight")), 8)
    }

    func testNonNumbersParseToNothing() {
        XCTAssertNil(number("left shoulder felt off"))
        XCTAssertNil(number(""))
    }
}

final class VoiceGrammarTests: XCTestCase {

    private func parse(_ phrase: String) -> VoiceParse? {
        VoiceGrammar.parse(phrase)
    }

    private func command(_ phrase: String) -> VoiceCommand? {
        VoiceGrammar.parse(phrase)?.command
    }

    // MARK: - The done-when: each grammar form parses

    /// The issue's headline example.
    func testAFullSetParses() {
        XCTAssertEqual(
            command("one eighty five for five at eight"),
            .logSet(load: Load(185), reps: 5, rpe: RPE(8))
        )
    }

    func testTheOtherWaysPeopleSayIt() {
        let expected = VoiceCommand.logSet(load: Load(225), reps: 5, rpe: RPE(8))
        XCTAssertEqual(command("two twenty five for five at eight"), expected)
        XCTAssertEqual(command("225 x 5 at 8"), expected)
        XCTAssertEqual(command("two twenty five times five rpe eight"), expected)
        XCTAssertEqual(command("225 by 5 @ 8"), expected)
    }

    func testHalfPointRPE() {
        XCTAssertEqual(
            command("one eighty five for five at eight and a half"),
            .logSet(load: Load(185), reps: 5, rpe: RPE(8.5))
        )
        XCTAssertEqual(
            command("185 for 5 at nine point five"),
            .logSet(load: Load(185), reps: 5, rpe: RPE(9.5))
        )
    }

    /// An RPE off the legal grid snaps rather than being discarded — the
    /// alternative is losing the whole utterance to one misheard syllable.
    func testAnOffGridRPESnaps() {
        XCTAssertEqual(
            command("185 for 5 at seven point eight"),
            .logSet(load: Load(185), reps: 5, rpe: RPE(8))
        )
    }

    // MARK: - Partial forms

    func testWeightAndRepsWithoutRPE() {
        XCTAssertEqual(command("one eighty five for five"),
                       .logSet(load: Load(185), reps: 5, rpe: nil))
    }

    /// "eight reps" says nothing about the weight, and mustn't claim to.
    func testRepsAlone() {
        XCTAssertEqual(command("eight reps"), .logSet(load: nil, reps: 8, rpe: nil))
        XCTAssertEqual(command("twelve reps"), .logSet(load: nil, reps: 12, rpe: nil))
    }

    func testAdjustments() {
        XCTAssertEqual(command("add five"), .adjustLoad(by: Load(5)))
        XCTAssertEqual(command("add ten"), .adjustLoad(by: Load(10)))
        XCTAssertEqual(command("drop ten"), .adjustLoad(by: Load(-10)))
        XCTAssertEqual(command("down five"), .adjustLoad(by: Load(-5)))
        XCTAssertEqual(command("up 25"), .adjustLoad(by: Load(25)))
    }

    func testSameAndNext() {
        XCTAssertEqual(command("same"), .repeatLast)
        XCTAssertEqual(command("again"), .repeatLast)
        XCTAssertEqual(command("next"), .nextExercise)
        XCTAssertEqual(command("skip"), .nextExercise)
    }

    func testTimers() {
        XCTAssertEqual(command("two minute timer"), .startTimer(seconds: 120))
        XCTAssertEqual(command("ninety second timer"), .startTimer(seconds: 90))
        XCTAssertEqual(command("three minutes"), .startTimer(seconds: 180))
    }

    /// A note is the one place free text belongs, so it's kept verbatim.
    func testNotes() {
        XCTAssertEqual(command("note left shoulder felt off"),
                       .note("left shoulder felt off"))
        XCTAssertEqual(command("note, bench felt heavy today"),
                       .note("bench felt heavy today"))
    }

    /// "note" must win over everything else, or "note, add five to the bar"
    /// silently changes the weight.
    func testANoteContainingACommandStaysANote() {
        XCTAssertEqual(command("note add five felt easy"),
                       .note("add five felt easy"))
    }

    // MARK: - Refusing to guess

    /// A closed grammar's job is to fail on noise rather than log something.
    func testNoiseParsesToNothing() {
        XCTAssertNil(parse("clang"))
        XCTAssertNil(parse("what do you think about"))
        XCTAssertNil(parse(""))
        XCTAssertNil(parse("   "))
    }

    /// A bare number is genuinely ambiguous — weight, reps, or a misheard word
    /// — so it's shown but never committed on its own (#22).
    func testABareNumberIsNotConfident() throws {
        let parsed = try XCTUnwrap(parse("185"))
        XCTAssertEqual(parsed.command, .logSet(load: Load(185), reps: nil, rpe: nil))
        XCTAssertFalse(parsed.isConfident)
    }

    func testAFullUtteranceIsConfident() throws {
        XCTAssertTrue(try XCTUnwrap(parse("185 for 5 at 8")).isConfident)
        XCTAssertTrue(try XCTUnwrap(parse("add five")).isConfident)
        XCTAssertTrue(try XCTUnwrap(parse("same")).isConfident)
    }

    // MARK: - Gym-noise samples

    /// Transcripts of the kind a recogniser actually returns mid-session:
    /// punctuation, digits mixed with words, trailing filler.
    func testMessyRealTranscripts() {
        XCTAssertEqual(command("One eighty-five for five at eight."),
                       .logSet(load: Load(185), reps: 5, rpe: RPE(8)))
        XCTAssertEqual(command("225 for 5, at 8"),
                       .logSet(load: Load(225), reps: 5, rpe: RPE(8)))
        XCTAssertEqual(command("ADD FIVE"), .adjustLoad(by: Load(5)))
        XCTAssertEqual(command("Next."), .nextExercise)
    }

    /// The failure that matters: a garbled weight must not silently become a
    /// plausible one. Parsing is allowed to produce 1080; #22's snapping is
    /// what refuses to commit it.
    func testAGarbledWeightParsesLiterallyRatherThanBeingInvented() throws {
        let parsed = try XCTUnwrap(parse("one thousand eighty for five"))
        guard case .logSet(let load, _, _) = parsed.command else {
            return XCTFail("expected a set")
        }
        XCTAssertNotNil(load)
        XCTAssertNotEqual(load, Load(180), "the parser must not quietly correct it")
    }
}
