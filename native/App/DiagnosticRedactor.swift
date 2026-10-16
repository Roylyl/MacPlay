import Foundation
import Darwin

/// Shared by the live log and both export formats. It never reads keychain or
/// authentication file contents; structured snapshots explicitly choose fields.
enum DiagnosticRedactor {
    static let hidden = "[redacted]"
    private static let secretNames = "password|passphrase|passwd|pwd|(?:lan|hotspot)?ssid|(?:lan|hotspot)password|bssid|private[-_\\s]?key|public[-_\\s]?key|shared[-_\\s]?secret|session[-_\\s]?key|encryption[-_\\s]?key|secret|token|authorization|credential|certificate|cert|pair[-_\\s]?record|payload|hex|identity(?:\\.pk8)?|certificate\\.p7b|device[-_\\s]?(?:id|name)|targetBluetooth|targetUSB|pairing[-_\\s]?id|controller[-_\\s]?id|serial|username|account|email|phone[-_\\s]?(?:name|id)|密码|口令|私钥|配对记录|认证材料"
    private static let secretKey = regex("^(?:" + secretNames + ")$")
    private static let assignment = regex("(?:\\b(?:" + secretNames + ")\\b|密码|口令|私钥|配对记录|认证材料)[\"'\\s]*[:=：]")
    private static let pemBegin = regex("-----BEGIN[^\\r\\n-]*(?:PRIVATE KEY|CERTIFICATE)[^-]*-----")
    private static let pemEnd = regex("-----END[^\\r\\n-]*-----")
    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are fixed program literals, never supplied by a log entry.
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
    private static func match(_ pattern: NSRegularExpression, _ text: String) -> NSTextCheckingResult? {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }
    private static func replacing(_ text: String, pattern: String, value: String) -> String {
        regex(pattern).stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: value)
    }

    /// Stateful because stdout delivers PEM and nested objects one line at a
    /// time. Nil means a continuation of an already-redacted sensitive value.
    final class Stream {
        private var inPEM = false
        private var value: ValueContinuation?
        func reset() { inPEM = false; value = nil }

        func consume(_ line: String) -> String? {
            if inPEM {
                if match(pemEnd, line) != nil { inPEM = false }
                return nil
            }
            if var continuation = value {
                continuation.consume(line)
                value = continuation.isOpen ? continuation : nil
                return nil
            }
            if let begin = match(pemBegin, line), let range = Range(begin.range, in: line) {
                inPEM = match(pemEnd, String(line[range.upperBound...])) == nil
                return redactPlain(String(line[..<range.lowerBound])) + hidden
            }
            if let secret = match(assignment, line), let range = Range(secret.range, in: line) {
                let suffix = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if var continuation = ValueContinuation(starting: suffix) {
                    continuation.consume(suffix)
                    value = continuation.isOpen ? continuation : nil
                }
                return redactPlain(String(line[..<range.lowerBound])) + hidden
            }
            return redactPlain(line)
        }
    }

    private struct ValueContinuation {
        private var depth = 0
        private var quote: Character?
        private var escaped = false
        private let container: Bool
        init?(starting text: String) {
            guard let first = text.first, "{[\"'".contains(first) else { return nil }
            container = first == "{" || first == "["
        }
        var isOpen: Bool { depth > 0 || quote != nil }
        mutating func consume(_ text: String) {
            for char in text {
                if escaped { escaped = false; continue }
                if let delimiter = quote {
                    if char == "\\" { escaped = true }
                    else if char == delimiter { quote = nil }
                } else if char == "\"" || char == "'" {
                    quote = char
                } else if container {
                    if char == "{" || char == "[" { depth += 1 }
                    else if char == "}" || char == "]" { depth = max(0, depth - 1) }
                }
            }
        }
    }

    static func redact(_ raw: String) -> String {
        let stream = Stream()
        return raw.components(separatedBy: .newlines).compactMap { stream.consume($0) }.joined(separator: "\n")
    }

    private static func redactPlain(_ raw: String) -> String {
        var text = raw
        text = replacing(text, pattern: #"(?:/Users/|/home/)[^\r\n\"'<>|)]+"#, value: "[user-path]")
        text = replacing(text, pattern: #"\b[A-Za-z]:[\\/]Users[\\/][^\r\n\"'<>|)]+"#, value: "[user-path]")
        text = replacing(text, pattern: #"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b|\b[0-9a-f]{8}-[0-9a-f]{16}\b"#, value: "[device-id]")
        text = replacing(text, pattern: #"\b(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}\b"#, value: "[MAC]")
        let ipv6 = regex(#"(?<![\w:])(?:[0-9a-f]{0,4}:){2,}[0-9a-f:.]{0,39}(?:%[\w.-]+)?"#)
        let matches = ipv6.matches(in: text, range: NSRange(text.startIndex..., in: text))
        let mutable = NSMutableString(string: text)
        for result in matches.reversed() {
            let address = mutable.substring(with: result.range).components(separatedBy: "%")[0]
            var parsed = in6_addr()
            if address.withCString({ inet_pton(AF_INET6, $0, &parsed) }) == 1 {
                mutable.replaceCharacters(in: result.range, with: "[IP]")
            }
        }
        text = mutable as String
        let ipv4 = regex(#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#)
        let ipv4Matches = ipv4.matches(in: text, range: NSRange(text.startIndex..., in: text))
        let ipv4Text = NSMutableString(string: text)
        for result in ipv4Matches.reversed() {
            var parsed = in_addr()
            if ipv4Text.substring(with: result.range).withCString({ inet_pton(AF_INET, $0, &parsed) }) == 1 {
                ipv4Text.replaceCharacters(in: result.range, with: "[IP]")
            }
        }
        text = ipv4Text as String
        text = replacing(text, pattern: #"\b[0-9a-f]{12}\b|\b[0-9a-f]{24,}\b"#, value: "[device-id]")
        text = replacing(text, pattern: #"(?<![A-Za-z0-9_+/-])[A-Za-z0-9_+/-]{80,}={0,2}(?![A-Za-z0-9_+/-])"#, value: hidden)
        return text
    }

    /// Redact before JSON serialization, including values hidden inside arrays.
    static func redactValue(_ value: Any, key: String = "", depth: Int = 0) -> Any {
        if match(secretKey, key) != nil { return hidden }
        guard depth < 24 else { return "[nested-data]" }
        if value is Data { return "[binary-data]" }
        if let text = value as? String { return redact(text) }
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, item in
                result[item.key] = redactValue(item.value, key: item.key, depth: depth + 1)
            }
        }
        if let array = value as? [Any] { return array.map { redactValue($0, depth: depth + 1) } }
        if let number = value as? NSNumber { return number.doubleValue.isFinite ? number : NSNull() }
        if value is NSNull { return value }
        return redact(String(describing: value))
    }
}
