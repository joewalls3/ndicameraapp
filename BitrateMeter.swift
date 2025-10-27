// FILE: BitrateMeter.swift
import Foundation
import Combine
import CoreMedia

final class BitrateMeter: ObservableObject {
    @Published private(set) var instantMbps: Double = 0.0
    @Published private(set) var averageMbps: Double = 0.0

    private var history: [(timestamp: TimeInterval, bits: Double)] = []
    private var cancellable: AnyCancellable?

    init() {
        cancellable = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.recalculate()
            }
    }

    func ingest(bytes: Int, timestamp: CMTime) {
        let bits = Double(bytes * 8)
        let now = Date().timeIntervalSinceReferenceDate
        history.append((timestamp: now, bits: bits))
        history = history.filter { now - $0.timestamp <= 10.0 }
    }

    private func recalculate() {
        let now = Date().timeIntervalSinceReferenceDate
        history = history.filter { now - $0.timestamp <= 10.0 }
        let instantBits = history.filter { now - $0.timestamp <= 1.0 }.reduce(0) { $0 + $1.bits }
        let totalBits = history.reduce(0) { $0 + $1.bits }
        instantMbps = instantBits / 1_000_000.0
        let duration = max(now - (history.first?.timestamp ?? now), 0.1)
        averageMbps = (totalBits / duration) / 1_000_000.0
    }
}
