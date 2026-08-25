import Foundation

struct UsageInfo: Sendable {
  let utilization: Double
  let resetsAt: Date?
}

struct Credits: Sendable {
  let used: Decimal
  let limit: Decimal
  let percent: Double
}

struct Usage: Sendable {
  /// Utilization value shown in the menu bar
  /// Defaults to five hour, fall back to credits
  let utilization: Double

  let fiveHour: UsageInfo?
  let sevenDay: UsageInfo?
  let credits: Credits?
}

enum FetchError: Error, LocalizedError {
  case noToken
  case rateLimited
  case authFailed
  case badResponse(String)

  var errorDescription: String? {
    switch self {
    case .noToken: "Could not read Claude Code credentials from keychain"
    case .rateLimited: "Rate limited — will retry shortly"
    case .authFailed: "Authentication failed — try logging in again with `claude`"
    case .badResponse(let body): "Unexpected API response: \(body)"
    }
  }
}

struct UsageFetcher: Sendable {
  private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

  func fetch() async throws -> Usage {
    let token = try bearerToken()

    var request = URLRequest(url: Self.usageURL)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

    let (data, _) = try await URLSession.shared.data(for: request)

    if let apiError = try? JSONDecoder().decode(ApiError.self, from: data) {
      switch apiError.error.type {
      case "rate_limit_error": throw FetchError.rateLimited
      case "authentication_error": throw FetchError.authFailed
      default: throw FetchError.badResponse(apiError.error.message)
      }
    }

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .custom { dec in
      let s = try dec.singleValueContainer().decode(String.self)
      if let d = Self.isoFractional.date(from: s) ?? Self.iso.date(from: s) { return d }
      throw DecodingError.dataCorruptedError(
        in: try dec.singleValueContainer(), debugDescription: "Cannot decode date: \(s)")
    }

    guard let raw = try? decoder.decode(RawUsage.self, from: data) else {
      throw FetchError.badResponse(String(decoding: data, as: UTF8.self))
    }

    let fiveHour = raw.fiveHour.map { UsageInfo(utilization: $0.utilization, resetsAt: $0.resetsAt) }
    let sevenDay = raw.sevenDay.map { UsageInfo(utilization: $0.utilization, resetsAt: $0.resetsAt) }
    let credits = raw.spend.flatMap { spend -> Credits? in
      guard let used = spend.used, let limit = spend.limit, let percent = spend.percent else {
        return nil
      }
      return Credits(used: used.value, limit: limit.value, percent: percent)
    }

    guard let utilization = fiveHour?.utilization ?? credits?.percent ?? sevenDay?.utilization
    else {
      throw FetchError.badResponse(String(decoding: data, as: UTF8.self))
    }

    return Usage(utilization: utilization, fiveHour: fiveHour, sevenDay: sevenDay, credits: credits)
  }

  private func bearerToken() throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
      "-c",
      #"security find-generic-password -s "Claude Code-credentials" -w | jq -r '.claudeAiOauth.accessToken'"#,
    ]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()

    let token = String(
      decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
    ).trimmingCharacters(in: .whitespacesAndNewlines)

    guard !token.isEmpty, token != "null" else { throw FetchError.noToken }
    return token
  }

  nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()

  nonisolated(unsafe) private static let iso = ISO8601DateFormatter()
}

private struct ApiError: Decodable {
  struct Detail: Decodable {
    let type: String
    let message: String
  }
  let error: Detail
}

private struct RawUsage: Decodable {
  let fiveHour: RawUsageInfo?
  let sevenDay: RawUsageInfo?
  let spend: RawSpend?
}

private struct RawUsageInfo: Decodable {
  let utilization: Double
  let resetsAt: Date?
}

private struct RawSpend: Decodable {
  let used: RawAmount?
  let limit: RawAmount?
  let percent: Double?
}

private struct RawAmount: Decodable {
  let amountMinor: Int
  let exponent: Int

  var value: Decimal { Decimal(amountMinor) / pow(10, exponent) }
}
