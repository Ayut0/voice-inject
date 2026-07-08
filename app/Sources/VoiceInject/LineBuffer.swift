import Foundation

/// Accumulates raw socket chunks and yields complete NDJSON lines.
struct LineBuffer {
    private var buffer = Data()

    mutating func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(buffer.subdata(in: buffer.startIndex..<nl))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        return lines
    }
}
