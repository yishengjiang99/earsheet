// SPDX-License-Identifier: AGPL-3.0-or-later
import HearSheet
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: ProStore
    @ObservedObject private var push = PushManager.shared
    @State private var shareUsage = Telemetry.shared.isEnabled
    @State private var pushBusy = false
    @Environment(\.dismiss) private var dismiss
    @State private var showPaywall = false
    @State private var restoring = false
    @AppStorage(NoiseGate.Settings.Keys.enabled) private var gateOn = NoiseGate.Settings.default.enabled
    @AppStorage(NoiseGate.Settings.Keys.thresholdDB) private var gateThreshold = NoiseGate.Settings.default.thresholdDB
    @AppStorage(NoiseGate.Settings.Keys.attackMs) private var gateAttackMs = NoiseGate.Settings.default.attack * 1000
    @AppStorage(NoiseGate.Settings.Keys.holdMs) private var gateHoldMs = NoiseGate.Settings.default.hold * 1000
    @AppStorage(NoiseGate.Settings.Keys.releaseMs) private var gateReleaseMs = NoiseGate.Settings.default.release * 1000
    @AppStorage(InputConditioner.Settings.Keys.autoThreshold) private var gateAuto = InputConditioner.Settings.default.autoThreshold
    @AppStorage(InputConditioner.Settings.Keys.marginDB) private var gateMarginDB = InputConditioner.Settings.default.marginDB
    @AppStorage(InputConditioner.Settings.Keys.highPass) private var highPassOn = InputConditioner.Settings.default.highPass
    @AppStorage(InputConditioner.Settings.Keys.highPassHz) private var highPassHz = InputConditioner.Settings.default.highPassHz
    @AppStorage(InputConditioner.Settings.Keys.dropQuietNotes) private var dropQuietNotes = InputConditioner.Settings.default.dropQuietNotes
    @AppStorage(InputConditioner.Settings.Keys.lastFloorDB) private var lastFloorDB = 0.0
    /// 0 = never measured.
    @AppStorage(InputConditioner.Settings.Keys.lastFloorAt) private var lastFloorAt = 0.0
    @State private var measuringFloor = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(action: { showPaywall = true }) {
                        HStack {
                            Image(systemName: "crown.fill")
                                .foregroundStyle(Ink.teal)
                            VStack(alignment: .leading) {
                                Text("Go Pro")
                                    .fontWeight(.semibold)
                                Text(store.isPro ? "You have Pro" : "Unlimited saves, MIDI, MusicXML & full PDF")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if store.isPro {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Ink.teal)
                            }
                        }
                    }
                    Button("Restore Purchases") {
                        restoring = true
                        Task {
                            await store.restore()
                            restoring = false
                        }
                    }
                    .disabled(restoring)
                }

                Section {
                    Toggle("Notifications", isOn: Binding(
                        get: { push.enabledInApp },
                        set: { on in
                            pushBusy = true
                            Task {
                                if on { await push.enable() } else { await push.disable() }
                                pushBusy = false
                            }
                        }))
                        .disabled(pushBusy)
                    Toggle("Share anonymous usage data", isOn: $shareUsage)
                        .onChange(of: shareUsage) { _, on in Telemetry.shared.isEnabled = on }
                } header: {
                    Text("Privacy")
                } footer: {
                    if push.status == .denied {
                        Text("Notifications are off for AI Music Radar in iOS Settings.")
                    } else {
                        Text("Usage data is anonymous: feature events only, never audio, notes or titles.")
                    }
                }

                Section {
                    noiseFloorRow
                    Toggle("Noise gate", isOn: $gateOn)
                    if gateOn {
                        Toggle("Auto threshold", isOn: $gateAuto)
                        if gateAuto {
                            gateSlider("Above noise floor", value: $gateMarginDB, in: 3...30, step: 1, unit: "dB")
                        } else {
                            gateSlider("Threshold", value: $gateThreshold, in: -80...(-20), step: 1, unit: "dB")
                        }
                        gateSlider("Attack", value: $gateAttackMs, in: 0...100, step: 1, unit: "ms")
                        gateSlider("Hold", value: $gateHoldMs, in: 0...500, step: 10, unit: "ms")
                        gateSlider("Release", value: $gateReleaseMs, in: 0...500, step: 10, unit: "ms")
                        Toggle("Ignore notes below the gate", isOn: $dropQuietNotes)
                    }
                    Toggle("Rumble filter (high-pass)", isOn: $highPassOn)
                    if highPassOn {
                        gateSlider("Cutoff", value: $highPassHz, in: 40...80, step: 5, unit: "Hz")
                    }
                    Button("Reset to defaults") {
                        let d = NoiseGate.Settings.default, c = InputConditioner.Settings.default
                        gateThreshold = d.thresholdDB
                        gateAttackMs = d.attack * 1000
                        gateHoldMs = d.hold * 1000
                        gateReleaseMs = d.release * 1000
                        gateAuto = c.autoThreshold
                        gateMarginDB = c.marginDB
                        highPassOn = c.highPass
                        highPassHz = c.highPassHz
                        dropQuietNotes = c.dropQuietNotes
                    }
                } header: {
                    Text("Microphone")
                } footer: {
                    Text(gateAuto
                         ? "The gate measures the room's steady noise (air conditioning, fans) in the first half second and the quiet moments, and opens \(Int(gateMarginDB)) dB above it. The rumble filter cuts hum and rumble below \(Int(highPassHz)) Hz; low piano notes keep their overtones. Applies to the next recording."
                         : "Mutes the mic below the threshold so background noise isn't transcribed. Raise the threshold in noisy rooms. The rumble filter cuts hum and rumble below the cutoff. Applies to the next recording.")
                }

                Section("About") {
                    Link(destination: URL(string: "https://grepawk.com/music-radar/privacy")!) {
                        HStack {
                            Text("Privacy Policy")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Link(destination: URL(string: "https://grepawk.com/music-radar/terms")!) {
                        HStack {
                            Text("Terms of Use")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Link(destination: URL(string: "https://grepawk.com/music-radar/support")!) {
                        HStack {
                            Text("Support")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView(store: store)
            }
        }
    }

    /// Noise floor from the latest recording (or "Measure now": 1 s from the mic).
    private var noiseFloorRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Noise floor")
                if lastFloorAt > 0 {
                    Text("\(Int(lastFloorDB.rounded())) dBFS · gate opens at \(Int((gateAuto ? lastFloorDB + gateMarginDB : gateThreshold).rounded())) dBFS")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Measured \(Date(timeIntervalSince1970: lastFloorAt).formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not measured yet — record, or measure now")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if measuringFloor {
                ProgressView()
            } else {
                Button("Measure now", action: measureFloor)
                    .buttonStyle(.bordered)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Listens for 1.2 s (stay quiet) and stores the floor; nothing is recorded or kept.
    private func measureFloor() {
        measuringFloor = true
        let recorder = AudioRecorder()
        do {
            try recorder.start()
        } catch {
            measuringFloor = false
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            _ = recorder.stop() // saves the measured floor to UserDefaults (shown above)
            measuringFloor = false
        }
    }

    private func gateSlider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>,
                            step: Double, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue)) \(unit)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
                .tint(Ink.teal)
                .accessibilityLabel(title)
                .accessibilityValue("\(Int(value.wrappedValue)) \(unit)")
        }
    }
}
