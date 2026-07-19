// MARK: - AppUpdateController.swift
// Sparkle アップデータのシングルトンラッパー。
// フィード URL と公開鍵が両方設定されている配布ビルドでのみ updater を起動する。

import Combine
import Sparkle

/// Sparkle の SPUStandardUpdaterController をラップし、SwiftUI へ状態を公開するコントローラ。
@MainActor
final class AppUpdateController: ObservableObject {

    static let shared = AppUpdateController()

    let updater: SPUUpdater

    /// Fork-owned feed and EdDSA public key are both present.
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
        let bundle = Bundle.main
        let feedURL = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        let isConfigured = Self.hasValue(feedURL) && Self.hasValue(publicKey)

        self.isConfigured = isConfigured
        controller = SPUStandardUpdaterController(
            startingUpdater: isConfigured,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        updater = controller.updater
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

    private static func hasValue(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
