// EXPERIMENTAL: Share Extension that hands a shared link to Semitone.
//
// Share extensions can't open their containing app through any public API, so
// this leans on the widely used responder-chain trick (see `openContainingApp`).
// Apple could close that door in any release, so the link always goes on the
// pasteboard first and the user gets a manual fallback.

import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private var started = false

    override func viewDidLoad() {
        super.viewDidLoad()
        // Light only, like the app.
        overrideUserInterfaceStyle = .light
        view.backgroundColor = .systemBackground
    }

    // Start once the view is in a window: the responder chain only reaches
    // UIApplication from there.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        Task { await handleShare() }
    }

    private func handleShare() async {
        guard let link = await firstSharedLink() else {
            showMessage("No link found to import.")
            return
        }
        // Copy before anything else so the user is never left empty-handed.
        UIPasteboard.general.string = link.absoluteString

        // Encode by hand: URLQueryItem leaves "&", "=" and "+" alone inside a
        // value, which would split or mangle the nested URL.
        guard let encoded = link.absoluteString.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed),
              let deepLink = URL(string: "semitone://import?url=" + encoded) else {
            showMessage("Link copied. Open Semitone and choose Import from link.")
            return
        }
        let opened = await openContainingApp(deepLink)
        if opened {
            extensionContext?.completeRequest(returningItems: nil)
        } else {
            showMessage("Link copied. Open Semitone and choose Import from link.")
        }
    }

    /// Unreserved characters only, so the nested URL survives as one opaque value.
    private static let queryValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    // MARK: - Finding the link

    /// A public.url attachment wins; otherwise the first http(s) URL inside
    /// shared text (Instagram and TikTok often share "caption + link" text).
    private func firstSharedLink() async -> URL? {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let string = await Self.loadString(provider, type: UTType.url.identifier),
               let url = URL(string: string), Self.isWeb(url) {
                return url
            }
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = await Self.loadString(provider, type: UTType.plainText.identifier),
               let url = Self.firstWebURL(in: text) {
                return url
            }
        }
        return nil
    }

    /// Item providers call back on a background queue and may hand over a URL,
    /// a String or raw Data; normalize to a String off the main actor.
    nonisolated private static func loadString(_ provider: NSItemProvider, type: String) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                let string: String? = switch item {
                case let url as URL: url.absoluteString
                case let string as String: string
                case let data as Data: String(data: data, encoding: .utf8)
                default: nil
                }
                continuation.resume(returning: string)
            }
        }
    }

    nonisolated private static func firstWebURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range).lazy
            .compactMap(\.url)
            .first(where: isWeb)
    }

    nonisolated private static func isWeb(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    // MARK: - Opening Semitone

    /// Walks the responder chain to the extension process's UIApplication and
    /// calls `open(_:options:completionHandler:)` through the runtime, since the
    /// API is marked unavailable to extensions. The old one-argument `openURL:`
    /// silently stopped working in iOS 18, so only the three-argument form is
    /// used; its completion handler is how failure is detected.
    private func openContainingApp(_ url: URL) async -> Bool {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder, !(current is UIApplication) {
            responder = current.next
        }
        guard let application = responder as? UIApplication,
              application.responds(to: selector) else { return false }

        typealias OpenURL = @convention(c) (
            AnyObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?
        ) -> Void
        let open = unsafeBitCast(application.method(for: selector), to: OpenURL.self)

        return await withCheckedContinuation { continuation in
            open(application, selector, url as NSURL, NSDictionary()) { success in
                continuation.resume(returning: success)
            }
        }
    }

    // MARK: - Fallback UI

    private func showMessage(_ text: String) {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .body)
        label.numberOfLines = 0
        label.textAlignment = .center

        let done = UIButton(configuration: .borderedProminent(), primaryAction: UIAction(title: "Done") { [weak self] _ in
            self?.extensionContext?.completeRequest(returningItems: nil)
        })

        let stack = UIStackView(arrangedSubviews: [label, done])
        stack.axis = .vertical
        stack.spacing = 20
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])
    }
}
