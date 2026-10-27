import Compression
import Foundation
import EmbersCore

/// Builds a zip in memory so the reader is checked against a known archive, not only a real export.
/// CRCs are left zero: the reader does not verify them, and inventing them here would test nothing.
private enum ZipBuilder {
    static func archive(files: [(name: String, contents: String, deflate: Bool)]) -> Data {
        var payload = Data()
        var directory = Data()
        var offsets: [Int] = []

        for file in files {
            let raw = Data(file.contents.utf8)
            let stored = file.deflate ? (deflate(raw) ?? raw) : raw
            let method: UInt16 = (file.deflate && stored.count != raw.count) || file.deflate ? 8 : 0
            let nameBytes = Data(file.name.utf8)
            offsets.append(payload.count)

            payload.appendUInt32(0x0403_4B50)
            payload.appendUInt16(20)                      // version needed
            payload.appendUInt16(0)                       // flags
            payload.appendUInt16(method)
            payload.appendUInt16(0)                       // mod time
            payload.appendUInt16(0)                       // mod date
            payload.appendUInt32(0)                       // crc32, unverified
            payload.appendUInt32(UInt32(stored.count))
            payload.appendUInt32(UInt32(raw.count))
            payload.appendUInt16(UInt16(nameBytes.count))
            payload.appendUInt16(0)                       // extra length
            payload.append(nameBytes)
            payload.append(stored)
        }

        for (index, file) in files.enumerated() {
            let raw = Data(file.contents.utf8)
            let stored = file.deflate ? (deflate(raw) ?? raw) : raw
            let method: UInt16 = file.deflate ? 8 : 0
            let nameBytes = Data(file.name.utf8)

            directory.appendUInt32(0x0201_4B50)
            directory.appendUInt16(20)                    // version made by
            directory.appendUInt16(20)                    // version needed
            directory.appendUInt16(0)                     // flags
            directory.appendUInt16(method)
            directory.appendUInt16(0)                     // mod time
            directory.appendUInt16(0)                     // mod date
            directory.appendUInt32(0)                     // crc32
            directory.appendUInt32(UInt32(stored.count))
            directory.appendUInt32(UInt32(raw.count))
            directory.appendUInt16(UInt16(nameBytes.count))
            directory.appendUInt16(0)                     // extra
            directory.appendUInt16(0)                     // comment
            directory.appendUInt16(0)                     // disk number
            directory.appendUInt16(0)                     // internal attrs
            directory.appendUInt32(0)                     // external attrs
            directory.appendUInt32(UInt32(offsets[index]))
            directory.append(nameBytes)
        }

        let directoryOffset = payload.count
        var archive = payload
        archive.append(directory)
        archive.appendUInt32(0x0605_4B50)
        archive.appendUInt16(0)
        archive.appendUInt16(0)
        archive.appendUInt16(UInt16(files.count))
        archive.appendUInt16(UInt16(files.count))
        archive.appendUInt32(UInt32(directory.count))
        archive.appendUInt32(UInt32(directoryOffset))
        archive.appendUInt16(0)
        return archive
    }

    static func deflate(_ input: Data) -> Data? {
        var stream = compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
            src_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB)
            == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(&stream) }

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
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
                let produced = buffer.count - stream.dst_size
                if produced > 0 { output.append(contentsOf: buffer[0..<produced]) }
                if status == COMPRESSION_STATUS_END { return output }
                if status != COMPRESSION_STATUS_OK { return nil }
            }
        }
    }
}

extension Data {
    fileprivate mutating func appendUInt16(_ value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)])
    }

    fileprivate mutating func appendUInt32(_ value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0xFF),
            UInt8(value >> 8 & 0xFF),
            UInt8(value >> 16 & 0xFF),
            UInt8(value >> 24 & 0xFF),
        ])
    }
}

func zipChecks(_ check: Checker) {
    check.suite("Zip archive reading") {
        let planCSV = """
        "Month","Category Group/Category","Category Group","Category","Assigned","Activity","Available"
        "Jan 2026","Immediate Obligations: Groceries","Immediate Obligations","Groceries",$100.00,-$70.00,$30.00
        """
        let registerCSV = """
        "Account","Flag","Date","Payee","Category Group/Category","Category Group","Category","Memo","Outflow","Inflow","Cleared"
        "Cash (USD)","","01/10/2026","Carreta Market","Immediate Obligations: Groceries","Immediate Obligations","Groceries","",$70.00,$0.00,"Cleared"
        """

        check.test("reads deflated entries") {
            let data = ZipBuilder.archive(files: [
                ("Budget - Plan.csv", planCSV, true),
                ("Budget - Register.csv", registerCSV, true),
            ])
            let archive = try ZipArchive(data: data)
            check.expect(archive.entries.count, 2)
            check.expect(try archive.text(matchingSuffix: "Plan.csv"), planCSV)
            check.expect(try archive.text(matchingSuffix: "Register.csv"), registerCSV)
        }

        check.test("reads stored entries") {
            let data = ZipBuilder.archive(files: [("Budget - Plan.csv", planCSV, false)])
            let archive = try ZipArchive(data: data)
            check.expect(archive.entries.first?.compressedSize, archive.entries.first?.uncompressedSize)
            check.expect(try archive.text(matchingSuffix: "Plan.csv"), planCSV)
        }

        check.test("survives a large entry that spans several output buffers") {
            let big = String(repeating: "\"Cash (USD)\",\"\",\"01/10/2026\",\"Carreta Market\"\n", count: 20_000)
            let data = ZipBuilder.archive(files: [("big.csv", big, true)])
            let archive = try ZipArchive(data: data)
            check.expect(try archive.text(matchingSuffix: "big.csv").count, big.count)
        }

        check.test("rejects data that is not a zip, and names a missing entry") {
            check.expectThrows { try ZipArchive(data: Data(repeating: 0x41, count: 512)) }
            let archive = try ZipArchive(data: ZipBuilder.archive(files: [("a.csv", planCSV, true)]))
            check.expectThrows { try archive.text(matchingSuffix: "Register.csv") }
        }

        check.test("imports straight from an archive") {
            let data = ZipBuilder.archive(files: [
                ("Budget - Plan.csv", planCSV, true),
                ("Budget - Register.csv", registerCSV, true),
            ])
            let archive = try ZipArchive(data: data)
            let budget = try YNABImporter().makeBudget(
                planCSV: try archive.text(matchingSuffix: "Plan.csv"),
                registerCSV: try archive.text(matchingSuffix: "Register.csv")
            )
            check.expect(budget.accounts.count, 1)
            check.expect(budget.transactions.count, 1)
            check.expect(budget.assignments.count, 1)
        }

        // Opportunistic: the real export is the only sample of YNAB's own zip output.
        check.test("reads the real YNAB export when it is present") {
            let url = URL(fileURLWithPath: NSString(
                string: "~/Downloads/YNAB Export - My Budget as of 2026-09-29 19-50.zip"
            ).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                print("      (skipped: export not present on this machine)")
                return
            }
            let archive = try ZipArchive(contentsOf: url)
            check.expect(archive.entries.count, 2)
            let plan = try archive.text(matchingSuffix: "Plan.csv")
            let register = try archive.text(matchingSuffix: "Register.csv")
            let budget = try YNABImporter().makeBudget(planCSV: plan, registerCSV: register)
            check.expect(budget.accounts.count, 32)
            check.expect(budget.payees.count, 580)
            check.expect(budget.transactions.count, 10_754)
            check.expect(budget.report.transferPairCount, 1_409)
            check.expect(budget.report.unmatchedTransferCount, 0)
            check.expect(budget.expectations.count, 5_160)
        }
    }
}
