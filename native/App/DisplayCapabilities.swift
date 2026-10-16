import Foundation

struct DisplayPixels: Equatable, Sendable {
    let width: Int
    let height: Int
}

enum DisplayCapabilities {
    static func parse(_ data: Data) -> [UInt32: DisplayPixels]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let gpus = root["SPDisplaysDataType"] as? [[String: Any]] else { return nil }
        var result: [UInt32: DisplayPixels] = [:]
        let expression = try! NSRegularExpression(pattern: #"(\d+)\s*[x×]\s*(\d+)"#)
        for panel in gpus.flatMap({ $0["spdisplays_ndrvs"] as? [[String: Any]] ?? [] }) {
            let rawID = panel["_spdisplays_displayID"].map { String(describing: $0) } ?? ""
            let id = rawID.hasPrefix("0x") ? UInt32(rawID.dropFirst(2), radix: 16) : UInt32(rawID)
            guard let id, let text = panel["spdisplays_pixelresolution"] as? String,
                  let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let wr = Range(match.range(at: 1), in: text), let hr = Range(match.range(at: 2), in: text),
                  let width = Int(text[wr]), let height = Int(text[hr]), width > 0, height > 0 else { continue }
            result[id] = DisplayPixels(width: width, height: height)
        }
        return result
    }

    static func permitsExactPixels(verified: Bool, widthMm: Double, heightMm: Double, loading: Bool) -> Bool {
        !loading && verified && widthMm.isFinite && heightMm.isFinite && widthMm > 0 && heightMm > 0
    }

    static func fittedSize(width: Int, height: Int, visibleWidth: Double, visibleHeight: Double) -> (Double, Double) {
        let ratio = Double(max(1, width)) / Double(max(1, height))
        let fitted = max(1, min(960, visibleWidth * 0.8, visibleHeight * 0.8 * ratio))
        return (fitted, fitted / ratio)
    }
}
