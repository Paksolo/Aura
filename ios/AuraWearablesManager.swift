// AuraWearablesManager.swift
// EchoSight — Meta Wearables DAT integration for Ray-Ban Meta Smart Glasses.
//
// Setup:
//   1. Xcode project (SwiftUI App) + SPM dependency:
//      https://github.com/facebook/meta-wearables-dat-ios
//      Add MWDATCore, MWDATCamera, MWDATInputs (and MWDATMockDevice for testing).
//   2. Configure Info.plist per the DAT Getting Started guide
//      (Bluetooth, microphone, URL scheme for Meta AI handoff).
//   3. Call AuraWearablesManager.configureSDK() once at app launch.
//   4. Forward Meta AI return URLs to Wearables.shared.handleUrl(_:) (see ContentView).

import AVFoundation
import Combine
import SwiftUI
import MWDATCore
import MWDATCamera
import MWDATInputs
#if canImport(MWDATMockDevice)
import MWDATMockDevice
#endif

/// Connection + streaming + assistance orchestrator for EchoSight.
///
/// Flow: register with Meta AI -> start session -> start camera preview ->
/// capture photo (glasses button, app button, or voice trigger) ->
/// POST frame + query to the EchoSight backend -> speak the returned guidance.
@MainActor
final class AuraWearablesManager: ObservableObject {
    // MARK: - Published UI state

    @Published var registrationState: RegistrationState
    @Published var devices: [DeviceIdentifier] = []
    @Published var sessionState: String = "No session"
    @Published var streamState: String = "Stopped"
    @Published var currentFrame: UIImage?
    @Published var lastGuidance: String = ""
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var isMockMode = false
    @Published var backendURLString = "http://localhost:8000/assist"
    @Published var apiKey = ""
    @Published var query = "What is in front of me? Any hazards?"

    // MARK: - SDK state

    private let wearables = Wearables.shared
    private var deviceSession: DeviceSession?
    private var camera: Camera?
    private var stream: Stream?
    private var inputs: Inputs?
    private var inputTask: Task<Void, Never>?
    private var pendingQuery: String?
    private var observationStarted = false

    /// Retained listener tokens — dropping a token cancels its subscription.
    private var tokens: [Any] = []

    private let speechSynthesizer = AVSpeechSynthesizer()

    // MARK: - Lifecycle

    init() {
        registrationState = wearables.registrationState
        #if targetEnvironment(simulator)
        // Simulators have no Bluetooth glasses: default to mock devices.
        isMockMode = true
        #endif
    }

    /// Call once at app launch, before touching `Wearables.shared`.
    static func configureSDK() {
        do {
            try Wearables.configure()
        } catch {
            assertionFailure("Wearables SDK configuration failed: \(error)")
        }
    }

    /// Starts observing registration + device lists. Safe to call once from `.task`.
    func observeState() {
        guard !observationStarted else { return }
        observationStarted = true
        Task { [weak self] in
            guard let self else { return }
            for await state in self.wearables.registrationStateStream() {
                await MainActor.run { self.registrationState = state }
            }
        }
        Task { [weak self] in
            guard let self else { return }
            for await deviceIds in self.wearables.devicesStream() {
                await MainActor.run { self.devices = deviceIds }
            }
        }
    }

    // MARK: - Registration

    func register() async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await wearables.startRegistration()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unregister() async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await wearables.startUnregistration()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Mock mode (Simulator testing without glasses)

    func setMockMode(_ enabled: Bool) {
        #if canImport(MWDATMockDevice)
        if enabled {
            enableMock()
        } else {
            disableMock()
        }
        #else
        errorMessage = "MWDATMockDevice is not linked. Add it via SPM to use mock mode."
        #endif
    }

    #if canImport(MWDATMockDevice)
    private func enableMock() {
        let mockDeviceKit = MockDeviceKit.shared
        mockDeviceKit.enable()
        do {
            let glasses = try mockDeviceKit.pairGlasses(model: .rayBanMeta)
            glasses.powerOn()
            glasses.unfold()
            glasses.don()
            if let videoURL = Bundle.main.url(forResource: "test_video", withExtension: "mp4") {
                glasses.services.camera.setCameraFeed(fileURL: videoURL)
            }
            isMockMode = true
        } catch {
            errorMessage = "Mock pairing failed: \(error.localizedDescription)"
        }
    }

    private func disableMock() {
        MockDeviceKit.shared.disable()
        isMockMode = false
    }
    #endif

    // MARK: - Session (step 1 of 2: connect, stays up across previews)

    func startSession() async {
        guard deviceSession == nil else { return }
        isBusy = true
        defer { isBusy = false }
        #if targetEnvironment(simulator)
        if !isMockMode { setMockMode(true) }
        #endif
        let selector = AutoDeviceSelector(wearables: wearables)
        do {
            let session = try wearables.createSession(deviceSelector: selector)
            tokens.append(session.errorPublisher.listen { [weak self] error in
                Task { @MainActor in self?.errorMessage = error.localizedDescription }
            })
            try session.start()
            for await state in session.stateStream() {
                sessionState = "\(state)"
                if state == .started { break }
            }
            deviceSession = session
            attachInputs(to: session)
        } catch {
            errorMessage = error.localizedDescription
            deviceSession = nil
        }
    }

    func stopSession() {
        detachInputs()
        stopPreview()
        deviceSession?.stop()
        deviceSession = nil
        sessionState = "No session"
    }

    // MARK: - Preview (step 2 of 2: camera + stream; session stays connected)

    func startPreview() async {
        guard let session = deviceSession, stream == nil else { return }
        isBusy = true
        defer { isBusy = false }
        let config = StreamConfiguration(videoCodec: .raw, resolution: .medium, frameRate: 24)
        do {
            guard let camera = try session.addCamera(config: config) else {
                errorMessage = "Glasses rejected the camera capability."
                return
            }
            self.camera = camera
            guard let stream = camera.stream else {
                errorMessage = "Camera has no stream."
                return
            }
            self.stream = stream

            tokens.append(stream.statePublisher.listen { [weak self] state in
                Task { @MainActor in self?.streamState = "\(state)" }
            })
            tokens.append(stream.errorPublisher.listen { [weak self] error in
                Task { @MainActor in self?.errorMessage = error.localizedDescription }
            })
            tokens.append(stream.videoFramePublisher.listen { [weak self] frame in
                guard let image = frame.makeUIImage() else { return }
                Task { @MainActor in self?.currentFrame = image }
            })
            tokens.append(stream.photoDataPublisher.listen { [weak self] photoData in
                Task { @MainActor in await self?.handleCapturedPhoto(photoData.data) }
            })

            stream.start()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopPreview() {
        // Stopping the camera cascades to its stream child; the session stays up.
        camera?.stop()
        stream = nil
        camera = nil
        streamState = "Stopped"
    }

    // MARK: - Inputs (glasses buttons / gestures)

    private func attachInputs(to session: DeviceSession) {
        do {
            // Must be called after the session reaches .started; starts automatically.
            let configuration = InputsConfiguration(consumeBack: true)
            guard let inputs = try session.addInputs(configuration: configuration) else {
                return
            }
            self.inputs = inputs
            tokens.append(inputs.statePublisher.listen { _ in })
            tokens.append(inputs.errorPublisher.listen { [weak self] error in
                Task { @MainActor in self?.errorMessage = error.localizedDescription }
            })
            let events = inputs.events
            inputTask = Task { [weak self] in
                for await event in events {
                    await self?.handleInput(event)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func detachInputs() {
        inputTask?.cancel()
        inputTask = nil
        if deviceSession != nil {
            try? deviceSession?.removeInputs()
        }
        inputs = nil
    }

    private func handleInput(_ event: InputEvent) async {
        switch event {
        case .nav(let direction, _, _):
            print("[EchoSight] nav: \(direction)")
        case .select:
            // Select = ask about the current view with the current query.
            captureAndAssist()
        case .back:
            break
        case .button(let button, _, _):
            print("[EchoSight] button: \(button)")
        case .capture(_, _, _):
            // Glasses capture button = hands-free assistance trigger.
            captureAndAssist()
        case .drag(let action, let x, let y, _, _, _, _):
            print("[EchoSight] drag: \(action) at (\(x), \(y))")
        }
    }

    // MARK: - Assistance: capture -> backend -> speak

    /// Captures a still frame; when it arrives via `photoDataPublisher`,
    /// it is POSTed to the backend with the current query.
    func captureAndAssist() {
        guard stream != nil else {
            errorMessage = "Start the preview before asking."
            return
        }
        pendingQuery = query
        isBusy = true
        stream?.capturePhoto(format: .jpeg)
    }

    private func handleCapturedPhoto(_ data: Data) async {
        defer {
            isBusy = false
            pendingQuery = nil
        }
        let question = pendingQuery ?? query
        do {
            let guidance = try await sendToBackend(imageData: data, query: question)
            lastGuidance = guidance
            speak(guidance)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Multipart POST to `POST {backend}/assist` matching backend/app.py.
    func sendToBackend(imageData: Data, query: String) async throws -> String {
        guard let url = URL(string: backendURLString.trimmingCharacters(in: .whitespaces)) else {
            throw URLError(.badURL, userInfo: [NSLocalizedDescriptionKey: "Invalid backend URL."])
        }
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"query\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(query)\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image\"; filename=\"frame.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let token = apiKey.trimmingCharacters(in: .whitespaces)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        request.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "Unknown backend error."
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: detail])
        }
        struct AssistResponse: Decodable { let spoken_guidance: String }
        let decoded = try JSONDecoder().decode(AssistResponse.self, from: data)
        return decoded.spoken_guidance
    }

    // MARK: - Speech output

    func speak(_ text: String) {
        speechSynthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        speechSynthesizer.speak(utterance)
    }

    // MARK: - Helpers

    func deviceName(for id: DeviceIdentifier) -> String {
        (try? wearables.deviceForIdentifier(id)?.nameOrId()) ?? id
    }
}
