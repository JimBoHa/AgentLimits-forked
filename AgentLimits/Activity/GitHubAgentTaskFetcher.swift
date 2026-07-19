import Foundation

nonisolated protocol SessionActivityURLLoading: Sendable {
    func data(
        for request: URLRequest,
        maximumBytes: Int
    ) async throws -> (Data, URLResponse)
}

nonisolated private enum SessionActivityURLLoaderError: Error {
    case responseTooLarge
}

/// Ephemeral loader that refuses redirects so an authorization header can
/// never be forwarded to a host selected by a redirect response.
nonisolated class SessionActivityRedirectRejectingDelegate:
    NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Receives bounded chunks instead of iterating URLSession.AsyncBytes one byte
/// at a time. Task-keyed state safely multiplexes concurrent account refreshes
/// over one ephemeral session and preserves HTTP connection reuse.
nonisolated private final class SessionActivityBoundedDataDelegate:
    SessionActivityRedirectRejectingDelegate,
    URLSessionDataDelegate,
    @unchecked Sendable {
    private final class RequestState: @unchecked Sendable {
        let maximumBytes: Int
        let continuation: CheckedContinuation<
            (Data, URLResponse),
            Error
        >
        var data = Data()
        var response: URLResponse?

        init(
            maximumBytes: Int,
            continuation: CheckedContinuation<
                (Data, URLResponse),
                Error
            >
        ) {
            self.maximumBytes = maximumBytes
            self.continuation = continuation
        }
    }

    private let lock = NSLock()
    private var pendingTaskIDs: Set<Int> = []
    private var statesByTaskID: [Int: RequestState] = [:]

    func load(
        request: URLRequest,
        maximumBytes: Int,
        using session: URLSession
    ) async throws -> (Data, URLResponse) {
        let task = session.dataTask(with: request)
        let taskID = task.taskIdentifier
        lock.withLock {
            _ = pendingTaskIDs.insert(taskID)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard pendingTaskIDs.remove(taskID) != nil else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                statesByTaskID[taskID] = RequestState(
                    maximumBytes: maximumBytes,
                    continuation: continuation
                )
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            cancel(task)
        }
    }

    private func cancel(_ task: URLSessionDataTask) {
        lock.lock()
        pendingTaskIDs.remove(task.taskIdentifier)
        let state = statesByTaskID.removeValue(
            forKey: task.taskIdentifier
        )
        lock.unlock()
        task.cancel()
        state?.continuation.resume(throwing: CancellationError())
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        guard let state = statesByTaskID[dataTask.taskIdentifier] else {
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        if response.expectedContentLength > Int64(state.maximumBytes) {
            statesByTaskID.removeValue(forKey: dataTask.taskIdentifier)
            lock.unlock()
            state.continuation.resume(
                throwing: SessionActivityURLLoaderError.responseTooLarge
            )
            completionHandler(.cancel)
            return
        }
        state.response = response
        if response.expectedContentLength > 0 {
            state.data.reserveCapacity(Int(response.expectedContentLength))
        }
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive chunk: Data
    ) {
        lock.lock()
        guard let state = statesByTaskID[dataTask.taskIdentifier] else {
            lock.unlock()
            return
        }
        if chunk.count > state.maximumBytes - state.data.count {
            statesByTaskID.removeValue(forKey: dataTask.taskIdentifier)
            lock.unlock()
            dataTask.cancel()
            state.continuation.resume(
                throwing: SessionActivityURLLoaderError.responseTooLarge
            )
            return
        }
        state.data.append(chunk)
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let state = statesByTaskID.removeValue(forKey: task.taskIdentifier)
        pendingTaskIDs.remove(task.taskIdentifier)
        lock.unlock()
        guard let state else { return }

        if let error {
            state.continuation.resume(throwing: error)
            return
        }
        guard let response = state.response else {
            state.continuation.resume(
                throwing: URLError(.badServerResponse)
            )
            return
        }
        state.continuation.resume(returning: (state.data, response))
    }
}

nonisolated final class SessionActivityURLSessionLoader:
    SessionActivityURLLoading,
    @unchecked Sendable {
    private let delegate: SessionActivityBoundedDataDelegate
    private let session: URLSession

    init(configuration: URLSessionConfiguration? = nil) {
        let delegate = SessionActivityBoundedDataDelegate()
        self.delegate = delegate
        self.session = URLSession(
            configuration: configuration ?? Self.defaultConfiguration(),
            delegate: delegate,
            delegateQueue: nil
        )
    }

    deinit {
        session.invalidateAndCancel()
    }

    func data(
        for request: URLRequest,
        maximumBytes: Int
    ) async throws -> (Data, URLResponse) {
        guard maximumBytes > 0 else {
            throw SessionActivityURLLoaderError.responseTooLarge
        }
        return try await delegate.load(
            request: request,
            maximumBytes: maximumBytes,
            using: session
        )
    }

    private static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return configuration
    }
}

nonisolated protocol GitHubAgentTaskFetching: Sendable {
    func fetchCurrentActivity(
        credential: String
    ) async throws -> SessionActivityCounts
}

nonisolated enum GitHubAgentTaskFetcherError: Error, Equatable {
    case authenticationRequired
    case insufficientPermissions
    case invalidResponse
    case invalidPayload
    case unsupportedSessionState
    case invalidPagination
    case tooManyPages
    case tooManyTasks
    case tooManyTaskDetails
    case tooManySessions
    case responseTooLarge
    case rateLimited(retryAt: Date)
    case timedOut
    case httpStatus(Int)
    case transport
}

private actor SessionActivityResponseBudget {
    private let maximumBytes: Int
    private var consumedBytes = 0
    private var reservedBytes = 0

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func reserve(upTo requestedBytes: Int) throws -> Int {
        let remaining = maximumBytes - consumedBytes - reservedBytes
        guard remaining > 0 else {
            throw GitHubAgentTaskFetcherError.responseTooLarge
        }
        let reservation = min(requestedBytes, remaining)
        reservedBytes += reservation
        return reservation
    }

    func finish(reservation: Int, actualBytes: Int) {
        precondition(actualBytes <= reservation)
        reservedBytes -= reservation
        consumedBytes += actualBytes
    }

    func cancel(reservation: Int) {
        reservedBytes -= reservation
    }
}

/// Counts nonterminal Copilot cloud-agent sessions visible to the authenticated
/// user. A task state describes only its most recent session, while
/// `session_count` is historical. Multi-session tasks therefore use exact
/// task-detail records rather than task-state proxies.
nonisolated final class GitHubAgentTaskFetcher:
    GitHubAgentTaskFetching,
    @unchecked Sendable {
    static let apiVersion = "2026-03-10"

    private struct TasksResponse: Decodable {
        let tasks: [TaskSummary]
    }

    private struct TaskDetail: Decodable {
        let id: String
        let sessionCount: Int
        let sessions: [Session]

        enum CodingKeys: String, CodingKey {
            case id
            case sessionCount = "session_count"
            case sessions
        }
    }

    private struct Session: Decodable {
        let id: String
        let taskID: String
        let state: String

        enum CodingKeys: String, CodingKey {
            case id
            case taskID = "task_id"
            case state
        }
    }

    private struct ErrorResponse: Decodable {
        let message: String?
        let documentationURL: String?

        enum CodingKeys: String, CodingKey {
            case message
            case documentationURL = "documentation_url"
        }
    }

    private struct TaskSummary: Decodable {
        let id: String
        let state: String
        let sessionCount: Int?

        enum CodingKeys: String, CodingKey {
            case id
            case state
            case sessionCount = "session_count"
        }
    }

    private enum ActivityState: String {
        case queued
        case inProgress = "in_progress"
        case completed
        case failed
        case idle
        case waitingForUser = "waiting_for_user"
        case timedOut = "timed_out"
        case cancelled

        var isWorking: Bool {
            self == .inProgress
        }

        var isWaiting: Bool {
            self == .queued || self == .idle || self == .waitingForUser
        }

        var isOpen: Bool {
            isWorking || isWaiting
        }
    }

    private static let maximumPages = 5
    private static let maximumTasks = 500
    private static let maximumTaskDetails = 100
    private static let maximumSessions = 10_000
    private static let maximumResponseBytes = 4 * 1_024 * 1_024
    private static let maximumTotalResponseBytes = 32 * 1_024 * 1_024
    private static let refreshTimeout: Duration = .seconds(45)
    private static let minimumRateLimitDelay: TimeInterval = 60
    private static let defaultRateLimitDelay: TimeInterval = 5 * 60
    private static let maximumRateLimitDelay: TimeInterval = 60 * 60
    private static let minimumRateLimitHeadroom = 100
    private static let trustedHost = "api.github.com"
    private static let trustedPath = "/agents/tasks"

    private let loader: any SessionActivityURLLoading
    private let now: @Sendable () -> Date
    private let refreshTimeout: Duration
    private let maximumTotalResponseBytes: Int

    init(
        loader: any SessionActivityURLLoading =
            SessionActivityURLSessionLoader(),
        now: @escaping @Sendable () -> Date = Date.init,
        refreshTimeout: Duration = GitHubAgentTaskFetcher.refreshTimeout,
        maximumTotalResponseBytes: Int =
            GitHubAgentTaskFetcher.maximumTotalResponseBytes
    ) {
        precondition(
            maximumTotalResponseBytes > 0
                && maximumTotalResponseBytes
                    <= Self.maximumTotalResponseBytes
        )
        self.loader = loader
        self.now = now
        self.refreshTimeout = refreshTimeout
        self.maximumTotalResponseBytes = maximumTotalResponseBytes
    }

    func fetchCurrentActivity(
        credential: String
    ) async throws -> SessionActivityCounts {
        try await withThrowingTaskGroup(
            of: SessionActivityCounts.self
        ) { group in
            group.addTask { [self] in
                try await performFetch(credential: credential)
            }
            group.addTask { [self] in
                try await Task.sleep(for: refreshTimeout)
                throw GitHubAgentTaskFetcherError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw GitHubAgentTaskFetcherError.transport
            }
            return result
        }
    }

    private func performFetch(
        credential: String
    ) async throws -> SessionActivityCounts {
        let budget = SessionActivityResponseBudget(
            maximumBytes: maximumTotalResponseBytes
        )
        var nextURL: URL? = Self.initialURL
        var visitedURLs: Set<String> = []
        var tasks: [TaskSummary] = []
        var tasksByID: [String: TaskSummary] = [:]
        var retryBeforeNextRequest: Date?

        while let pageURL = nextURL {
            try Task.checkCancellation()
            guard visitedURLs.count < Self.maximumPages else {
                throw GitHubAgentTaskFetcherError.tooManyPages
            }
            guard visitedURLs.insert(pageURL.absoluteString).inserted else {
                throw GitHubAgentTaskFetcherError.invalidPagination
            }

            let request = makeRequest(url: pageURL, credential: credential)
            let (data, httpResponse) = try await load(
                request: request,
                maximumBytes: Self.maximumResponseBytes,
                budget: budget
            )

            let page: TasksResponse
            do {
                page = try JSONDecoder().decode(TasksResponse.self, from: data)
            } catch {
                throw GitHubAgentTaskFetcherError.invalidPayload
            }

            for task in page.tasks {
                guard Self.isValidIdentifier(task.id),
                      ActivityState(rawValue: task.state) != nil,
                      task.sessionCount.map({ $0 >= 0 }) ?? true else {
                    throw GitHubAgentTaskFetcherError.invalidPayload
                }
                if let prior = tasksByID[task.id] {
                    guard prior.state == task.state,
                          prior.sessionCount == task.sessionCount else {
                        throw GitHubAgentTaskFetcherError.invalidPayload
                    }
                    continue
                }
                guard tasks.count < Self.maximumTasks else {
                    throw GitHubAgentTaskFetcherError.tooManyTasks
                }
                tasksByID[task.id] = task
                tasks.append(task)
            }

            nextURL = try nextPageURL(from: httpResponse)
            retryBeforeNextRequest = rateLimitHeadroomRetryDate(
                httpResponse
            )
            if nextURL != nil, let retryBeforeNextRequest {
                throw GitHubAgentTaskFetcherError.rateLimited(
                    retryAt: retryBeforeNextRequest
                )
            }
        }

        return try await fetchSessionCounts(
            tasks: tasks,
            credential: credential,
            budget: budget,
            retryBeforeNextRequest: retryBeforeNextRequest
        )
    }

    private func fetchSessionCounts(
        tasks: [TaskSummary],
        credential: String,
        budget: SessionActivityResponseBudget,
        retryBeforeNextRequest: Date?
    ) async throws -> SessionActivityCounts {
        let detailTasks = tasks.filter { $0.sessionCount != 1 }
        guard detailTasks.count <= Self.maximumTaskDetails else {
            throw GitHubAgentTaskFetcherError.tooManyTaskDetails
        }

        var sessionsByID: [String: ActivityState] = [:]
        var working = 0
        var waiting = 0
        var countedSessions = 0
        var detailRetryBeforeNextRequest = retryBeforeNextRequest

        for task in tasks where task.sessionCount == 1 {
            guard let state = ActivityState(rawValue: task.state) else {
                throw GitHubAgentTaskFetcherError.unsupportedSessionState
            }
            countedSessions += 1
            guard countedSessions <= Self.maximumSessions else {
                throw GitHubAgentTaskFetcherError.tooManySessions
            }
            if state.isWorking {
                working += 1
            } else if state.isWaiting {
                waiting += 1
            }
        }

        for task in detailTasks {
            if let detailRetryBeforeNextRequest {
                throw GitHubAgentTaskFetcherError.rateLimited(
                    retryAt: detailRetryBeforeNextRequest
                )
            }
            try Task.checkCancellation()
            let (detail, response) = try await fetchTaskDetail(
                taskID: task.id,
                expectedSessionCount: task.sessionCount,
                credential: credential,
                budget: budget
            )
            detailRetryBeforeNextRequest = rateLimitHeadroomRetryDate(
                response
            )
            for session in detail.sessions {
                guard Self.isValidIdentifier(session.id),
                      session.taskID == detail.id else {
                    throw GitHubAgentTaskFetcherError.invalidPayload
                }
                guard let state = ActivityState(rawValue: session.state) else {
                    throw GitHubAgentTaskFetcherError
                        .unsupportedSessionState
                }
                guard sessionsByID[session.id] == nil else {
                    throw GitHubAgentTaskFetcherError.invalidPayload
                }
                countedSessions += 1
                guard countedSessions <= Self.maximumSessions else {
                    throw GitHubAgentTaskFetcherError.tooManySessions
                }
                sessionsByID[session.id] = state
                if state.isWorking {
                    working += 1
                } else if state.isWaiting {
                    waiting += 1
                }
            }
        }

        return SessionActivityCounts(working: working, waiting: waiting)
    }

    private func fetchTaskDetail(
        taskID: String,
        expectedSessionCount: Int?,
        credential: String,
        budget: SessionActivityResponseBudget
    ) async throws -> (TaskDetail, HTTPURLResponse) {
        try Task.checkCancellation()
        let url = Self.detailURL(taskID: taskID)
        let (data, response) = try await load(
            request: makeRequest(url: url, credential: credential),
            maximumBytes: Self.maximumResponseBytes,
            budget: budget
        )
        let detail: TaskDetail
        do {
            detail = try JSONDecoder().decode(TaskDetail.self, from: data)
        } catch {
            throw GitHubAgentTaskFetcherError.invalidPayload
        }
        guard detail.id == taskID,
              detail.sessionCount == detail.sessions.count,
              expectedSessionCount.map({ $0 == detail.sessions.count })
                ?? true else {
            throw GitHubAgentTaskFetcherError.invalidPayload
        }
        return (detail, response)
    }

    private func load(
        request: URLRequest,
        maximumBytes: Int,
        budget: SessionActivityResponseBudget
    ) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let reservation = try await budget.reserve(upTo: maximumBytes)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await loader.data(
                for: request,
                maximumBytes: reservation
            )
        } catch is CancellationError {
            await budget.cancel(reservation: reservation)
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            await budget.cancel(reservation: reservation)
            throw CancellationError()
        } catch SessionActivityURLLoaderError.responseTooLarge {
            await budget.cancel(reservation: reservation)
            throw GitHubAgentTaskFetcherError.responseTooLarge
        } catch let error as GitHubAgentTaskFetcherError {
            await budget.cancel(reservation: reservation)
            throw error
        } catch {
            await budget.cancel(reservation: reservation)
            throw GitHubAgentTaskFetcherError.transport
        }

        guard data.count <= reservation else {
            await budget.cancel(reservation: reservation)
            throw GitHubAgentTaskFetcherError.responseTooLarge
        }
        await budget.finish(
            reservation: reservation,
            actualBytes: data.count
        )

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.url == request.url else {
            throw GitHubAgentTaskFetcherError.invalidResponse
        }
        try validateStatus(httpResponse, data: data)
        return (data, httpResponse)
    }

    private func validateStatus(
        _ response: HTTPURLResponse,
        data: Data
    ) throws {
        switch response.statusCode {
        case 200:
            return
        case 401:
            throw GitHubAgentTaskFetcherError.authenticationRequired
        case 403:
            let remaining = response.value(
                forHTTPHeaderField: "X-RateLimit-Remaining"
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            if remaining == "0" || response.value(
                forHTTPHeaderField: "Retry-After"
            ) != nil || responseIndicatesRateLimit(data) {
                throw GitHubAgentTaskFetcherError.rateLimited(
                    retryAt: rateLimitRetryDate(response)
                )
            }
            throw GitHubAgentTaskFetcherError.insufficientPermissions
        case 429:
            throw GitHubAgentTaskFetcherError.rateLimited(
                retryAt: rateLimitRetryDate(response)
            )
        default:
            throw GitHubAgentTaskFetcherError.httpStatus(
                response.statusCode
            )
        }
    }

    /// A completed final response is still useful at low remaining quota.
    /// Apply headroom only when exact counting requires another HTTP request.
    private func rateLimitHeadroomRetryDate(
        _ response: HTTPURLResponse
    ) -> Date? {
        guard let remainingValue = response.value(
            forHTTPHeaderField: "X-RateLimit-Remaining"
        )?.trimmingCharacters(in: .whitespacesAndNewlines),
              let remaining = Int(remainingValue),
              remaining < Self.minimumRateLimitHeadroom else {
            return nil
        }
        return rateLimitRetryDate(response)
    }

    private func rateLimitRetryDate(_ response: HTTPURLResponse) -> Date {
        let current = now()
        let candidate: Date
        if let retryValue = response.value(
            forHTTPHeaderField: "Retry-After"
        )?.trimmingCharacters(in: .whitespacesAndNewlines),
           let seconds = TimeInterval(retryValue), seconds.isFinite {
            candidate = current.addingTimeInterval(seconds)
        } else if let resetValue = response.value(
            forHTTPHeaderField: "X-RateLimit-Reset"
        )?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let epoch = TimeInterval(resetValue), epoch.isFinite {
            candidate = Date(timeIntervalSince1970: epoch)
        } else {
            candidate = current.addingTimeInterval(
                Self.defaultRateLimitDelay
            )
        }
        return min(
            max(
                candidate,
                current.addingTimeInterval(Self.minimumRateLimitDelay)
            ),
            current.addingTimeInterval(Self.maximumRateLimitDelay)
        )
    }

    private func makeRequest(
        url: URL,
        credential: String
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(
            "application/vnd.github+json",
            forHTTPHeaderField: "Accept"
        )
        request.setValue(
            "Bearer \(credential)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(
            Self.apiVersion,
            forHTTPHeaderField: "X-GitHub-Api-Version"
        )
        request.setValue(
            "AgentLimits-forked",
            forHTTPHeaderField: "User-Agent"
        )
        return request
    }

    /// GitHub secondary-rate-limit responses do not always include Retry-After.
    /// Inspect only the documented error fields and never propagate their text.
    private func responseIndicatesRateLimit(_ data: Data) -> Bool {
        guard let errorResponse = try? JSONDecoder().decode(
            ErrorResponse.self,
            from: data
        ) else {
            return false
        }
        return errorResponse.message?.localizedCaseInsensitiveContains(
            "rate limit"
        ) == true || errorResponse.documentationURL?
            .localizedCaseInsensitiveContains("rate-limit") == true
    }

    private func nextPageURL(
        from response: HTTPURLResponse
    ) throws -> URL? {
        guard let linkHeader = response.value(
            forHTTPHeaderField: "Link"
        ) else {
            return nil
        }

        var nextURLs: [URL] = []
        for rawLink in try splitLinkHeader(linkHeader) {
            let value = rawLink.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard value.first == "<",
                  let targetEnd = value.firstIndex(of: ">") else {
                throw GitHubAgentTaskFetcherError.invalidPagination
            }

            let parameters = value[value.index(after: targetEnd)...]
            guard relationIncludesNext(parameters) else {
                continue
            }

            let target = value[
                value.index(after: value.startIndex)..<targetEnd
            ]
            guard let url = URL(string: String(target)),
                  Self.isTrustedPaginationURL(url) else {
                throw GitHubAgentTaskFetcherError.invalidPagination
            }
            nextURLs.append(url)
        }

        guard nextURLs.count <= 1 else {
            throw GitHubAgentTaskFetcherError.invalidPagination
        }
        return nextURLs.first
    }

    /// A Link URL can legally contain a raw comma. Split only between link
    /// values, never inside angle brackets or a quoted parameter value.
    private func splitLinkHeader(_ header: String) throws -> [String] {
        var values: [String] = []
        var current = ""
        var insideTarget = false
        var insideQuote = false
        var escaped = false

        for character in header {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\" && insideQuote {
                current.append(character)
                escaped = true
                continue
            }
            if character == "\"" && !insideTarget {
                insideQuote.toggle()
            } else if character == "<" && !insideQuote {
                guard !insideTarget else {
                    throw GitHubAgentTaskFetcherError.invalidPagination
                }
                insideTarget = true
            } else if character == ">" && !insideQuote {
                guard insideTarget else {
                    throw GitHubAgentTaskFetcherError.invalidPagination
                }
                insideTarget = false
            }

            if character == "," && !insideTarget && !insideQuote {
                guard !current.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty else {
                    throw GitHubAgentTaskFetcherError.invalidPagination
                }
                values.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }

        guard !insideTarget, !insideQuote, !escaped,
              !current.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty else {
            throw GitHubAgentTaskFetcherError.invalidPagination
        }
        values.append(current)
        return values
    }

    private func relationIncludesNext(
        _ parameters: Substring
    ) -> Bool {
        for rawParameter in parameters.split(separator: ";") {
            let parameter = rawParameter.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let pieces = parameter.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard pieces.count == 2,
                  pieces[0].trimmingCharacters(
                    in: .whitespacesAndNewlines
                  ).lowercased() == "rel" else {
                continue
            }
            var relation = pieces[1].trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if relation.count >= 2,
               relation.first == "\"", relation.last == "\"" {
                relation.removeFirst()
                relation.removeLast()
            }
            if relation.split(whereSeparator: { $0.isWhitespace })
                .contains(where: { $0.lowercased() == "next" }) {
                return true
            }
        }
        return false
    }

    private static var initialURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = trustedHost
        components.path = trustedPath
        components.queryItems = [
            URLQueryItem(name: "per_page", value: "100"),
            URLQueryItem(name: "sort", value: "updated_at"),
            URLQueryItem(name: "direction", value: "desc"),
            URLQueryItem(name: "is_archived", value: "false")
        ]
        guard let url = components.url else {
            preconditionFailure("Invalid static GitHub Agent Tasks URL")
        }
        return url
    }

    private static func detailURL(taskID: String) -> URL {
        precondition(isValidIdentifier(taskID))
        let unreserved = CharacterSet(
            charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        guard let encodedTaskID = taskID.addingPercentEncoding(
            withAllowedCharacters: unreserved
        ) else {
            preconditionFailure("Invalid GitHub Agent Task identifier")
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = trustedHost
        components.percentEncodedPath = "\(trustedPath)/\(encodedTaskID)"
        guard let url = components.url else {
            preconditionFailure("Invalid GitHub Agent Task detail URL")
        }
        return url
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                && !CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
    }

    private static func isTrustedPaginationURL(_ url: URL) -> Bool {
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            return false
        }
        guard components.scheme?.lowercased() == "https"
            && components.host?.lowercased() == trustedHost
            && components.port == nil
            && components.user == nil
            && components.password == nil
            && components.path == trustedPath
            && components.fragment == nil else {
            return false
        }

        var queryValues: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard let value = item.value,
                  queryValues.updateValue(value, forKey: item.name) == nil else {
                return false
            }
        }
        guard queryValues["per_page"] == "100",
              queryValues["sort"] == "updated_at",
              queryValues["direction"] == "desc",
              queryValues["is_archived"] == "false",
              let pageValue = queryValues["page"],
              let page = Int(pageValue), page > 1,
              queryValues.count == 5 else {
            return false
        }
        return true
    }
}
