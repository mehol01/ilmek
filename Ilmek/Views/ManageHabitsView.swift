import SwiftUI
import SwiftData
import IlmekKit

/// All habits in one place: drag to reorder, open to edit, and bring archived ones back.
struct ManageHabitsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Habit.sortOrder) private var habits: [Habit]

    @State private var editing: Habit?
    @State private var deleting: Habit?

    var body: some View {
        let active = habits.filter { $0.archivedAt == nil }
        let archived = habits.filter { $0.archivedAt != nil }
            .sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }

        List {
            Section {
                if active.isEmpty {
                    Text("Henüz alışkanlık yok").foregroundStyle(.secondary)
                }
                ForEach(active) { h in
                    Button { editing = h } label: { row(h) }
                        .buttonStyle(.plain)
                }
                .onMove { from, to in move(active, from: from, to: to) }
            } header: {
                Text("Alışkanlıklar")
            } footer: {
                if active.count > 1 { Text("Sıralamak için Düzenle'ye bas ve sürükle.") }
            }

            if !archived.isEmpty {
                Section {
                    ForEach(archived) { h in
                        row(h)
                            .swipeActions(edge: .trailing) {
                                Button("Sil", systemImage: "trash", role: .destructive) { deleting = h }
                            }
                            .swipeActions(edge: .leading) {
                                Button("Geri al", systemImage: "arrow.uturn.backward") { unarchive(h, after: active) }
                                    .tint(.accentColor)
                            }
                            .contextMenu {
                                Button("Arşivden çıkar", systemImage: "arrow.uturn.backward") { unarchive(h, after: active) }
                                Button("Sil", systemImage: "trash", role: .destructive) { deleting = h }
                            }
                    }
                } header: {
                    Text("Arşiv")
                } footer: {
                    Text("Arşivdekiler listede görünmez ama geçmişleri ve serileri durur. Geri almak için sağa kaydır.")
                }
            }
        }
        .navigationTitle("Alışkanlıklarım")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if active.count > 1 { EditButton() } }
        .sheet(item: $editing) { HabitEditorView(habit: $0) }
        .confirmationDialog("Bu alışkanlık ve tüm geçmişi silinsin mi?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Sil", role: .destructive) {
                if let h = deleting { withAnimation { context.delete(h); context.saveQuietly() } }
                deleting = nil
            }
        } message: {
            Text("Bu işlem geri alınamaz.")
        }
    }

    private func row(_ h: Habit) -> some View {
        HStack(spacing: 12) {
            HabitBadge(emoji: h.emoji, color: h.color.color, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(h.name).font(.body.weight(.medium)).lineLimit(1)
                Text(h.schedule.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if h.isMedication {
                Image(systemName: "pills.fill").font(.caption).foregroundStyle(.secondary)
            }
        }
        .contentShape(.rect)
        .opacity(h.archivedAt == nil ? 1 : 0.6)
    }

    private func move(_ active: [Habit], from: IndexSet, to: Int) {
        var list = active
        list.move(fromOffsets: from, toOffset: to)
        // Rewrite only what changed, so sync sends as little as possible.
        for (i, h) in list.enumerated() where h.sortOrder != Double(i) { h.sortOrder = Double(i) }
        context.saveQuietly()
    }

    private func unarchive(_ h: Habit, after active: [Habit]) {
        withAnimation {
            h.archivedAt = nil
            h.sortOrder = (active.map(\.sortOrder).max() ?? -1) + 1
            context.saveQuietly()
        }
    }
}
