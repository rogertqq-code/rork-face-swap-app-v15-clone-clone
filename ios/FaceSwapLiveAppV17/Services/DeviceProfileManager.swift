import Foundation

@Observable
@MainActor
final class DeviceProfileManager {
    var profiles: [DeviceProfile] = []
    var activeProfileID: UUID?

    var activeProfile: DeviceProfile? {
        guard let id = activeProfileID else { return nil }
        return profiles.first { $0.id == id }
    }

    var hasActiveProfile: Bool { activeProfile != nil }

    private let profilesKey = "device_profiles_v1"
    private let activeProfileKey = "active_profile_id_v1"

    init() {
        loadProfiles()
    }

    func addProfile(_ profile: DeviceProfile) {
        profiles.append(profile)
        activeProfileID = profile.id
        saveProfiles()
    }

    func deleteProfile(_ profile: DeviceProfile) {
        profiles.removeAll { $0.id == profile.id }
        if activeProfileID == profile.id {
            activeProfileID = profiles.first?.id
        }
        saveProfiles()
    }

    func selectProfile(_ profile: DeviceProfile) {
        activeProfileID = profile.id
        UserDefaults.standard.set(profile.id.uuidString, forKey: activeProfileKey)
    }

    func updateProfile(_ profile: DeviceProfile) {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
            saveProfiles()
        }
    }

    private func loadProfiles() {
        if let data = UserDefaults.standard.data(forKey: profilesKey),
           let decoded = try? JSONDecoder().decode([DeviceProfile].self, from: data) {
            profiles = decoded
        }
        if let idStr = UserDefaults.standard.string(forKey: activeProfileKey),
           let id = UUID(uuidString: idStr) {
            activeProfileID = id
        }
    }

    private func saveProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: profilesKey)
        }
        if let id = activeProfileID {
            UserDefaults.standard.set(id.uuidString, forKey: activeProfileKey)
        }
    }
}
