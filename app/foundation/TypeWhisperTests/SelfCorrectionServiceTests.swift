import Foundation
import XCTest
@testable import TypeWhisper

final class SelfCorrectionServiceTests: XCTestCase {
    func testExplicitReplacementRetainsNameAndAmountExactly() throws {
        let raw = "Send Rohan, sorry, Rohit 15,000 rupees at 10:30."
        let output = "Send Rohit 15,000 rupees at 10:30."
        XCTAssertEqual(try SelfCorrectionService.decode(reply(output), rawText: raw), output)
    }

    func testInventedReorderedWordsAndChangedNumbersAreRejected() {
        for output in ["Send Rohit 15000 rupees.", "Send Rohit 15,000 dollars.", "Rohit Send 15,000 rupees."] {
            XCTAssertThrowsError(try SelfCorrectionService.decode(reply(output), rawText: "Send Rohit 15,000 rupees."))
        }
    }

    func testRetainedTermCasingAndRepetition() {
        XCTAssertTrue(SelfCorrectionService.preservesRetainedWords(raw: "really, really good on iPhone", output: "Really, really good on iPhone"))
        XCTAssertFalse(SelfCorrectionService.preservesRetainedWords(raw: "good on iPhone", output: "Good on iphone"))
        XCTAssertFalse(SelfCorrectionService.preservesRetainedWords(raw: "very good", output: "very very good"))
    }

    func testTruncatedEmptyMalformedAndUnfinishedResponsesAreRejected() {
        XCTAssertThrowsError(try SelfCorrectionService.decode(reply("", reason: "stop"), rawText: "Hello"))
        XCTAssertThrowsError(try SelfCorrectionService.decode(reply("Hello", reason: "length"), rawText: "Hello"))
        XCTAssertThrowsError(try SelfCorrectionService.decode(reply("Hello", done: false), rawText: "Hello"))
        XCTAssertThrowsError(try SelfCorrectionService.decode(Data("{}".utf8), rawText: "Hello"))
    }

    func testUnavailableModelKeepsOriginal() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MissingModelProtocol.self]
        let service = SelfCorrectionService(session: URLSession(configuration: configuration))
        let result = try await service.clean("Meet Tuesday, sorry, Wednesday.")
        XCTAssertEqual(result.rawText, result.text)
        XCTAssertNotNil(result.fallbackReason)
    }

    func testTooLongTakeIsRecoverableWithoutRequest() async throws {
        let raw = String(repeating: "a", count: 4_001)
        let result = try await SelfCorrectionService().clean(raw)
        XCTAssertEqual(result.text, raw)
        XCTAssertNotNil(result.fallbackReason)
    }

    func testCancelledTakeDoesNotBecomeFallback() async {
        let started = expectation(description: "Request started")
        CancellationProtocol.started = started
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CancellationProtocol.self]
        let service = SelfCorrectionService(session: URLSession(configuration: configuration))
        let task = Task { try await service.clean("Meet Wednesday.") }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation should throw") }
        catch { XCTAssertTrue(error is CancellationError) }
        CancellationProtocol.started = nil
    }

    func testGeminiReplacementAndProtocolFailures() throws {
        let raw = "Send Rohan, sorry, Rohit 15,000 rupees."
        let output = "Send Rohit 15,000 rupees."
        XCTAssertEqual(try SelfCorrectionService.decodeGemini(geminiReply(output), rawText: raw), output)
        XCTAssertThrowsError(try SelfCorrectionService.decodeGemini(geminiReply(output, reason: "MAX_TOKENS"), rawText: raw))
        XCTAssertThrowsError(try SelfCorrectionService.decodeGemini(geminiReply("Send Rohit 16,000 rupees."), rawText: raw))
        XCTAssertThrowsError(try SelfCorrectionService.decodeGemini(geminiReply(""), rawText: raw))
    }

    func testOrdinaryRepetitionDoesNotTriggerNetworkCleanup() {
        XCTAssertFalse(SelfCorrectionService.hasRepairCue("It was very, very good."))
        XCTAssertFalse(SelfCorrectionService.hasRepairCue("I was going to… perhaps we should wait."))
        XCTAssertTrue(SelfCorrectionService.hasRepairCue("Tuesday, sorry, Wednesday."))
        XCTAssertTrue(SelfCorrectionService.hasRepairCue("I need to—I need to send it."))
    }

    func testGeminiCancellationPropagates() async {
        let started = expectation(description: "Gemini request started")
        CancellationProtocol.started = started
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CancellationProtocol.self]
        let service = SelfCorrectionService(session: URLSession(configuration: configuration), apiKey: "synthetic-key")
        let task = Task { try await service.clean("Tuesday, sorry, Wednesday.") }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation should throw") }
        catch { XCTAssertTrue(error is CancellationError) }
        CancellationProtocol.started = nil
    }

    func testCurrencyAndSignedNumbersCannotBeRewritten() {
        XCTAssertFalse(SelfCorrectionService.preservesRetainedWords(raw: "Budget ₹3,450.", output: "Budget 3,450."))
        XCTAssertFalse(SelfCorrectionService.preservesRetainedWords(raw: "Temperature -5 degrees.", output: "Temperature 5 degrees."))
    }

    func testGeminiQuotaFailureKeepsOriginal() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QuotaProtocol.self]
        let service = SelfCorrectionService(session: URLSession(configuration: configuration), apiKey: "synthetic-key")
        let raw = "Tuesday, sorry, Wednesday."
        let result = try await service.clean(raw)
        XCTAssertEqual(result.text, raw)
        XCTAssertEqual(result.fallbackReason, "Gemini reached its usage limit.")
    }

    func testGroqDecodingRejectsTruncationAndChangedFacts() throws {
        func reply(_ text: String, reason: String = "stop") -> Data {
            let content = String(decoding: try! JSONSerialization.data(withJSONObject: ["text": text]), as: UTF8.self)
            return try! JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": reason, "message": ["content": content]]]])
        }
        let raw = "Tuesday, sorry, Wednesday at 10:30."
        XCTAssertEqual(try SelfCorrectionService.decodeGroq(reply("Wednesday at 10:30."), rawText: raw), "Wednesday at 10:30.")
        XCTAssertThrowsError(try SelfCorrectionService.decodeGroq(reply("Wednesday at 11:30."), rawText: raw))
        XCTAssertThrowsError(try SelfCorrectionService.decodeGroq(reply("Wednesday at 10:30.", reason: "length"), rawText: raw))
    }

    func testGroqQuotaFallbackAndCredentialDestination() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GroqQuotaProtocol.self]
        let result = try await SelfCorrectionService(session: URLSession(configuration: configuration), apiKey: "synthetic-groq-key", useGroq: true).clean("Tuesday, sorry, Wednesday.")
        XCTAssertEqual(result.text, result.rawText)
        XCTAssertEqual(result.fallbackReason, "Groq reached its usage limit.")
    }

    private func geminiReply(_ text: String, reason: String = "STOP") -> Data {
        let content = String(decoding: try! JSONSerialization.data(withJSONObject: ["text": text]), as: UTF8.self)
        return try! JSONSerialization.data(withJSONObject: ["candidates": [["finishReason": reason, "content": ["parts": [["text": content]]]]]])
    }

    private func reply(_ text: String, reason: String = "stop", done: Bool = true) -> Data {
        let content = String(decoding: try! JSONSerialization.data(withJSONObject: ["text": text]), as: UTF8.self)
        return try! JSONSerialization.data(withJSONObject: ["message": ["content": content], "done": done, "done_reason": reason])
    }
}

private final class CancellationProtocol: URLProtocol {
    nonisolated(unsafe) static var started: XCTestExpectation?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.started?.fulfill() }
    override func stopLoading() {}
}

private final class MissingModelProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class QuotaProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.url?.host, "generativelanguage.googleapis.com")
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "synthetic-key")
        XCTAssertNil(request.url?.query)
        let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class GroqQuotaProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.url?.host, "api.groq.com")
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-groq-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-goog-api-key"))
        XCTAssertNil(request.url?.query)
        let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
