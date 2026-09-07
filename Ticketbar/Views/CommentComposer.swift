import AppKit
import SwiftUI

/// A text view that understands a pasted image.
///
/// A screenshot on the clipboard is the common case here: the team pastes UI captures into design
/// issues constantly. `NSTextView` would otherwise drop the image on the floor, so paste is
/// intercepted, the bytes handed up, and the caller uploads them as an attachment.
private final class PastingTextView: NSTextView {
    var onPasteImage: ((Data) -> Void)?

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general

        // Text wins when the clipboard carries both. Copying an image from a browser usually also
        // puts its URL on the pasteboard, and silently uploading a screenshot when the user meant
        // to paste a link would be worse than the reverse.
        let hasText = pasteboard.string(forType: .string)?.isEmpty == false
        if !hasText, let image = NSImage(pasteboard: pasteboard), let png = image.pngData() {
            onPasteImage?(png)
            return
        }
        super.paste(sender)
    }
}

extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff) else { return nil }
        return representation.representation(using: .png, properties: [:])
    }
}

struct CommentEditor: NSViewRepresentable {
    @Binding var text: String
    var onPasteImage: (Data) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PastingTextView()
        textView.delegate = context.coordinator
        textView.onPasteImage = onPasteImage
        textView.font = .systemFont(ofSize: 12)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 5)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? PastingTextView else { return }
        textView.onPasteImage = onPasteImage
        // Only when it differs, or every keystroke would reset the insertion point to the end.
        if textView.string != text { textView.string = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}

/// Add a comment, or edit one. There is no delete control here, by design.
struct CommentComposer: View {
    @Bindable var store: IssueStore
    let issueKey: String

    private var isEditing: Bool { store.editingCommentID != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(isEditing ? "Editing a comment" : "Add a comment")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if store.isUploadingImage {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                        Text("Uploading image").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

            CommentEditor(text: $store.commentDraft) { data in
                Task { await store.attachPastedImage(data, to: issueKey) }
            }
            .frame(height: 58)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06)))

            HStack(spacing: 8) {
                Button(isEditing ? "Save" : "Comment") {
                    Task { await store.submitComment(on: issueKey) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(store.commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || store.isSubmittingComment)

                if isEditing {
                    Button("Cancel") { store.cancelCommentEdit() }
                        .controlSize(.small)
                }

                if store.isSubmittingComment {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                }

                Spacer(minLength: 0)

                Text("Paste a screenshot to attach it")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
