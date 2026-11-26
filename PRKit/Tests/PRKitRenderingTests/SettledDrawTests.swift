import Testing

/// `SettledDraw`'s rules, with draws that are made up: each is the picture it gives and how long it takes. A renderer
/// that gives up takes 2 seconds and gives an empty or unfinished picture.
struct SettledDrawTests {
    private static let quick: Duration = .milliseconds(5)
    private static let slow: Duration = .seconds(2)

    /// Draws `draws` in order (the last one for ever) on a clock that only they move. Returns the picture, or the
    /// error's words, and how many draws it took.
    private func settle(_ draws: [(picture: String, takes: Duration)]) -> (picture: String?, error: String?, drawn: Int) {
        var time = ContinuousClock.now
        var drawn = 0
        do {
            let picture = try SettledDraw.picture(now: { time }, isEmpty: \.isEmpty, draw: { () -> String in
                let next = draws[min(drawn, draws.count - 1)]
                drawn += 1
                time = time.advanced(by: next.takes)
                return next.picture
            })
            return (picture, nil, drawn)
        } catch {
            return (nil, "\(error)", drawn)
        }
    }

    @Test func aViewThatDrawsAtOnceIsDrawnTwice() {
        let result = settle([("row", Self.quick)])
        #expect(result.picture == "row")
        #expect(result.drawn == 2)
    }

    /// Run 45746139535: the pipeline took 12.7 seconds, six draws gave up, and six was all the helper had.
    @Test func aRendererThatGivesUpSevenTimesIsWaitedFor() {
        let result = settle(Array(repeating: ("", Self.slow), count: 7) + [("row", Self.quick)])
        #expect(result.picture == "row")
        #expect(result.drawn == 9)
    }

    @Test func whatTheRendererGaveUpOnIsNeverThePicture() {
        let unfinished = ("half a row", Self.slow)
        #expect(settle([unfinished, unfinished, unfinished, ("row", Self.quick)]).picture == "row")
        // Nor is it compared: a quick draw that matches an unfinished one is drawn again.
        let result = settle([unfinished, ("half a row", Self.quick), ("row", Self.quick)])
        #expect(result.picture == "row")
        #expect(result.drawn == 4)
    }

    @Test func aRendererThatIsNeverReadyFailsWhenPatienceRunsOut() {
        let result = settle([("", Self.slow)])
        #expect(result.picture == nil)
        #expect(result.error?.contains("the renderer gave up on 90 draws") == true, "\(result.error ?? "")")
    }

    @Test func aViewThatNeverDrawsTheSameTwiceFails() {
        let result = settle((1 ... 9).map { ("frame \($0)", Self.quick) })
        #expect(result.picture == nil)
        #expect(result.drawn == SettledDraw.pictures)
        #expect(result.error?.contains("no two in a row were the same") == true, "\(result.error ?? "")")
    }

    @Test func aViewThatDrawsNothingFails() {
        let result = settle([("", Self.quick)])
        #expect(result.picture == nil)
        #expect(result.drawn == SettledDraw.pictures)
    }
}
