@_exported import Foundation

// Minimal template doubles for running the actual controller on a macOS host.
// These are not included in the app and do not test native CarPlay rendering.
public final class UIImage {
    public init?(systemName: String) {}
}

@MainActor
public final class CPBarButton {
    public enum Style { case rounded }

    public let title: String
    public var buttonStyle: Style = .rounded
    public var isEnabled = true

    public init(title: String, handler: @escaping (CPBarButton) -> Void) {
        self.title = title
    }
}

@MainActor
public final class CPListItem {
    public let text: String
    public let detailText: String
    public var isEnabled = true
    public var handler: ((CPListItem, @escaping () -> Void) -> Void)?

    public init(text: String, detailText: String, image: UIImage?) {
        self.text = text
        self.detailText = detailText
    }
}

@MainActor
public final class CPListSection {
    public let items: [CPListItem]

    public init(items: [CPListItem], header: String?, sectionIndexTitle: String?) {
        self.items = items
    }
}

@MainActor
public final class CPListTemplate {
    public static let maximumItemCount = 100
    public var emptyViewTitleVariants: [String] = []
    public var emptyViewSubtitleVariants: [String] = []
    public var trailingNavigationBarButtons: [CPBarButton] = []
    public private(set) var sections: [CPListSection]
    public private(set) var updateCount = 0

    public init(title: String, sections: [CPListSection]) {
        self.sections = sections
    }

    public func updateSections(_ sections: [CPListSection]) {
        self.sections = sections
        updateCount += 1
    }
}

@MainActor
public final class CPInterfaceController {
    public private(set) var rootTemplate: CPListTemplate?

    public init() {}

    public func setRootTemplate(
        _ template: CPListTemplate,
        animated: Bool,
        completion: (Bool, Error?) -> Void
    ) {
        rootTemplate = template
        completion(true, nil)
    }
}
