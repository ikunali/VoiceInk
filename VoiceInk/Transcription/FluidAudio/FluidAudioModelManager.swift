import Foundation
import FluidAudio
import AppKit
import os

struct FluidAudioDownloadStatus {
    let fractionCompleted: Double
    let message: String
}

@MainActor
class FluidAudioModelManager: ObservableObject {
    @Published private var downloadStatuses: [String: FluidAudioDownloadStatus] = [:]
    private var activeDownloadIDs: [String: UUID] = [:]

    var onModelDeleted: ((String) -> Void)?
    var onModelsChanged: (() -> Void)?

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "FluidAudioModelManager")

    // Add new Fluid Audio models here when support is added.
    private static let modelVersionMap: [String: AsrModelVersion] = [
        "parakeet-tdt-0.6b-v2": .v2,
        "parakeet-tdt-0.6b-v3": .v3,
    ]

    nonisolated static func asrVersion(for modelName: String) -> AsrModelVersion {
        modelVersionMap[modelName] ?? .v3
    }

    nonisolated static func languageHint(from languageCode: String?, for modelName: String) -> Language? {
        guard asrVersion(for: modelName) == .v3,
              let languageCode,
              languageCode != "auto"
        else { return nil }

        return Language(rawValue: languageCode)
    }

    init() {}

    // MARK: - Query helpers

    func isFluidAudioModelDownloaded(named modelName: String) -> Bool {
        let version = FluidAudioModelManager.asrVersion(for: modelName)
        return AsrModels.modelsExist(at: cacheDirectory(for: version), version: version)
    }

    func isFluidAudioModelDownloaded(_ model: FluidAudioModel) -> Bool {
        isFluidAudioModelDownloaded(named: model.name)
    }

    func isFluidAudioModelDownloading(_ model: FluidAudioModel) -> Bool {
        downloadStatuses[model.name] != nil
    }

    func downloadStatus(for model: FluidAudioModel) -> FluidAudioDownloadStatus? {
        downloadStatuses[model.name]
    }

    // MARK: - Download

    func downloadFluidAudioModel(_ model: FluidAudioModel) async {
        if isFluidAudioModelDownloaded(model) || isFluidAudioModelDownloading(model) {
            return
        }

        let modelName = model.name
        let downloadID = UUID()
        activeDownloadIDs[modelName] = downloadID
        downloadStatuses[modelName] = FluidAudioDownloadStatus(
            fractionCompleted: 0.0,
            message: "Preparing FluidAudio download..."
        )
        defer {
            clearProxyEnvVars()
            clearDownloadStatus(for: modelName, downloadID: downloadID)
            onModelsChanged?()
        }

        applyProxyToFluidAudio()

        let version = FluidAudioModelManager.asrVersion(for: modelName)
        let progressHandler: DownloadUtils.ProgressHandler = { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.updateDownloadProgress(progress, for: modelName, downloadID: downloadID)
            }
        }

        #if LOCAL_BUILD
        DebugFileLogger.shared.write("Starting download for \(modelName)", category: "FluidAudioModelManager")
        #endif

        do {
            _ = try await AsrModels.downloadAndLoad(
                version: version,
                progressHandler: progressHandler
            )
            #if LOCAL_BUILD
            DebugFileLogger.shared.write("Download succeeded for \(modelName)", category: "FluidAudioModelManager")
            #endif
        } catch {
            logger.error("❌ FluidAudio download failed for \(modelName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            #if LOCAL_BUILD
            DebugFileLogger.shared.write("Download FAILED for \(modelName): \(error)", category: "FluidAudioModelManager")
            #endif
        }
    }

    // MARK: - Proxy bridging

    /// Sets https_proxy / http_proxy env vars so FluidAudio's URLSession picks them up.
    /// FluidAudio reads these env vars when creating DownloadUtils.sharedSession on first access.
    private func applyProxyToFluidAudio() {
        if let proxy = ProxySettingsManager.shared.effectiveConfiguration {
            let scheme = proxy.type == .socks5 ? "socks5" : "http"
            let proxyURL = "\(scheme)://\(proxy.host):\(proxy.port)"
            setenv("https_proxy", proxyURL, 1)
            setenv("http_proxy", proxyURL, 1)
            logger.notice("FluidAudio proxy env vars set: \(proxyURL, privacy: .public)")
            #if LOCAL_BUILD
            DebugFileLogger.shared.write("Proxy env vars set: \(proxyURL)", category: "FluidAudioModelManager")
            #endif
        } else {
            unsetenv("https_proxy")
            unsetenv("http_proxy")
            logger.notice("FluidAudio proxy env vars cleared (direct connection)")
            #if LOCAL_BUILD
            DebugFileLogger.shared.write("No proxy configured — direct connection", category: "FluidAudioModelManager")
            #endif
        }
    }

    private func clearProxyEnvVars() {
        unsetenv("https_proxy")
        unsetenv("http_proxy")
    }

    // MARK: - Delete

    func deleteFluidAudioModel(_ model: FluidAudioModel) {
        let cacheDirectory = cacheDirectory(for: model)

        do {
            if FileManager.default.fileExists(atPath: cacheDirectory.path) {
                try FileManager.default.removeItem(at: cacheDirectory)
            }
        } catch {
            // Silently ignore removal errors
        }

        // Notify TranscriptionModelManager to clear currentTranscriptionModel if it matches
        onModelDeleted?(model.name)
    }

    // MARK: - Finder

    func showFluidAudioModelInFinder(_ model: FluidAudioModel) {
        let cacheDirectory = cacheDirectory(for: model)

        if FileManager.default.fileExists(atPath: cacheDirectory.path) {
            NSWorkspace.shared.selectFile(cacheDirectory.path, inFileViewerRootedAtPath: "")
        }
    }

    // MARK: - Private helpers

    private func cacheDirectory(for model: FluidAudioModel) -> URL {
        cacheDirectory(for: FluidAudioModelManager.asrVersion(for: model.name))
    }

    private func cacheDirectory(for version: AsrModelVersion) -> URL {
        AsrModels.defaultCacheDirectory(for: version)
    }

    private func clearDownloadStatus(for modelName: String, downloadID: UUID) {
        guard activeDownloadIDs[modelName] == downloadID else { return }
        activeDownloadIDs[modelName] = nil
        downloadStatuses[modelName] = nil
    }

    private func updateDownloadProgress(_ progress: DownloadUtils.DownloadProgress, for modelName: String, downloadID: UUID) {
        guard activeDownloadIDs[modelName] == downloadID else { return }

        let message = FluidAudioModelManager.statusMessage(for: progress)
        downloadStatuses[modelName] = FluidAudioDownloadStatus(
            fractionCompleted: min(max(progress.fractionCompleted, 0.0), 1.0),
            message: message
        )
        #if LOCAL_BUILD
        DebugFileLogger.shared.write("\(message) (\(Int(progress.fractionCompleted * 100))%)", category: "FluidAudioModelManager")
        #endif
    }

    private static func statusMessage(for progress: DownloadUtils.DownloadProgress) -> String {
        switch progress.phase {
        case .listing:
            return "Listing files from repository..."
        case .downloading(let completedFiles, let totalFiles):
            guard totalFiles > 0 else {
                return "Checking cached models..."
            }
            return "Downloading models: \(completedFiles)/\(totalFiles) files"
        case .compiling(let modelName):
            guard !modelName.isEmpty else {
                return "Finalizing models..."
            }
            return "Compiling \(displayName(forModelComponent: modelName))"
        }
    }

    private static func displayName(forModelComponent modelName: String) -> String {
        modelName.replacingOccurrences(of: ".mlmodelc", with: "")
    }
}
