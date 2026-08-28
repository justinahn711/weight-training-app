//
//  BackupFile.swift
//  ChickenBreast
//

import SwiftUI
import UniformTypeIdentifiers
import WeightTrainingCore
import WeightTrainingStore

/// The archive as something Files and the share sheet can carry (#87).
struct TrainingArchiveDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Export and restore, in the place someone looks when they're worried (#87, #88).
///
/// Deliberately not phrased as "backup to iCloud". iCloud is already carrying
/// this training and is not what this protects against — the point of a file is
/// that it survives the account.
struct BackupSection: View {
    /// Called after a restore lands, so the screens built from this data get
    /// rebuilt. Without it a restore writes hundreds of rows and every derived
    /// view — history, volume, trends, the cycle line — keeps showing the
    /// state from before it, until the app is relaunched. `DigestView` solves
    /// the same problem the same way.
    var onRestored: () -> Void = {}

    let store: TrainingStore

    @State private var document: TrainingArchiveDocument?
    @State private var filename = "ChickenBreast.json"
    @State private var exportedSets = 0
    @State private var exporting = false
    @State private var importing = false
    @State private var outcome: Outcome?
    @State private var summary: String?

    var body: some View {
        Section {
            Button {
                prepareExport()
            } label: {
                Label("Export training history", systemImage: "square.and.arrow.up")
            }

            Button {
                importing = true
            } label: {
                Label("Restore from a backup", systemImage: "square.and.arrow.down")
            }
        } header: {
            Text("Backup")
        } footer: {
            Text(footer)
        }
        .task { await loadSummary() }
        .fileExporter(
            isPresented: $exporting,
            document: document,
            contentType: .json,
            defaultFilename: filename
        ) { result in
            switch result {
            case .success:
                outcome = .exported(sets: exportedSets)
            case .failure(let error):
                // Dismissing the picker arrives here as an error. Reporting it
                // as one puts "That didn't work" on the screen someone opened
                // to be reassured.
                if !error.isUserCancelled { outcome = .failed(error.localizedDescription) }
            }
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.json]
        ) { result in
            restore(from: result)
        }
        .alert(
            outcome?.title ?? "",
            isPresented: Binding(
                get: { outcome != nil },
                set: { if !$0 { outcome = nil } }
            ),
            presenting: outcome
        ) { _ in
            Button("OK", role: .cancel) { outcome = nil }
        } message: { outcome in
            Text(outcome.message)
        }
    }

    private var footer: String {
        let base = "A file you keep. iCloud syncs this training between your devices, but it's one account holding one copy — this is what survives losing it."
        guard let summary else { return base }
        return "\(base)\n\nRight now: \(summary)."
    }

    private func loadSummary() async {
        guard let archive = try? store.archive() else { return }
        let sets = archive.sets.count
        let lifts = Set(archive.sets.map(\.exerciseID)).count
        summary = "\(sets) set\(sets == 1 ? "" : "s") across \(lifts) lift\(lifts == 1 ? "" : "s")"
    }

    private func prepareExport() {
        do {
            let archive = try store.archive()
            document = TrainingArchiveDocument(data: try archive.jsonData())
            filename = archive.suggestedFilename
            exportedSets = archive.sets.count
            exporting = true
        } catch {
            outcome = .failed(error.localizedDescription)
        }
    }

    private func restore(from result: Result<URL, Error>) {
        do {
            let url = try result.get()

            // A file picked out of Files arrives security-scoped. Reading it
            // without asking fails with a permissions error that reads exactly
            // like a corrupt backup, which is the worst possible thing to tell
            // someone restoring their training.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let archive = try TrainingArchive(json: try Data(contentsOf: url))
            let report = try store.restore(from: archive)
            outcome = .restored(report)
            onRestored()
            Task { await loadSummary() }
        } catch {
            if !error.isUserCancelled { outcome = .failed(error.localizedDescription) }
        }
    }

    enum Outcome {
        case exported(sets: Int)
        case restored(RestoreReport)
        case failed(String)

        var title: String {
            switch self {
            case .exported: return "Exported"
            case .restored: return "Restored"
            case .failed:   return "That didn't work"
            }
        }

        var message: String {
            switch self {
            case .exported(let sets):
                return "\(sets) set\(sets == 1 ? "" : "s") written. Keep it somewhere that isn't this phone."

            case .restored(let report):
                guard !report.isEmpty else {
                    return "That backup was empty — nothing changed."
                }
                var text = "\(report.sets) set\(report.sets == 1 ? "" : "s") and \(report.exercises) lift\(report.exercises == 1 ? "" : "s") merged in. Anything already logged here was kept."
                if !report.deduplicated.isEmpty {
                    text += " \(report.deduplicated.total) duplicate row\(report.deduplicated.total == 1 ? "" : "s") merged."
                }
                return text

            case .failed(let reason):
                return reason
            }
        }
    }
}

private extension Error {
    /// The file picker reports dismissal as `CocoaError.userCancelled`, which
    /// is indistinguishable from a real failure unless it is asked for by name.
    var isUserCancelled: Bool {
        (self as? CocoaError)?.code == .userCancelled
    }
}
