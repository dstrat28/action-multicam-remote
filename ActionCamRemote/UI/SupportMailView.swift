import MessageUI
import SwiftUI

struct SupportMailView: UIViewControllerRepresentable {
    let draft: SupportEmailDraft
    var onComplete: (String?) -> Void

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients([SupportEmailDraft.recipient])
        controller.setSubject(draft.subject)
        controller.setMessageBody(draft.body, isHTML: false)
        controller.addAttachmentData(
            draft.attachmentData,
            mimeType: draft.attachmentMIMEType,
            fileName: draft.attachmentName
        )
        return controller
    }

    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onComplete: (String?) -> Void

        init(onComplete: @escaping (String?) -> Void) {
            self.onComplete = onComplete
        }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            onComplete(error?.localizedDescription ?? (result == .failed ? "The email could not be sent. Please try again." : nil))
        }
    }
}
