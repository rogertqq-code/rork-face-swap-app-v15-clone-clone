import Foundation
import UIKit

@Observable
@MainActor
final class ExportBundleService {
    var isExporting: Bool = false
    var lastExportURL: URL?

    func exportBundle(
        profile: DeviceProfile?,
        constraintLogs: [ConstraintLogEntry],
        siteHistory: [SiteHistoryEntry],
        injectionReports: [InjectionInspectionReport],
        sessionDiagnostics: String,
        mediaMetadata: String,
        fingerprintResults: String
    ) async -> URL? {
        isExporting = true

        let profileString: String
        if let profile {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            if let data = try? encoder.encode(profile) {
                profileString = String(data: data, encoding: .utf8) ?? "No profile"
            } else {
                profileString = "No profile"
            }
        } else {
            profileString = "No profile"
        }

        let bundle = DebugBundle(
            exportDate: Date(),
            deviceProfile: profileString,
            sessionDiagnostics: sessionDiagnostics,
            constraintLogs: constraintLogs,
            mediaMetadata: mediaMetadata,
            fingerprintResults: fingerprintResults,
            siteHistory: siteHistory,
            injectionReports: injectionReports
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted

        guard let data = try? encoder.encode(bundle) else {
            isExporting = false
            return nil
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let fileName = "debug_bundle_\(dateFormatter.string(from: Date())).json"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        do {
            try data.write(to: fileURL)
            lastExportURL = fileURL
        } catch {
            isExporting = false
            return nil
        }

        isExporting = false
        return fileURL
    }

    func shareURL() -> URL? {
        guard let url = lastExportURL,
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }
}
