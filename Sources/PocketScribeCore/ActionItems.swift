import EventKit
import Foundation

/// An action item line from a summary ("Sam: send the budget report (by Friday) [12:30]"),
/// cleaned up into what a reminder or calendar event needs.
public struct ActionItem: Sendable, Equatable {
    /// The task without timestamps, Markdown links or the deadline parenthetical.
    public var title: String
    /// A date found in the text ("by Friday", "Nov 14 at 3pm"), if any.
    public var due: Date?
    /// True when the text gave a time of day, not just a day.
    public var dueHasTime: Bool

    public init(_ line: String, speakerNames: [Int: String]? = nil, now: Date = Date()) {
        var text = Speakers.apply(speakerNames, to: line)
        // "[01:23](seek://83)" or "[01:23]" → gone; "[label](url)" → "label"; strip emphasis.
        text = text.replacingOccurrences(of: #"\[(?:\d{1,2}:)?\d{1,2}:\d{2}\](\([^)]*\))?"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")

        var due: Date?
        var hasTime = false
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
           let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let date = match.date, let range = Range(match.range, in: text) {
            due = date
            let phrase = String(text[range])
            hasTime = phrase.range(of: #"\d{1,2}(:\d{2})?\s*(am|pm|a\.m\.|p\.m\.)|\d{1,2}:\d{2}|\b(noon|midnight|morning|afternoon|evening|tonight)\b"#,
                                   options: [.regularExpression, .caseInsensitive]) != nil
            // A deadline in parentheses, "(by Friday)", isn't part of the task name.
            text = text.replacingOccurrences(of: #"\s*\((?:by|due|before|until)?[^()]*\)\s*$"#, with: "",
                                             options: [.regularExpression, .caseInsensitive])
            // A date that only says "today" at a time already passed means today, not a past moment.
            if let d = due, d < now, !hasTime { due = Calendar.current.startOfDay(for: now) }
        }
        title = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—:")))
        if title.isEmpty { title = line.trimmingCharacters(in: .whitespacesAndNewlines) }
        self.due = due
        self.dueHasTime = hasTime
    }

    /// When a calendar event for this item should start: its time, 9:00 on its day, or tomorrow at 9:00.
    public func suggestedEventStart(now: Date = Date()) -> Date {
        let cal = Calendar.current
        if let due, dueHasTime { return due }
        let day = due ?? cal.date(byAdding: .day, value: 1, to: now)!
        return cal.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
    }
}

public enum ActionItemError: LocalizedError {
    case remindersDenied, calendarDenied, noDefaultList, noDefaultCalendar

    public var errorDescription: String? {
        switch self {
        case .remindersDenied:
            return "Pocket Scribe isn't allowed to add reminders. Turn it on in System Settings › Privacy & Security › Reminders."
        case .calendarDenied:
            return "Pocket Scribe isn't allowed to add events. Turn it on in System Settings › Privacy & Security › Calendars."
        case .noDefaultList: return "There's no default Reminders list to add to."
        case .noDefaultCalendar: return "There's no default calendar to add to."
        }
    }
}

/// Sends action items to Reminders and Calendar with EventKit. Everything stays on the device
/// (and in whatever account the user's Reminders and Calendar already sync with).
@MainActor
public final class ActionItemSender {
    public static let shared = ActionItemSender()
    public let store = EKEventStore()

    public init() {}

    /// Adds one reminder per item to the default Reminders list. Returns how many were added.
    @discardableResult
    public func addReminders(_ items: [ActionItem], from recordingTitle: String, link: URL? = nil) async throws -> Int {
        guard try await store.requestFullAccessToReminders() else { throw ActionItemError.remindersDenied }
        guard let list = store.defaultCalendarForNewReminders() else { throw ActionItemError.noDefaultList }
        for item in items {
            let r = EKReminder(eventStore: store)
            r.calendar = list
            r.title = item.title
            r.notes = "From “\(recordingTitle)” in Pocket Scribe"
            r.url = link
            if let due = item.due {
                let comps: Set<Calendar.Component> = item.dueHasTime
                    ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
                r.dueDateComponents = Calendar.current.dateComponents(comps, from: due)
                if item.dueHasTime { r.addAlarm(EKAlarm(absoluteDate: due)) }
            }
            try store.save(r, commit: false)
        }
        try store.commit()
        return items.count
    }

    /// A new, unsaved event for the item (30 minutes, or all day when only a day was given),
    /// for the system event editor on iOS. Needs no Calendar permission until it is saved there.
    public func draftEvent(_ item: ActionItem, from recordingTitle: String, link: URL? = nil) -> EKEvent {
        let e = EKEvent(eventStore: store)
        e.title = item.title
        e.notes = "From “\(recordingTitle)” in Pocket Scribe"
        e.url = link
        let start = item.suggestedEventStart()
        e.startDate = start
        e.endDate = start.addingTimeInterval(30 * 60)
        return e
    }

    /// Saves an event straight to the default calendar (asks for add-only Calendar access).
    /// Returns its start date so the UI can say when it was added.
    @discardableResult
    public func addEvent(_ item: ActionItem, from recordingTitle: String, link: URL? = nil) async throws -> Date {
        guard try await store.requestWriteOnlyAccessToEvents() else { throw ActionItemError.calendarDenied }
        let e = draftEvent(item, from: recordingTitle, link: link)
        guard let cal = store.defaultCalendarForNewEvents else { throw ActionItemError.noDefaultCalendar }
        e.calendar = cal
        try store.save(e, span: .thisEvent, commit: true)
        return e.startDate
    }
}
