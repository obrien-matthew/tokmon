import Foundation
import os

/// Structured diagnostics for the installed app, where `print` goes
/// nowhere: a menu bar accessory launched by Finder or launchd has no
/// attached stdout. Read with
///
///     log stream --predicate 'subsystem == "tokmon"' --style compact
///     log show --predicate 'subsystem == "tokmon"' --last 30m --style compact
///
/// Never log token material — only presence, length, and expiry.
enum Diag {
    static let refresh = Logger(subsystem: "tokmon", category: "refresh")
    static let claude = Logger(subsystem: "tokmon", category: "claude")
}
