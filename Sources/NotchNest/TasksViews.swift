import SwiftUI

struct TasksView: View {
    @Bindable var tasks: TasksService
    let openSettings: () -> Void

    var body: some View {
        if !tasks.hasSource {
            VStack(spacing: 8) {
                Image(systemName: "checklist").font(.system(size: 22)).foregroundStyle(.secondary)
                Text("Connect Google Tasks, or turn on Apple Reminders, in Settings.").font(.system(size: 11)).foregroundStyle(.secondary)
                pill("Open Settings", action: openSettings)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if tasks.needsReconnect {
            VStack(spacing: 7) {
                Image(systemName: "checklist").font(.system(size: 22)).foregroundStyle(.secondary)
                Text("Google Tasks needs one more sign-in").font(.system(size: 12, weight: .semibold))
                Text("Turn on the Google Tasks API in your Cloud project, then sign in again.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    pill("1 · Enable Tasks API ↗") {
                        NSWorkspace.shared.open(URL(string: "https://console.cloud.google.com/apis/library/tasks.googleapis.com")!)
                    }
                    pill(tasks.auth.isSigningIn ? "Waiting for browser…" : "2 · Sign in again") {
                        Task { await tasks.auth.signIn() }
                    }
                }
                if let message = tasks.auth.statusMessage {
                    Text(message).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            list
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Menu {
                    let google = tasks.lists.filter { !$0.isApple }
                    let reminders = tasks.lists.filter(\.isApple)
                    if !google.isEmpty {
                        Section("Google Tasks") {
                            ForEach(google) { list in Button(list.title) { tasks.selectedListID = list.id } }
                        }
                    }
                    if !reminders.isEmpty {
                        Section("Reminders") {
                            ForEach(reminders) { list in Button(list.title) { tasks.selectedListID = list.id } }
                        }
                    }
                } label: {
                    Text(tasks.currentList?.title ?? "Tasks").font(.system(size: 12, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Menu {
                    Picker("Sort by", selection: $tasks.sort) {
                        Text("Date").tag(TaskSort.date)
                        Text("My order").tag(TaskSort.myOrder)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(tasks.sort == .date ? "Date" : "My order", systemImage: "arrow.up.arrow.down")
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Sort tasks")
                TextField("Add a task and press Return", text: $tasks.draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .onSubmit { tasks.addTask() }
                if tasks.isLoading { ProgressView().controlSize(.mini) }
            }
            if tasks.tasks.isEmpty {
                Text(tasks.lastError ?? (tasks.lastUpdated == nil ? "Loading…" : "All done. Nothing left on this list."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Two columns, read top-to-bottom, so the order (and subtasks) run down each column.
                let shown = tasks.displayedTasks
                let half = (shown.count + 1) / 2
                ScrollView(.vertical, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        column(Array(shown.prefix(half)))
                        column(Array(shown.dropFirst(half)))
                    }
                }
            }
        }
    }

    private func column(_ items: [GTask]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(items) { task in
                // Indenting subtasks only makes sense in Google's order, where they follow their parent.
                TaskRow(task: task, indented: task.isSubtask && tasks.sort == .myOrder) { tasks.complete(task) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}

struct TaskRow: View {
    let task: GTask
    let indented: Bool
    let complete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Button(action: complete) {
                Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(task.completed ? Color.accentColor : Color.white.opacity(0.55))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .disabled(task.completed)
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .strikethrough(task.completed)
                    .foregroundStyle(task.completed ? .secondary : .primary)
                if let due = task.due {
                    let label = Self.dueLabel(due)
                    Text(label.text).font(.system(size: 9, weight: .medium)).foregroundStyle(label.color)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, indented ? 16 : 0)
        .frame(minHeight: 26, alignment: .top)
    }

    private static func dueLabel(_ date: Date) -> (text: String, color: Color) {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return ("Today", .orange) }
        if cal.isDateInTomorrow(date) { return ("Tomorrow", Color.white.opacity(0.5)) }
        if date < cal.startOfDay(for: .now) { return (date.formatted(.dateTime.month(.abbreviated).day()), .red) }
        return (date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()), Color.white.opacity(0.5))
    }
}
