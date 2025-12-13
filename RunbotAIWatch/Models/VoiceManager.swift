import Foundation
import AVFoundation
import WatchKit
import Combine

// MARK: - WatchOS Voice Manager
/// Optimized voice synthesis for Apple Watch with haptic sync
final class VoiceManager: NSObject, ObservableObject {
    
    // MARK: - Published State
    @Published var isSpeaking = false
    @Published var currentText = ""
    
    // MARK: - Private Properties
    private let synthesizer = AVSpeechSynthesizer()
    private var currentUtterance: AVSpeechUtterance?
    private var audioPlayer: AVAudioPlayer?
    
    // Speech completion callback
    var onSpeechFinished: (() -> Void)?
    
    // Configuration
    private let openAIKey: String
    private let supabaseURL: String
    private let supabaseKey: String
    
    // MARK: - Initialization
    
    override init() {
        if let config = ConfigLoader.loadConfig() {
            self.openAIKey = (config["OPENAI_API_KEY"] as? String) ?? ""
            self.supabaseURL = (config["SUPABASE_URL"] as? String) ?? ""
            self.supabaseKey = (config["SUPABASE_ANON_KEY"] as? String) ?? ""
        } else {
            self.openAIKey = ""
            self.supabaseURL = ""
            self.supabaseKey = ""
        }
        super.init()
        synthesizer.delegate = self
        configureAudioSession()
    }
    
    // MARK: - Public API
    
    /// Initialize voice manager
    func setupSpeech() {
        print("🔊 [Voice] Setting up speech...")
        configureAudioSession()
        print("🔊 [Voice] ✅ Voice manager ready")
    }
    
    /// Speak text with specified voice option
    func speak(_ text: String, using voiceOption: VoiceOption, rate: Float = 0.50) {
        stopSpeaking()
        
        currentText = text
        isSpeaking = true
        
        // Play haptic on speech start
        playHaptic(.click)
        
        print("🎤 [Voice] ========== SPEAK REQUEST ==========")
        print("🎤 [Voice] Voice Option: \(voiceOption.rawValue)")
        print("🎤 [Voice] Text preview: \(text.prefix(50))...")
        print("🎤 [Voice] Text length: \(text.count) characters")
        
        switch voiceOption {
        case .samantha:
            print("🎤 [Voice] ✅ Using Apple Samantha TTS")
            speakWithAppleTTS(text, rate: rate)
        case .gpt4:
            print("🎤 [Voice] ✅✅✅ Using OpenAI GPT-4 Mini TTS ✅✅✅")
            print("🎤 [Voice] OpenAI API Key present: \(!openAIKey.isEmpty)")
            print("🎤 [Voice] Supabase URL present: \(!supabaseURL.isEmpty)")
            // Use OpenAI TTS - works on watch cellular or iPhone connection
            // Priority: 1) Watch Cellular, 2) iPhone Connection via Bluetooth
            // watchOS automatically uses best available connection
            if true { // Always allow - system handles connection priority
                print("🎤 [Voice] Calling speakWithOpenAITTS()...")
                speakWithOpenAITTS(text)
            } else {
                print("⚠️ [Voice] Not on WiFi, falling back to Apple TTS")
                speakWithAppleTTS(text, rate: rate)
            }
        }
    }
    
    /// Stop current speech
    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        audioPlayer?.stop()
        audioPlayer = nil
        isSpeaking = false
        currentText = ""
    }
    
    
    // MARK: - Audio Session Configuration
    
    private func configureAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            // watchOS optimized configuration
            try audioSession.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            
            print("🔊 [Voice] ✅ Audio session configured")
        } catch {
            print("🔊 [Voice] ❌ Audio session error: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Apple TTS (Recommended for Watch)
    
    private func speakWithAppleTTS(_ text: String, rate: Float) {
        let utterance = AVSpeechUtterance(string: text)
        
        // Find Samantha voice or fall back to en-US
        let preferredVoice = AVSpeechSynthesisVoice(identifier: "com.apple.ttsbundle.Samantha-compact")
            ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.voice = preferredVoice
        
        // Optimized settings for Watch speaker clarity
        utterance.rate = rate // 0.50 default - slightly slower for clarity
        utterance.volume = 1.0 // Max volume for outdoor running
        utterance.pitchMultiplier = 1.05 // Slightly higher for encouragement
        utterance.preUtteranceDelay = 0.1
        utterance.postUtteranceDelay = 0.2
        
        currentUtterance = utterance
        synthesizer.speak(utterance)
    }
    
    // MARK: - OpenAI TTS (Works on Watch Cellular or iPhone Connection)
    
    private func speakWithOpenAITTS(_ text: String) {
        print("🎙️ [Voice] ========== OPENAI TTS CALLED ==========")
        print("🎙️ [Voice] Text to synthesize: \(text.prefix(100))...")
        print("🎙️ [Voice] Starting OpenAI TTS request...")
        
        Task {
            do {
                print("🎙️ [Voice] Requesting OpenAI TTS audio...")
                let audioData = try await requestOpenAITTS(text)
                print("🎙️ [Voice] ✅ OpenAI TTS audio received: \(audioData.count) bytes")
                await playAudioData(audioData)
                print("🎙️ [Voice] ✅✅✅ OpenAI GPT-4 Mini TTS playback started ✅✅✅")
            } catch {
                print("❌ [Voice] ========== OPENAI TTS ERROR ==========")
                print("❌ [Voice] Error: \(error.localizedDescription)")
                print("❌ [Voice] Error type: \(type(of: error))")
                if let nsError = error as NSError? {
                    print("❌ [Voice] Error domain: \(nsError.domain)")
                    print("❌ [Voice] Error code: \(nsError.code)")
                }
                print("❌ [Voice] Falling back to Apple TTS...")
                // Fall back to Apple TTS
                await MainActor.run {
                    speakWithAppleTTS(text, rate: 0.50)
                }
            }
        }
    }
    
    /// Request OpenAI TTS via Supabase edge function (shared with iOS app)
    /// Uses the 'openai-proxy' edge function which has OPENAI_API_KEY in Supabase secrets
    /// URLSession automatically uses best connection: watch cellular → iPhone connection
    private func requestOpenAITTS(_ text: String) async throws -> Data {
        print("🎙️ [Voice] ========== REQUESTING OPENAI TTS ==========")
        
        guard !supabaseURL.isEmpty else {
            print("❌ [Voice] Supabase URL not configured")
            throw NSError(domain: "VoiceManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Supabase URL not configured"])
        }
        
        // Use Supabase edge function: openai-proxy (shared with iOS app)
        // The edge function uses OPENAI_API_KEY from Supabase secrets, so we don't need to pass it
        let url = URL(string: "\(supabaseURL)/functions/v1/openai-proxy")!
        print("🎙️ [Voice] Using Supabase edge function: openai-proxy (shared with iOS)")
        print("🎙️ [Voice] URL: \(url)")
        print("🎙️ [Voice] Note: Edge function uses OPENAI_API_KEY from Supabase secrets")
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue(getAuthToken(), forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        print("🎙️ [Voice] Request timeout: 20 seconds")
        
        // Request body for OpenAI TTS API
        // Edge function expects endpoint='audio/speech' to identify TTS request
        // Edge function defaults: model='tts-1-hd', voice='nova', response_format='mp3', speed=1.0
        let body: [String: Any] = [
            "endpoint": "audio/speech", // Required: tells edge function this is TTS, not chat completion
            "input": text, // Required: text to convert to speech
            "model": "tts-1", // Optional: defaults to 'tts-1-hd' if not provided
            "voice": "nova", // Optional: defaults to 'nova' if not provided
            "response_format": "mp3", // Optional: defaults to 'mp3' if not provided
            "speed": 1.0 // Optional: defaults to 1.0 if not provided
        ]
        print("🎙️ [Voice] Request body (matching edge function format):")
        print("   - endpoint: audio/speech (TTS request)")
        print("   - input: \(text.count) characters")
        print("   - model: tts-1")
        print("   - voice: nova")
        print("   - response_format: mp3")
        print("   - speed: 1.0")
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        print("🎙️ [Voice] Request body size: \(request.httpBody?.count ?? 0) bytes")
        print("🎙️ [Voice] Sending request to Supabase edge function...")
        
        let startTime = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        let duration = Date().timeIntervalSince(startTime)
        
        print("🎙️ [Voice] Response received in \(String(format: "%.2f", duration)) seconds")
        print("🎙️ [Voice] Response data size: \(data.count) bytes")
        
        if let http = response as? HTTPURLResponse {
            print("🎙️ [Voice] HTTP Status Code: \(http.statusCode)")
            print("🎙️ [Voice] Content-Type: \(http.value(forHTTPHeaderField: "Content-Type") ?? "unknown")")
            
            if http.statusCode == 200 {
                // Edge function returns binary audio data (arrayBuffer) with Content-Type: 'audio/mpeg'
                let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
                if contentType.contains("audio/mpeg") || contentType.contains("audio/") {
                    print("🎙️ [Voice] ✅✅✅ Supabase edge function SUCCESS ✅✅✅")
                    print("🎙️ [Voice] ✅✅✅ OpenAI GPT-4 Mini TTS audio received: \(data.count) bytes ✅✅✅")
                    print("🎙️ [Voice] Content-Type: \(contentType)")
                    return data
                } else {
                    // Might be JSON error even with 200 status
                    if let errorBody = String(data: data, encoding: .utf8), errorBody.contains("error") {
                        print("❌ [Voice] Edge function returned error in response body")
                        print("❌ [Voice] Error: \(errorBody)")
                        throw NSError(domain: "VoiceManager", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Edge function error: \(errorBody)"])
                    }
                    // Assume it's audio data even if Content-Type is missing
                    print("🎙️ [Voice] ✅✅✅ Audio data received (Content-Type missing but assuming audio) ✅✅✅")
                    return data
                }
            } else {
                let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                print("❌ [Voice] Edge function error - Status: \(http.statusCode)")
                print("❌ [Voice] Error response: \(errorBody)")
                throw NSError(domain: "VoiceManager", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Edge function error: \(http.statusCode) - \(errorBody)"])
            }
        }
        
        print("❌ [Voice] Invalid response type")
        throw NSError(domain: "VoiceManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response from edge function"])
    }
    
    private func playAudioData(_ data: Data) async {
        await MainActor.run {
            do {
                print("🎙️ [Voice] Creating AVAudioPlayer from OpenAI TTS data...")
                audioPlayer = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.mp3.rawValue)
                audioPlayer?.delegate = self
                audioPlayer?.volume = 1.0
                print("🎙️ [Voice] Starting playback of OpenAI TTS audio...")
                audioPlayer?.play()
                print("🎙️ [Voice] ✅✅✅ OpenAI GPT-4 Mini TTS audio is now playing ✅✅✅")
            } catch {
                print("❌ [Voice] Audio playback error: \(error.localizedDescription)")
                print("❌ [Voice] Error type: \(type(of: error))")
                isSpeaking = false
            }
        }
    }
    
    // MARK: - Helpers
    // Note: Watch app uses iPhone's cellular/Bluetooth connection automatically
    // No WiFi check needed - watch connects via Bluetooth to iPhone for network access
    
    private func getAuthToken() -> String {
        if let token = UserDefaults.standard.string(forKey: "sessionToken") {
            return "Bearer \(token)"
        }
        return "Bearer \(supabaseKey)"
    }
    
    private func playHaptic(_ type: WKHapticType) {
        WKInterfaceDevice.current().play(type)
    }
    
    private func speechFinished() {
        isSpeaking = false
        currentText = ""
        onSpeechFinished?()
        print("✅ [Voice] Speech finished")
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension VoiceManager: AVSpeechSynthesizerDelegate {
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isSpeaking = true
        }
        playHaptic(.click)
        print("🎤 [Voice] Speech started")
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.speechFinished()
        }
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isSpeaking = false
            self.currentText = ""
        }
        print("⏹️ [Voice] Speech cancelled")
    }
}

// MARK: - AVAudioPlayerDelegate

extension VoiceManager: AVAudioPlayerDelegate {
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.speechFinished()
        }
    }
    
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        DispatchQueue.main.async {
            self.isSpeaking = false
            self.currentText = ""
        }
        print("❌ [Voice] Audio decode error: \(error?.localizedDescription ?? "unknown")")
    }
}
