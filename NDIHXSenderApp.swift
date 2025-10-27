// FILE: NDIHXSenderApp.swift
import SwiftUI

@main
struct NDIHXSenderApp: App {
    @StateObject private var captureManager = CaptureManager()
    @StateObject private var audioEngine = AudioEngine()
    @StateObject private var bitrateMeter = BitrateMeter()
    @StateObject private var motionLeveler = MotionLeveler()
    @StateObject private var ndiSender = NDIHXSender()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(captureManager)
                .environmentObject(audioEngine)
                .environmentObject(bitrateMeter)
                .environmentObject(motionLeveler)
                .environmentObject(ndiSender)
                .task {
                    await Permissions.shared.ensureAllPermissions()
                    await MainActor.run {
                        captureManager.reconfigureAfterPermissionsGranted()
                    }
                }
                .task {
                    motionLeveler.start()
                }
                .onDisappear {
                    motionLeveler.stop()
                }
        }
    }
}
