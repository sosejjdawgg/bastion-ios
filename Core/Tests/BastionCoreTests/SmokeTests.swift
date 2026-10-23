import XCTest
@testable import BastionCore

final class SmokeTests: XCTestCase {
    func testSoup() { XCTAssertTrue(BastionCore.soupWorks()) }
}
