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
        print("[tour] " + label)
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

    private func dismissPopover() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.6)).tap()
        usleep(400_000)
    }

    // MARK: The tour

    func testScreenshotTour() throws {
        app = XCUIApplication()
        app.launchArguments = ["-ui-tour"]
        if let b64 = fixtureBase64() { app.launchEnvironment["UI_TOUR_BACKUP_BASE64"] = b64 }
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "the app did not launch")
        usleep(1_500_000)

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
            let opened = tap(button("Split screen page"))
            if opened { _ = tap(app.staticTexts["Chemistry"].firstMatch, wait: 5) }
            return opened
        }
        _ = tap(button("Close split screen"))

        // Back out, then the board
        step("back-to-library") { tap(button("Back to library")) }
        step("board-notice") { tap(app.staticTexts["Mind map"].firstMatch) }
        step("board-back-to-library") { tap(button("Back to library")) }

        if !missing.isEmpty {
            print("[tour] steps whose control was not found: " + missing.joined(separator: ", "))
        }
    }
}
