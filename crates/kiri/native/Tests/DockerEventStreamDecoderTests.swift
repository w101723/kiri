import Foundation
import XCTest
@testable import KiriMobyUI

final class DockerEventStreamDecoderTests: XCTestCase {
    func testSplitPlainHTTPAndResourceEvents() throws {
        var decoder = MobyDockerEventStreamDecoder()
        XCTAssertEqual(try decoder.append(Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n".utf8)), 0)
        XCTAssertEqual(try decoder.append(Data("\r\n{\"Type\":\"container\",\"Action\":\"start\"}".utf8)), 0)
        XCTAssertEqual(try decoder.append(Data("\n{\"Type\":\"plugin\",\"Action\":\"enable\"}\n".utf8)), 1)
    }

    func testChunkedHTTPAcrossReadBoundaries() throws {
        var decoder = MobyDockerEventStreamDecoder()
        let line = "{\"Type\":\"image\",\"Action\":\"pull\"}\n"
        let chunk = String(line.utf8.count, radix: 16) + "\r\n" + line + "\r\n"
        let wire = Data(("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" + chunk).utf8)
        XCTAssertEqual(try decoder.append(Data(wire.prefix(17))), 0)
        XCTAssertEqual(try decoder.append(Data(wire.dropFirst(17).prefix(23))), 0)
        XCTAssertEqual(try decoder.append(Data(wire.dropFirst(40))), 1)
    }

    func testRejectsNonSuccessHTTP() {
        var decoder = MobyDockerEventStreamDecoder()
        XCTAssertThrowsError(try decoder.append(Data("HTTP/1.1 403 Forbidden\r\n\r\n".utf8)))
    }
}
