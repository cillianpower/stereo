import Testing
import TunerModel

@Suite struct SearchIndexDiffTests {
    @Test func findsAddedChangedAndRemovedItems() {
        let diff = SearchIndexDiff(old: ["same": "a", "changed": "b", "gone": "c"],
                                   new: ["same": "a", "changed": "B", "added": "d"])
        #expect(diff.upserted == ["changed", "added"])
        #expect(diff.removed == ["gone"])
    }

    @Test func identicalIndexesNeedNoWork() {
        let diff = SearchIndexDiff(old: ["a": "1"], new: ["a": "1"])
        #expect(diff.upserted.isEmpty)
        #expect(diff.removed.isEmpty)
    }
}
