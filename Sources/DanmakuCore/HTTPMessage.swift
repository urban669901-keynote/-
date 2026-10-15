import Foundation

/// 已解析的 HTTP/1.1 請求（只支援本 App 需要的最小子集）。
public struct HTTPRequest: Equatable {
    public var method: String
    public var path: String
    public var query: String?
    /// header 名稱一律小寫。
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, query: String? = nil, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }
}

public enum HTTPParseResult: Equatable {
    /// 資料還沒收完，繼續讀。
    case incomplete
    case complete(HTTPRequest)
    case invalid(String)
    case tooLarge
}

public enum HTTPRequestParser {
    public static let maxHeaderBytes = 8 * 1024
    public static let maxBodyBytes = 8 * 1024

    private static let headerTerminator = Data("\r\n\r\n".utf8)

    public static func parse(_ data: Data) -> HTTPParseResult {
        guard let terminator = data.range(of: headerTerminator) else {
            return data.count > maxHeaderBytes ? .tooLarge : .incomplete
        }
        let headerData = data[data.startIndex..<terminator.lowerBound]
        guard headerData.count <= maxHeaderBytes else { return .tooLarge }
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .invalid("header 不是 UTF-8")
        }

        var lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else {
            return .invalid("request line 格式錯誤")
        }

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .invalid("header 格式錯誤") }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        if headers["transfer-encoding"] != nil {
            return .invalid("不支援 chunked 傳輸")
        }
        var contentLength = 0
        if let raw = headers["content-length"] {
            guard let value = Int(raw), value >= 0 else { return .invalid("Content-Length 錯誤") }
            contentLength = value
        }
        guard contentLength <= maxBodyBytes else { return .tooLarge }

        let bodyStart = terminator.upperBound
        guard data.endIndex - bodyStart >= contentLength else { return .incomplete }
        let body = Data(data[bodyStart..<(bodyStart + contentLength)])

        let target = String(parts[1])
        let path: String
        let query: String?
        if let questionMark = target.firstIndex(of: "?") {
            path = String(target[..<questionMark])
            query = String(target[target.index(after: questionMark)...])
        } else {
            path = target
            query = nil
        }

        return .complete(HTTPRequest(
            method: parts[0].uppercased(),
            path: path,
            query: query,
            headers: headers,
            body: body
        ))
    }
}

public struct HTTPResponse {
    public var status: Int
    public var headers: [(String, String)]
    public var body: Data

    public init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func html(_ html: String) -> HTTPResponse {
        HTTPResponse(status: 200, headers: [("Content-Type", "text/html; charset=utf-8")], body: Data(html.utf8))
    }

    public static func text(_ status: Int, _ text: String) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "text/plain; charset=utf-8")], body: Data(text.utf8))
    }

    public static func json<T: Encodable>(_ status: Int, _ value: T) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: [("Content-Type", "application/json; charset=utf-8")], body: body)
    }

    public func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reasonPhrase(status))\r\n"
        for (name, value) in headers {
            head += "\(name): \(value)\r\n"
        }
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    public static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 423: return "Locked"
        case 429: return "Too Many Requests"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}
