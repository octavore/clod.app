import Foundation
import Observation

@MainActor
@Observable
final class UsageModel {
  private(set) var usage: Usage?
  private(set) var lastScan: Date?
  private(set) var error: String?

  private let fetcher = UsageFetcher()
  private var refreshTask: Task<Void, Never>?

  private static let refreshInterval: Double = 300

  func start() {
    refreshTask = Task { [weak self] in
      while !Task.isCancelled {
        _ = await self?.refresh() ?? false
        try? await Task.sleep(for: .seconds(Self.refreshInterval))
      }
    }
  }

  func refreshIfStale(threshold: Double = 30) {
    guard lastScan.map({ Date().timeIntervalSince($0) >= threshold }) ?? true else {
      print("[\(Date().formatted(.iso8601))] Skipping refresh — data is fresh")
      return
    }
    Task { await refresh() }
  }

  func refreshNow() {
    Task { await refresh() }
  }

  @discardableResult
  private func refresh() async -> Bool {
    let fetcher = self.fetcher
    print("[\(Date().formatted(.iso8601))] Fetching usage data…")
    do {
      let result = try await Task.detached(priority: .utility) {
        try await fetcher.fetch()
      }.value
      print("[\(Date().formatted(.iso8601))] Fetch succeeded")
      usage = result
      error = nil
      lastScan = Date()
      return true
    } catch FetchError.rateLimited {
      print("[\(Date().formatted(.iso8601))] Rate limited — retrying in 60s")
      error = FetchError.rateLimited.localizedDescription
      lastScan = Date()
      try? await Task.sleep(for: .seconds(60))
      return await refresh()
    } catch {
      print("[\(Date().formatted(.iso8601))] Fetch failed: \(error)")
      self.error = error.localizedDescription
      lastScan = Date()
      return false
    }
  }

  var menuBarTitle: String {
    guard let usage else { return "…" }
    let percent = usage.utilization.percent
    return error == nil ? percent : "(\(percent))"
  }
}
