import Foundation

internal func newClientMsgId() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
}

internal func defaultImageFilename(mimeType: String) -> String {
    "image_\(UUID().uuidString.replacingOccurrences(of: "-", with: "")).\(imageExtension(mimeType: mimeType))"
}

private func imageExtension(mimeType: String) -> String {
    switch mimeType.lowercased() {
    case "image/png": return "png"
    case "image/gif": return "gif"
    default: return "jpg"
    }
}

internal extension URL {
    func liveChatAppendingPath(_ rawPath: String) -> URL {
        var url = self
        rawPath.split(separator: "/").forEach { url.appendPathComponent(String($0)) }
        return url
    }
}

internal extension String {
    var urlEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
    }
}
