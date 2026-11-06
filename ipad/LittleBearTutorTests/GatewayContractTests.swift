import UIKit
import XCTest
@testable import LittleBearTutor

/// Keeps the iPad client in line with `server/src/gateway.mjs` validation.
final class GatewayContractTests: XCTestCase {
    private let token = String(repeating: "t", count: 32)
    private let child = Child(name: "林林", grade: 2)

    private func json(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    func testRequestUsesGatewaySubjectCodesAndLimits() throws {
        var task = Homework(childID: child.id, subject: .chinese, title: String(repeating: "题", count: 150), instructions: "读一读")
        task.conversation = (0..<12).map { TutorTurn(question: "q\($0)", reply: "r\($0)") }
        let body = TutorRequest(mode: "help", child: child, subject: task.subject, task: task, message: "怎么做", image: nil)
        let request = try TutorClient().makeRequest(config: ServiceConfig(url: "https://tutor.example.com/", token: token, consent: true), body: body)
        XCTAssertEqual(request.url?.absoluteString, "https://tutor.example.com/v1/tutor")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        let payload = try json(request)
        XCTAssertEqual(payload["subject"] as? String, "CHINESE")
        XCTAssertEqual(payload["grade"] as? Int, 2)
        XCTAssertEqual((payload["title"] as? String)?.count, 100)
        XCTAssertEqual((payload["history"] as? [[String: String]])?.count, 8)
        XCTAssertEqual((payload["history"] as? [[String: String]])?.first?["question"], "q4")
        XCTAssertNil(payload["image"], "no image key unless a photo is sent")
    }

    func testRequestRefusedWithoutConsentOrHTTPS() {
        let body = TutorRequest(mode: "help", child: child, subject: .math, task: nil, message: "m", image: nil)
        XCTAssertThrowsError(try TutorClient().makeRequest(config: ServiceConfig(url: "https://a.example", token: token, consent: false), body: body))
        XCTAssertThrowsError(try TutorClient().makeRequest(config: ServiceConfig(url: "http://a.example", token: token, consent: true), body: body))
        XCTAssertThrowsError(try TutorClient.validate(url: "https://a.example", token: "short"))
        XCTAssertThrowsError(try TutorClient.validate(url: "https://user@a.example", token: token))
    }

    func testDecodesPracticeReplyAsUnverified() throws {
        let data = Data("""
        {"message":"试试这道题","assessment":"UNKNOWN","exercise":{"id":"g-1","subject":"MATH","concept":"两位数加法",
         "prompt":"35 + 27 = ？","answer":"62","hints":["a","b","c"],"explanation":"e"}}
        """.utf8)
        let reply = try TutorClient.decode(data)
        let exercise = try XCTUnwrap(reply.exercise?.unverified(expected: .math))
        XCTAssertFalse(exercise.verified)
        XCTAssertNil(reply.exercise?.unverified(expected: .english), "subject mismatch is rejected")
    }

    func testRejectsMalformedReplies() {
        XCTAssertThrowsError(try TutorClient.decode(Data(#"{"message":""}"#.utf8)))
        XCTAssertThrowsError(try TutorClient.decode(Data(#"{"message":"hi","assessment":"MAYBE"}"#.utf8)))
        XCTAssertThrowsError(try TutorClient.decode(Data("not json".utf8)))
    }

    func testHTTPStatusMapping() {
        XCTAssertEqual(TutorError(status: 401), .unauthorized)
        XCTAssertEqual(TutorError(status: 429), .rateLimited)
        XCTAssertEqual(TutorError(status: 503), .modelNotConfigured)
        XCTAssertEqual(TutorError(status: 502), .serviceUnavailable)
    }

    func testPhotosAreDownscaledToGatewayJPEG() throws {
        let size = CGSize(width: 4000, height: 3000)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            for i in 0..<400 {
                UIColor(hue: CGFloat(i) / 400, saturation: 1, brightness: 1, alpha: 1).setFill()
                context.fill(CGRect(x: CGFloat(i * 10), y: CGFloat((i * 37) % 3000), width: 10, height: 3000))
            }
        }
        let data = try XCTUnwrap(PhotoStore.gatewayJPEG(image))
        XCTAssertLessThanOrEqual(data.count, PhotoStore.maxBytes)
        XCTAssertTrue(data.starts(with: [0xFF, 0xD8, 0xFF]))
        XCTAssertLessThanOrEqual(try XCTUnwrap(UIImage(data: data)).size.width, 2000)
    }
}
