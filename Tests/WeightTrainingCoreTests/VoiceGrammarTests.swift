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
        XCTAssertEqual(SpokenNumber.parse(words("eight and a half")), 8.5)
        XCTAssertEqual(SpokenNumber.parse(words("eight point five")), 8.5)
        XCTAssertEqual(SpokenNumber.parse(words("nine and a half")), 9.5)
        XCTAssertEqual(SpokenNumber.parse(words("eight")), 8)
    }

    func testNonNumbersParseToNothing() {
        XCTAssertNil(number("left shoulder felt off"))
        XCTAssertNil(number(""))
    }

    // MARK: - Number words stop at a complete number (#267)

    /// A number word after a load that is already complete in the ones place
    /// is a second number, exactly as #80 made a second *numeral*. The rep
    /// marker is the syllable a loud gym eats, and folding the rep count into
    /// the weight produced a buildable 190 that auto-committed.
    func testANumberWordAfterACompleteLoadIsNotAddedToIt() {
        XCTAssertEqual(number("one eighty five five"), 185, "used to be 190")
        XCTAssertEqual(number("two twenty five five"), 225, "used to be 230")
        XCTAssertEqual(number("one thirty five eight"), 135, "used to be 143")
        XCTAssertEqual(number("forty five five"), 45)
        XCTAssertEqual(number("185 five"), 185, "a word after a numeral too")
    }

    /// The shorthand the place-value rule has to leave alone.
    func testWantedShorthandStillCombines() {
        XCTAssertEqual(number("one eighty five"), 185)
        XCTAssertEqual(number("two twenty five"), 225)
        XCTAssertEqual(number("three fifteen"), 315)
        XCTAssertEqual(number("a hundred and five"), 105)
        XCTAssertEqual(number("one hundred eighty five"), 185)
        XCTAssertEqual(number("two hundred and twenty five"), 225)
        XCTAssertEqual(number("twenty five"), 25)
        XCTAssertEqual(number("forty five"), 45)
        XCTAssertEqual(number("one thousand eighty"), 1_080)
    }

    /// "oh" is the spoken zero of the hundreds shorthand. It used to sum as
    /// 1 + 0 + 5 = 6.
    func testOhAsTheHundredsShorthandZero() {
        XCTAssertEqual(number("one oh five"), 105)
        XCTAssertEqual(number("two oh five"), 205)
    }

    // MARK: - Decimals (#264)

    /// A decimal numeral is one number, not two tokens with the fraction lost.
    func testDecimalsAndSpokenPointsAreOneNumber() {
        XCTAssertEqual(number("62.5"), 62.5)
        XCTAssertEqual(number("sixty two point five"), 62.5)
        XCTAssertEqual(number("two and a half"), 2.5)
        XCTAssertEqual(number("eight and a half"), 8.5)
        XCTAssertEqual(number("eight point five"), 8.5)
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

    // MARK: - Real phrasings that used to fail (#80)

    /// Reported from the gym: the rep count came through and the weight and
    /// RPE didn't. A word before the number was fatal — the parser gave up at
    /// the first token that wasn't a numeral, so "log" ate the weight, while a
    /// trailing "pounds" had always been harmless.
    func testAWordBeforeTheWeightNoLongerEatsIt() throws {
        let parsed = try XCTUnwrap(VoiceGrammar.parse("log 185 for 8 at 8"))
        guard case .logSet(let load, let reps, let rpe) = parsed.command else {
            return XCTFail("expected a set")
        }
        XCTAssertEqual(load, Load(185))
        XCTAssertEqual(reps, 8)
        XCTAssertEqual(rpe, RPE(8))
    }

    /// A weight that lands where an RPE belongs is refused rather than dragged
    /// onto the scale. It used to arrive as a confident RPE 10.
    func testAWeightInTheRPESlotIsRefused() throws {
        let parsed = try XCTUnwrap(VoiceGrammar.parse("8 reps at 185"))
        guard case .logSet(_, let reps, let rpe) = parsed.command else {
            return XCTFail("expected a set")
        }
        XCTAssertEqual(reps, 8)
        XCTAssertNil(rpe, "185 is not an RPE, and inventing one is worse than missing it")
    }

    /// A misheard RPE still snaps: "twelve" is a ten that went astray, and the
    /// grid exists for exactly that.
    func testANearMissRPEStillSnaps() throws {
        let parsed = try XCTUnwrap(VoiceGrammar.parse("185 for 5 at twelve"))
        guard case .logSet(_, _, let rpe) = parsed.command else {
            return XCTFail("expected a set")
        }
        XCTAssertEqual(rpe, RPE(10))
    }

    /// A weight in the rep slot is refused too — 185 reps is not a set.
    func testAWeightInTheRepSlotIsRefused() throws {
        let parsed = VoiceGrammar.parse("185 pounds 8 reps")
        if case .logSet(_, let reps, _)? = parsed?.command {
            XCTAssertNotEqual(reps, 185, "185 reps is a misparse, not a set")
        }
    }

    /// Separate numbers stay separate: three of them are not one big one.
    func testLooseNumbersDoNotMergeIntoOne() throws {
        let parsed = try XCTUnwrap(VoiceGrammar.parse("185 8 8"))
        guard case .logSet(let load, _, _) = parsed.command else {
            return XCTFail("expected a set")
        }
        XCTAssertEqual(load, Load(185), "used to add up to 201")
    }

    /// The hundreds shorthand still works, which is the reason digits could
    /// merge in the first place.
    func testHundredsShorthandSurvives() throws {
        for (phrase, expected) in [("one 85 for 8", 185.0), ("two 25 for 5", 225.0)] {
            let parsed = try XCTUnwrap(VoiceGrammar.parse(phrase))
            guard case .logSet(let load, _, _) = parsed.command else {
                return XCTFail("expected a set")
            }
            XCTAssertEqual(load, Load(expected), phrase)
        }
    }
}

/// Decimals survive tokenizing (#264).
///
/// iOS dictation writes "eight and a half" as `8.5`, and the tokenizer split
/// on the dot: `8` and `5`, the `5` discarded. When the truncated value was
/// still valid nothing refused or snapped it, so RPE 8.5 auto-committed as 8
/// and a 32.5 kg stack set as 32.
final class VoiceDecimalTests: XCTestCase {

    private func set(_ phrase: String, in unit: MassUnit = .pounds)
        -> (load: Load?, reps: Int?, rpe: RPE?)? {
        guard case .logSet(let load, let reps, let rpe)? =
                VoiceGrammar.parse(phrase, in: unit)?.command else { return nil }
        return (load, reps, rpe)
    }

    func testADecimalRPEIsKept() throws {
        for (phrase, expected) in [
            ("185 for 5 at 8.5", 8.5), ("185 for 5 at 7.5", 7.5),
            ("185 for 5 at 9.5", 9.5), ("185 for 5 at 8 1/2", 8.5),
            ("185 for 5 at 8½", 8.5), ("185 x 5 @ 8.5", 8.5),
        ] {
            let heard = try XCTUnwrap(set(phrase), phrase)
            XCTAssertEqual(heard.rpe, RPE(expected), phrase)
            XCTAssertEqual(heard.load, Load(185), phrase)
            XCTAssertEqual(heard.reps, 5, phrase)
        }
    }

    func testADecimalRPEInAKilogramGym() throws {
        let heard = try XCTUnwrap(set("60 for 5 at 8.5", in: .kilograms))
        XCTAssertEqual(heard.rpe, RPE(8.5))
        XCTAssertEqual(heard.load?.value(in: .kilograms) ?? 0, 60, accuracy: 0.0001)
    }

    /// The load is heard exactly; snapping is the snapper's job, not the
    /// tokenizer's.
    func testADecimalLoadIsHeardExactly() throws {
        for (phrase, kilograms) in [
            ("62.5 for 5", 62.5), ("62.5 kilos for 5", 62.5), ("62.5kg for 5", 62.5),
            ("32.5 for 10", 32.5), ("27.5 for 10", 27.5), ("102.5 for 3", 102.5),
            ("sixty two point five for 5", 62.5),
            ("sixty two point five kilos for 5", 62.5),
        ] {
            let heard = try XCTUnwrap(set(phrase, in: .kilograms), phrase)
            XCTAssertEqual(heard.load?.value(in: .kilograms) ?? 0, kilograms,
                           accuracy: 0.0001, phrase)
        }
    }

    func testADecimalAdjustment() throws {
        for phrase in ["add 2.5", "add two and a half", "up 2.5"] {
            guard case .adjustLoad(let by)? = VoiceGrammar.parse(phrase)?.command else {
                return XCTFail("expected an adjustment from \(phrase)")
            }
            XCTAssertEqual(by.pounds, 2.5, accuracy: 0.0001, phrase)
        }
        guard case .adjustLoad(let by)? = VoiceGrammar.parse("drop 2.5 kilos")?.command else {
            return XCTFail("expected an adjustment")
        }
        XCTAssertEqual(by.value(in: .kilograms), -2.5, accuracy: 0.0001)
    }

    /// The period that ends a sentence is still punctuation, not a decimal.
    func testASentenceEndingPeriodIsStillPunctuation() throws {
        let heard = try XCTUnwrap(set("185 for 5."))
        XCTAssertEqual(heard.load, Load(185))
        XCTAssertEqual(heard.reps, 5)
        let full = try XCTUnwrap(set("185 for 5 at 8.5."))
        XCTAssertEqual(full.rpe, RPE(8.5))
    }

    /// A half rep is not a rep count, and truncating it to 5 would invent one.
    func testAHalfRepIsNotTruncated() throws {
        let heard = try XCTUnwrap(set("185 for 5.5"))
        XCTAssertNotEqual(heard.reps, 5)
    }
}

/// Hearing a unit that was said out loud, and defaulting to the gym's (#67, #21).
final class VoiceUnitTests: XCTestCase {

    func testAnUnqualifiedNumberMeansTheGymsUnit() throws {
        let parse = try XCTUnwrap(VoiceGrammar.parse("sixty for eight", in: .kilograms))
        guard case .logSet(let load, let reps, _) = parse.command else {
            return XCTFail("expected a set")
        }
        XCTAssertEqual(load?.value(in: .kilograms) ?? 0, 60, accuracy: 0.0001)
        XCTAssertEqual(reps, 8)
    }

    /// The issue's own example.
    func testSixtyKilos() throws {
        let parse = try XCTUnwrap(VoiceGrammar.parse("sixty kilos for eight"))
        guard case .logSet(let load, let reps, _) = parse.command else {
            return XCTFail("expected a set")
        }
        XCTAssertEqual(load?.value(in: .kilograms) ?? 0, 60, accuracy: 0.0001)
        XCTAssertEqual(reps, 8)
    }

    /// Both worlds are always understood, whichever the gym is set to —
    /// refusing "two twenty five pounds" in a metric gym would log 225 kg.
    func testASpokenUnitOverridesTheGym() throws {
        let parse = try XCTUnwrap(
            VoiceGrammar.parse("two twenty five pounds for five", in: .kilograms)
        )
        guard case .logSet(let load, _, _) = parse.command else {
            return XCTFail("expected a set")
        }
        XCTAssertEqual(load?.pounds ?? 0, 225, accuracy: 0.0001)
    }

    /// Dictation writes it stuck together about as often as not.
    func testAUnitStuckToTheNumber() throws {
        let parse = try XCTUnwrap(VoiceGrammar.parse("60kg for 8"))
        guard case .logSet(let load, let reps, _) = parse.command else {
            return XCTFail("expected a set")
        }
        XCTAssertEqual(load?.value(in: .kilograms) ?? 0, 60, accuracy: 0.0001)
        XCTAssertEqual(reps, 8)
    }

    func testAnAdjustmentIsHeardInTheUnitSaid() throws {
        let parse = try XCTUnwrap(VoiceGrammar.parse("add five kilos", in: .pounds))
        guard case .adjustLoad(let by) = parse.command else {
            return XCTFail("expected an adjustment")
        }
        XCTAssertEqual(by.value(in: .kilograms), 5, accuracy: 0.0001)
    }

    func testAnUnqualifiedAdjustmentUsesTheGym() throws {
        let parse = try XCTUnwrap(VoiceGrammar.parse("add five", in: .kilograms))
        guard case .adjustLoad(let by) = parse.command else {
            return XCTFail("expected an adjustment")
        }
        XCTAssertEqual(by.value(in: .kilograms), 5, accuracy: 0.0001)
    }

    /// Naming the unit is grammar, so it lifts the utterance out of the
    /// shown-but-never-committed case a bare number falls into (#22).
    func testNamingTheUnitMakesABareNumberConfident() throws {
        XCTAssertFalse(try XCTUnwrap(VoiceGrammar.parse("sixty")).isConfident)
        XCTAssertTrue(try XCTUnwrap(VoiceGrammar.parse("sixty kilos")).isConfident)
    }

    /// "rep" and "lb" must not collide: reps still win.
    func testRepsStillParseWithUnitsInTheVocabulary() throws {
        let parse = try XCTUnwrap(VoiceGrammar.parse("185 for 5 reps"))
        guard case .logSet(let load, let reps, _) = parse.command else {
            return XCTFail("expected a set")
        }
        XCTAssertEqual(load?.pounds ?? 0, 185, accuracy: 0.0001)
        XCTAssertEqual(reps, 5)
    }
}
