import CLibArchive
import Darwin
import Foundation

/// Reads headers and copies only regular files/directories; never delegates extraction to a shell.
enum AgentArchive {
    static func extract(_ archive: URL, to directory: URL, maximumBytes: Int = 1_073_741_824) async throws {
        let task = Task.detached(priority: .utility) {
            try extractFiles(archive, to: directory, maximumBytes: maximumBytes)
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func relativePath(_ path: String) throws -> String {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"),
            !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
            !path.split(separator: "/").contains("..")
        else { throw AgentInstallation.Failure.unsafeArchive }
        return path.split(separator: "/").filter { $0 != "." }.joined(separator: "/")
    }

    private static func extractFiles(_ source: URL, to directory: URL, maximumBytes: Int) throws {
        try Task.checkCancellation()
        guard let reader = archive_read_new() else { throw AgentInstallation.Failure.unsafeArchive }
        defer { archive_read_free(reader) }
        // A warning can mean a filter would invoke an external helper; accept built-in support only.
        guard
            [
                archive_read_support_filter_none(reader), archive_read_support_filter_gzip(reader),
                archive_read_support_filter_bzip2(reader), archive_read_support_filter_xz(reader),
                archive_read_support_format_tar(reader),
                archive_read_support_format_zip(reader),
            ].allSatisfy({ $0 == ARCHIVE_OK })
        else { throw AgentInstallation.Failure.unsafeArchive }
        guard archive_read_open_filename(reader, source.path(percentEncoded: false), 65_536) == ARCHIVE_OK else {
            throw AgentInstallation.Failure.unsafeArchive
        }
        // Extraction owns a fresh private directory, so an existing link or tree is never followed.
        guard mkdir(directory.path(percentEncoded: false), 0o700) == 0 else {
            throw AgentInstallation.Failure.unsafeArchive
        }
        let root = directory.resolvingSymlinksInPath().pathComponents
        var remaining = maximumBytes
        var count = 0
        while true {
            try Task.checkCancellation()
            var entry: OpaquePointer?
            let status = archive_read_next_header(reader, &entry)
            if status == ARCHIVE_EOF { break }
            guard status == ARCHIVE_OK, let entry, let name = archive_entry_pathname(entry),
                archive_entry_symlink(entry) == nil, archive_entry_hardlink(entry) == nil,
                archive_entry_is_encrypted(entry) == 0, count < 10_000
            else { throw AgentInstallation.Failure.unsafeArchive }
            count += 1
            let path = try relativePath(String(cString: name))
            let kind = archive_entry_filetype(entry)
            if path.isEmpty, kind == AE_IFDIR { continue }
            guard !path.isEmpty, kind == AE_IFREG || kind == AE_IFDIR else {
                throw AgentInstallation.Failure.unsafeArchive
            }
            let destination = directory.appending(path: path)
            let resolved = destination.resolvingSymlinksInPath().pathComponents
            guard resolved.count > root.count, resolved.starts(with: root) else {
                throw AgentInstallation.Failure.unsafeArchive
            }
            if kind == AE_IFDIR {
                try FileManager.default.createDirectory(
                    at: destination,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                continue
            }
            let size = archive_entry_size(entry)
            guard size >= 0, size <= remaining else { throw AgentInstallation.Failure.unsafeArchive }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let mode: mode_t = archive_entry_perm(entry) & 0o111 == 0 ? 0o600 : 0o700
            let fd = open(destination.path(percentEncoded: false), O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, mode)
            guard fd >= 0 else { throw AgentInstallation.Failure.unsafeArchive }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            var bytes = [UInt8](repeating: 0, count: 65_536)
            var copied = 0
            while true {
                try Task.checkCancellation()
                let read = archive_read_data(reader, &bytes, bytes.count)
                if read == 0 { break }
                guard read > 0, read <= remaining, copied + read <= size else {
                    throw AgentInstallation.Failure.unsafeArchive
                }
                try handle.write(contentsOf: Data(bytes.prefix(read)))
                remaining -= read
                copied += read
            }
            guard copied == size else { throw AgentInstallation.Failure.unsafeArchive }
        }
        guard count > 0 else { throw AgentInstallation.Failure.unsafeArchive }
    }
}
