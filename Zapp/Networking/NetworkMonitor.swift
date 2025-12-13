import Foundation
import Network
import Combine

final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    enum ConnectionType {
        case wifi
        case cellular
        case wired
        case none
    }

    @Published private(set) var connectionType: ConnectionType = .none

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitorQueue")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.updateConnectionType(with: path)
        }
        monitor.start(queue: queue)
    }

    var isOnWiFi: Bool {
        switch connectionType {
        case .wifi, .wired:
            return true
        case .cellular, .none:
            return false
        }
    }

    var isOnCellular: Bool {
        connectionType == .cellular
    }

    var hasConnection: Bool {
        connectionType != .none
    }

    func retryConnectionCheck() {
        queue.async { [weak self] in
            guard let self else { return }
            let path = self.monitor.currentPath
            self.updateConnectionType(with: path)
        }
    }

    private func updateConnectionType(with path: NWPath) {
        let type = connectionType(from: path)
        DispatchQueue.main.async {
            self.connectionType = type
        }
    }

    private func connectionType(from path: NWPath) -> ConnectionType {
        guard path.status == .satisfied else { return .none }

        if path.usesInterfaceType(.wifi) {
            return .wifi
        }
        if path.usesInterfaceType(.cellular) {
            return .cellular
        }
        if path.usesInterfaceType(.wiredEthernet) {
            return .wired
        }
        return .none
    }
}
