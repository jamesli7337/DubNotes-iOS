import XCTest
@testable import DubNotes

final class NotebookCapTests: ScratchTestCase {
    private func makeStore(plan: Plan, in folder: String = "a") -> LibraryStore {
        let s = LibraryStore(files: FileStore(root: scratch.appendingPathComponent(folder)))
        s.planProvider = { plan }
        return s
    }

    private func fill(_ s: LibraryStore, _ n: Int) throws {
        for i in 0..<n {
            _ = try s.createNotebook(name: "N\(i)", folderId: nil, paper: .default, kind: i % 2 == 0 ? .pages : .board)
        }
    }

    func testAllowsCreationRule() {
        XCTAssertTrue(NotebookCap.allowsCreation(plan: .free, existing: 7))
        XCTAssertFalse(NotebookCap.allowsCreation(plan: .free, existing: 8))
        XCTAssertFalse(NotebookCap.allowsCreation(plan: .free, existing: 20))
        XCTAssertTrue(NotebookCap.allowsCreation(plan: .pro, existing: 500))
    }

    func testFreeStoreBlocksTheNinthNotebookOfEitherKind() throws {
        let s = makeStore(plan: .free)
        try fill(s, 8) // pages and boards both count
        XCTAssertThrowsError(try s.createNotebook(name: "Nine", folderId: nil, paper: .default, kind: .pages)) {
            XCTAssertEqual($0 as? LibraryError, .freePlanLimit)
        }
        XCTAssertThrowsError(try s.createNotebook(name: "Nine", folderId: nil, paper: .default, kind: .board))
        XCTAssertEqual(s.notebooks.count, 8)
    }

    func testFoldersAndDividersDoNotCount() throws {
        let s = makeStore(plan: .free)
        try fill(s, 7)
        for i in 0..<5 { s.createFolder(name: "F\(i)", parentId: nil) }
        s.createDivider(folderId: nil, label: "D", aboveNotebookId: s.notebooks[0].id)
        XCTAssertNoThrow(try s.createNotebook(name: "Eight", folderId: nil, paper: .default, kind: .pages))
    }

    func testProIsUnlimited() throws {
        let s = makeStore(plan: .pro)
        try fill(s, 12)
        XCTAssertEqual(s.notebooks.count, 12)
    }

    func testDeletingBelowTheCapReopensCreation() throws {
        let s = makeStore(plan: .free)
        try fill(s, 8)
        s.delete(s.notebooks[0].id)
        XCTAssertNoThrow(try s.createNotebook(name: "Again", folderId: nil, paper: .default, kind: .pages))
    }

    func testBackupImportIsNeverBlockedAndKeepsEverything() throws {
        let source = makeStore(plan: .pro, in: "source")
        try fill(source, 3)
        let backup = try source.exportBackup()

        let s = makeStore(plan: .free, in: "dest")
        try fill(s, 8)
        let summary = try s.importBackup(backup)
        XCTAssertEqual(summary.notebooks, 3)
        XCTAssertEqual(s.notebooks.count, 11) // over the cap, nothing removed
        XCTAssertThrowsError(try s.createNotebook(name: "More", folderId: nil, paper: .default, kind: .pages))
        s.delete(s.notebooks[0].id) // deleting still works over the cap
        XCTAssertEqual(s.notebooks.count, 10)
    }
}

final class AITrialTests: XCTestCase {
    func testStartsWithFullTrialAndCountsDown() {
        let c = AITrialCounter(storage: InMemoryAITrialStorage())
        XCTAssertEqual(c.remaining, 2)
        c.consume()
        XCTAssertEqual(c.remaining, 1)
        c.consume()
        XCTAssertEqual(c.remaining, 0)
        c.consume() // never below zero
        XCTAssertEqual(c.remaining, 0)
    }

    func testCountPersistsInStorageAndNeverResets() {
        let storage = InMemoryAITrialStorage()
        AITrialCounter(storage: storage).consume()
        let reopened = AITrialCounter(storage: storage)
        XCTAssertEqual(reopened.remaining, 1)
        XCTAssertEqual(AITrialCounter(storage: InMemoryAITrialStorage(used: 99)).remaining, 0)
    }

    @MainActor
    private func gate(plan: Plan, used: Int = 0) -> (AISendGate, MockAccountService) {
        let counter = AITrialCounter(storage: InMemoryAITrialStorage(used: used))
        let account = MockAccountService(plan: plan, aiTrial: counter, notebookCount: { 0 })
        return (AISendGate(account: account), account)
    }

    @MainActor
    func testFreeWithQuestionsLeftMayStartAndIsNotCountedUntilSaved() async {
        let (g, account) = gate(plan: .free)
        let decision = await g.decide()
        XCTAssertEqual(decision, .allowed)
        XCTAssertEqual(account.aiTrialRemaining, 2) // a send that never saved a reply costs nothing
        g.recordSuccessfulReply()
        XCTAssertEqual(account.aiTrialRemaining, 1)
    }

    @MainActor
    func testFreeWithNoneLeftIsBlocked() async {
        let (g, _) = gate(plan: .free, used: 2)
        let decision = await g.decide()
        XCTAssertEqual(decision, .trialExhausted)
    }

    @MainActor
    func testProIsNeverBlockedOrCounted() async {
        let (g, account) = gate(plan: .pro, used: 2)
        let decision = await g.decide()
        XCTAssertEqual(decision, .allowed)
        g.recordSuccessfulReply()
        XCTAssertEqual(account.aiTrialRemaining, 0)
    }

    @MainActor
    func testServerHookCanDeny() async {
        struct Deny: AIServerCheck {
            func decide(plan: Plan) async -> AISendGate.Decision { .trialExhausted }
        }
        let account = MockAccountService(plan: .pro, notebookCount: { 0 })
        let decision = await AISendGate(account: account, serverCheck: Deny()).decide()
        XCTAssertEqual(decision, .trialExhausted)
    }
}
