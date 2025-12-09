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
        
        print("🎤 [Voice] Speaking (\(voiceOption.rawValue)): \(text.prefix(50))...")
        
        switch voiceOption {
        case .samantha:
            speakWithAppleTTS(text, rate: rate)
        case .gpt4:
            // Use OpenAI TTS - works on watch cellular or iPhone connection
            // Priority: 1) Watch Cellular, 2) iPhone Connection via Bluetooth
            // watchOS automatically uses best available connection
            if true { // Always allow - system handles connection priority
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
        Task {
            do {
                let audioData = try await requestOpenAITTS(text)
                await playAudioData(audioData)
            } catch {
                print("❌ [Voice] OpenAI TTS error: \(error.localizedDescription)")
                // Fall back to Apple TTS
                await MainActor.run {
                    speakWithAppleTTS(text, rate: 0.50)
                }
            }
        }
    }
    
    /// Request OpenAI TTS
    /// URLSession automatically uses best connection: watch cellular → iPhone connection
    /// Optimized for outdoor running - no connection checking overhead
    private func requestOpenAITTS(_ text: String) async throws -> Data {
        // Use Supabase proxy if available, otherwise direct OpenAI
        let url: URL
        let headers: [String: String]
        
        if !supabaseURL.isEmpty {
            url = URL(string: "\(supabaseURL)/functions/v1/openai-tts-proxy")!
            headers = [
                "Content-Type": "application/json",
                "apikey": supabaseKey,
                "Authorization": getAuthToken()
            ]
        } else if !openAIKey.isEmpty {
            url = URL(string: "https://api.openai.com/v1/audio/speech")!
            headers = [
                "Content-Type": "application/json",
                "Authorization": "Bearer \(openAIKey)"
            ]
        } else {
            throw NSError(domain: "VoiceManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No API key configured"])
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        // Optimized timeout for outdoor running (cellular may be slower)
        request.timeoutInterval = 20
        
        let body: [String: Any] = [
            "model": "tts-1", // Standard model for faster response
            "input": text,
            "voice": "nova", // Nova voice - clear and encouraging
            "speed": 1.0
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let http = response as? HTTPURLResponse, http.statusCode == 200 {
            print("🎙️ [Voice] OpenAI TTS audio received")
            return data
        }
        
        throw NSError(domain: "VoiceManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "OpenAI API error"])
    }
    
    private func playAudioData(_ data: Data) async {
        await MainActor.run {
            do {
                audioPlayer = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.mp3.rawValue)
                audioPlayer?.delegate = self
                audioPlayer?.volume = 1.0
                audioPlayer?.play()
            } catch {
                print("❌ [Voice] Audio playback error: \(error.localizedDescription)")
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
