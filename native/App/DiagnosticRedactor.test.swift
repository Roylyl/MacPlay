import Foundation

@main struct DiagnosticRedactorTests {
    static func main() throws {
        let stream = DiagnosticRedactor.Stream()
        precondition(stream.consume("[auth] -----BEGIN PRIVATE KEY-----") == "[auth] [redacted]")
        precondition(stream.consume("short-secret-base64-line") == nil)
        precondition(stream.consume("-----END PRIVATE KEY-----") == nil)
        precondition(stream.consume("first-frame width=1920 fps=60") == "first-frame width=1920 fps=60")
        precondition(stream.consume("[pair] payload = {") == "[pair] [redacted]")
        precondition(stream.consume(#""escaped": "text } with \" quotes", "items": ["secret"]"#) == nil)
        precondition(stream.consume("}") == nil)
        precondition(stream.consume("audio packets=123 jitterMs=2.5") == "audio packets=123 jitterMs=2.5")
        precondition(stream.consume("password = \"unterminated") == "[redacted]")
        precondition(stream.consume("second secret line\"") == nil)
        precondition(stream.consume("ready") == "ready")
        let text = DiagnosticRedactor.redact("address=[fe80::1%en0]:7000 IPv4=192.0.2.1 peer=::ffff:192.0.2.2 MAC=AA:BB:CC:DD:EE:FF id=00008030-0000000000000001 path=/Users/example/Library/Logs/test.log\nprogress=1.2.3 frames=60")
        for secret in ["fe80", "192.0.2", "AA:BB", "00008030", "/Users/example"] { precondition(!text.contains(secret)) }
        precondition(text.contains("progress=1.2.3 frames=60"))
        precondition(DiagnosticRedactor.redact("binary " + String(repeating: "Zyxw0123", count: 20)).contains("[redacted]"))
        let value: [String: Any] = ["version": "1.2.3", "authenticationReady": true,
            "metrics": ["fps": 60, "nested": ["password": "never-export", "deviceName": "phone-name"]],
            "bytes": Data([1, 2]), "unknown": Double.nan]
        let data = try JSONSerialization.data(withJSONObject: DiagnosticRedactor.redactValue(value), options: [.sortedKeys])
        let json = String(decoding: data, as: UTF8.self)
        precondition(!json.contains("never-export") && !json.contains("phone-name"))
        precondition(json.contains("\"authenticationReady\":true") && json.contains("\"fps\":60"))
        precondition(json.contains("[binary-data]") && json.contains("\"unknown\":null"))
        _ = stream.consume("-----BEGIN CERTIFICATE-----")
        stream.reset()
        precondition(stream.consume("new-process-ready") == "new-process-ready")
        print("Diagnostic redaction: streamed PEM, nested assignments, network identities, paths and JSON preservation passed")
    }
}
