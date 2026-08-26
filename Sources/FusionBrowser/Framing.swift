import Foundation

// FR-09: per-client read loop, frame timeout, large payload buffering, explicit backpressure.
// FR-09: single client large frame must NOT block other clients' small requests.

public final class FBFrameReader {
    private let buffer = DispatchQueue(label: "fusion-browser.framereader", attributes: .concurrent)
    private var data = Data()
    private let maxFrameBytes: Int
    private let log = FBLogger.shared

    public init(maxFrameBytes: Int = 8 * 1024 * 1024) {
        self.maxFrameBytes = maxFrameBytes
    }

    // Append incoming bytes; return complete frames (without length prefix) ready to decode.
    // Synchronous: called on per-client serial queue. Backpressure: if buffered > maxFrameBytes, drop & signal.
    public func append(_ chunk: Data) -> (frames: [Data], overflow: Bool) {
        var frames: [Data] = []
        var overflow = false
        data.append(chunk)
        while data.count >= 4 {
            let len = data.withUnsafeBytes { rawPtr -> UInt32 in
                let p = rawPtr.bindMemory(to: UInt8.self)
                return (UInt32(p[0]) << 24) | (UInt32(p[1]) << 16) | (UInt32(p[2]) << 8) | UInt32(p[3])
            }
            let frameLen = Int(len)
            if frameLen > maxFrameBytes {
                log.error("Framing", "frame \(frameLen) bytes > cap \(maxFrameBytes); backpressure drop")
                overflow = true
                data.removeAll()
                break
            }
            if data.count < 4 + frameLen { break }
            let frame = data.subdata(in: 4..<(4 + frameLen))
            frames.append(frame)
            data.removeSubrange(0..<(4 + frameLen))
        }
        return (frames, overflow)
    }

    public func reset() {
        data.removeAll()
    }
}
