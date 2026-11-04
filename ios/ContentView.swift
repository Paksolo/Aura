// ContentView.swift
// EchoSight — main SwiftUI view: connect glasses, preview, ask, hear guidance.
//
// If this view is your app's root, Meta AI return URLs are already forwarded
// via the .onOpenURL below. Otherwise move that modifier to your root view.

import SwiftUI
import MWDATCore

struct ContentView: View {
    @StateObject private var manager = AuraWearablesManager()
    @State private var showError = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // MARK: Registration
                    GroupBox("1. Meta AI Registration") {
                        Text("Status: \(String(describing: manager.registrationState))")
                            .font(.footnote)
                        HStack {
                            Button("Register") {
                                Task { await manager.register() }
                            }
                            .buttonStyle(.borderedProminent)
                            Button("Unregister") {
                                Task { await manager.unregister() }
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    // MARK: Devices
                    GroupBox("2. Glasses") {
                        #if targetEnvironment(simulator)
                        Toggle("Mock glasses (Simulator)", isOn: Binding(
                            get: { manager.isMockMode },
                            set: { manager.setMockMode($0) }
                        ))
                        #endif
                        if manager.devices.isEmpty {
                            Text("No devices found yet.").font(.footnote)
                        } else {
                            ForEach(manager.devices, id: \.self) { id in
                                Text(manager.deviceName(for: id)).font(.footnote)
                            }
                        }
                        Text("Session: \(manager.sessionState)").font(.footnote)
                        Text("Stream: \(manager.streamState)").font(.footnote)
                        HStack {
                            Button("Start Session") {
                                Task { await manager.startSession() }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(manager.isBusy)
                            Button("Stop Session") {
                                manager.stopSession()
                            }
                            .buttonStyle(.bordered)
                        }
                        HStack {
                            Button("Start Preview") {
                                Task { await manager.startPreview() }
                            }
                            .buttonStyle(.bordered)
                            Button("Stop Preview") {
                                manager.stopPreview()
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    // MARK: Live preview
                    GroupBox("3. Live Preview") {
                        if let frame = manager.currentFrame {
                            Image(uiImage: frame)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .cornerRadius(8)
                        } else {
                            Text("Preview frames appear here once streaming.")
                                .font(.footnote)
                        }
                    }

                    // MARK: Assistance
                    GroupBox("4. Ask EchoSight") {
                        TextField("Backend URL", text: $manager.backendURLString)
                            .textFieldStyle(.roundedBorder)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .font(.footnote)
                        Text("On-device: replace localhost with your Mac's LAN IP, e.g. http://192.168.1.5:8000/assist")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        SecureField("API Key (if backend requires)", text: $manager.apiKey)
                            .textFieldStyle(.roundedBorder)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .font(.footnote)
                        TextField("Question", text: $manager.query)
                            .textFieldStyle(.roundedBorder)
                        Button(manager.isBusy ? "Working…" : "Capture & Ask") {
                            manager.captureAndAssist()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(manager.isBusy)
                        Text("Tip: the glasses capture button and Select gesture also trigger Capture & Ask.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    // MARK: Guidance
                    GroupBox("Spoken Guidance") {
                        if manager.lastGuidance.isEmpty {
                            Text("Guidance from the backend appears here and is spoken aloud.")
                                .font(.footnote)
                        } else {
                            Text(manager.lastGuidance)
                            Button("Repeat Aloud") {
                                manager.speak(manager.lastGuidance)
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    if manager.isBusy {
                        ProgressView("Working…")
                    }
                }
                .padding()
            }
            .navigationTitle("EchoSight")
            .task {
                manager.observeState()
            }
            .onOpenURL { url in
                // Meta AI registration / permission handoff.
                guard
                    let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                    components.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true
                else { return }
                Task { _ = try? await Wearables.shared.handleUrl(url) }
            }
            .alert("EchoSight", isPresented: Binding(
                get: { manager.errorMessage != nil },
                set: { if !$0 { manager.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(manager.errorMessage ?? "")
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
