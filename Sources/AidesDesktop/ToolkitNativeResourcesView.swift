import Contacts
import EventKit
import SwiftUI

struct ToolkitNativeResourcesView: View {
    var body: some View {
        Form {
            ToolkitCalendarSection()
            ToolkitContactsSection()
        }
        .formStyle(.grouped)
    }
}

private struct ToolkitCalendarSection: View {
    @ViewState private var store = EKEventStore()
    @ViewState private var calendarChoices: [CalendarChoice] = []
    @ViewState private var calendarID: String?
    @ViewState private var selectedDay = Date.now
    @ViewState private var dayEvents: [DayEvent]?
    @ViewState private var busy = false
    @ViewState private var error: String?
    @ViewState private var showsNewEvent = false
    @ViewState private var editingEvent: DayEvent?

    private var calendar: EKCalendar? {
        calendarID.flatMap { store.calendar(withIdentifier: $0) }
    }

    var body: some View {
        Section("Calendar on this Mac") {
            if calendarChoices.isEmpty {
                Button("Load calendars…") { Task { await loadCalendars() } }
                    .disabled(busy)
            } else {
                Picker("Calendar", selection: $calendarID) {
                    Text("Choose a calendar").tag(String?.none)
                    ForEach(calendarChoices) { choice in
                        Text("\(choice.title) · \(choice.account)").tag(Optional(choice.id))
                    }
                }
                DatePicker("Day", selection: $selectedDay, displayedComponents: .date)
                HStack {
                    Button("View day") { loadDay() }
                        .disabled(calendarID == nil)
                    Button("Add event…") { showsNewEvent = true }
                        .disabled(calendar?.allowsContentModifications != true)
                }
                .disabled(busy)
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            if let dayEvents {
                if dayEvents.isEmpty {
                    Text("No events for this day.").foregroundStyle(.secondary)
                }
                ForEach(dayEvents) { event in
                    HStack {
                        LabeledContent(event.title, value: event.allDay ? "All day" : timeRange(event.start, event.end))
                        if event.canEdit {
                            Button("Edit…") { editingEvent = event }
                        }
                    }
                }
                LabeledContent("Availability") {
                    VStack(alignment: .trailing, spacing: 3) {
                        let open = availableTimes(excluding: dayEvents)
                        if open.isEmpty {
                            Text("No open time")
                        }
                        ForEach(open, id: \.start) { interval in
                            Text(timeRange(interval.start, interval.end))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .sheet(isPresented: $showsNewEvent) {
            if let calendar {
                ToolkitCalendarEventSheet(store: store, calendar: calendar, day: selectedDay, onSaved: loadDay)
            }
        }
        .sheet(item: $editingEvent) { event in
            if let calendar {
                ToolkitCalendarEventSheet(store: store, calendar: calendar, day: selectedDay, original: event, onSaved: loadDay)
            }
        }
        .onChange(of: calendarID) { _, _ in dayEvents = nil }
        .onChange(of: selectedDay) { _, _ in dayEvents = nil }
    }

    private func loadCalendars() async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            guard try await store.requestFullAccessToEvents() else {
                error = "Calendar access is disabled. Enable Aides under Privacy & Security in System Settings."
                return
            }
            calendarChoices = store.calendars(for: .event).map {
                CalendarChoice(id: $0.calendarIdentifier, title: $0.title, account: $0.source?.title ?? "Local calendar")
            }
            if calendarChoices.isEmpty { error = "No calendars are available on this Mac." }
            calendarID = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadDay() {
        error = nil
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess, let calendar,
              let day = Calendar.current.dateInterval(of: .day, for: selectedDay) else {
            dayEvents = nil
            error = "The calendar is unavailable or access was revoked."
            return
        }
        let predicate = store.predicateForEvents(withStart: day.start, end: day.end, calendars: [calendar])
        // Include each occurrence. Recurring events may share the provider's event identifier.
        let rows = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }.map { event in
            DayEvent(
                identifier: event.eventIdentifier, version: event.lastModifiedDate, title: event.title ?? "(No title)",
                start: event.startDate, end: event.endDate, allDay: event.isAllDay,
                available: event.availability == .free || event.status == .canceled,
                canEdit: calendar.allowsContentModifications && DayEvent.canEdit(event)
            )
        }
        dayEvents = rows
    }

    private func availableTimes(excluding events: [DayEvent]) -> [DateInterval] {
        guard let day = Calendar.current.dateInterval(of: .day, for: selectedDay) else { return [] }
        var start = day.start
        var open: [DateInterval] = []
        for event in events where !event.available && event.end > start && event.start < day.end {
            let end = min(event.start, day.end)
            if end > start { open.append(DateInterval(start: start, end: end)) }
            start = max(start, min(day.end, event.end))
        }
        if start < day.end { open.append(DateInterval(start: start, end: day.end)) }
        return open
    }

    private func timeRange(_ start: Date, _ end: Date) -> String {
        let time = Date.FormatStyle(date: .omitted, time: .shortened)
        if !Calendar.current.isDate(start, inSameDayAs: end) {
            return "\(start.formatted(time)) – \(end.formatted(.dateTime.weekday().hour().minute()))"
        }
        return "\(start.formatted(time)) – \(end.formatted(time))"
    }
}

private struct CalendarChoice: Identifiable {
    let id: String
    let title: String
    let account: String
}

private struct DayEvent: Identifiable {
    let id = UUID()
    let identifier: String?
    let version: Date?
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let available: Bool
    let canEdit: Bool

    static func canEdit(_ event: EKEvent) -> Bool {
        event.eventIdentifier != nil && !event.isAllDay && !event.hasRecurrenceRules &&
            !event.hasAttendees && event.organizer == nil && event.status != .canceled
    }
}

private struct ToolkitCalendarEventSheet: View {
    let store: EKEventStore
    let calendar: EKCalendar
    let original: DayEvent?
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @ViewState private var title: String
    @ViewState private var start: Date
    @ViewState private var end: Date
    @ViewState private var error: String?
    @ViewState private var confirms = false

    init(store: EKEventStore, calendar: EKCalendar, day: Date, original: DayEvent? = nil, onSaved: @escaping () -> Void) {
        self.store = store
        self.calendar = calendar
        self.original = original
        self.onSaved = onSaved
        let initial = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
        _title = ViewState(initialValue: original?.title ?? "")
        _start = ViewState(initialValue: original?.start ?? initial)
        _end = ViewState(initialValue: original?.end ?? initial.addingTimeInterval(3_600))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            PageHeading(original == nil ? "Add calendar event" : "Edit calendar event")
            Form {
                LabeledContent("Calendar", value: calendar.title)
                TextField("Title", text: $title)
                DatePicker("Starts", selection: $start)
                DatePicker("Ends", selection: $end)
            }
            if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Review event") { confirms = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(end <= start || title.trimmed.isEmpty || title.trimmed.count > 180)
            }
        }
        .padding(22)
        .frame(width: 470)
        .confirmationDialog(original == nil ? "Add this event?" : "Save changes to this event?", isPresented: $confirms) {
            Button(original == nil ? "Confirm and add" : "Confirm and save") { save() }
        } message: {
            Text("""
            \(title.trimmed)
            \(calendar.title) · \(calendar.source?.title ?? "Local calendar")
            \(start.formatted(date: .abbreviated, time: .shortened)) – \(end.formatted(date: .abbreviated, time: .shortened))
            """)
        }
    }

    private func save() {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess, calendar.allowsContentModifications else {
            error = "Calendar write access is unavailable."
            return
        }
        let event: EKEvent
        if let original {
            guard let id = original.identifier, let current = store.event(withIdentifier: id),
                  current.calendar.calendarIdentifier == calendar.calendarIdentifier, DayEvent.canEdit(current),
                  current.lastModifiedDate == original.version, (current.title ?? "(No title)") == original.title,
                  current.startDate == original.start, current.endDate == original.end else {
                error = "The event changed or can no longer be edited. Close this form and select it again."
                return
            }
            event = current
        } else {
            event = EKEvent(eventStore: store)
            event.calendar = calendar
        }
        event.title = title.trimmed
        event.startDate = start
        event.endDate = end
        do {
            try store.save(event, span: .thisEvent)
            onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ToolkitContactsSection: View {
    @ViewState private var containers: [ContactContainer] = []
    @ViewState private var containerID: String?
    @ViewState private var query = ""
    @ViewState private var contacts: [ContactMatch]?
    @ViewState private var editing: ContactMatch?
    @ViewState private var busy = false
    @ViewState private var error: String?

    var body: some View {
        Section("Contacts on this Mac") {
            if containers.isEmpty {
                Button("Load contact accounts…") { Task { await loadAccounts() } }
                    .disabled(busy)
            } else {
                Picker("Account", selection: $containerID) {
                    Text("Choose an account").tag(String?.none)
                    ForEach(containers) { container in
                        Text(container.name.isEmpty ? "Local contacts" : container.name).tag(Optional(container.id))
                    }
                }
                HStack {
                    TextField("Name or email", text: $query)
                        .onSubmit { Task { await lookup() } }
                    Button("Find contacts") { Task { await lookup() } }
                        .disabled(containerID == nil || query.trimmed.isEmpty)
                }
                .disabled(busy)
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            if let contacts {
                if contacts.isEmpty { Text("No matching contacts.").foregroundStyle(.secondary) }
                ForEach(contacts) { contact in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(contact.name.isEmpty ? "(No name)" : contact.name)
                            Text(contact.emails.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                        }
                        .textSelection(.enabled)
                        Spacer()
                        Button("Edit email…") { editing = contact }
                    }
                }
            }
        }
        .sheet(item: $editing) { contact in
            if let container = containers.first(where: { $0.id == containerID }) {
                EditToolkitContactEmail(container: container, contact: contact) { Task { await lookup() } }
            }
        }
        .onChange(of: containerID) { _, _ in contacts = nil }
    }

    private func loadAccounts() async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let store = CNContactStore()
            guard try await store.requestAccess(for: .contacts) else {
                error = "Contacts access is disabled. Enable Aides under Privacy & Security in System Settings."
                return
            }
            containers = try await Task.detached {
                try CNContactStore().containers(matching: nil).map { ContactContainer(id: $0.identifier, name: $0.name) }
            }.value
            if containers.isEmpty { error = "No contact accounts are available on this Mac." }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func lookup() async {
        let term = query.trimmed
        guard !busy, let selected = containerID, !term.isEmpty else { return }
        busy = true
        error = nil
        contacts = nil
        defer { busy = false }
        do {
            let matches = try await Task.detached {
                let keys = [
                    CNContactIdentifierKey, CNContactGivenNameKey, CNContactFamilyNameKey, CNContactEmailAddressesKey,
                ] as [CNKeyDescriptor]
                let request = CNContactFetchRequest(keysToFetch: keys)
                request.predicate = CNContact.predicateForContactsInContainer(withIdentifier: selected)
                request.unifyResults = false
                var results: [ContactMatch] = []
                try CNContactStore().enumerateContacts(with: request) { contact, stop in
                    let name = "\(contact.givenName) \(contact.familyName)".trimmed
                    let emails = contact.emailAddresses.map { $0.value as String }
                    if name.localizedCaseInsensitiveContains(term) ||
                        emails.contains(where: { $0.localizedCaseInsensitiveContains(term) }) {
                        results.append(ContactMatch(id: contact.identifier, name: name, emails: emails))
                        if results.count >= 30 { stop.pointee = true }
                    }
                }
                return results
            }.value
            if containerID == selected && query.trimmed == term { contacts = matches }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ContactContainer: Identifiable, Sendable {
    let id: String
    let name: String
}

private struct ContactMatch: Identifiable, Sendable {
    let id: String
    let name: String
    let emails: [String]
}


private struct EditToolkitContactEmail: View {
    let container: ContactContainer
    let contact: ContactMatch
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @ViewState private var index: Int?
    @ViewState private var address = ""
    @ViewState private var confirmation = false
    @ViewState private var saving = false
    @ViewState private var error: String?

    private var currentAddress: String? {
        guard let index, contact.emails.indices.contains(index) else { return nil }
        return contact.emails[index]
    }

    private var ready: Bool {
        let email = address.trimmed
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty } && email.utf8.count <= 254 &&
            !email.contains(where: { $0.isWhitespace || $0.isNewline }) && currentAddress != email
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            PageHeading("Edit contact email")
            Form {
                LabeledContent("Contact", value: contact.name.isEmpty ? "(No name)" : contact.name)
                LabeledContent("Account", value: container.name.isEmpty ? "Local contacts" : container.name)
                Picker("Email", selection: $index) {
                    Text("Add an address").tag(Int?.none)
                    ForEach(contact.emails.indices, id: \.self) { index in
                        Text(contact.emails[index]).tag(Optional(index))
                    }
                }
                TextField("New email address", text: $address)
            }
            .onChange(of: index) { _, _ in address = currentAddress ?? "" }
            if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Review change") { confirmation = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(!ready)
            }
        }
        .disabled(saving)
        .padding(22)
        .frame(width: 470)
        .confirmationDialog("Change this contact?", isPresented: $confirmation) {
            Button("Confirm and save") { Task { await save() } }
        } message: {
            Text("""
            \(contact.name) · \(container.name.isEmpty ? "Local contacts" : container.name)
            \(currentAddress ?? "New address") → \(address.trimmed)
            """)
        }
    }

    private func save() async {
        guard ready, !saving else { return }
        let accountID = container.id
        let selected = contact
        let index = index
        let newAddress = address.trimmed
        saving = true
        error = nil
        defer { saving = false }
        do {
            try await Task.detached {
                let store = CNContactStore()
                let keys: [CNKeyDescriptor] = [
                    CNContactIdentifierKey as CNKeyDescriptor, CNContactGivenNameKey as CNKeyDescriptor,
                    CNContactFamilyNameKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor,
                ]
                let request = CNContactFetchRequest(keysToFetch: keys)
                request.predicate = CNContact.predicateForContactsInContainer(withIdentifier: accountID)
                request.unifyResults = false
                var current: CNContact?
                try store.enumerateContacts(with: request) { match, stop in
                    if match.identifier == selected.id {
                        current = match
                        stop.pointee = true
                    }
                }
                guard let current,
                      "\(current.givenName) \(current.familyName)".trimmed == selected.name,
                      current.emailAddresses.map({ $0.value as String }) == selected.emails,
                      let editable = current.mutableCopy() as? CNMutableContact else {
                    throw ToolkitContactError.changed
                }
                var emails = current.emailAddresses
                if let index, emails.indices.contains(index) {
                    emails[index] = emails[index].settingValue(newAddress as NSString)
                } else if index == nil {
                    emails.append(CNLabeledValue(label: CNLabelOther, value: newAddress as NSString))
                } else {
                    throw ToolkitContactError.changed
                }
                editable.emailAddresses = emails
                let change = CNSaveRequest()
                change.update(editable)
                try store.execute(change)
            }.value
            onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private enum ToolkitContactError: LocalizedError {
    case changed

    var errorDescription: String? {
        "The contact has changed or moved. Close this form and look it up again."
    }
}
