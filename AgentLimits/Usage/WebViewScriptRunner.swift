// MARK: - WebViewScriptRunner.swift
// Runs bounded JavaScript requests in WKWebView and decodes their results.

import Foundation
import WebKit

/// Errors that can occur when executing scripts inside WKWebView.
enum WebViewScriptRunnerError: LocalizedError, Equatable {
    case invalidResponse
    case scriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "error.parseFailed".localized()
        case .scriptFailed(let message):
            return "error.fetchFailed".localized(message)
        }
    }
}

/// Utility for evaluating JavaScript with an overall deadline and response cap.
struct WebViewScriptRunner {
    typealias ScriptEvaluator = @MainActor @Sendable (
        _ script: String,
        _ webView: WKWebView
    ) async throws -> Any?

    static let defaultRequestTimeout: TimeInterval = 20
    static let defaultMaximumJSONResponseBytes = 4 * 1_024 * 1_024
    private static let timeoutMarker = "__AGENT_LIMITS_TIMEOUT__"
    private static let cancellationMarker = "__AGENT_LIMITS_CANCELLED__"

    private let requestTimeoutNanoseconds: UInt64
    private let requestTimeoutMilliseconds: Int
    private let maximumJSONResponseBytes: Int
    private let evaluator: ScriptEvaluator

    init(
        requestTimeout: TimeInterval = Self.defaultRequestTimeout,
        javaScriptTimeout: TimeInterval? = nil,
        maximumJSONResponseBytes: Int = Self.defaultMaximumJSONResponseBytes,
        evaluator: ScriptEvaluator? = nil
    ) {
        precondition(requestTimeout.isFinite && requestTimeout > 0)
        let resolvedJavaScriptTimeout = javaScriptTimeout ?? requestTimeout
        precondition(
            resolvedJavaScriptTimeout.isFinite
                && resolvedJavaScriptTimeout > 0
                && resolvedJavaScriptTimeout <= requestTimeout
        )
        precondition(maximumJSONResponseBytes > 0)

        requestTimeoutNanoseconds = UInt64(requestTimeout * 1_000_000_000)
        requestTimeoutMilliseconds = max(
            1,
            Int(resolvedJavaScriptTimeout * 1_000)
        )
        self.maximumJSONResponseBytes = maximumJSONResponseBytes
        self.evaluator = evaluator ?? Self.evaluateWithWebKit
    }

    /// Runs a script expected to return a JSON string.
    @MainActor
    func runJSONScript(
        _ script: String,
        webView: WKWebView
    ) async throws -> String {
        let result = try await evaluateJavaScript(script, webView: webView)
        guard case .string(let jsonString) = result,
              jsonString.utf8.count <= maximumJSONResponseBytes else {
            throw WebViewScriptRunnerError.invalidResponse
        }
        if let errorMessage = extractErrorMessage(from: jsonString) {
            throw WebViewScriptRunnerError.scriptFailed(errorMessage)
        }
        return jsonString
    }

    /// Runs a script and decodes the returned, bounded JSON string.
    @MainActor
    func decodeJSONScript<T: Decodable>(
        _ type: T.Type,
        script: String,
        webView: WKWebView,
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> T {
        let jsonString = try await runJSONScript(script, webView: webView)
        return try decoder.decode(T.self, from: Data(jsonString.utf8))
    }

    /// Runs a script expected to return a Boolean value.
    @MainActor
    func runBooleanScript(
        _ script: String,
        webView: WKWebView
    ) async throws -> Bool {
        let result = try await evaluateJavaScript(script, webView: webView)
        guard case .boolean(let value) = result else {
            throw WebViewScriptRunnerError.invalidResponse
        }
        return value
    }

    @MainActor
    private func evaluateJavaScript(
        _ script: String,
        webView: WKWebView
    ) async throws -> WebViewJavaScriptValue {
        try Task.checkCancellation()

        let operationID = UUID().uuidString.lowercased()
        let wrappedScript = Self.wrapScript(
            script,
            operationID: operationID,
            timeoutMilliseconds: requestTimeoutMilliseconds,
            maximumResponseBytes: maximumJSONResponseBytes
        )
        let cancellationScript = Self.abortScript(
            operationID: operationID,
            reason: Self.cancellationMarker
        )
        let timeoutScript = Self.abortScript(
            operationID: operationID,
            reason: Self.timeoutMarker
        )
        let pair = AsyncThrowingStream<WebViewJavaScriptValue, Error>
            .makeStream()
        let controller = WebViewJavaScriptEvaluationController(
            streamContinuation: pair.continuation,
            webView: webView,
            script: wrappedScript,
            cancellationScript: cancellationScript,
            timeoutScript: timeoutScript,
            timeoutNanoseconds: requestTimeoutNanoseconds,
            evaluator: evaluator
        )
        controller.start()

        return try await withTaskCancellationHandler {
            var iterator = pair.stream.makeAsyncIterator()
            guard let value = try await iterator.next() else {
                try Task.checkCancellation()
                throw WebViewScriptRunnerError.invalidResponse
            }
            try Task.checkCancellation()
            return value
        } onCancel: {
            Task { @MainActor in
                controller.cancel()
            }
        }
    }

    @MainActor
    private static func evaluateWithWebKit(
        _ script: String,
        _ webView: WKWebView
    ) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(
                script,
                arguments: [:],
                in: nil,
                in: .page
            ) { result in
                switch result {
                case .success(let value):
                    continuation.resume(returning: value)
                case .failure(let error):
                    let message = error.localizedDescription
                    let exceptionMessage = (error as NSError)
                        .userInfo["WKJavaScriptExceptionMessage"] as? String
                    if message.contains(Self.timeoutMarker)
                        || exceptionMessage?.contains(Self.timeoutMarker)
                            == true {
                        continuation.resume(
                            throwing: WebViewScriptRunnerError.scriptFailed(
                                URLError(.timedOut).localizedDescription
                            )
                        )
                        return
                    }
                    if message.contains(Self.cancellationMarker)
                        || exceptionMessage?.contains(Self.cancellationMarker)
                            == true {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    continuation.resume(
                        throwing: WebViewScriptRunnerError.scriptFailed(
                            message
                        )
                    )
                }
            }
        }
    }

    /// Adds a hard deadline, native-addressable cancellation handle, and a
    /// streaming cap to JSON read through the script's scoped fetch helper.
    private static func wrapScript(
        _ script: String,
        operationID: String,
        timeoutMilliseconds: Int,
        maximumResponseBytes: Int
    ) -> String {
        """
        const __agentLimitsOperationID = "\(operationID)";
        const __agentLimitsController = new AbortController();
        const __agentLimitsControllers = globalThis.__agentLimitsFetchControllers
          || (globalThis.__agentLimitsFetchControllers = new Map());
        const __agentLimitsSignalCleanups = [];
        let __agentLimitsRejectCancellation;
        const __agentLimitsCancellation = new Promise((_, reject) => {
          __agentLimitsRejectCancellation = reject;
        });
        const __agentLimitsOperation = {
          controller: __agentLimitsController,
          cancel(reason) {
            __agentLimitsController.abort(reason);
            __agentLimitsRejectCancellation(reason);
          },
          finish() {
            __agentLimitsController.abort();
            for (const cleanup of __agentLimitsSignalCleanups) {
              try { cleanup(); } catch (_) {}
            }
          }
        };
        __agentLimitsControllers.set(
          __agentLimitsOperationID,
          __agentLimitsOperation
        );
        const __agentLimitsTimeout = setTimeout(
          () => __agentLimitsOperation.cancel("\(timeoutMarker)"),
          \(timeoutMilliseconds)
        );
        const __agentLimitsMaximumBytes = \(maximumResponseBytes);
        const __agentLimitsNativeFetch = globalThis.fetch.bind(globalThis);

        async function __agentLimitsReadJSON(response) {
          const declaredLength = Number(
            response.headers.get("Content-Length")
          );
          if (Number.isFinite(declaredLength)
              && declaredLength > __agentLimitsMaximumBytes) {
            __agentLimitsController.abort();
            throw new Error("Response exceeds the allowed size");
          }

          if (!response.body
              || typeof response.body.getReader !== "function") {
            throw new Error("Response body cannot be read within a size bound");
          }

          const reader = response.body.getReader();
          const chunks = [];
          let totalBytes = 0;
          try {
            while (true) {
              const result = await reader.read();
              if (result.done) { break; }
              if (!result.value) { continue; }
              totalBytes += result.value.byteLength;
              if (totalBytes > __agentLimitsMaximumBytes) {
                try { await reader.cancel("Response too large"); } catch (_) {}
                __agentLimitsController.abort();
                throw new Error("Response exceeds the allowed size");
              }
              chunks.push(result.value);
            }
          } finally {
            try { reader.releaseLock(); } catch (_) {}
          }

          const bytes = new Uint8Array(totalBytes);
          let offset = 0;
          for (const chunk of chunks) {
            bytes.set(chunk, offset);
            offset += chunk.byteLength;
          }
          return JSON.parse(new TextDecoder().decode(bytes));
        }

        function __agentLimitsRequestSignal(input, init) {
          if (__agentLimitsController.signal.aborted) {
            return __agentLimitsController.signal;
          }
          let callerSignal = null;
          if (init
              && Object.prototype.hasOwnProperty.call(init, "signal")) {
            callerSignal = init.signal;
          } else if (typeof Request !== "undefined"
                     && input instanceof Request) {
            callerSignal = input.signal;
          }
          if (!callerSignal) {
            return __agentLimitsController.signal;
          }
          if (callerSignal.aborted
              || typeof callerSignal.addEventListener !== "function") {
            return callerSignal;
          }

          const composedController = new AbortController();
          const relayOperationAbort = () => composedController.abort(
            __agentLimitsController.signal.reason
          );
          const relayCallerAbort = () => composedController.abort(
            callerSignal.reason
          );
          __agentLimitsController.signal.addEventListener(
            "abort",
            relayOperationAbort,
            { once: true }
          );
          callerSignal.addEventListener(
            "abort",
            relayCallerAbort,
            { once: true }
          );
          __agentLimitsSignalCleanups.push(() => {
            __agentLimitsController.signal.removeEventListener(
              "abort",
              relayOperationAbort
            );
            callerSignal.removeEventListener("abort", relayCallerAbort);
          });
          return composedController.signal;
        }

        const fetch = async (input, init = {}) => {
          const options = Object.assign({}, init, {
            signal: __agentLimitsRequestSignal(input, init)
          });
          const response = await __agentLimitsNativeFetch(input, options);
          return new Proxy(response, {
            get(target, property) {
              if (property === "json") {
                return () => __agentLimitsReadJSON(target);
              }
              if (["arrayBuffer", "blob", "clone", "formData", "text"]
                  .includes(property)
                  || property === "body") {
                throw new Error(
                  "Only bounded response.json() reads are supported"
                );
              }
              const value = Reflect.get(target, property, target);
              return typeof value === "function" ? value.bind(target) : value;
            }
          });
        };

        try {
          const __agentLimitsProvider = (async () => {
              \(script)
          })();
          return await Promise.race([
            __agentLimitsProvider,
            __agentLimitsCancellation
          ]);
        } finally {
          clearTimeout(__agentLimitsTimeout);
          __agentLimitsOperation.finish();
          __agentLimitsControllers.delete(__agentLimitsOperationID);
        }
        """
    }

    private static func abortScript(
        operationID: String,
        reason: String
    ) -> String {
        """
        (() => {
          const controllers = globalThis.__agentLimitsFetchControllers;
          const operation = controllers && controllers.get("\(operationID)");
          if (!operation) { return false; }
          operation.cancel("\(reason)");
          controllers.delete("\(operationID)");
          return true;
        })();
        """
    }

    private func extractErrorMessage(from jsonString: String) -> String? {
        guard let data = jsonString.data(using: .utf8),
              let jsonObject = try? JSONSerialization.jsonObject(
                with: data,
                options: []
              ) as? [String: Any] else {
            return nil
        }
        return jsonObject["__error"] as? String
    }
}

private enum WebViewJavaScriptValue: Sendable {
    case string(String)
    case boolean(Bool)
    case unsupported
}

@MainActor
private final class WebViewJavaScriptEvaluationController {
    private let streamContinuation:
        AsyncThrowingStream<WebViewJavaScriptValue, Error>.Continuation
    private let webView: WKWebView
    private let script: String
    private let cancellationScript: String
    private let timeoutScript: String
    private let timeoutNanoseconds: UInt64
    private let evaluator: WebViewScriptRunner.ScriptEvaluator

    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var isFinished = false

    init(
        streamContinuation:
            AsyncThrowingStream<WebViewJavaScriptValue, Error>.Continuation,
        webView: WKWebView,
        script: String,
        cancellationScript: String,
        timeoutScript: String,
        timeoutNanoseconds: UInt64,
        evaluator: @escaping WebViewScriptRunner.ScriptEvaluator
    ) {
        self.streamContinuation = streamContinuation
        self.webView = webView
        self.script = script
        self.cancellationScript = cancellationScript
        self.timeoutScript = timeoutScript
        self.timeoutNanoseconds = timeoutNanoseconds
        self.evaluator = evaluator
    }

    func start() {
        operationTask = Task { @MainActor [weak self] in
            guard let evaluator = self?.evaluator,
                  let script = self?.script,
                  let webView = self?.webView else { return }
            let result: Result<WebViewJavaScriptValue, Error>
            do {
                let rawValue = try await evaluator(script, webView)
                result = .success(Self.value(from: rawValue))
            } catch {
                result = .failure(error)
            }
            self?.complete(with: result)
        }
        timeoutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            timeOut()
        }
    }

    func cancel() {
        guard !isFinished else { return }
        operationTask?.cancel()
        abortWebOperation(cancellationScript)
        complete(with: .failure(CancellationError()))
    }

    private func timeOut() {
        guard !isFinished else { return }
        operationTask?.cancel()
        abortWebOperation(timeoutScript)
        complete(
            with: .failure(
                WebViewScriptRunnerError.scriptFailed(
                    URLError(.timedOut).localizedDescription
                )
            )
        )
    }

    private func complete(
        with result: Result<WebViewJavaScriptValue, Error>
    ) {
        guard !isFinished else { return }
        isFinished = true
        timeoutTask?.cancel()

        switch result {
        case .success(let value):
            streamContinuation.yield(value)
            streamContinuation.finish()
        case .failure(let error):
            streamContinuation.finish(throwing: error)
        }

        operationTask = nil
        timeoutTask = nil
    }

    private func abortWebOperation(_ script: String) {
        webView.callAsyncJavaScript(
            script,
            arguments: [:],
            in: nil,
            in: .page
        ) { _ in }
    }

    private static func value(from rawValue: Any?) -> WebViewJavaScriptValue {
        if let string = rawValue as? String {
            return .string(string)
        }
        if let boolean = rawValue as? Bool {
            return .boolean(boolean)
        }
        return .unsupported
    }
}
