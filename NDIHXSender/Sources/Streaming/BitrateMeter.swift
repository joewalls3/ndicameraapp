// FILE: BitrateMeter.swift
import Foundation
import Combine
import CoreMedia

final class BitrateMeter: ObservableObject {
    @Published private(set) var instantMbps: Double = 0.0
    @Published private(set) var averageMbps: Double = 0.0

    private var history: [(timestamp: TimeInterval, bits: Double)] = []
    private let historyQueue = DispatchQueue(label: "BitrateMeter.historyQueue")
    private var cancellable: AnyCancellable?

    init() {
        cancellable = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.recalculate()
            }
    }

    func ingest(bytes: Int, timestamp: CMTime) {
        historyQueue.async { [weak self] in
            guard let self = self else { return }
            let bits = Double(bytes * 8)
            let now = Date().timeIntervalSinceReferenceDate
            self.history.append((timestamp: now, bits: bits))
            self.history = self.history.filter { now - $0.timestamp <= 10.0 }
        }
    }

    private func recalculate() {
        historyQueue.async { [weak self] in
            guard let self = self else { return }
            let now = Date().timeIntervalSinceReferenceDate
            self.history = self.history.filter { now - $0.timestamp <= 10.0 }
            let instantBits = self.history
                .filter { now - $0.timestamp <= 1.0 }
                .reduce(0) { $0 + $1.bits }
            let totalBits = self.history.reduce(0) { $0 + $1.bits }
            let duration = max(now - (self.history.first?.timestamp ?? now), 0.1)
            DispatchQueue.main.async {
                self.instantMbps = instantBits / 1_000_000.0
                self.averageMbps = (totalBits / duration) / 1_000_000.0
            }
        }
    }
}
