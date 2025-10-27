// FILE: MotionLeveler.swift
import Foundation
import CoreMotion
import Combine

final class MotionLeveler: ObservableObject {
    @Published private(set) var roll: Double = 0.0

    private let motionManager = CMMotionManager()
    private var queue = OperationQueue()

    func start() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] motion, _ in
            guard let motion = motion else { return }
            let roll = motion.attitude.roll
            DispatchQueue.main.async {
                self?.roll = roll
            }
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
    }
}
