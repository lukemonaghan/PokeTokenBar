import XCTest
@testable import PokeTokenBar

final class OnlineStoreTests: XCTestCase {
    func testHealthURLAddsHTTPSSchemeForBareDomain() {
        XCTAssertEqual(OnlineStore.healthURL(from: "trade.example.com")?.absoluteString,
                        "https://trade.example.com/health")
    }

    func testHealthURLKeepsExplicitScheme() {
        XCTAssertEqual(OnlineStore.healthURL(from: "http://localhost:3000")?.absoluteString,
                        "http://localhost:3000/health")
    }

    func testHealthURLTrimsWhitespace() {
        XCTAssertEqual(OnlineStore.healthURL(from: "  trade.example.com  ")?.absoluteString,
                        "https://trade.example.com/health")
    }

    func testHealthURLRejectsEmptyOrInvalidInput() {
        XCTAssertNil(OnlineStore.healthURL(from: ""))
        XCTAssertNil(OnlineStore.healthURL(from: "   "))
        XCTAssertNil(OnlineStore.healthURL(from: "https://"))
    }
}
