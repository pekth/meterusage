import Foundation

/// Observed balance decreases, not a provider billing ledger. Top-ups and
/// spending between two polls can cancel each other out.
struct CodexCreditUsage: Codable, Equatable {
    var usedCredits: Double = 0
    var since: Date
    var lastBalance: Double?
    var capturedAt: Date
}

struct CodexCreditTracker: Codable, Equatable {
    var accounts: [String: CodexCreditUsage] = [:]

    mutating func record(_ credits: CreditBalance?, for slot: ProviderSlot, at date: Date) {
        guard slot.provider == .codex else { return }
        if let previous = accounts[slot.key], date <= previous.capturedAt { return }
        guard let credits, credits.unit == .credits, !credits.unlimited,
              credits.balance.isFinite, credits.balance >= 0 else {
            pause(key: slot.key)
            return
        }
        var usage = accounts[slot.key] ?? CodexCreditUsage(since: date, capturedAt: date)
        if let previous = usage.lastBalance {
            usage.usedCredits += max(0, previous - credits.balance)
        }
        usage.lastBalance = credits.balance
        usage.capturedAt = date
        accounts[slot.key] = usage
    }

    mutating func pause(key: String? = nil) {
        for account in Array(accounts.keys) where key == nil || account == key {
            accounts[account]?.lastBalance = nil
        }
    }
}
