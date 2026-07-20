// MARK: - AppUpdateController.swift
// Sparkle アップデータのシングルトンラッパー。
// フォーク所有の配布経路が別途レビューされるまで updater は起動しない。

import Combine
import Sparkle

/// Enabling updates requires a reviewed source change, not mutable defaults or
/// an accidentally inherited Info.plist feed.
nonisolated enum ForkUpdatePolicy {
    static let allowsAutomaticUpdates = false
}

/// Sparkle の SPUStandardUpdaterController をラップし、SwiftUI へ状態を公開するコントローラ。
@MainActor
final class AppUpdateController: ObservableObject {

    static let shared = AppUpdateController()

    let updater: SPUUpdater

    /// Always false until a fork-owned feed and EdDSA trust path are reviewed.
    let isConfigured: Bool

    private let controller: SPUStandardUpdaterController

    /// アップデートチェックが現在実行可能か（Sparkle KVO）
    @Published var canCheckForUpdates: Bool

    /// 最終チェック日時（Sparkle KVO）
    @Published var lastUpdateCheckDate: Date?

    /// 起動時/定期チェックの有効フラグ
    @Published var automaticChecksEnabled: Bool

    private var cancellables = Set<AnyCancellable>()

    private init() {
        let isConfigured = ForkUpdatePolicy.allowsAutomaticUpdates

        self.isConfigured = isConfigured
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        updater = controller.updater
        // Trust only fork build configuration, never a persisted feed override.
        if !AppRuntimeEnvironment.isUITesting {
            updater.clearFeedURLFromUserDefaults()
        }
        if isConfigured {
            controller.startUpdater()
        }
        canCheckForUpdates = isConfigured && updater.canCheckForUpdates
        lastUpdateCheckDate = updater.lastUpdateCheckDate
        automaticChecksEnabled = isConfigured && updater.automaticallyChecksForUpdates

        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .map { isConfigured && $0 }
            .assign(to: &$canCheckForUpdates)

        updater.publisher(for: \.lastUpdateCheckDate)
            .receive(on: DispatchQueue.main)
            .assign(to: &$lastUpdateCheckDate)
    }

    /// 手動アップデートチェックを開始する。
    func checkForUpdates() {
        guard isConfigured else { return }
        controller.checkForUpdates(nil)
    }

    /// 起動時/定期チェックの有効/無効を切り替える。
    func setAutomaticChecksEnabled(_ enabled: Bool) {
        guard isConfigured else {
            automaticChecksEnabled = false
            return
        }
        updater.automaticallyChecksForUpdates = enabled
        automaticChecksEnabled = enabled
    }
}
