import AVFoundation
import Foundation

/// Saving, loading and housekeeping for the library folder. Shared by the Mac and iOS apps
/// so both keep notes safe the same way.
public enum LibraryFiles {
    /// Days a deleted item stays in Recently Deleted before it is removed for good.
    public static let trashDays = 30

    /// Writes one item as `<id>.json`. The write is atomic: a crash or a full disk mid-save
    /// leaves the previous version in place, never half a file.
    public static func save<T: Encodable>(_ item: T, id: UUID, in dir: URL) throws {
        let data = try JSONEncoder().encode(item)
        try data.write(to: dir.appending(path: "\(id.uuidString).json"), options: [.atomic])
    }

    public struct Loaded<T> {
        public var items: [T]
        /// Files that are there but couldn't be read. They are left untouched, never deleted.
        public var unreadable: [String]
    }

    /// Reads every `.json` item in the folder, and reports the ones it couldn't read instead
    /// of skipping them silently.
    public static func load<T: Decodable>(_ type: T.Type, from dir: URL) -> Loaded<T> {
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var items: [T] = []
        var unreadable: [String] = []
        for file in files {
            do { items.append(try JSONDecoder().decode(T.self, from: Data(contentsOf: file))) }
            catch { unreadable.append(file.lastPathComponent) }
        }
        return Loaded(items: items, unreadable: unreadable)
    }

    /// What to tell the user when some saved items couldn't be opened.
    public static func unreadableMessage(_ names: [String], in dir: URL) -> String? {
        guard !names.isEmpty else { return nil }
        let what = names.count == 1 ? "1 saved item couldn't be opened" : "\(names.count) saved items couldn't be opened"
        return "\(what), so it isn't shown. Nothing was deleted: the file stays in the app's \(dir.lastPathComponent) folder."
    }

    /// True when a deleted item has been in Recently Deleted long enough to remove for good.
    public static func isExpired(deletedAt: Date?, now: Date = Date()) -> Bool {
        guard let d = deletedAt else { return false }
        return now.timeIntervalSince(d) > Double(trashDays) * 86_400
    }

    // MARK: Crash-safe recordings

    /// Recordings are written as IMA4 in a CAF file: unlike .m4a, a CAF file that was cut off
    /// by a crash, a force quit or a dead battery still opens and plays up to the last moment.
    /// IMA4 keeps it small (about 33 MB an hour at 16 kHz mono).
    public static let recordingExtension = "caf"
    public static let recordingSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatAppleIMA4,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
    ]

    /// Recordings that were being made when the app quit unexpectedly: audio files in the
    /// Audio folder that no library item points to and that still hold sound.
    public static func orphanRecordings(in audioDir: URL, known: Set<String>) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: audioDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.filter { url in
            guard url.pathExtension.lowercased() == recordingExtension, !known.contains(url.lastPathComponent) else { return false }
            guard let f = try? AVAudioFile(forReading: url) else { return false }
            return Double(f.length) / f.processingFormat.sampleRate >= 1
        }
    }

    /// When a recording file was started (its creation date), for a recovered recording's title.
    public static func creationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
    }
}

extension LibraryItem {
    /// A title for a typed note: its first line, without Markdown marks, cut to a sensible length.
    public static func title(forNote body: String, createdAt: Date = Date()) -> String {
        let first = body.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        var t = first
        for prefix in ["- [ ] ", "- [x] ", "- [X] ", "* ", "- ", "> "] where t.hasPrefix(prefix) {
            t = String(t.dropFirst(prefix.count))
        }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
        t = t.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        if t.isEmpty { return "Note, " + createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()) }
        if t.count > 60 {
            let cut = t.prefix(60)
            t = (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + "…"
        }
        return t
    }

    /// A new note typed in the app: no audio or file behind it, ready right away.
    public static func writtenNote(id: UUID = UUID(), createdAt: Date = Date()) -> LibraryItem {
        var item = LibraryItem(id: id, title: "", createdAt: createdAt, audioFileName: "", status: .ready)
        item.noteKind = .note
        item.summary = ""
        return item
    }
}
