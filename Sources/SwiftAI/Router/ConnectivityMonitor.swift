// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Network

/// Snapshot of current network connectivity
public struct ConnectivityState: Sendable {
    public let isConnected: Bool
    public let connectionType: ConnectionType

    public enum ConnectionType: String, Sendable {
        case wifi
        case cellular
        case ethernet
        case none
    }

    public static let offline = ConnectivityState(isConnected: false, connectionType: .none)
    public static let wifi = ConnectivityState(isConnected: true, connectionType: .wifi)
}

/// Checks network connectivity on-demand using NWPathMonitor.
struct ConnectivityMonitor: Sendable {
    private static let monitorQueue = DispatchQueue(label: "com.swiftai.connectivity")

    static func checkConnectivity() async -> ConnectivityState {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let guard_ = ResumeGuard()

            monitor.pathUpdateHandler = { path in
                monitor.cancel()
                guard guard_.tryResume() else { return }
                let state = ConnectivityState(
                    isConnected: path.status == .satisfied,
                    connectionType: mapConnectionType(from: path)
                )
                continuation.resume(returning: state)
            }
            monitor.start(queue: monitorQueue)
        }
    }

    private static func mapConnectionType(from path: NWPath) -> ConnectivityState.ConnectionType {
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.cellular) { return .cellular }
        if path.usesInterfaceType(.wiredEthernet) { return .ethernet }
        return .none
    }
}

/// Thread-safe guard ensuring a continuation is resumed exactly once.
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    /// Returns `true` on the first call, `false` on all subsequent calls.
    func tryResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return false }
        resumed = true
        return true
    }
}
