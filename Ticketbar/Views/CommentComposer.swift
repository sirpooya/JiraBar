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
        let image = NSImage(pasteboard: pasteboard)

        // The image wins unless the text beside it is real prose: see `PasteRouting`. The old
        // rule let any text at all beat the image, so pasting a screenshot copied out of a
        // browser or a design tool inserted its file name as a line of text and dropped the
        // picture on the floor.
        if PasteRouting.prefersImage(hasImageData: image != nil,
                                     text: pasteboard.string(forType: .string)),
           let png = image?.pngData() {
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
    /// Reported back as the text is laid out, so the box is as tall as what has been typed.
    @Binding var height: CGFloat
    var onPasteImage: (Data) -> Void

    /// One line, and the height the composer sits at when the draft is empty.
    static let restingHeight: CGFloat = 29
    /// After this the text view scrolls. A composer that keeps growing would push the thread it
    /// belongs to off the bottom of a popover that is only 340 points tall to begin with.
    static let maxVisibleLines = 5

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
        context.coordinator.applyDirection(textView)
        // Measured here as well as on every keystroke, because the draft also changes from outside
        // the text view: starting an edit loads an existing comment, which is often several lines,
        // and submitting one empties the box again.
        context.coordinator.remeasure(textView)
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, height: $height) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        private let height: Binding<CGFloat>

        init(text: Binding<String>, height: Binding<CGFloat>) {
            self.text = text
            self.height = height
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            applyDirection(textView)
            remeasure(textView)
        }

        /// Lays the box out in the direction the draft is actually written in, from its own first
        /// strong character. A draft that starts in Persian gets a right-to-left paragraph and
        /// sits against the right edge; one that starts in English is unchanged. Until a strong
        /// character is typed the box keeps whatever direction it had, so it does not flip about
        /// while somebody types a number or a bullet.
        func applyDirection(_ textView: NSTextView) {
            guard let direction = TextDirection.firstStrong(in: textView.string) else { return }
            let isRTL = direction == .rightToLeft
            let writing: NSWritingDirection = isRTL ? .rightToLeft : .leftToRight
            let alignment: NSTextAlignment = isRTL ? .right : .left
            guard textView.baseWritingDirection != writing || textView.alignment != alignment else {
                return
            }
            textView.baseWritingDirection = writing
            textView.alignment = alignment
        }

        /// Grows with the wrapped text rather than with the number of typed newlines: a long
        /// sentence that wraps onto a third line is three lines, which is what the eye counts.
        func remeasure(_ textView: NSTextView) {
            guard let container = textView.textContainer,
                  let layoutManager = textView.layoutManager else { return }
            layoutManager.ensureLayout(for: container)

            let inset = textView.textContainerInset.height * 2
            let line = layoutManager.defaultLineHeight(for: textView.font ?? .systemFont(ofSize: 12))
            let ceiling = CommentEditor.restingHeight
                + line * CGFloat(CommentEditor.maxVisibleLines - 1)
            let fitted = min(max(layoutManager.usedRect(for: container).height + inset,
                                 CommentEditor.restingHeight),
                             ceiling)

            // Deferred: this runs inside a SwiftUI update pass when it comes from updateNSView,
            // and writing to the binding there would be a mutation mid-render.
            DispatchQueue.main.async {
                guard abs(self.height.wrappedValue - fitted) > 0.5 else { return }
                self.height.wrappedValue = fitted
            }
        }
    }
}

/// Add a comment, or edit one. There is no delete control here, by design.
struct CommentComposer: View {
    @Bindable var store: IssueStore
    let issueKey: String

    @State private var editorHeight: CGFloat = CommentEditor.restingHeight

    private var isEditing: Bool { store.editingCommentID != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // No "Add a comment" heading. The section is already titled Comments and an empty
            // text box under it needs no label to explain itself.
            if isEditing {
                Text("Editing a comment")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            CommentEditor(text: $store.commentDraft, height: $editorHeight) { data in
                Task { await store.attachPastedImage(data, to: issueKey) }
            }
            // One line at rest, taller as lines are typed, and scrolling past five. It used to be
            // pinned at one line, so anything longer than a sentence was written through a slot.
            .frame(height: editorHeight)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06)))

            HStack(spacing: 8) {
                if store.isUploadingImage {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                    Text("Uploading image").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Paste a screenshot to attach it")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)

                if store.isSubmittingComment {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                }

                if isEditing {
                    Button("Cancel") { store.cancelCommentEdit() }
                        .controlSize(.small)
                }

                // Trailing: the confirming action sits where the eye ends up.
                Button(isEditing ? "Save" : "Comment") {
                    Task { await store.submitComment(on: issueKey) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(store.commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || store.isSubmittingComment)
            }
        }
    }
}
