// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.arbiter", category: "AnthropicImageResolver")

/// Downloads `.url` images and re-encodes them as inline base64.
///
/// The Messages API takes image bytes inline, so a request carrying a URL
/// would otherwise lose the image entirely.
///
/// Only `http(s)` URLs are fetched: a request's image URL can come from model
/// or tool output, and `URLSession` would happily read a `file://` path or a
/// link-local address into the prompt. The size cap is checked against the
/// declared `Content-Length` before the body is read and against the received
/// bytes afterwards, since the header can be absent or wrong.
struct AnthropicImageResolver: Sendable {
    /// Default per-image download cap.
    static let defaultMaxBytes = 5 * 1024 * 1024

    /// Media types the Messages API accepts for image blocks.
    static let supportedMimeTypes: Set<String> = [
        "image/jpeg", "image/png", "image/gif", "image/webp",
    ]

    /// URL schemes an image may be fetched from.
    static let allowedSchemes: Set<String> = ["https", "http"]

    let maxBytes: Int
    let load: @Sendable (URL) async throws -> (Data, String?)

    init(
        maxBytes: Int = AnthropicImageResolver.defaultMaxBytes,
        session: URLSession
    ) {
        self.maxBytes = maxBytes
        let cap = maxBytes
        self.load = { url in
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            let (bytes, response) = try await session.bytes(for: request)
            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                throw ArbiterError.httpError(
                    statusCode: http.statusCode,
                    body: "Failed to download image"
                )
            }
            // Refuse before reading a body the server already says is too big.
            if response.expectedContentLength > Int64(cap) {
                throw ArbiterError.invalidRequest(
                    reason: "Image at \(url.absoluteString) declares \(response.expectedContentLength) bytes, over the \(cap)-byte limit"
                )
            }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > cap {
                    throw ArbiterError.invalidRequest(
                        reason: "Image at \(url.absoluteString) is over the \(cap)-byte limit"
                    )
                }
            }
            return (data, response.mimeType)
        }
    }

    init(maxBytes: Int = AnthropicImageResolver.defaultMaxBytes,
         load: @escaping @Sendable (URL) async throws -> (Data, String?)) {
        self.maxBytes = maxBytes
        self.load = load
    }

    /// Replace every `.url` image in the request with inline base64 data.
    ///
    /// Requests with no URL images are returned untouched, so the common path
    /// costs nothing.
    func resolvingImages(in request: AIRequest) async throws -> AIRequest {
        guard request.messages.contains(where: { $0.content.containsURLImage }) else {
            return request
        }
        var resolved = request
        var messages: [Message] = []
        messages.reserveCapacity(request.messages.count)
        for message in request.messages {
            messages.append(Message(
                id: message.id,
                role: message.role,
                content: try await resolve(message.content)
            ))
        }
        resolved.messages = messages
        return resolved
    }

    func resolve(_ content: MessageContent) async throws -> MessageContent {
        switch content {
        case .image(.url(let url)):
            return .image(try await download(url))
        case .mixed(let parts):
            var resolved: [MessageContent] = []
            resolved.reserveCapacity(parts.count)
            for part in parts {
                resolved.append(try await resolve(part))
            }
            return .mixed(resolved)
        case .text, .image, .document, .toolCalls, .toolResults, .thinking:
            return content
        }
    }

    private func download(_ url: URL) async throws -> ImageSource {
        guard let scheme = url.scheme?.lowercased(), Self.allowedSchemes.contains(scheme) else {
            throw ArbiterError.invalidRequest(
                reason: "Image URLs must use http or https, got '\(url.scheme ?? "none")'"
            )
        }

        let data: Data
        let mimeType: String?
        do {
            (data, mimeType) = try await load(url)
        } catch let error as ArbiterError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.error("Image download failed")
            throw ArbiterError.networkError(underlying: error as? URLError ?? URLError(.unknown))
        }

        guard data.count <= maxBytes else {
            throw ArbiterError.invalidRequest(
                reason: "Image at \(url.absoluteString) is \(data.count) bytes, over the \(maxBytes)-byte limit"
            )
        }

        guard let mimeType, Self.supportedMimeTypes.contains(mimeType.lowercased()) else {
            throw ArbiterError.invalidRequest(
                reason: "Image at \(url.absoluteString) has unsupported media type '\(mimeType ?? "unknown")'"
            )
        }

        return .base64(data: data.base64EncodedString(), mimeType: mimeType.lowercased())
    }
}

extension MessageContent {
    /// Whether this content holds an image that still needs downloading.
    var containsURLImage: Bool {
        switch self {
        case .image(.url): true
        case .mixed(let parts): parts.contains(where: \.containsURLImage)
        default: false
        }
    }
}
