import XCTest
import Darwin
@testable import MirageHelper

final class ShutdownSignalTests: XCTestCase {
    func testSigtermInvokesHandler() {
        let signal = ShutdownSignal()
        let called = expectation(description: "SIGTERM handler")
        signal.install { called.fulfill() }
        defer { signal.uninstall() }

        kill(getpid(), SIGTERM)

        wait(for: [called], timeout: 2)
    }

    func testSigintInvokesHandler() {
        let signal = ShutdownSignal()
        let called = expectation(description: "SIGINT handler")
        signal.install { called.fulfill() }
        defer { signal.uninstall() }

        kill(getpid(), SIGINT)

        wait(for: [called], timeout: 2)
    }

    func testHandlerSurvivesSecondUninstall() {
        let signal = ShutdownSignal()
        signal.uninstall()
        signal.uninstall()
    }
}