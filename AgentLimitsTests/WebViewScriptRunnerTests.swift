import WebKit
import XCTest
@testable import AgentLimits

final class WebViewScriptRunnerTests: XCTestCase {
    private struct FixturePayload: Decodable, Equatable {
        let value: Int
    }

    @MainActor
    func testWrapsProviderScriptWithDeadlineAbortAndStreamingCap() async throws {
        let recorder = ScriptRecorder()
        let runner = WebViewScriptRunner(
            requestTimeout: 2,
            maximumJSONResponseBytes: 1_234,
            evaluator: { script, _ in
                recorder.script = script
                return "{}"
            }
        )

        _ = try await runner.runJSONScript(
            "return Promise.resolve('{}');",
            webView: makeWebView()
        )

        XCTAssertTrue(recorder.script.contains("new AbortController()"))
        XCTAssertTrue(recorder.script.contains("Promise.race"))
        XCTAssertTrue(recorder.script.contains("2000"))
        XCTAssertTrue(recorder.script.contains("1234"))
        XCTAssertTrue(recorder.script.contains("response.body.getReader"))
        XCTAssertTrue(
            recorder.script.contains("Only bounded response.json()")
        )
        XCTAssertTrue(recorder.script.contains("return Promise.resolve('{}');"))
    }

    @MainActor
    func testNativeDeadlineReturnsWhenEvaluatorDoesNotFinish() async {
        let runner = WebViewScriptRunner(
            requestTimeout: 0.01,
            evaluator: { _, _ in
                try await Task.sleep(for: .seconds(3_600))
                return "{}"
            }
        )

        do {
            _ = try await runner.runJSONScript(
                "return '{}';",
                webView: makeWebView()
            )
            XCTFail("Expected timeout")
        } catch let error as WebViewScriptRunnerError {
            guard case .scriptFailed(let message) = error else {
                return XCTFail("Expected scriptFailed, got \(error)")
            }
            XCTAssertFalse(message.isEmpty)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testCancellationReturnsCancellationError() async {
        let runner = WebViewScriptRunner(
            requestTimeout: 60,
            evaluator: { _, _ in
                try await Task.sleep(for: .seconds(3_600))
                return "{}"
            }
        )
        let webView = makeWebView()
        let task = Task { @MainActor in
            try await runner.runJSONScript("return '{}';", webView: webView)
        }

        await Task.yield()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    @MainActor
    func testCancellationWinsAgainstSimultaneousEvaluatorSuccess() async {
        let evaluator = ControlledScriptEvaluator()
        let runner = WebViewScriptRunner(
            requestTimeout: 60,
            evaluator: { _, _ in await evaluator.evaluate() }
        )
        let task = Task { @MainActor in
            try await runner.runJSONScript(
                "return '{}';",
                webView: makeWebView()
            )
        }

        await evaluator.waitUntilStarted()
        task.cancel()
        evaluator.succeed(with: "{}")

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    @MainActor
    func testRejectsNativeJSONResultAboveUTF8ByteCap() async {
        let runner = WebViewScriptRunner(
            maximumJSONResponseBytes: 4,
            evaluator: { _, _ in "ééé" }
        )

        do {
            _ = try await runner.runJSONScript(
                "return 'unused';",
                webView: makeWebView()
            )
            XCTFail("Expected invalid response")
        } catch let error as WebViewScriptRunnerError {
            XCTAssertEqual(error, .invalidResponse)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testSurfacesScriptReportedError() async {
        let runner = WebViewScriptRunner(
            evaluator: { _, _ in #"{"__error":"denied"}"# }
        )

        do {
            _ = try await runner.runJSONScript(
                "return 'unused';",
                webView: makeWebView()
            )
            XCTFail("Expected script error")
        } catch let error as WebViewScriptRunnerError {
            XCTAssertEqual(error, .scriptFailed("denied"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testBooleanRunnerRejectsWrongResultType() async throws {
        let validRunner = WebViewScriptRunner(
            evaluator: { _, _ in true }
        )
        let invalidRunner = WebViewScriptRunner(
            evaluator: { _, _ in "true" }
        )
        let webView = makeWebView()

        let value = try await validRunner.runBooleanScript(
            "return true;",
            webView: webView
        )
        XCTAssertTrue(value)
        do {
            _ = try await invalidRunner.runBooleanScript(
                "return true;",
                webView: webView
            )
            XCTFail("Expected invalid response")
        } catch let error as WebViewScriptRunnerError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    @MainActor
    func testWrappedScriptExecutesBoundedFetchInWebKit() async throws {
        let webView = makeWebView()
        webView.loadHTMLString("<html><body></body></html>", baseURL: nil)
        await waitUntilNavigationSettles(webView)

        let payload = try await WebViewScriptRunner().decodeJSONScript(
            FixturePayload.self,
            script: """
            return (async () => {
              const response = await fetch(
                "data:application/json,%7B%22value%22%3A7%7D"
              );
              return JSON.stringify(await response.json());
            })();
            """,
            webView: webView
        )

        XCTAssertEqual(payload, FixturePayload(value: 7))
    }

    @MainActor
    func testRealWebKitNeverSettlingPromiseTimesOutAndCleansUp() async throws {
        let webView = makeWebView()
        webView.loadHTMLString("<html><body></body></html>", baseURL: nil)
        await waitUntilNavigationSettles(webView)
        let runner = WebViewScriptRunner(
            requestTimeout: 1,
            javaScriptTimeout: 0.05
        )

        do {
            _ = try await runner.runJSONScript(
                "return new Promise(() => {});",
                webView: webView
            )
            XCTFail("Expected timeout")
        } catch let error as WebViewScriptRunnerError {
            guard case .scriptFailed(let message) = error else {
                return XCTFail("Expected scriptFailed, got \(error)")
            }
            XCTAssertEqual(
                message,
                URLError(.timedOut).localizedDescription
            )
        }

        let mapCount = try await evaluateRawJavaScript(
            """
            return globalThis.__agentLimitsFetchControllers
              ? globalThis.__agentLimitsFetchControllers.size
              : 0;
            """,
            webView: webView
        )
        XCTAssertEqual((mapCount as? NSNumber)?.intValue, 0)
        let followupValue = try await WebViewScriptRunner().runBooleanScript(
            "return true;",
            webView: webView
        )
        XCTAssertTrue(followupValue)
    }

    @MainActor
    func testProviderContinuationCannotFetchAfterTimeoutCleanup() async throws {
        let webView = makeWebView()
        webView.loadHTMLString("<html><body></body></html>", baseURL: nil)
        await waitUntilNavigationSettles(webView)
        let runner = WebViewScriptRunner(
            requestTimeout: 1,
            javaScriptTimeout: 0.05
        )

        do {
            _ = try await runner.runJSONScript(
                """
                globalThis.__agentLimitsLateFetch = "pending";
                const caller = new AbortController();
                setTimeout(async () => {
                  try {
                    await fetch(
                      "data:application/json,%7B%22value%22%3A7%7D",
                      { signal: caller.signal }
                    );
                    globalThis.__agentLimitsLateFetch = "succeeded";
                  } catch (_) {
                    globalThis.__agentLimitsLateFetch = "aborted";
                  }
                }, 100);
                return new Promise(() => {});
                """,
                webView: webView
            )
            XCTFail("Expected timeout")
        } catch is WebViewScriptRunnerError {
            // Expected.
        }

        try await Task.sleep(for: .milliseconds(250))
        let lateFetchState = try await evaluateRawJavaScript(
            "return globalThis.__agentLimitsLateFetch;",
            webView: webView
        )
        XCTAssertEqual(lateFetchState as? String, "aborted")
    }

    @MainActor
    func testRealWebKitRejectsOversizedJSONBodyBeforeParsing() async throws {
        let webView = makeWebView()
        webView.loadHTMLString("<html><body></body></html>", baseURL: nil)
        await waitUntilNavigationSettles(webView)
        let payload = #"{"value":"\#(String(repeating: "x", count: 256))"}"#
        let dataURL = "data:application/json;base64,"
            + Data(payload.utf8).base64EncodedString()
        let runner = WebViewScriptRunner(maximumJSONResponseBytes: 32)

        do {
            _ = try await runner.runJSONScript(
                """
                const response = await fetch("\(dataURL)");
                return JSON.stringify(await response.json());
                """,
                webView: webView
            )
            XCTFail("Expected oversized response rejection")
        } catch is WebViewScriptRunnerError {
            // Expected.
        }
    }

    @MainActor
    func testRealWebKitRejectsUnboundedAlternateBodyReader() async throws {
        let webView = makeWebView()
        webView.loadHTMLString("<html><body></body></html>", baseURL: nil)
        await waitUntilNavigationSettles(webView)

        do {
            _ = try await WebViewScriptRunner().runJSONScript(
                """
                const response = await fetch("data:text/plain,hello");
                return JSON.stringify({ value: await response.text() });
                """,
                webView: webView
            )
            XCTFail("Expected unsupported reader rejection")
        } catch is WebViewScriptRunnerError {
            // Expected.
        }
    }

    @MainActor
    func testRealWebKitPreservesPreAbortedCallerSignal() async throws {
        let webView = makeWebView()
        webView.loadHTMLString("<html><body></body></html>", baseURL: nil)
        await waitUntilNavigationSettles(webView)

        do {
            _ = try await WebViewScriptRunner().runJSONScript(
                """
                const caller = new AbortController();
                caller.abort();
                const response = await fetch(
                  "data:application/json,%7B%22value%22%3A7%7D",
                  { signal: caller.signal }
                );
                return JSON.stringify(await response.json());
                """,
                webView: webView
            )
            XCTFail("Expected caller cancellation")
        } catch is WebViewScriptRunnerError {
            // Expected.
        }
    }

    @MainActor
    private func makeWebView() -> WKWebView {
        WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    }

    @MainActor
    private func waitUntilNavigationSettles(_ webView: WKWebView) async {
        for _ in 0..<200 {
            if webView.url != nil, !webView.isLoading {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("WebView did not finish loading")
    }

    @MainActor
    private func evaluateRawJavaScript(
        _ script: String,
        webView: WKWebView
    ) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(
                script,
                arguments: [:],
                in: nil,
                in: .page
            ) { continuation.resume(with: $0) }
        }
    }
}

@MainActor
private final class ScriptRecorder {
    var script = ""
}

@MainActor
private final class ControlledScriptEvaluator {
    private var continuation: CheckedContinuation<Any?, Never>?
    private var isStarted = false

    func evaluate() async -> Any? {
        isStarted = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        while !isStarted {
            await Task.yield()
        }
    }

    func succeed(with value: Any?) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
