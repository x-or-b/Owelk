import SwiftUI

/// The desktop's six mark colors to choose from, the chosen one ringed in the accent.
struct InkChoice: View {
    @Binding var color: String
    private static let names = ["Blue", "Yellow", "Green", "Pink", "Purple", "Navy"]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(PenTool.colors.enumerated()), id: \.element) { index, hex in
                Button {
                    color = hex
                } label: {
                    Circle()
                        .fill(Color(uiColor: UIColor(hex: hex) ?? .black))
                        .frame(width: 22, height: 22)
                        .padding(4)
                        .overlay(Circle().strokeBorder(color == hex ? Theme.accent : .clear, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.names[index])
                .accessibilityAddTraits(color == hex ? .isSelected : [])
            }
        }
    }
}

/// A note typed, or written with Apple Pencil (Scribble turns handwriting into text in it).
private struct NoteField: View {
    @Binding var text: String
    let prompt: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        TextEditor(text: $text)
            .focused(focused)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 96, maxHeight: 220)
            .padding(6)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(prompt).foregroundStyle(.tertiary).padding(.horizontal, 11).padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// The quoted text with the mark's ink beside it.
private struct Quote: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 3)
            Text(text).font(.callout).foregroundStyle(.secondary).lineLimit(5)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A mark's note and color to change, and Delete. Changes are kept when it closes.
struct MarkEditor: View {
    let mark: Mark
    let finish: (_ color: String, _ body: String) -> Void
    let delete: () -> Void
    @State private var color: String
    @State private var note: String
    @State private var deleted = false
    @FocusState private var writing: Bool

    init(mark: Mark, finish: @escaping (String, String) -> Void, delete: @escaping () -> Void) {
        self.mark = mark
        self.finish = finish
        self.delete = delete
        _color = State(initialValue: PenTool.hex(nearest: mark.color))
        _note = State(initialValue: mark.body)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(mark.name).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) {
                    deleted = true
                    delete()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .labelStyle(.iconOnly)
                .foregroundStyle(.red)
            }
            if !mark.text.isEmpty { Quote(text: mark.text, color: Color(uiColor: UIColor(hex: color) ?? mark.color)) }
            NoteField(text: $note, prompt: "Add a note", focused: $writing)
            InkChoice(color: $color)
        }
        .padding(16)
        .onDisappear { if !deleted { finish(color, note) } }
    }
}

/// A comment on selected text: the note (needed, as on the desktop) and its color.
struct CommentComposer: View {
    let quote: String
    let save: (_ body: String, _ color: String) -> Void
    let cancel: () -> Void
    @State private var color = TextMarks.color
    @State private var note = ""
    @FocusState private var writing: Bool

    private var empty: Bool { note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Comment").font(.headline)
            if !quote.isEmpty { Quote(text: quote, color: Color(uiColor: UIColor(hex: color) ?? .gray)) }
            NoteField(text: $note, prompt: "Write a comment", focused: $writing)
            HStack {
                InkChoice(color: $color)
                Spacer()
                Button("Cancel", action: cancel)
                    .tint(.primary)
                Button("Save") { save(note, color) }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(empty)
            }
        }
        .padding(16)
        .onAppear { writing = true }
    }
}
