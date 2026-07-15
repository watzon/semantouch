import Foundation
import Darwin

/// Per-user Unix-domain socket location under `_CS_DARWIN_USER_TEMP_DIR`.
///
/// Layout: `<user-temp>/tech.watzon.semantouch/host-v1.sock` with a sibling
/// lock file. Parent directory must be mode 0700 and owned by the effective
/// UID; the socket must be a non-symlink socket mode 0600 owned by euid.
/// Paths that cannot fit `sockaddr_un.sun_path` (104 bytes on Darwin) are
/// rejected — there is no fallback to a world-shared `/tmp` path.
public struct SocketLocation: Equatable, Sendable {
    /// Absolute path of the 0700 runtime directory.
    public let directoryURL: URL
    /// Absolute path of `host-v1.sock`.
    public let socketURL: URL
    /// Absolute path of the exclusive host lock file.
    public let lockURL: URL

    public var directoryPath: String { directoryURL.path }
    public var socketPath: String { socketURL.path }
    public var lockPath: String { lockURL.path }

    /// Maximum bytes for a pathname in `sockaddr_un.sun_path` on Darwin.
    public static let sunPathLimit = 104

    public init(directoryURL: URL, socketURL: URL, lockURL: URL) {
        self.directoryURL = directoryURL
        self.socketURL = socketURL
        self.lockURL = lockURL
    }

    /// Resolve the live per-user location via `confstr(_CS_DARWIN_USER_TEMP_DIR)`.
    public static func resolve(
        fileSystem: FileSystemSeam = .live,
        euid: uid_t = geteuid()
    ) throws -> SocketLocation {
        let temp = try fileSystem.darwinUserTempDirectory()
        return try make(userTempDirectory: temp, fileSystem: fileSystem, euid: euid)
    }

    /// Build a location under an explicit user-temp root (tests inject a temp dir).
    public static func make(
        userTempDirectory: URL,
        fileSystem: FileSystemSeam = .live,
        euid: uid_t = geteuid()
    ) throws -> SocketLocation {
        let directory = userTempDirectory
            .appendingPathComponent(HostProtocol.runtimeDirectoryName, isDirectory: true)
        let socket = directory.appendingPathComponent(HostProtocol.socketFileName, isDirectory: false)
        let lock = directory.appendingPathComponent(HostProtocol.lockFileName, isDirectory: false)

        try validatePathLength(socket.path)

        // Ensure / validate the runtime directory.
        try ensureDirectory(at: directory, fileSystem: fileSystem, euid: euid)

        return SocketLocation(directoryURL: directory, socketURL: socket, lockURL: lock)
    }

    /// Validate that `path` fits in `sockaddr_un.sun_path` including the NUL terminator.
    public static func validatePathLength(_ path: String) throws {
        // sun_path is a fixed char[104]; the kernel stores a NUL-terminated path.
        let utf8Count = path.utf8.count
        if utf8Count + 1 > sunPathLimit {
            throw IPCError.pathTooLong(path: path, limit: sunPathLimit)
        }
    }

    /// Validate an existing socket path for client connect: must be a socket,
    /// not a symlink, owned by euid, mode exactly 0600 (no group/other bits).
    public static func validateSocketPath(
        _ path: String,
        fileSystem: FileSystemSeam = .live,
        euid: uid_t = geteuid()
    ) throws {
        try validatePathLength(path)
        let info = try fileSystem.lstat(path)
        if info.isSymlink {
            throw IPCError.socketInvalid(path: path, reason: "path is a symlink")
        }
        if !info.isSocket {
            throw IPCError.socketInvalid(path: path, reason: "path is not a socket")
        }
        if info.uid != euid {
            throw IPCError.socketInvalid(path: path, reason: "owner uid \(info.uid) != euid \(euid)")
        }
        let mode = info.mode & 0o777
        if mode != 0o600 {
            throw IPCError.socketInvalid(
                path: path,
                reason: String(format: "mode %04o is not 0600", mode)
            )
        }
    }

    /// Validate the runtime directory: directory (not symlink), owner euid, mode 0700.
    public static func validateDirectory(
        _ path: String,
        fileSystem: FileSystemSeam = .live,
        euid: uid_t = geteuid()
    ) throws {
        let info = try fileSystem.lstat(path)
        if info.isSymlink {
            throw IPCError.directoryInvalid(path: path, reason: "path is a symlink")
        }
        if !info.isDirectory {
            throw IPCError.directoryInvalid(path: path, reason: "path is not a directory")
        }
        if info.uid != euid {
            throw IPCError.directoryInvalid(path: path, reason: "owner uid \(info.uid) != euid \(euid)")
        }
        let mode = info.mode & 0o777
        if mode != 0o700 {
            throw IPCError.directoryInvalid(
                path: path,
                reason: String(format: "mode %04o is not 0700", mode)
            )
        }
    }

    // MARK: - Internals

    private static func ensureDirectory(
        at url: URL,
        fileSystem: FileSystemSeam,
        euid: uid_t
    ) throws {
        let path = url.path
        if fileSystem.fileExists(path) {
            try validateDirectory(path, fileSystem: fileSystem, euid: euid)
            return
        }
        try fileSystem.createDirectory(path, 0o700)
        // Re-validate after create (fail closed if something raced us).
        try validateDirectory(path, fileSystem: fileSystem, euid: euid)
    }
}

// MARK: - File-system seam

/// Observable file metadata from `lstat(2)`.
public struct FileStatInfo: Equatable, Sendable {
    public var mode: mode_t
    public var uid: uid_t
    public var gid: gid_t
    public var isDirectory: Bool
    public var isSocket: Bool
    public var isSymlink: Bool
    public var isRegular: Bool

    public init(
        mode: mode_t,
        uid: uid_t,
        gid: gid_t,
        isDirectory: Bool,
        isSocket: Bool,
        isSymlink: Bool,
        isRegular: Bool
    ) {
        self.mode = mode
        self.uid = uid
        self.gid = gid
        self.isDirectory = isDirectory
        self.isSocket = isSocket
        self.isSymlink = isSymlink
        self.isRegular = isRegular
    }

    public init(stat st: stat) {
        let type = st.st_mode & S_IFMT
        self.mode = st.st_mode
        self.uid = st.st_uid
        self.gid = st.st_gid
        self.isDirectory = type == S_IFDIR
        self.isSocket = type == S_IFSOCK
        self.isSymlink = type == S_IFLNK
        self.isRegular = type == S_IFREG
    }
}

/// Injectable filesystem operations for permission-free unit tests.
public struct FileSystemSeam: Sendable {
    public var darwinUserTempDirectory: @Sendable () throws -> URL
    public var fileExists: @Sendable (String) -> Bool
    public var lstat: @Sendable (String) throws -> FileStatInfo
    public var createDirectory: @Sendable (String, mode_t) throws -> Void
    public var removeItem: @Sendable (String) throws -> Void
    public var chmod: @Sendable (String, mode_t) throws -> Void
    public var symlink: @Sendable (String, String) throws -> Void
    public var createFile: @Sendable (String, mode_t) throws -> Void

    public init(
        darwinUserTempDirectory: @escaping @Sendable () throws -> URL,
        fileExists: @escaping @Sendable (String) -> Bool,
        lstat: @escaping @Sendable (String) throws -> FileStatInfo,
        createDirectory: @escaping @Sendable (String, mode_t) throws -> Void,
        removeItem: @escaping @Sendable (String) throws -> Void,
        chmod: @escaping @Sendable (String, mode_t) throws -> Void,
        symlink: @escaping @Sendable (String, String) throws -> Void,
        createFile: @escaping @Sendable (String, mode_t) throws -> Void
    ) {
        self.darwinUserTempDirectory = darwinUserTempDirectory
        self.fileExists = fileExists
        self.lstat = lstat
        self.createDirectory = createDirectory
        self.removeItem = removeItem
        self.chmod = chmod
        self.symlink = symlink
        self.createFile = createFile
    }

    public static let live: FileSystemSeam = makeLive()

    private static func makeLive() -> FileSystemSeam {
        FileSystemSeam(
            darwinUserTempDirectory: {
                var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
                let n = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
                if n == 0 || n > buffer.count {
                    throw IPCError.userTempUnavailable
                }
                let path = String(cString: buffer)
                return URL(fileURLWithPath: path, isDirectory: true)
            },
            fileExists: { path in
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            },
            lstat: { path in
                var st = Darwin.stat()
                let rc = path.withCString { cPath in Darwin.lstat(cPath, &st) }
                if rc != 0 {
                    throw IPCError.ioFailed(operation: "lstat", errnoCode: errno)
                }
                return FileStatInfo(stat: st)
            },
            createDirectory: { path, mode in
                try FileManager.default.createDirectory(
                    atPath: path,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: NSNumber(value: mode)]
                )
                // FileManager may apply umask; force the requested mode.
                if Darwin.chmod(path, mode) != 0 {
                    throw IPCError.ioFailed(operation: "chmod", errnoCode: errno)
                }
            },
            removeItem: { path in
                try FileManager.default.removeItem(atPath: path)
            },
            chmod: { path, mode in
                if Darwin.chmod(path, mode) != 0 {
                    throw IPCError.ioFailed(operation: "chmod", errnoCode: errno)
                }
            },
            symlink: { dest, link in
                if Darwin.symlink(dest, link) != 0 {
                    throw IPCError.ioFailed(operation: "symlink", errnoCode: errno)
                }
            },
            createFile: { path, mode in
                if !FileManager.default.createFile(
                    atPath: path,
                    contents: Data(),
                    attributes: [.posixPermissions: NSNumber(value: mode)]
                ) {
                    throw IPCError.ioFailed(operation: "createFile", errnoCode: errno)
                }
                if Darwin.chmod(path, mode) != 0 {
                    throw IPCError.ioFailed(operation: "chmod", errnoCode: errno)
                }
            }
        )
    }
}
