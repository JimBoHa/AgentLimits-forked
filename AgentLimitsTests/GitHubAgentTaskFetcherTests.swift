import Foundation
import XCTest
@testable import AgentLimits

@MainActor
final class GitHubAgentTaskFetcherTests: XCTestCase {
    func testPaginatesAndCountsExactNonterminalSessions() async throws {
        let secondURL = pageURL(2)
        let loader = QueueSessionActivityURLLoader(stubs: [
            .response(
                listPayload([
                    .init(id: "single-running", state: "in_progress", sessionCount: 1),
                    .init(id: "multi", state: "completed", sessionCount: 3),
                    .init(id: "single-wait", state: "queued", sessionCount: 1)
                ]),
                makeResponse(
                    url: initialURL,
                    link: "<\(secondURL.absoluteString)>; rel=\"next\""
                )
            ),
            .response(
                listPayload([
                    .init(id: "multi", state: "completed", sessionCount: 3),
                    .init(id: "single-idle", state: "idle", sessionCount: 1),
                    .init(id: "zero", state: "completed", sessionCount: 0)
                ]),
                makeResponse(url: secondURL)
            ),
            .response(
                detailPayload(
                    taskID: "multi",
                    sessionCount: 3,
                    sessions: [
                        .init(id: "queued", taskID: "multi", state: "queued"),
                        .init(id: "running", taskID: "multi", state: "in_progress"),
                        .init(id: "done", taskID: "multi", state: "completed")
                    ]
                ),
                makeResponse(url: detailURL("multi"))
            ),
            .response(
                detailPayload(taskID: "zero", sessionCount: 0, sessions: []),
                makeResponse(url: detailURL("zero"))
            )
        ])

        let counts = try await GitHubAgentTaskFetcher(loader: loader)
            .fetchCurrentActivity(credential: "github-test-token")

        XCTAssertEqual(counts.working, 2)
        XCTAssertEqual(counts.waiting, 3)
        XCTAssertEqual(counts.open, 5)
        let requests = await loader.requests
        XCTAssertEqual(requests.map(\.url), [
            initialURL,
            secondURL,
            detailURL("multi"),
            detailURL("zero")
        ])
        for request in requests {
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer github-test-token"
            )
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Accept"),
                "application/vnd.github+json"
            )
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "X-GitHub-Api-Version"),
                "2026-03-10"
            )
        }
    }

    func testTerminalLatestTaskStillCountsOlderOpenSession() async throws {
        let loader = QueueSessionActivityURLLoader(stubs: [
            .response(
                listPayload([
                    .init(id: "restarted", state: "completed", sessionCount: 2)
                ]),
                makeResponse(url: initialURL)
            ),
            .response(
                detailPayload(
                    taskID: "restarted",
                    sessionCount: 2,
                    sessions: [
                        .init(id: "older", taskID: "restarted", state: "in_progress"),
                        .init(id: "latest", taskID: "restarted", state: "completed")
                    ]
                ),
                makeResponse(url: detailURL("restarted"))
            )
        ])

        let counts = try await GitHubAgentTaskFetcher(loader: loader)
            .fetchCurrentActivity(credential: "token")

        XCTAssertEqual(counts.working, 1)
        XCTAssertEqual(counts.waiting, 0)
    }

    func testSingleSessionTaskUsesDerivedStateWithoutDetailRequest()
        async throws {
        let loader = QueueSessionActivityURLLoader(stubs: [
            .response(
                listPayload([
                    .init(id: "queued", state: "queued", sessionCount: 1),
                    .init(id: "running", state: "in_progress", sessionCount: 1),
                    .init(id: "done", state: "completed", sessionCount: 1)
                ]),
                makeResponse(url: initialURL)
            )
        ])

        let counts = try await GitHubAgentTaskFetcher(loader: loader)
            .fetchCurrentActivity(credential: "token")

        XCTAssertEqual(counts.working, 1)
        XCTAssertEqual(counts.waiting, 1)
        let requestCount = await loader.requests.count
        XCTAssertEqual(requestCount, 1)
    }

    func testMissingSessionCountFetchesDetail() async throws {
        let loader = QueueSessionActivityURLLoader(stubs: [
            .response(
                listPayload([.init(id: "missing", state: "idle", sessionCount: nil)]),
                makeResponse(url: initialURL)
            ),
            .response(
                detailPayload(
                    taskID: "missing",
                    sessionCount: 1,
                    sessions: [
                        .init(
                            id: "waiting",
                            taskID: "missing",
                            state: "waiting_for_user"
                        )
                    ]
                ),
                makeResponse(url: detailURL("missing"))
            )
        ])

        let counts = try await GitHubAgentTaskFetcher(loader: loader)
            .fetchCurrentActivity(credential: "token")

        XCTAssertEqual(counts.open, 1)
        let requestCount = await loader.requests.count
        XCTAssertEqual(requestCount, 2)
    }

    func testMismatchedSessionCountsRejectEntireObservation() async {
        let loader = QueueSessionActivityURLLoader(stubs: [
            .response(
                listPayload([.init(id: "task", state: "idle", sessionCount: 2)]),
                makeResponse(url: initialURL)
            ),
            .response(
                detailPayload(
                    taskID: "task",
                    sessionCount: 1,
                    sessions: [.init(id: "only", taskID: "task", state: "idle")]
                ),
                makeResponse(url: detailURL("task"))
            )
        ])

        await assertError(.invalidPayload, loader: loader)
    }

    func testDuplicateSessionIDsRejectEntireObservation() async {
        for secondState in ["idle", "in_progress"] {
            let loader = QueueSessionActivityURLLoader(stubs: [
                .response(
                    listPayload([
                        .init(id: "task", state: "idle", sessionCount: 2)
                    ]),
                    makeResponse(url: initialURL)
                ),
                .response(
                    detailPayload(
                        taskID: "task",
                        sessionCount: 2,
                        sessions: [
                            .init(
                                id: "same",
                                taskID: "task",
                                state: "idle"
                            ),
                            .init(
                                id: "same",
                                taskID: "task",
                                state: secondState
                            )
                        ]
                    ),
                    makeResponse(url: detailURL("task"))
                )
            ])

            await assertError(.invalidPayload, loader: loader)
        }
    }

    func testMissingRequiredDetailFieldsRejectEntireObservation() async {
        let invalidDetails = [
            detailPayload(
                taskID: "task",
                sessionCount: nil,
                sessions: [
                    .init(id: "one", taskID: "task", state: "idle")
                ]
            ),
            detailPayload(
                taskID: "task",
                sessionCount: 1,
                sessions: [
                    .init(id: "one", taskID: nil, state: "idle")
                ]
            )
        ]

        for detail in invalidDetails {
            let loader = QueueSessionActivityURLLoader(stubs: [
                .response(
                    listPayload([
                        .init(id: "task", state: "idle", sessionCount: nil)
                    ]),
                    makeResponse(url: initialURL)
                ),
                .response(detail, makeResponse(url: detailURL("task")))
            ])
            await assertError(.invalidPayload, loader: loader)
        }
    }

    func testUnknownSessionStateAndDetailIDMismatchFailClosed() async {
        let cases: [(Data, GitHubAgentTaskFetcherError)] = [
            (
                detailPayload(
                    taskID: "task",
                    sessionCount: 1,
                    sessions: [.init(id: "one", taskID: "task", state: "new_state")]
                ),
                .unsupportedSessionState
            ),
            (
                detailPayload(taskID: "other", sessionCount: 0, sessions: []),
                .invalidPayload
            )
        ]

        for (detail, expectedError) in cases {
            let loader = QueueSessionActivityURLLoader(stubs: [
                .response(
                    listPayload([.init(id: "task", state: "idle", sessionCount: nil)]),
                    makeResponse(url: initialURL)
                ),
                .response(detail, makeResponse(url: detailURL("task")))
            ])
            await assertError(expectedError, loader: loader)
        }
    }

    func testTaskIdentifierIsEncodedAsOnePathSegment() async throws {
        let taskID = "task/with?percent%and雪"
        let loader = QueueSessionActivityURLLoader(stubs: [
            .response(
                listPayload([.init(id: taskID, state: "completed", sessionCount: 0)]),
                makeResponse(url: initialURL)
            ),
            .response(
                detailPayload(taskID: taskID, sessionCount: 0, sessions: []),
                makeResponse(url: detailURL(taskID))
            )
        ])

        _ = try await GitHubAgentTaskFetcher(loader: loader)
            .fetchCurrentActivity(credential: "token")

        let lastRequestURL = await loader.requests.last?.url
        let requestURL = try XCTUnwrap(lastRequestURL)
        let encodedPath = URLComponents(
            url: requestURL,
            resolvingAgainstBaseURL: false
        )?.percentEncodedPath
        let expectedEncodedPath = URLComponents(
            url: detailURL(taskID),
            resolvingAgainstBaseURL: false
        )?.percentEncodedPath
        XCTAssertEqual(encodedPath, expectedEncodedPath)
        XCTAssertTrue(requestURL.absoluteString.contains("%2F"))
        XCTAssertTrue(requestURL.absoluteString.contains("%3F"))
        XCTAssertTrue(requestURL.absoluteString.contains("%25"))
    }

    func testAuthenticationFailureDoesNotExposeSecrets() async {
        let loader = QueueSessionActivityURLLoader(stubs: [
            .response(
                Data("secret response body".utf8),
                makeResponse(url: initialURL, statusCode: 401)
            )
        ])

        do {
            _ = try await GitHubAgentTaskFetcher(loader: loader)
                .fetchCurrentActivity(credential: "credential-must-not-escape")
            XCTFail("Expected authentication failure")
        } catch {
            XCTAssertEqual(
                error as? GitHubAgentTaskFetcherError,
                .authenticationRequired
            )
            let description = String(describing: error)
            XCTAssertFalse(description.contains("credential-must-not-escape"))
            XCTAssertFalse(description.contains("secret response body"))
        }
    }

    func testForbiddenWithoutRateLimitSignalsReportsPermissions() async {
        let loader = QueueSessionActivityURLLoader(stubs: [
            .response(
                Data(),
                makeResponse(url: initialURL, statusCode: 403)
            )
        ])

        await assertError(.insufficientPermissions, loader: loader)
    }

    func testRateLimitCarriesClampedRetryDeadline() async {
        let current = Date(timeIntervalSince1970: 1_000)
        let loader = QueueSessionActivityURLLoader(stubs: [
            .response(
                Data(),
                makeResponse(
                    url: initialURL,
                    statusCode: 429,
                    headers: ["Retry-After": "120"]
                )
            )
        ])

        do {
            _ = try await GitHubAgentTaskFetcher(
                loader: loader,
                now: { current }
            ).fetchCurrentActivity(credential: "token")
            XCTFail("Expected rate limit")
        } catch let error as GitHubAgentTaskFetcherError {
            guard case .rateLimited(let retryAt) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(retryAt, current.addingTimeInterval(120))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFinalSuccessfulResponseUsesExactResultAtLowHeadroom()
        async throws {
        let current = Date(timeIntervalSince1970: 2_000)
        let loader = QueueSessionActivityURLLoader(stubs: [
            .response(
                listPayload([]),
                makeResponse(
                    url: initialURL,
                    headers: [
                        "X-RateLimit-Remaining": "99",
                        "X-RateLimit-Reset": "2600"
                    ]
                )
            )
        ])

        let counts = try await GitHubAgentTaskFetcher(
            loader: loader,
            now: { current }
        ).fetchCurrentActivity(credential: "token")

        XCTAssertEqual(counts.open, 0)
        let requestCount = await loader.requests.count
        XCTAssertEqual(requestCount, 1)
    }

    func testLowRateLimitHeadroomStopsBeforeNextPage() async {
        let current = Date(timeIntervalSince1970: 2_000)
        let secondURL = pageURL(2)
        let loader = QueueSessionActivityURLLoader(stubs: [
            .response(
                listPayload([]),
                makeResponse(
                    url: initialURL,
                    link: "<\(secondURL.absoluteString)>; rel=next",
                    headers: [
                        "X-RateLimit-Remaining": "99",
                        "X-RateLimit-Reset": "2600"
                    ]
                )
            )
        ])

        await assertRateLimitHeadroom(
            loader: loader,
            current: current
        )
        let requestCount = await loader.requests.count
        XCTAssertEqual(requestCount, 1)
    }

    func testLowRateLimitHeadroomStopsBeforeTaskDetail() async {
        let current = Date(timeIntervalSince1970: 2_000)
        let loader = QueueSessionActivityURLLoader(stubs: [
            .response(
                listPayload([
                    .init(id: "task", state: "in_progress", sessionCount: 2)
                ]),
                makeResponse(
                    url: initialURL,
                    headers: [
                        "X-RateLimit-Remaining": "99",
                        "X-RateLimit-Reset": "2600"
                    ]
                )
            )
        ])

        await assertRateLimitHeadroom(
            loader: loader,
            current: current
        )
        let requestCount = await loader.requests.count
        XCTAssertEqual(requestCount, 1)
    }

    func testFinalTaskDetailUsesExactResultAtLowHeadroom()
        async throws {
        let loader = QueueSessionActivityURLLoader(stubs: [
            .response(
                listPayload([
                    .init(id: "task", state: "completed", sessionCount: 2)
                ]),
                makeResponse(url: initialURL)
            ),
            .response(
                detailPayload(
                    taskID: "task",
                    sessionCount: 2,
                    sessions: [
                        .init(id: "working", taskID: "task", state: "in_progress"),
                        .init(id: "done", taskID: "task", state: "completed")
                    ]
                ),
                makeResponse(
                    url: detailURL("task"),
                    headers: ["X-RateLimit-Remaining": "99"]
                )
            )
        ])

        let counts = try await GitHubAgentTaskFetcher(loader: loader)
            .fetchCurrentActivity(credential: "token")

        XCTAssertEqual(counts.working, 1)
        XCTAssertEqual(counts.waiting, 0)
        let requestCount = await loader.requests.count
        XCTAssertEqual(requestCount, 2)
    }

    func testUntrustedAndSemanticallyInvalidPaginationLinksAreRejected()
        async {
        let links = [
            "<https://attacker.invalid/steal>; rel=\"next\"",
            "<https://api.github.com/agents/tasks?page=2>; rel=\"next\"",
            "<https://api.github.com/agents/tasks?per_page=100&sort=updated_at&direction=desc&is_archived=true&page=2>; rel=\"next\""
        ]

        for link in links {
            let loader = QueueSessionActivityURLLoader(stubs: [
                .response(
                    listPayload([]),
                    makeResponse(url: initialURL, link: link)
                )
            ])
            await assertError(.invalidPagination, loader: loader)
            let requestCount = await loader.requests.count
            XCTAssertEqual(requestCount, 1)
        }
    }

    func testPaginationCycleIsRejected() async {
        let secondURL = pageURL(2)
        let loader = QueueSessionActivityURLLoader(stubs: [
            .response(
                listPayload([]),
                makeResponse(
                    url: initialURL,
                    link: "<\(secondURL.absoluteString)>; rel=next"
                )
            ),
            .response(
                listPayload([]),
                makeResponse(
                    url: secondURL,
                    link: "<\(secondURL.absoluteString)>; rel=next"
                )
            )
        ])

        await assertError(.invalidPagination, loader: loader)
    }

    func testPageAndTaskCapsRejectPartialCounts() async {
        var pageStubs: [QueueSessionActivityURLLoader.Stub] = []
        for page in 1...5 {
            let url = page == 1 ? initialURL : pageURL(page)
            let next = pageURL(page + 1)
            pageStubs.append(.response(
                listPayload([]),
                makeResponse(
                    url: url,
                    link: "<\(next.absoluteString)>; rel=next"
                )
            ))
        }
        await assertError(
            .tooManyPages,
            loader: QueueSessionActivityURLLoader(stubs: pageStubs)
        )

        let tooManyTasks = (0...500).map {
            TaskStub(id: "task-\($0)", state: "completed", sessionCount: 1)
        }
        await assertError(
            .tooManyTasks,
            loader: QueueSessionActivityURLLoader(stubs: [
                .response(listPayload(tooManyTasks), makeResponse(url: initialURL))
            ])
        )
    }

    func testDetailRequestCapRejectsUnboundedHistoryScan() async {
        let tasks = (0...100).map {
            TaskStub(id: "task-\($0)", state: "completed", sessionCount: 2)
        }
        let loader = QueueSessionActivityURLLoader(stubs: [
            .response(listPayload(tasks), makeResponse(url: initialURL))
        ])

        await assertError(.tooManyTaskDetails, loader: loader)
        let requestCount = await loader.requests.count
        XCTAssertEqual(requestCount, 1)
    }

    func testCumulativeResponseBudgetRejectsLaterResponse() async {
        let list = listPayload([
            .init(id: "task", state: "completed", sessionCount: 0)
        ])
        let detail = detailPayload(
            taskID: "task",
            sessionCount: 0,
            sessions: []
        )
        let loader = QueueSessionActivityURLLoader(stubs: [
            .response(list, makeResponse(url: initialURL)),
            .response(detail, makeResponse(url: detailURL("task")))
        ])
        let budget = list.count + detail.count - 1

        do {
            _ = try await GitHubAgentTaskFetcher(
                loader: loader,
                maximumTotalResponseBytes: budget
            ).fetchCurrentActivity(credential: "token")
            XCTFail("Expected cumulative response rejection")
        } catch {
            XCTAssertEqual(
                error as? GitHubAgentTaskFetcherError,
                .responseTooLarge
            )
        }
    }

    func testTransportCancellationAndTimeoutStaySanitized() async {
        let transport = QueueSessionActivityURLLoader(stubs: [.transportFailure])
        await assertError(.transport, loader: transport)

        do {
            _ = try await GitHubAgentTaskFetcher(
                loader: QueueSessionActivityURLLoader(stubs: [.cancelled])
            ).fetchCurrentActivity(credential: "token")
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        let timeoutLoader = QueueSessionActivityURLLoader(stubs: [.never])
        do {
            _ = try await GitHubAgentTaskFetcher(
                loader: timeoutLoader,
                refreshTimeout: .milliseconds(10)
            ).fetchCurrentActivity(credential: "token")
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? GitHubAgentTaskFetcherError, .timedOut)
        }
    }

    func testOversizedResponseIsRejectedBeforeDecoding() async {
        let loader = QueueSessionActivityURLLoader(stubs: [
            .response(
                Data(repeating: 0x61, count: 4_194_305),
                makeResponse(url: initialURL)
            )
        ])

        await assertError(.responseTooLarge, loader: loader)
    }

    func testBoundedLoaderAcceptsExactLimitAndRejectsOverflow()
        async throws {
        let loader = makeBoundedLoader()
        let exactURL = URL(string: "https://loader.test/exact")!
        let (data, response) = try await loader.data(
            for: URLRequest(url: exactURL),
            maximumBytes: 6
        )
        XCTAssertEqual(data, Data("abcdef".utf8))
        XCTAssertEqual(response.url, exactURL)

        for path in ["overflow", "expected-overflow"] {
            do {
                _ = try await loader.data(
                    for: URLRequest(
                        url: URL(string: "https://loader.test/\(path)")!
                    ),
                    maximumBytes: 6
                )
                XCTFail("Expected bounded loader rejection for \(path)")
            } catch {
                XCTAssertFalse(error is CancellationError)
            }
        }
    }

    func testBoundedLoaderMultiplexesConcurrentRequests() async throws {
        let loader = makeBoundedLoader()

        let results = try await withThrowingTaskGroup(of: Data.self) { group in
            for index in 0..<8 {
                group.addTask {
                    let url = URL(
                        string: "https://loader.test/concurrent/\(index)"
                    )!
                    return try await loader.data(
                        for: URLRequest(url: url),
                        maximumBytes: 6
                    ).0
                }
            }
            var values: [Data] = []
            for try await value in group {
                values.append(value)
            }
            return values
        }

        XCTAssertEqual(results.count, 8)
        XCTAssertTrue(results.allSatisfy { $0 == Data("abcdef".utf8) })
    }

    func testBoundedLoaderCancellationResumesExactlyOnce() async {
        let loader = makeBoundedLoader()
        let load = Task {
            try await loader.data(
                for: URLRequest(
                    url: URL(string: "https://loader.test/never")!
                ),
                maximumBytes: 6
            )
        }
        await Task.yield()
        load.cancel()

        do {
            _ = try await load.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testRedirectDelegateRefusesForwardingRequest() {
        let delegate = SessionActivityRedirectRejectingDelegate()
        let task = URLSession.shared.dataTask(with: initialURL)
        let response = makeResponse(url: initialURL, statusCode: 302)
        var forwardedRequest: URLRequest?

        delegate.urlSession(
            .shared,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(
                url: URL(string: "https://attacker.invalid/steal")!
            ),
            completionHandler: { forwardedRequest = $0 }
        )

        XCTAssertNil(forwardedRequest)
        task.cancel()
    }

    private func makeBoundedLoader() -> SessionActivityURLSessionLoader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedLoaderURLProtocol.self]
        return SessionActivityURLSessionLoader(configuration: configuration)
    }

    private func assertError(
        _ expected: GitHubAgentTaskFetcherError,
        loader: QueueSessionActivityURLLoader,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await GitHubAgentTaskFetcher(loader: loader)
                .fetchCurrentActivity(credential: "private-token")
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? GitHubAgentTaskFetcherError,
                expected,
                file: file,
                line: line
            )
            XCTAssertFalse(
                String(describing: error).contains("private-token"),
                file: file,
                line: line
            )
        }
    }

    private func assertRateLimitHeadroom(
        loader: QueueSessionActivityURLLoader,
        current: Date,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await GitHubAgentTaskFetcher(
                loader: loader,
                now: { current }
            ).fetchCurrentActivity(credential: "token")
            XCTFail(
                "Expected rate-limit headroom protection",
                file: file,
                line: line
            )
        } catch let error as GitHubAgentTaskFetcherError {
            guard case .rateLimited(let retryAt) = error else {
                return XCTFail(
                    "Unexpected error: \(error)",
                    file: file,
                    line: line
                )
            }
            XCTAssertEqual(
                retryAt,
                Date(timeIntervalSince1970: 2_600),
                file: file,
                line: line
            )
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private var initialURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/agents/tasks"
        components.queryItems = [
            URLQueryItem(name: "per_page", value: "100"),
            URLQueryItem(name: "sort", value: "updated_at"),
            URLQueryItem(name: "direction", value: "desc"),
            URLQueryItem(name: "is_archived", value: "false")
        ]
        return components.url!
    }

    private func pageURL(_ page: Int) -> URL {
        var components = URLComponents(
            url: initialURL,
            resolvingAgainstBaseURL: false
        )!
        components.queryItems?.append(
            URLQueryItem(name: "page", value: String(page))
        )
        return components.url!
    }

    private func detailURL(_ taskID: String) -> URL {
        let unreserved = CharacterSet(
            charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        let encoded = taskID.addingPercentEncoding(
            withAllowedCharacters: unreserved
        )!
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.percentEncodedPath = "/agents/tasks/\(encoded)"
        return components.url!
    }

    private func makeResponse(
        url: URL,
        statusCode: Int = 200,
        link: String? = nil,
        headers: [String: String] = [:]
    ) -> HTTPURLResponse {
        var responseHeaders = headers
        if let link { responseHeaders["Link"] = link }
        return HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: responseHeaders
        )!
    }

    private func listPayload(_ tasks: [TaskStub]) -> Data {
        let object: [String: Any] = [
            "tasks": tasks.map { task in
                var value: [String: Any] = [
                    "id": task.id,
                    "state": task.state
                ]
                if let sessionCount = task.sessionCount {
                    value["session_count"] = sessionCount
                }
                return value
            }
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func detailPayload(
        taskID: String,
        sessionCount: Int?,
        sessions: [SessionStub]
    ) -> Data {
        var object: [String: Any] = [
            "id": taskID,
            "sessions": sessions.map { session in
                var value: [String: Any] = [
                    "id": session.id,
                    "state": session.state
                ]
                if let sessionTaskID = session.taskID {
                    value["task_id"] = sessionTaskID
                }
                return value
            }
        ]
        if let sessionCount { object["session_count"] = sessionCount }
        return try! JSONSerialization.data(withJSONObject: object)
    }
}

nonisolated private final class BoundedLoaderURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "loader.test"
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if url.path == "/never" { return }

        let expectedOverflow = url.path == "/expected-overflow"
        let headers = expectedOverflow ? ["Content-Length": "7"] : nil
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )

        if expectedOverflow {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didLoad: Data("abc".utf8))
        client?.urlProtocol(
            self,
            didLoad: Data(
                (url.path == "/overflow" ? "defg" : "def").utf8
            )
        )
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct TaskStub {
    let id: String
    let state: String
    let sessionCount: Int?
}

private struct SessionStub {
    let id: String
    let taskID: String?
    let state: String
}

private actor QueueSessionActivityURLLoader: SessionActivityURLLoading {
    enum Stub {
        case response(Data, URLResponse)
        case transportFailure
        case cancelled
        case never
    }

    private var stubs: [Stub]
    private(set) var requests: [URLRequest] = []
    private(set) var maximumByteCounts: [Int] = []

    init(stubs: [Stub]) {
        self.stubs = stubs
    }

    func data(
        for request: URLRequest,
        maximumBytes: Int
    ) async throws -> (Data, URLResponse) {
        requests.append(request)
        maximumByteCounts.append(maximumBytes)
        guard !stubs.isEmpty else { throw URLError(.badServerResponse) }
        switch stubs.removeFirst() {
        case .response(let data, let response):
            return (data, response)
        case .transportFailure:
            throw URLError(.notConnectedToInternet)
        case .cancelled:
            throw URLError(.cancelled)
        case .never:
            try await Task.sleep(for: .seconds(3_600))
            throw URLError(.timedOut)
        }
    }
}
