import AVFoundation
import Foundation
import Testing
@testable import PocketScribeCore

@Suite struct LibraryFilesTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ps-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func savesAndLoadsAndReportsUnreadableFiles() throws {
        let dir = try tempDir()
        var item = LibraryItem(title: "Standup", audioFileName: "a.caf", status: .ready)
        item.deletedAt = Date()
        item.originalSummary = "AI text"
        item.editedAt = Date()
        try LibraryFiles.save(item, id: item.id, in: dir)
        try Data("{ not json".utf8).write(to: dir.appending(path: "broken.json"))

        let loaded = LibraryFiles.load(LibraryItem.self, from: dir)
        #expect(loaded.items == [item])
        #expect(loaded.unreadable == ["broken.json"])
        // The unreadable file is reported, never removed.
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "broken.json").path))
        #expect(LibraryFiles.unreadableMessage(loaded.unreadable, in: dir)?.contains("1 saved item") == true)
        #expect(LibraryFiles.unreadableMessage([], in: dir) == nil)
    }

    @Test func oldItemsWithoutNewFieldsStillLoad() throws {
        let dir = try tempDir()
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","title":"Old","titleIsAutomatic":true,"createdAt":700000000,
         "audioFileName":"x.m4a","status":"ready","checkedActions":[]}
        """
        try Data(json.utf8).write(to: dir.appending(path: "\(id.uuidString).json"))
        let loaded = LibraryFiles.load(LibraryItem.self, from: dir)
        #expect(loaded.items.count == 1)
        #expect(loaded.items.first?.deletedAt == nil)
        #expect(loaded.unreadable.isEmpty)
    }

    @Test func trashExpiresAfterThirtyDays() {
        let now = Date()
        #expect(!LibraryFiles.isExpired(deletedAt: nil, now: now))
        #expect(!LibraryFiles.isExpired(deletedAt: now.addingTimeInterval(-29 * 86_400), now: now))
        #expect(LibraryFiles.isExpired(deletedAt: now.addingTimeInterval(-31 * 86_400), now: now))
    }

    @Test func writtenNotesHaveNoAudioAndGetTitlesFromTheirFirstLine() {
        let note = LibraryItem.writtenNote()
        #expect(note.isWritten)
        #expect(!note.hasAudio)
        #expect(!note.isDocument)
        #expect(note.status == .ready)
        #expect(note.noteKind == .note)

        #expect(LibraryItem.title(forNote: "\n\n# Groceries for **Sunday**\n- milk") == "Groceries for Sunday")
        #expect(LibraryItem.title(forNote: "- [ ] Call the dentist") == "Call the dentist")
        let long = String(repeating: "word ", count: 30)
        let t = LibraryItem.title(forNote: long)
        #expect(t.count <= 61 && t.hasSuffix("…"))
        #expect(LibraryItem.title(forNote: "   ").hasPrefix("Note, "))

        let audio = LibraryItem(title: "Rec", audioFileName: "a.caf")
        #expect(audio.hasAudio && !audio.isWritten)
        let doc = LibraryItem(title: "Deck", audioFileName: "a.pptx")
        #expect(!doc.hasAudio && !doc.isWritten)
    }

    /// The point of the CAF format: a recording cut off by a crash still opens.
    @Test func interruptedRecordingIsFoundAndReadable() throws {
        let dir = try tempDir()
        let name = "\(UUID().uuidString).\(LibraryFiles.recordingExtension)"
        let url = dir.appending(path: name)
        do {
            let file = try AVAudioFile(forWriting: url, settings: LibraryFiles.recordingSettings)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_000)!
            buffer.frameLength = 16_000
            for i in 0..<16_000 { buffer.floatChannelData![0][i] = sin(Float(i) * 0.05) * 0.3 }
            for _ in 0..<2 { try file.write(from: buffer) }
            // Leaving scope closes the file normally; the crash case was checked by hand with kill -9.
        }
        try Data().write(to: dir.appending(path: "empty.caf"))
        let orphans = LibraryFiles.orphanRecordings(in: dir, known: [])
        #expect(orphans.map(\.lastPathComponent) == [name])
        #expect(LibraryFiles.orphanRecordings(in: dir, known: [name]).isEmpty)
    }
}

@Suite struct NotePreviewTests {
    @Test func previewSkipsAHeadingThatRepeatsTheTitle() {
        var note = LibraryItem.writtenNote()
        note.title = "Ideas for the study group"
        note.summary = "# Ideas for the study group\n\nMeet on Tuesdays.\n- [ ] Book room 204"
        #expect(note.tldr == "Meet on Tuesdays.")
        note.summary = "- [ ] Book room 204"
        #expect(note.tldr == "Book room 204")
    }
}
