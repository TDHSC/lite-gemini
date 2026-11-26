import Foundation

// MARK: - GeminiURLRoute

/// Pure parser and canonical URL builder for `gemini.google.com` application routes.
nonisolated enum GeminiURLRoute: Equatable, Hashable, Sendable {

    /// New empty conversation route (`/app`).
    case newChat(authUser: Int?)
    /// Specific conversation route (`/app/<id>`).
    case conversation(id: String, authUser: Int?)
    /// Gem route (`/gem/<gemId>` or `/gem/<gemId>/<conversationId>`).
    case gem(gemId: String, conversationId: String?, authUser: Int?)

    // MARK: - Constants

    static let canonicalHost = "gemini.google.com"

    // MARK: - Parsing

    /// Parses a Gemini web URL, normalizing `/u/<N>/...` prefixes and `?authuser=N` query parameters.
    init?(url: URL) {
        guard let parsed = Self.parse(url) else {
            return nil
        }
        self = parsed
    }

    /// Parses a Gemini web URL into a typed route, returning `nil` for non-Gemini or unsupported paths.
    static func parse(_ url: URL) -> GeminiURLRoute? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host?.lowercased() == canonicalHost else {
            return nil
        }

        let queryAuthUser: Int? = components.queryItems?
            .first(where: { $0.name.lowercased() == "authuser" })?
            .value
            .flatMap { Int($0) }
            .flatMap { $0 >= 0 ? $0 : nil }

        var segments = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        var pathAuthUser: Int?
        if segments.count >= 2,
           segments[0].lowercased() == "u",
           let index = Int(segments[1]),
           index >= 0 {
            pathAuthUser = index
            segments.removeFirst(2)
        }

        let resolvedAuthUser = queryAuthUser ?? pathAuthUser

        if segments.isEmpty {
            return .newChat(authUser: resolvedAuthUser)
        }

        switch segments[0].lowercased() {
        case "app":
            if segments.count == 1 {
                return .newChat(authUser: resolvedAuthUser)
            }
            let conversationId = segments[1]
            guard !conversationId.isEmpty else {
                return .newChat(authUser: resolvedAuthUser)
            }
            return .conversation(id: conversationId, authUser: resolvedAuthUser)

        case "gem":
            guard segments.count >= 2, !segments[1].isEmpty else {
                return nil
            }
            let gemId = segments[1]
            let conversationId = segments.count >= 3 && !segments[2].isEmpty ? segments[2] : nil
            return .gem(gemId: gemId, conversationId: conversationId, authUser: resolvedAuthUser)

        default:
            return nil
        }
    }

    // MARK: - Properties & URL Building

    /// Multi-account `?authuser=N` index associated with this route, if present.
    var authUser: Int? {
        switch self {
        case .newChat(let authUser):
            return authUser
        case .conversation(_, let authUser):
            return authUser
        case .gem(_, _, let authUser):
            return authUser
        }
    }

    /// Conversation identifier carried by `.conversation` or `.gem` routes, if any.
    var conversationId: String? {
        switch self {
        case .newChat:
            return nil
        case .conversation(let id, _):
            return id
        case .gem(_, let conversationId, _):
            return conversationId
        }
    }

    /// Returns a copy of this route with an updated `?authuser` index.
    func withAuthUser(_ authUser: Int?) -> GeminiURLRoute {
        switch self {
        case .newChat:
            return .newChat(authUser: authUser)
        case .conversation(let id, _):
            return .conversation(id: id, authUser: authUser)
        case .gem(let gemId, let conversationId, _):
            return .gem(gemId: gemId, conversationId: conversationId, authUser: authUser)
        }
    }

    /// Builds the canonical `https://gemini.google.com/...` URL preserving `?authuser=N` when set.
    var canonicalURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.canonicalHost

        switch self {
        case .newChat:
            components.path = "/app"
        case .conversation(let id, _):
            components.path = "/app/\(id)"
        case .gem(let gemId, let conversationId, _):
            if let conversationId, !conversationId.isEmpty {
                components.path = "/gem/\(gemId)/\(conversationId)"
            } else {
                components.path = "/gem/\(gemId)"
            }
        }

        if let authUser, authUser >= 0 {
            components.queryItems = [URLQueryItem(name: "authuser", value: String(authUser))]
        }

        // All components are static valid scheme/host/path values, so url construction cannot fail.
        return components.url ?? URL(string: "https://gemini.google.com/app")!
    }
}
