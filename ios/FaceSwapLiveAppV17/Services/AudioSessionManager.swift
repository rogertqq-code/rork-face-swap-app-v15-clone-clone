import AVFoundation

@MainActor
final class AudioSessionManager: @unchecked Sendable {
    static let shared = AudioSessionManager()
    
    private var savedCategory: AVAudioSession.Category?
    private var savedMode: AVAudioSession.Mode?
    private var savedOptions: AVAudioSession.CategoryOptions?
    private var isManagedActive = false

    private init() {}

    /// Activates the audio session with the desired configuration, saving the prior state.
    func activate(category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions = []) {
        let session = AVAudioSession.sharedInstance()
        
        if !isManagedActive {
            savedCategory = session.category
            savedMode = session.mode
            savedOptions = session.categoryOptions
            isManagedActive = true
        }

        try? session.setCategory(category, mode: mode, options: options)
        try? session.setActive(true)
    }

    /// Restores the audio session to the state it was in before `activate` was called.
    func restore() {
        guard isManagedActive else { return }
        let session = AVAudioSession.sharedInstance()
        
        if let category = savedCategory, let mode = savedMode, let options = savedOptions {
            try? session.setCategory(category, mode: mode, options: options)
        }
        
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        
        savedCategory = nil
        savedMode = nil
        savedOptions = nil
        isManagedActive = false
    }
}
