import Compression
import Foundation

public enum ZipArchiveError: Error, CustomStringConvertible, Equatable {
    case notAZipArchive
    case truncated
    case zip64NotSupported
    case unsupportedCompression(UInt16)
    case entryNotFound(String)
    case inflateFailed(String)
    case notUTF8(String)

    public var description: String {
        switch self {
        case .notAZipArchive: String(localized: "That file is not a zip archive.", bundle: .module)
        case .truncated: String(localized: "The zip archive is incomplete.", bundle: .module)
        case .zip64NotSupported: String(localized: "Zip64 archives are not supported.", bundle: .module)
        case let .unsupportedCompression(method): String(localized: "Unsupported zip compression method \(method).", bundle: .module, locale: .display)
        case let .entryNotFound(name): String(localized: "The archive has no entry named \(name).", bundle: .module)
        case let .inflateFailed(name): String(localized: "Could not decompress \(name).", bundle: .module)
        case let .notUTF8(name): String(localized: "\(name) is not valid UTF-8 text.", bundle: .module)
        }
    }
}

/// A minimal reader for the zip files YNAB produces.
///
/// iOS has no public API for reading a zip, and the format's two common cases — stored and deflate —
/// are small enough to handle directly with the Compression framework. That avoids taking on a
/// dependency just to open the one file this app imports.
public struct ZipArchive: Sendable {
    public struct Entry: Sendable, Equatable {
        public let path: String
        public let compressedSize: Int
        public let uncompressedSize: Int
        /// When the entry was written, from the archive's DOS timestamp. For a YNAB export this is
        /// when the export was taken, which the importer needs: YNAB omits transactions dated after
        /// it from category activity.
        public let modifiedAt: Date?
        let compressionMethod: UInt16
        let localHeaderOffset: Int

        public var fileName: String {
            path.split(separator: "/").last.map(String.init) ?? path
        }
    }

    public let entries: [Entry]
    private let data: Data

    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50
    private static let centralDirectorySignature: UInt32 = 0x0201_4B50
    private static let localHeaderSignature: UInt32 = 0x0403_4B50

    public init(data: Data) throws {
        self.data = data
        guard data.count > 22 else { throw ZipArchiveError.notAZipArchive }

        // The end-of-central-directory record sits at the tail, after an optional comment.
        let searchStart = max(0, data.count - 22 - 65_535)
        var directoryStart: Int?
        var entryCount = 0
        var index = data.count - 22
        while index >= searchStart {
            if data.readUInt32(at: index) == Self.endOfCentralDirectorySignature {
                entryCount = Int(data.readUInt16(at: index + 10))
                directoryStart = Int(data.readUInt32(at: index + 16))
                break
            }
            index -= 1
        }
        guard let directoryStart else { throw ZipArchiveError.notAZipArchive }
        if directoryStart == 0xFFFF_FFFF || entryCount == 0xFFFF {
            throw ZipArchiveError.zip64NotSupported
        }

        var parsed: [Entry] = []
        var cursor = directoryStart
        for _ in 0..<entryCount {
            guard cursor + 46 <= data.count else { throw ZipArchiveError.truncated }
            guard data.readUInt32(at: cursor) == Self.centralDirectorySignature else {
                throw ZipArchiveError.notAZipArchive
            }
            let method = data.readUInt16(at: cursor + 10)
            let dosTime = data.readUInt16(at: cursor + 12)
            let dosDate = data.readUInt16(at: cursor + 14)
            let compressedSize = Int(data.readUInt32(at: cursor + 20))
            let uncompressedSize = Int(data.readUInt32(at: cursor + 24))
            let nameLength = Int(data.readUInt16(at: cursor + 28))
            let extraLength = Int(data.readUInt16(at: cursor + 30))
            let commentLength = Int(data.readUInt16(at: cursor + 32))
            let localOffset = Int(data.readUInt32(at: cursor + 42))

            let nameStart = cursor + 46
            guard nameStart + nameLength <= data.count else { throw ZipArchiveError.truncated }
            let nameData = data.subdata(in: nameStart..<(nameStart + nameLength))
            let name = String(data: nameData, encoding: .utf8)
                ?? String(decoding: nameData, as: UTF8.self)

            // Directory entries end in "/" and carry no content.
            if !name.hasSuffix("/") {
                parsed.append(
                    Entry(
                        path: name,
                        compressedSize: compressedSize,
                        uncompressedSize: uncompressedSize,
                        modifiedAt: Self.date(dosDate: dosDate, dosTime: dosTime),
                        compressionMethod: method,
                        localHeaderOffset: localOffset
                    )
                )
            }
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        self.entries = parsed
    }

    public init(contentsOf url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    public func entry(matchingSuffix suffix: String) -> Entry? {
        entries.first { $0.path.hasSuffix(suffix) }
    }

    /// The newest entry timestamp, which for an export is when it was produced.
    public var writtenAt: Date? {
        entries.compactMap(\.modifiedAt).max()
    }

    /// DOS packs the timestamp into two 16-bit fields, in local time with two-second resolution.
    static func date(dosDate: UInt16, dosTime: UInt16) -> Date? {
        guard dosDate != 0 else { return nil }
        let day = Int(dosDate & 0x1F)
        let month = Int(dosDate >> 5 & 0x0F)
        let year = Int(dosDate >> 9) + 1980
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = Int(dosTime >> 11 & 0x1F)
        components.minute = Int(dosTime >> 5 & 0x3F)
        components.second = Int(dosTime & 0x1F) * 2
        return Calendar.current.date(from: components)
    }

    public func data(for entry: Entry) throws -> Data {
        // The local header repeats the name and extra field, whose lengths vary, so the payload
        // offset has to be read from the header rather than assumed.
        let headerOffset = entry.localHeaderOffset
        guard headerOffset + 30 <= data.count,
              data.readUInt32(at: headerOffset) == Self.localHeaderSignature
        else { throw ZipArchiveError.truncated }
        let nameLength = Int(data.readUInt16(at: headerOffset + 26))
        let extraLength = Int(data.readUInt16(at: headerOffset + 28))
        let payloadStart = headerOffset + 30 + nameLength + extraLength
        guard payloadStart + entry.compressedSize <= data.count else { throw ZipArchiveError.truncated }
        let payload = data.subdata(in: payloadStart..<(payloadStart + entry.compressedSize))

        switch entry.compressionMethod {
        case 0:
            return payload
        case 8:
            guard let inflated = Self.inflate(payload, expectedSize: entry.uncompressedSize) else {
                throw ZipArchiveError.inflateFailed(entry.path)
            }
            return inflated
        default:
            throw ZipArchiveError.unsupportedCompression(entry.compressionMethod)
        }
    }

    public func text(for entry: Entry) throws -> String {
        let raw = try data(for: entry)
        if let text = String(data: raw, encoding: .utf8) { return text }
        // YNAB writes UTF-8, but a hand-edited export may arrive in a Windows encoding.
        if let text = String(data: raw, encoding: .windowsCP1252) { return text }
        throw ZipArchiveError.notUTF8(entry.path)
    }

    public func text(matchingSuffix suffix: String) throws -> String {
        guard let entry = entry(matchingSuffix: suffix) else {
            throw ZipArchiveError.entryNotFound(suffix)
        }
        return try text(for: entry)
    }

    /// Raw DEFLATE, which is what a zip entry holds — no zlib wrapper.
    static func inflate(_ input: Data, expectedSize: Int) -> Data? {
        guard !input.isEmpty else { return Data() }
        var stream = compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!,
            dst_size: 0,
            src_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!,
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
            == COMPRESSION_STATUS_OK
        else { return nil }
        defer { compression_stream_destroy(&stream) }

        let bufferSize = max(64 * 1024, min(expectedSize, 1 << 20))
        var output = Data()
        output.reserveCapacity(max(expectedSize, bufferSize))
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        return input.withUnsafeBytes { rawInput -> Data? in
            guard let base = rawInput.bindMemory(to: UInt8.self).baseAddress else { return nil }
            stream.src_ptr = base
            stream.src_size = rawInput.count

            while true {
                let status: compression_status = buffer.withUnsafeMutableBufferPointer { out in
                    stream.dst_ptr = out.baseAddress!
                    stream.dst_size = out.count
                    return compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                }
                let produced = bufferSize - stream.dst_size
                if produced > 0 { output.append(contentsOf: buffer[0..<produced]) }

                switch status {
                case COMPRESSION_STATUS_END:
                    return output
                case COMPRESSION_STATUS_OK:
                    continue
                default:
                    return nil
                }
            }
        }
    }
}

// MARK: - Little-endian reads

extension Data {
    fileprivate func readUInt16(at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        let base = startIndex + offset
        return UInt16(self[base]) | UInt16(self[base + 1]) << 8
    }

    fileprivate func readUInt32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        let base = startIndex + offset
        return UInt32(self[base])
            | UInt32(self[base + 1]) << 8
            | UInt32(self[base + 2]) << 16
            | UInt32(self[base + 3]) << 24
    }
}
