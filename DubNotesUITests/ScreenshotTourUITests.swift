import XCTest

/// Walks the app and attaches a numbered screenshot after every step (NN-name). A step whose control can't be found
/// records that in its screenshot name and in the log, then the tour carries on: the point is the pictures, so the
/// test only fails if the app can't launch at all.
final class ScreenshotTourUITests: XCTestCase {
    private var app: XCUIApplication!
    private var number = 0
    private var missing: [String] = []

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    // MARK: Helpers

    private func fixtureBase64() -> String? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DubNotesTests/Fixtures/backup-sample.json")
        return (try? Data(contentsOf: url))?.base64EncodedString()
    }

    private func shot(_ name: String, note: String? = nil) {
        number += 1
        let label = String(format: "%02d-%@", number, name) + (note.map { "-" + $0 } ?? "")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = label
        attachment.lifetime = .keepAlways
        add(attachment)
        print("[tour] screenshot: " + label)
    }

    /// Taps the first element that appears within a few seconds; false if none does.
    @discardableResult
    private func tap(_ candidates: XCUIElement..., wait: TimeInterval = 4) -> Bool {
        let deadline = Date().addingTimeInterval(wait)
        repeat {
            for e in candidates where e.exists && e.isHittable {
                e.tap()
                return true
            }
            usleep(200_000)
        } while Date() < deadline
        return false
    }

    /// Runs one step: the action returns whether it found its control. The screenshot is taken either way.
    private func step(_ name: String, _ action: () -> Bool) {
        print("[tour] step: " + name)
        let found = action()
        usleep(600_000) // let animations settle
        if found {
            shot(name)
        } else {
            missing.append(name)
            shot(name, note: "CONTROL-NOT-FOUND")
        }
    }

    private func button(_ label: String) -> XCUIElement { app.buttons[label].firstMatch }

    private func buttonStarting(_ prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    /// If a sheet or picker is still open, taps Cancel first and says so in the log.
    private func cancelIfSheetOpen(_ context: String) {
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists && cancel.isHittable {
            print("[tour] a sheet or picker was open " + context + "; tapping Cancel")
            cancel.tap()
            usleep(500_000)
        }
    }

    private func dismissPopover() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.6)).tap()
        usleep(400_000)
    }

    // MARK: The tour

    func testScreenshotTour() throws {
        app = XCUIApplication()
        app.launchArguments = ["-ui-tour"]
        if let b64 = fixtureBase64() { app.launchEnvironment["UI_TOUR_BACKUP_BASE64"] = b64 }
        app.launch()

        // Hard gate: no screenshots of a home screen. If the app is not up and showing the library, fail here.
        let foreground: Bool = app.state == .runningForeground
        let newButton: XCUIElement = app.buttons["New"].firstMatch
        let libraryUp: Bool = foreground && newButton.waitForExistence(timeout: 20)
        if !libraryUp {
            let state: String = String(describing: app.state)
            print("[tour] FATAL: app not ready. state=" + state + " foreground=" + String(foreground))
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "app-debugDescription"
            tree.lifetime = .keepAlways
            add(tree)
            let picture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            picture.name = "00-app-not-ready"
            picture.lifetime = .keepAlways
            add(picture)
            XCTFail("The app is not in the foreground showing the library (state " + state + ")")
            return
        }
        print("[tour] app is up; library visible")

        // Library
        shot("library-grid")
        step("library-list") { tap(app.segmentedControls.firstMatch.buttons.element(boundBy: 1)) }
        step("library-grid-again") { tap(app.segmentedControls.firstMatch.buttons.element(boundBy: 0)) }
        step("open-folder") { tap(app.staticTexts["School"].firstMatch, app.buttons["School"].firstMatch) }
        step("new-notebook-sheet") {
            let ok = tap(button("New"))
            return ok
        }
        _ = tap(button("Cancel"))
        step("settings-sheet") { tap(button("Settings")) }
        _ = tap(button("Done"))
        _ = tap(app.staticTexts["All items"].firstMatch)

        // The first paged notebook
        step("open-notebook") { tap(button("Continue Physics"), app.staticTexts["Physics"].firstMatch) }

        let tools = ["Pen", "Highlighter", "Eraser", "Lasso select", "Text", "Shapes", "Tape", "Laser pointer"]
        for tool in tools {
            step("tool-" + tool.lowercased().replacingOccurrences(of: " ", with: "-")) { tap(button(tool)) }
        }
        step("tool-hand") { tap(buttonStarting("Hand")) }
        step("ai-mode-on") { tap(button("AI mode")) }
        step("ai-send") {
            guard tap(button("Send to AI")) else { return false }
            usleep(2_000_000) // the fake reply arrives after about a second
            return true
        }
        step("ai-mode-off") { tap(button("AI mode")) }
        step("ruler") { tap(button("Ruler")) }
        _ = tap(button("Ruler")) // off again
        step("protractor") { tap(button("Protractor")) }
        _ = tap(button("Protractor"))

        step("paper-menu") { tap(button("Customize paper")) }
        _ = tap(button("Confirm"))
        step("page-manager") { tap(button("Manage pages")) }
        _ = tap(button("Close"))
        step("export-menu") { tap(button("Export")) }
        dismissPopover()

        step("split-menu") { tap(button("Split screen")) }
        step("split-pane-open") {
            guard tap(button("Split screen page")) else { return false }
            // the notebook picker is a sheet: pick Chemistry, then wait for the pane itself
            let picked = tap(button("Chemistry"), app.staticTexts["Chemistry"].firstMatch, wait: 6)
            let paneUp = picked && button("Close split screen").waitForExistence(timeout: 8)
            usleep(1_500_000) // let the pane render its pages
            return paneUp
        }
        cancelIfSheetOpen("before closing the split pane")
        _ = tap(button("Close split screen"))

        // Back out, then the board
        cancelIfSheetOpen("before going back to the library")
        step("back-to-library") { tap(button("Back to library")) }
        cancelIfSheetOpen("before opening the board")
        step("board-notice") { tap(app.staticTexts["Mind map"].firstMatch, app.buttons["Mind map"].firstMatch) }
        cancelIfSheetOpen("before leaving the board")
        step("board-back-to-library") { tap(button("Back to library")) }

        if !missing.isEmpty {
            print("[tour] steps whose control was not found: " + missing.joined(separator: ", "))
        }
    }
}
