import Foundation
import Observation

struct LibraryItem: Identifiable, Sendable {
    let url: URL
    let size: Int64

    var id: String { url.lastPathComponent }
    var name: String { url.lastPathComponent }
}

// File copies and provider coordination stay off the UI actor. The directory
// itself is the source of truth, so edits made in Files appear after a refresh.
actor MediaLibrary {
    private let files = FileManager.default
    private let directory = URL.documentsDirectory.appending(path: "Media", directoryHint: .isDirectory)

    func items() throws -> [LibraryItem] {
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        return try files.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ).compactMap { url in
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { return nil }
            return LibraryItem(url: url, size: Int64(values.fileSize ?? 0))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func importFile(from source: URL) throws {
        let accessed = source.startAccessingSecurityScopedResource()
        defer {
            if accessed { source.stopAccessingSecurityScopedResource() }
        }

        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appending(path: ".imports", directoryHint: .isDirectory)
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        let temporary = staging.appending(path: UUID().uuidString)
        defer { try? files.removeItem(at: temporary) }

        var coordinationError: NSError?
        var copyError: (any Error)?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
            do {
                let values = try readable.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else {
                    throw CocoaError(.fileReadUnsupportedScheme)
                }
                try files.copyItem(at: readable, to: temporary)
            } catch {
                copyError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }

        // A second import never overwrites an existing user file.
        let destination = availableDestination(for: source.lastPathComponent)
        try files.moveItem(at: temporary, to: destination)
    }

    private func availableDestination(for name: String) -> URL {
        let original = directory.appending(path: name)
        guard files.fileExists(atPath: original.path()) else { return original }
        let stem = original.deletingPathExtension().lastPathComponent
        let suffix = original.pathExtension
        var count = 2
        while true {
            let filename = "\(stem) (\(count))" + (suffix.isEmpty ? "" : ".\(suffix)")
            let candidate = directory.appending(path: filename)
            if !files.fileExists(atPath: candidate.path()) { return candidate }
            count += 1
        }
    }
}

@MainActor
@Observable
final class LibraryModel {
    private let library = MediaLibrary()
    private(set) var items: [LibraryItem] = []
    private(set) var isImporting = false
    var errorMessage: String?

    func refresh() async {
        do {
            items = try await library.items()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importFiles(_ urls: [URL]) async {
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        var failures: [String] = []
        for url in urls {
            do {
                try await library.importFile(from: url)
            } catch {
                failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        await refresh()
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
    }
}
