import AppKit
import MowaCore
import SwiftUI

struct HistoryView: View {
    let controller: DictationController
    @ObservedObject private var store = HistoryStore.shared
    @EnvironmentObject var settings: AppSettings
    @State private var search = ""
    @State private var showRaw: Set<UUID> = []
    @State private var confirmClear = false

    private var filtered: [HistoryItem] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return store.items }
        return store.items.filter { $0.final.lowercased().contains(q) || $0.raw.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 18) {
                Stat(value: "\(store.wordsThisWeek)", label: L("words this week"))
                Stat(value: "\(store.totalWords)", label: L("words in total"))
                Stat(value: "\(store.items.count)", label: L("dictations"))
                Spacer()
                Button(L("Clear History…"), role: .destructive) { confirmClear = true }
                    .disabled(store.items.isEmpty)
            }
            if !settings.keepHistory {
                Text(L("History is turned off (Settings → General)."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            TextField(L("Search"), text: $search).textFieldStyle(.roundedBorder)

            List(filtered) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(item.date, style: .date).font(.caption).foregroundStyle(.secondary)
                        Text(item.date, style: .time).font(.caption).foregroundStyle(.secondary)
                        if let app = item.appName { Text("· \(app)").font(.caption).foregroundStyle(.secondary) }
                        if item.mode == .command {
                            Image(systemName: "wand.and.stars").font(.caption).foregroundStyle(.secondary)
                        }
                        Text("· \(item.language?.uppercased() ?? "?") · \(item.processedBy)")
                            .font(.caption).foregroundStyle(.tertiary)
                        Spacer()
                        Button { copy(item.final) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless).help(L("Copy"))
                        Button {
                            if showRaw.contains(item.id) { showRaw.remove(item.id) } else { showRaw.insert(item.id) }
                        } label: { Image(systemName: "waveform") }
                            .buttonStyle(.borderless).help(L("Show what Whisper heard"))
                        Button { store.delete(item) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help(L("Delete"))
                    }
                    Text(item.final).textSelection(.enabled)
                    if showRaw.contains(item.id) {
                        Text(item.raw)
                            .font(.callout).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
                    }
                }
                .padding(.vertical, 4)
            }
            .overlay {
                if filtered.isEmpty {
                    Text(store.items.isEmpty ? L("Your dictations will appear here.") : L("No matches."))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .confirmationDialog(L("Delete all dictation history?"), isPresented: $confirmClear) {
            Button(L("Delete All"), role: .destructive) { store.clear() }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct Stat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.title2).fontWeight(.semibold).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
