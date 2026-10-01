import Testing
@testable import Foldera

@Suite struct TypingToSelect {
    @Test func aQuickBurstSpellsOutOneName() {
        var typing = TypeSelection()
        let names = ["apple", "readme", "report"]
        #expect(typing.match("r", at: 0, names: names, selected: nil) == 1)
        #expect(typing.match("e", at: 0.2, names: names, selected: 1) == 1)
        #expect(typing.match("p", at: 0.4, names: names, selected: 1) == 2)
    }

    @Test func repeatingOneLetterWalksThroughItsNames() {
        var typing = TypeSelection()
        let names = ["bar", "baz", "foo"]
        #expect(typing.match("b", at: 0, names: names, selected: nil) == 0)
        #expect(typing.match("B", at: 0.3, names: names, selected: 0) == 1)
        #expect(typing.match("b", at: 0.6, names: names, selected: 1) == 0)
    }

    @Test func aPauseStartsAgainAfterTheSelection() {
        var typing = TypeSelection()
        let names = ["bar", "baz", "foo"]
        #expect(typing.match("f", at: 0, names: names, selected: nil) == 2)
        #expect(typing.match("b", at: 0.5, names: names, selected: 2) == nil)
        #expect(typing.match("b", at: 2, names: names, selected: 2) == 0)
        typing.reset()
        #expect(typing.match("b", at: 2.1, names: names, selected: 0) == 1)
    }

    @Test func caseAndAccentsDontMatter() {
        var typing = TypeSelection()
        #expect(typing.match("z", at: 0, names: ["Zeta", "Žabljak"], selected: 0) == 1)
        typing.reset()
        #expect(typing.match("Ž", at: 0, names: ["mapa", "zvono"], selected: nil) == 1)
    }

    @Test func nothingToMatchSelectsNothing() {
        var typing = TypeSelection()
        #expect(typing.match("a", at: 0, names: [], selected: nil) == nil)
        #expect(typing.match("q", at: 5, names: ["a", "b"], selected: 7) == nil)
        // A selection that is no longer there counts as none.
        #expect(typing.match("b", at: 10, names: ["a", "b"], selected: 7) == 1)
    }
}
