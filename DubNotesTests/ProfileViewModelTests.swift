import XCTest
@testable import DubNotes

@MainActor
final class ProfileViewModelTests: XCTestCase {
    private func model(plan: Plan = .free, signedIn: Bool = false, notebooks: Int = 3) -> (ProfileViewModel, MockAccountService) {
        let user = signedIn ? AccountUser(name: "A", email: "a@example.com") : nil
        let service = MockAccountService(user: user, plan: plan, referralCode: signedIn ? "DUB-ME" : "",
                                         notebookCount: { notebooks })
        return (ProfileViewModel(service: service), service)
    }

    func testFreeUsageText() {
        let (vm, _) = model(notebooks: 3)
        XCTAssertEqual(vm.notebooksUsage, "3 of 8 notebooks used")
        XCTAssertEqual(vm.aiTrialUsage, "2 of 2 free AI questions left")
    }

    func testSignInThenUpgrade() async {
        let (vm, _) = model()
        await vm.upgrade()
        XCTAssertEqual(vm.plan, .free)
        XCTAssertNotNil(vm.notice)
        await vm.signIn()
        XCTAssertTrue(vm.isSignedIn)
        await vm.upgrade()
        XCTAssertEqual(vm.plan, .pro)
        XCTAssertEqual(vm.notebooksUsage, "3 notebooks")
    }

    func testReferralCodeRules() async {
        let (vm, _) = model(signedIn: true)
        vm.friendCode = "dub-me"
        await vm.redeemFriendCode()
        XCTAssertEqual(vm.notice?.message, AccountError.ownCode.errorDescription)
        vm.notice = nil
        vm.friendCode = "DUB-FRIEND"
        await vm.redeemFriendCode()
        XCTAssertEqual(vm.notice?.title, "Code applied")
        XCTAssertEqual(vm.friendCode, "")
    }

    func testDeleteAccountSignsOut() async {
        let (vm, _) = model(plan: .pro, signedIn: true)
        await vm.deleteAccount()
        XCTAssertFalse(vm.isSignedIn)
        XCTAssertEqual(vm.plan, .free)
        XCTAssertEqual(vm.referralCode, "")
    }
}
