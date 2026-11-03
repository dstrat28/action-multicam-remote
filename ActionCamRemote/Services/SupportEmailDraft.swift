import Foundation

struct SupportEmailDraft: Identifiable, Sendable {
    static let recipient = "multicam@dstrat.io"

    let id = UUID()
    let subject: String
    let body: String
    let attachmentData: Data
    let attachmentName: String
    let attachmentMIMEType = "text/plain"

    init(diagnosticsURL: URL, version: String) throws {
        subject = "Multicam Feedback — \(version)"
        body = "Please describe the issue:\n\n"
        attachmentData = try Data(contentsOf: diagnosticsURL)
        attachmentName = diagnosticsURL.lastPathComponent
    }
}
