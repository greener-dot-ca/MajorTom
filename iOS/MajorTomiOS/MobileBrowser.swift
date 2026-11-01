import Foundation
import MajorTomCore
import SwiftUI
import UIKit
import WebKit

/// One browsing session on iOS: fetches with Core's transport, renders with Core's
/// HTML renderer, and streams the result into a WebPage, as the Mac BrowserModel does.
@MainActor
final class MobileBrowser: ObservableObject {
    struct InputPrompt: Identifiable {
        let id = UUID()
        let url: URL
        let message: String
        let isSensitive: Bool
    }

    struct TrustPrompt: Identifiable {
        let id = UUID()
        let host: String
        let message: String
    }

    @Published var locationText = ""
    @Published private(set) var title = "Major Tom"
    @Published private(set) var isLoading = false
    @Published private(set) var backStack: [URL] = []
    @Published private(set) var forwardStack: [URL] = []
    @Published var inputPrompt: InputPrompt?
    @Published var trustPrompt: TrustPrompt?

    let page: WebPage
    let preferences = BrowserPreferences()

    private let documents = DocumentStore()
    private let transport = GeminiTransport()
    private let trustPolicy = ServerTrustPolicy()
    private let trustStore: TrustedIdentityStore?
    private var currentURL: URL?
    private var navigationTask: Task<Void, Never>?
    private var document: AsyncThrowingStream<Data, any Error>.Continuation?
    private var trustContinuation: CheckedContinuation<Bool, Never>?
    private var titleClaim = GemtextTitleClaim()

    init() {
        let router = Router()
        var configuration = WebPage.Configuration()
        configuration.urlSchemeHandlers = [
            URLScheme(DocumentSchemeHandler.scheme)!: DocumentSchemeHandler(store: documents)
        ]
        page = WebPage(configuration: configuration, navigationDecider: NavigationDecider(router: router))

        let support = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        trustStore = try? TrustedIdentityStore(fileURL: support.appending(path: "trusted-identities.json"))

        router.open = { [weak self] url in self?.follow(url) }
    }

    // MARK: Navigation

    func open(_ input: String) {
        let searchEndpoint = URL(string: "gemini://kennedy.gemi.dev/search")!
        switch try? AddressInputInterpreter(searchEndpoint: searchEndpoint).interpret(input) {
        case .gemini(let target), .viewSource(let target):
            navigate(to: target, recordsHistory: true)
        case .external(let url):
            UIApplication.shared.open(url)
        case .internalPage, nil:
            break
        }
    }

    func follow(_ url: URL) {
        guard url.scheme?.lowercased() == "gemini" else {
            UIApplication.shared.open(url)
            return
        }
        guard let target = try? GeminiRequestTarget(url.absoluteString) else { return }
        navigate(to: target, recordsHistory: true)
    }

    func goBack() {
        guard let url = backStack.popLast(), let target = try? GeminiRequestTarget(url.absoluteString) else { return }
        if let currentURL { forwardStack.append(currentURL) }
        navigate(to: target, recordsHistory: false)
    }

    func goForward() {
        guard let url = forwardStack.popLast(), let target = try? GeminiRequestTarget(url.absoluteString) else { return }
        if let currentURL { backStack.append(currentURL) }
        navigate(to: target, recordsHistory: false)
    }

    func reload() {
        guard let currentURL, let target = try? GeminiRequestTarget(currentURL.absoluteString) else { return }
        navigate(to: target, recordsHistory: false)
    }

    func stop() {
        navigationTask?.cancel()
        isLoading = false
        locationText = currentURL?.absoluteString ?? ""
    }

    func submitInput(_ value: String, for prompt: InputPrompt) {
        guard let url = GeminiQueryEncoding.url(base: prompt.url, query: value) else { return }
        follow(url)
    }

    func answerTrust(_ approved: Bool) {
        trustPrompt = nil
        trustContinuation?.resume(returning: approved)
        trustContinuation = nil
    }

    private func navigate(to target: GeminiRequestTarget, recordsHistory: Bool) {
        navigationTask?.cancel()
        isLoading = true
        locationText = target.url.absoluteString
        navigationTask = Task { [weak self] in
            await self?.load(target, recordsHistory: recordsHistory, redirects: 0)
            self?.isLoading = false
        }
    }

    // MARK: Loading

    private func load(_ target: GeminiRequestTarget, recordsHistory: Bool, redirects: Int) async {
        var header: GeminiResponseHeader?
        var mimeType = ""
        var body = Data()
        var decoder = IncrementalUTF8Decoder()
        var parser = IncrementalGemtextParser()

        do {
            let events = transport.events(for: target) { [weak self] identity, _ in
                await self?.authorize(identity) ?? false
            }
            for try await event in events {
                try Task.checkCancellation()
                switch event {
                case .responseHeader(let response):
                    header = response
                    if response.isRedirect {
                        guard redirects < 5,
                              let next = URL(string: response.meta.trimmingCharacters(in: .whitespaces), relativeTo: target.url)?.absoluteURL,
                              let nextTarget = try? GeminiRequestTarget(next.absoluteString) else {
                            showError("Too Many Redirects", "The capsule redirected too many times, or to an address Major Tom could not understand.", url: target.url, recordsHistory: recordsHistory)
                            return
                        }
                        locationText = next.absoluteString
                        await load(nextTarget, recordsHistory: recordsHistory, redirects: redirects + 1)
                        return
                    }
                    if response.isInput {
                        inputPrompt = InputPrompt(url: target.url, message: response.meta, isSensitive: response.status == 11)
                        locationText = currentURL?.absoluteString ?? ""
                        return
                    }
                    if response.requiresClientCertificate {
                        // ponytail: no client identities on iOS yet; see ClientCertificateKeychain.
                        showError("Client Certificate Required", response.meta.isEmpty ? "This capsule asks for a client certificate, which Major Tom for iOS can't send yet." : response.meta, url: target.url, recordsHistory: recordsHistory)
                        return
                    }
                    guard response.isSuccess else {
                        let title = response.isTemporaryFailure ? "Temporary Capsule Failure" : "Permanent Capsule Failure"
                        showError(title, response.meta, details: "Gemini status \(response.status)", url: target.url, recordsHistory: recordsHistory)
                        return
                    }
                    mimeType = response.meta.split(separator: ";", maxSplits: 1).first
                        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
                    if mimeType.hasPrefix("text/") {
                        beginDocument(at: target.url, recordsHistory: recordsHistory)
                        if mimeType != "text/gemini" { yield(Data("<pre><code>".utf8)) }
                    }

                case .body(let data):
                    guard header?.isSuccess == true else { continue }
                    if mimeType == "text/gemini" {
                        for event in parser.receive(decoder.decode(data)) { emit(event, baseURL: target.url) }
                    } else if mimeType.hasPrefix("text/") {
                        yield(Data(HTMLDocumentStreamRenderer.escape(decoder.decode(data)).utf8))
                    } else {
                        body.append(data)
                    }

                case .completed:
                    guard header?.isSuccess == true else { return }
                    if mimeType == "text/gemini" {
                        for event in parser.receive(decoder.finish()) + parser.finish() { emit(event, baseURL: target.url) }
                        finishDocument()
                    } else if mimeType.hasPrefix("text/") {
                        yield(Data((HTMLDocumentStreamRenderer.escape(decoder.finish()) + "</code></pre>").utf8))
                        finishDocument()
                    } else if mimeType.hasPrefix("image/") {
                        showImage(body, mimeType: mimeType, url: target.url, recordsHistory: recordsHistory)
                    } else {
                        // ponytail: no downloads yet; add a share sheet for other types.
                        showError("Unsupported File", "Major Tom for iOS can't show this kind of file yet.", details: "\(mimeType)\n\(body.count) bytes", url: target.url, recordsHistory: recordsHistory)
                    }

                default:
                    break
                }
            }
        } catch is CancellationError {
            document?.finish()
        } catch {
            showError("Couldn't Open Capsule", Self.describe(error), details: target.url.absoluteString, url: target.url, recordsHistory: recordsHistory)
        }
    }

    private func authorize(_ identity: PresentedServerIdentity) async -> Bool {
        let trusted = await trustStore?.identity(for: identity.endpoint)
        switch trustPolicy.evaluate(presented: identity, locallyTrusted: trusted, seeds: []) {
        case .allowSilently(let source):
            try? await trustStore?.trust(identity, source: source)
            return true
        case .requiresApproval(.firstUse):
            try? await trustStore?.trust(identity, source: .user)
            return true
        case .requiresApproval(let challenge):
            let message = switch challenge {
            case .invalidCertificateDates: "This capsule's certificate has expired or isn't valid yet."
            default: "This capsule is presenting a different identity than the one you trusted before. Someone may be intercepting the connection."
            }
            let approved = await withCheckedContinuation { continuation in
                trustContinuation = continuation
                trustPrompt = TrustPrompt(host: identity.endpoint.host, message: message)
            }
            if approved { try? await trustStore?.trust(identity, source: .user) }
            return approved
        }
    }

    private static func describe(_ error: any Error) -> String {
        switch error as? GeminiTransportError {
        case .connectionFailed(let failure): failure.userFacingDescription
        case .responseFailed(let failure): failure.userFacingDescription
        case .trustDeclined: "You chose not to trust this capsule's identity."
        case .connectionTimedOut, .responseTimedOut: "The capsule took too long to respond."
        default: error.localizedDescription
        }
    }

    // MARK: Document

    private var isDark: Bool { UITraitCollection.current.userInterfaceStyle == .dark }

    private var theme: ContentTheme { isDark ? .draculaDark : .draculaLight }

    private var renderer: HTMLDocumentStreamRenderer {
        HTMLDocumentStreamRenderer(contentPalette: theme.palette(effectiveDarkAppearance: isDark))
    }

    private var themeCSS: String {
        // The Mac stylesheet leaves room for its window chrome; a phone has none above the page.
        theme.css(effectiveDarkAppearance: isDark)
            + "\n" + preferences.contentWidth.css
            + "\n@media screen { body { padding-top: 0; } main { padding: 1.25rem 1.25rem 5rem; } }"
    }

    private func beginDocument(at url: URL, recordsHistory: Bool, browserGenerated: Bool = false) {
        document?.finish()
        let new = documents.create()
        document = new.continuation
        _ = page.load(new.url)
        yield(renderer.documentStart(themeCSS: themeCSS, baseURL: url, browserGenerated: browserGenerated))

        if recordsHistory, let currentURL, currentURL != url {
            backStack.append(currentURL)
            forwardStack.removeAll()
        }
        currentURL = url
        locationText = url.absoluteString
        titleClaim = GemtextTitleClaim()
        title = url.host() ?? url.absoluteString
    }

    private func emit(_ event: GemtextEvent, baseURL: URL) {
        if titleClaim.receive(event), let claimed = titleClaim.title { title = claimed }
        yield(renderer.render(event, options: preferences.renderingOptions, baseURL: baseURL))
    }

    private func yield(_ data: Data) {
        document?.yield(data)
    }

    private func finishDocument() {
        yield(renderer.documentEnd())
        document?.finish()
        document = nil
    }

    private func showError(_ heading: String, _ message: String, details: String? = nil, url: URL, recordsHistory: Bool) {
        beginDocument(at: url, recordsHistory: recordsHistory, browserGenerated: true)
        let escape = HTMLDocumentStreamRenderer.escape
        var html = "<p class=\"eyebrow\">Major Tom</p><h1>\(escape(heading))</h1><p>\(escape(message))</p>"
        if let details { html += "<div class=\"details\">\(escape(details))</div>" }
        yield(Data(html.utf8))
        finishDocument()
        title = heading
    }

    private func showImage(_ data: Data, mimeType: String, url: URL, recordsHistory: Bool) {
        beginDocument(at: url, recordsHistory: recordsHistory)
        let source = "data:\(HTMLDocumentStreamRenderer.escapeAttribute(mimeType));base64,\(data.base64EncodedString())"
        yield(Data("<img alt=\"\" src=\"\(source)\" style=\"display:block;max-width:100%;margin:0 auto\">".utf8))
        finishDocument()
        title = url.lastPathComponent
    }
}

// MARK: - WebKit plumbing (mirrors the Mac app's document scheme handler)

private final class Router {
    var open: ((URL) -> Void)?
}

private struct NavigationDecider: WebPage.NavigationDeciding {
    let router: Router

    @MainActor
    func decidePolicy(
        for action: WebPage.NavigationAction,
        preferences: inout WebPage.NavigationPreferences
    ) async -> WKNavigationActionPolicy {
        preferences.allowsContentJavaScript = false
        guard let url = action.request.url else { return .cancel }
        if url.scheme == DocumentSchemeHandler.scheme { return .allow }
        router.open?(url)
        return .cancel
    }
}

private final class DocumentStore: @unchecked Sendable {
    private let lock = NSLock()
    private var streams: [String: AsyncThrowingStream<Data, any Error>] = [:]

    func create() -> (url: URL, continuation: AsyncThrowingStream<Data, any Error>.Continuation) {
        let id = UUID().uuidString
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        lock.withLock { streams[id] = stream }
        return (URL(string: "\(DocumentSchemeHandler.scheme)://document/\(id)")!, continuation)
    }

    func take(id: String) -> AsyncThrowingStream<Data, any Error>? {
        lock.withLock { streams.removeValue(forKey: id) }
    }
}

private struct DocumentSchemeHandler: URLSchemeHandler, Sendable {
    static let scheme = "majortom-document"
    let store: DocumentStore

    func reply(for request: URLRequest) -> AsyncThrowingStream<URLSchemeTaskResult, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard let url = request.url, let stream = store.take(id: url.lastPathComponent) else {
                    continuation.finish(throwing: URLError(.resourceUnavailable))
                    return
                }
                continuation.yield(.response(URLResponse(url: url, mimeType: "text/html", expectedContentLength: -1, textEncodingName: "utf-8")))
                do {
                    for try await data in stream {
                        try Task.checkCancellation()
                        continuation.yield(.data(data))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
