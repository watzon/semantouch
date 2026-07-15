import Foundation
import Darwin
import Dispatch
import ComputerUseCore
import ComputerUseService
import MCPServer
import SemantouchIPC

/// Resident host controller: exclusive Unix-domain listener, authenticated hello,
/// isolated MCP runtimes per connection, and closed control-method dispatch.
///
/// Invariants:
/// - Only this process invokes ComputerUseService / AX / capture / action code.
/// - Each `.mcp` connection gets a fresh `ServiceContext` (no shared revisions/ids).
/// - Physical-input-capable MCP runtimes are serialized conservatively via a single
///   serial queue so cross-client fallback input never interleaves.
/// - `bootId` is fixed for the host process lifetime; every hello mints a fresh
///   `sessionId`. Neither is reused across host restarts.
/// - Production trust has no environment bypass.
/// - `showOnboarding` is an injected callback only — HostController never builds UI.
final class HostController: @unchecked Sendable {
    /// Fixed for this host process; never shared across restarts.
    let bootId: String
    let hostVersion: String

    private let showOnboardingCallback: @Sendable () -> Void
    private let physicalInputQueue: DispatchQueue
    private let stateLock = NSLock()

    private var listener: HostListener?
    private var acceptThread: Thread?
    private var running = false
    private var stopping = false
    private var activeSessions = 0
    private var controlSessions = 0
    private var mcpSessions = 0
    private var acceptGeneration: UInt64 = 0

    /// Active post-hello sessions (MCP + control).
    var activeSessionCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activeSessions
    }

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    /// - Parameter showOnboarding: Invoked for the closed `showOnboarding` control
    ///   method. Must marshal onto the main queue if it touches AppKit; HostController
    ///   never imports or builds UI itself.
    init(showOnboarding: @escaping @Sendable () -> Void = {}) {
        self.bootId = UUID().uuidString
        self.hostVersion = MCPServer.serverVersion
        self.showOnboardingCallback = showOnboarding
        self.physicalInputQueue = DispatchQueue(
            label: "tech.watzon.semantouch.host.physical-input",
            qos: .userInitiated
        )
    }

    /// Acquire the exclusive host lock, bind the private socket, and start the accept loop.
    func start() throws {
        stateLock.lock()
        if running {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        let location = try SocketLocation.resolve()
        let policy = PeerTrustPolicy.hostAcceptsRelay(relayExecutablePath: nil)
        let hostListener = HostListener(location: location, policy: policy)
        try hostListener.start()

        stateLock.lock()
        listener = hostListener
        running = true
        stopping = false
        acceptGeneration &+= 1
        let generation = acceptGeneration
        stateLock.unlock()

        let thread = Thread { [weak self] in
            self?.acceptLoop(generation: generation)
        }
        thread.name = "tech.watzon.semantouch.host.accept"
        thread.stackSize = 1 << 20
        acceptThread = thread
        thread.start()
    }

    /// Stop accepting, close the listener. Idempotent.
    func stop() {
        stateLock.lock()
        guard running || listener != nil else {
            stateLock.unlock()
            return
        }
        stopping = true
        running = false
        acceptGeneration &+= 1
        let hostListener = listener
        listener = nil
        stateLock.unlock()

        hostListener?.stop()
    }

    // MARK: - Accept loop

    private func acceptLoop(generation: UInt64) {
        while true {
            stateLock.lock()
            let stillCurrent = running && !stopping && acceptGeneration == generation
            let hostListener = listener
            stateLock.unlock()
            guard stillCurrent, let hostListener else { return }

            let accepted: AcceptedConnection
            do {
                accepted = try hostListener.accept()
            } catch let error as IPCError {
                if case .notListening = error { return }
                fputs("semantouch-host: accept failed: \(error)\n", stderr)
                continue
            } catch {
                fputs("semantouch-host: accept failed: \(error)\n", stderr)
                continue
            }

            Thread.detachNewThread { [weak self] in
                self?.handleAccepted(accepted)
            }
        }
    }

    private func handleAccepted(_ accepted: AcceptedConnection) {
        let connection = accepted.connection
        let fd = connection.fd

        let hello: (request: HelloRequest, result: HelloResult)
        do {
            hello = try HostListener.performHello(
                fd: fd,
                hostVersion: hostVersion,
                bootId: bootId,
                allowedRoles: [.mcp, .control]
            )
        } catch {
            fputs("semantouch-host: hello failed: \(error)\n", stderr)
            connection.close()
            return
        }

        switch hello.request.role {
        case .mcp:
            runMCPSession(connection: connection, sessionId: hello.result.sessionId)
        case .control:
            runControlSession(connection: connection, sessionId: hello.result.sessionId)
        }
    }

    // MARK: - MCP sessions

    private func runMCPSession(connection: SocketConnection, sessionId: String) {
        beginSession(kind: .mcp)
        defer {
            connection.close()
            endSession(kind: .mcp)
        }

        let input = FileHandle(fileDescriptor: connection.fd, closeOnDealloc: false)
        let output = FileHandle(fileDescriptor: connection.fd, closeOnDealloc: false)

        // Serialize physical-input-capable MCP runtimes conservatively.
        let done = DispatchSemaphore(value: 0)
        physicalInputQueue.async {
            defer { done.signal() }
            // Fresh ServiceContext inside MCPRuntime.run (context: nil).
            MCPRuntime.run(context: nil, input: input, output: output)
        }
        done.wait()
        _ = sessionId
    }

    // MARK: - Control sessions

    private func runControlSession(connection: SocketConnection, sessionId: String) {
        beginSession(kind: .control)
        defer {
            connection.close()
            endSession(kind: .control)
        }
        _ = sessionId

        while true {
            stateLock.lock()
            let shouldStop = stopping
            stateLock.unlock()
            if shouldStop { return }

            let payload: Data
            do {
                payload = try FrameIO.readFrame(
                    fd: connection.fd,
                    maximumFrameBytes: HostProtocol.controlMaxFrameBytes
                )
            } catch {
                return
            }

            let request: ControlRequest
            do {
                request = try HostCodec.decode(ControlRequest.self, from: payload)
            } catch {
                let response = ControlResponse(
                    id: "unknown",
                    ok: false,
                    error: ControlErrorBody(
                        code: "invalid_request",
                        message: "Could not decode control request: \(error)",
                        retryable: false
                    )
                )
                try? writeControl(response, to: connection.fd)
                return
            }

            let response = dispatchControl(request)
            do {
                try writeControl(response, to: connection.fd)
            } catch {
                return
            }

            if request.method == ControlMethod.shutdownIfIdle.rawValue,
               case .bool(true)? = response.result?.objectValue?["shuttingDown"] {
                DispatchQueue.global().async { [weak self] in
                    self?.stop()
                }
            }
        }
    }

    private func writeControl(_ response: ControlResponse, to fd: Int32) throws {
        let data = try HostCodec.encode(response)
        if data.count > HostProtocol.controlMaxFrameBytes {
            throw IPCError.oversizedFrame(
                length: data.count,
                maximum: HostProtocol.controlMaxFrameBytes
            )
        }
        try FrameIO.writeFrame(fd: fd, payload: data)
    }

    // MARK: - Control dispatch (closed set; unknown → fail closed)

    private func dispatchControl(_ request: ControlRequest) -> ControlResponse {
        guard let method = ControlMethod(rawValue: request.method) else {
            return ControlResponse(
                id: request.id,
                ok: false,
                error: ControlErrorBody(
                    code: "unknown_method",
                    message: "Unknown control method \"\(request.method)\".",
                    retryable: false
                )
            )
        }

        switch method {
        case .ping:
            return ControlResponse(
                id: request.id,
                ok: true,
                result: .object([
                    "pong": .bool(true),
                    "hostVersion": .string(hostVersion),
                    "bootId": .string(bootId),
                    "activeSessionCount": .number(Double(activeSessionCount)),
                ])
            )

        case .doctor:
            return runDoctorControl(id: request.id, params: request.params)

        case .listApps:
            return runListAppsControl(id: request.id)

        case .probe:
            return runProbeControl(id: request.id, params: request.params)

        case .showOnboarding:
            showOnboardingCallback()
            return ControlResponse(
                id: request.id,
                ok: true,
                result: .object(["shown": .bool(true)])
            )

        case .checkForUpdate:
            return runCheckForUpdateControl(id: request.id)

        case .installUpdate:
            return runInstallUpdateControl(id: request.id)

        case .shutdownIfIdle:
            return runShutdownIfIdleControl(id: request.id)
        }
    }

    private func runDoctorControl(id: String, params: [String: SemantouchIPC.JSONValue]?) -> ControlResponse {
        let requestOnboarding = params?["requestOnboarding"]?.boolValue ?? false
        let doctor = DoctorService.run(requestOnboarding: requestOnboarding)
        let update = blockOn {
            .success(await UpdateService().check(currentVersion: doctor.helper.version))
        }
        let updateValue: UpdateCheck
        switch update {
        case let .success(check):
            updateValue = check
        case let .failure(error):
            updateValue = UpdateCheck(
                currentVersion: doctor.helper.version,
                latestVersion: nil,
                status: .unknown,
                message: error.localizedDescription
            )
        }
        let report = DoctorCommandReport(doctor: doctor, update: updateValue)
        do {
            let result = try encodeToIPCJSON(report)
            return ControlResponse(id: id, ok: true, result: result)
        } catch {
            return ControlResponse(
                id: id,
                ok: false,
                error: ControlErrorBody(
                    code: "encode_failed",
                    message: "doctor: failed to encode result: \(error)",
                    retryable: false
                )
            )
        }
    }

    private func runListAppsControl(id: String) -> ControlResponse {
        let apps = AppLister.listApps()
        let payload = ListAppsResult(apps: apps)
        do {
            let result = try encodeToIPCJSON(payload)
            return ControlResponse(id: id, ok: true, result: result)
        } catch {
            return ControlResponse(
                id: id,
                ok: false,
                error: ControlErrorBody(
                    code: "encode_failed",
                    message: "listApps: failed to encode result: \(error)",
                    retryable: false
                )
            )
        }
    }

    private func runProbeControl(id: String, params: [String: SemantouchIPC.JSONValue]?) -> ControlResponse {
        guard let kind = params?["kind"]?.stringValue else {
            return ControlResponse(
                id: id,
                ok: false,
                error: ControlErrorBody(
                    code: "invalid_params",
                    message: "probe requires params.kind (capture|ax-tree|press|set-value).",
                    retryable: false
                )
            )
        }
        guard let app = params?["app"]?.stringValue, !app.isEmpty else {
            return ControlResponse(
                id: id,
                ok: false,
                error: ControlErrorBody(
                    code: "invalid_params",
                    message: "probe requires params.app.",
                    retryable: false
                )
            )
        }

        let context = ServiceContext()
        do {
            switch kind {
            case "capture":
                guard let out = params?["out"]?.stringValue, !out.isEmpty else {
                    return ControlResponse(
                        id: id,
                        ok: false,
                        error: ControlErrorBody(
                            code: "invalid_params",
                            message: "probe capture requires params.out.",
                            retryable: false
                        )
                    )
                }
                let captureResult = try blockOnThrowing {
                    try await Probe.capture(app: app, outPath: out, context: context)
                }
                return ControlResponse(id: id, ok: true, result: encodeProbeCapture(captureResult))

            case "ax-tree":
                let tree = try Probe.axTree(app: app, context: context)
                return ControlResponse(id: id, ok: true, result: .object(["tree": .string(tree)]))

            case "press":
                guard let identifier = params?["identifier"]?.stringValue else {
                    return ControlResponse(
                        id: id,
                        ok: false,
                        error: ControlErrorBody(
                            code: "invalid_params",
                            message: "probe press requires params.identifier.",
                            retryable: false
                        )
                    )
                }
                try Probe.press(app: app, identifier: identifier, context: context)
                return ControlResponse(
                    id: id,
                    ok: true,
                    result: .object(["pressed": .string(identifier)])
                )

            case "set-value":
                guard let identifier = params?["identifier"]?.stringValue else {
                    return ControlResponse(
                        id: id,
                        ok: false,
                        error: ControlErrorBody(
                            code: "invalid_params",
                            message: "probe set-value requires params.identifier.",
                            retryable: false
                        )
                    )
                }
                guard let value = params?["value"]?.stringValue else {
                    return ControlResponse(
                        id: id,
                        ok: false,
                        error: ControlErrorBody(
                            code: "invalid_params",
                            message: "probe set-value requires params.value.",
                            retryable: false
                        )
                    )
                }
                try Probe.setValue(app: app, identifier: identifier, value: value, context: context)
                return ControlResponse(
                    id: id,
                    ok: true,
                    result: .object([
                        "identifier": .string(identifier),
                        "value": .string(value),
                    ])
                )

            default:
                return ControlResponse(
                    id: id,
                    ok: false,
                    error: ControlErrorBody(
                        code: "invalid_params",
                        message: "probe: unknown kind \"\(kind)\"; expected capture|ax-tree|press|set-value.",
                        retryable: false
                    )
                )
            }
        } catch let error as CUError {
            return ControlResponse(
                id: id,
                ok: false,
                error: ControlErrorBody(
                    code: error.code.rawValue,
                    message: error.message,
                    retryable: false
                )
            )
        } catch {
            return ControlResponse(
                id: id,
                ok: false,
                error: ControlErrorBody(
                    code: "probe_failed",
                    message: String(describing: error),
                    retryable: false
                )
            )
        }
    }

    private func runCheckForUpdateControl(id: String) -> ControlResponse {
        let check = blockOn {
            .success(await UpdateService().check(currentVersion: self.hostVersion))
        }
        switch check {
        case let .success(update):
            do {
                let result = try encodeToIPCJSON(update)
                return ControlResponse(id: id, ok: true, result: result)
            } catch {
                return ControlResponse(
                    id: id,
                    ok: false,
                    error: ControlErrorBody(
                        code: "encode_failed",
                        message: "checkForUpdate: failed to encode result: \(error)",
                        retryable: false
                    )
                )
            }
        case let .failure(error):
            return ControlResponse(
                id: id,
                ok: false,
                error: ControlErrorBody(
                    code: "update_check_failed",
                    message: error.localizedDescription,
                    retryable: true
                )
            )
        }
    }

    private func runInstallUpdateControl(id: String) -> ControlResponse {
        // Whole-app replace only: pass Semantouch.app bundle URL, never nested Mach-O.
        let appBundleURL: URL
        if Bundle.main.bundleURL.pathExtension == "app" {
            appBundleURL = Bundle.main.bundleURL
        } else if let preferred = UpdateService().discoverCanonicalInstalls().preferred {
            appBundleURL = preferred
        } else {
            do {
                appBundleURL = try UpdateService().preferredInstallDestination()
            } catch {
                return ControlResponse(
                    id: id,
                    ok: false,
                    error: ControlErrorBody(
                        code: "update_destination_unavailable",
                        message: error.localizedDescription,
                        retryable: false
                    )
                )
            }
        }

        let result = blockOn { () -> Result<UpdateInstallResult, Error> in
            do {
                let install = try await UpdateService().installLatest(
                    currentVersion: self.hostVersion,
                    appBundleURL: appBundleURL,
                    isReadyToReplace: { [weak self] in
                        guard let self else { return false }
                        self.stateLock.lock()
                        let mcp = self.mcpSessions
                        self.stateLock.unlock()
                        return mcp == 0
                    }
                )
                return .success(install)
            } catch {
                return .failure(error)
            }
        }

        switch result {
        case let .success(install):
            do {
                let encoded = try encodeToIPCJSON(install)
                return ControlResponse(id: id, ok: true, result: encoded)
            } catch {
                return ControlResponse(
                    id: id,
                    ok: false,
                    error: ControlErrorBody(
                        code: "encode_failed",
                        message: "installUpdate: failed to encode result: \(error)",
                        retryable: false
                    )
                )
            }
        case let .failure(error):
            return ControlResponse(
                id: id,
                ok: false,
                error: ControlErrorBody(
                    code: "install_failed",
                    message: error.localizedDescription,
                    retryable: false
                )
            )
        }
    }

    private func runShutdownIfIdleControl(id: String) -> ControlResponse {
        stateLock.lock()
        let count = activeSessions
        let mcp = mcpSessions
        stateLock.unlock()

        let idle = mcp == 0
        return ControlResponse(
            id: id,
            ok: true,
            result: .object([
                "idle": .bool(idle),
                "activeSessionCount": .number(Double(count)),
                "mcpSessionCount": .number(Double(mcp)),
                "shuttingDown": .bool(idle),
            ])
        )
    }

    // MARK: - Session accounting

    private enum SessionKind {
        case mcp
        case control
    }

    private func beginSession(kind: SessionKind) {
        stateLock.lock()
        activeSessions += 1
        switch kind {
        case .mcp: mcpSessions += 1
        case .control: controlSessions += 1
        }
        stateLock.unlock()
    }

    private func endSession(kind: SessionKind) {
        stateLock.lock()
        activeSessions = max(0, activeSessions - 1)
        switch kind {
        case .mcp: mcpSessions = max(0, mcpSessions - 1)
        case .control: controlSessions = max(0, controlSessions - 1)
        }
        stateLock.unlock()
    }
}

// MARK: - IPC JSON bridge

private extension SemantouchIPC.JSONValue {
    var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var objectValue: [String: SemantouchIPC.JSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }
}

private func encodeToIPCJSON<T: Encodable>(_ value: T) throws -> SemantouchIPC.JSONValue {
    let data = try CanonicalJSON.encodeToData(value)
    return try HostCodec.decode(SemantouchIPC.JSONValue.self, from: data)
}

private func encodeProbeCapture(_ capture: Probe.CaptureResult) -> SemantouchIPC.JSONValue {
    .object([
        "path": .string(capture.path),
        "byteCount": .number(Double(capture.byteCount)),
        "width": .number(Double(capture.width)),
        "height": .number(Double(capture.height)),
        "windowNumber": .number(Double(capture.windowNumber)),
    ])
}

// MARK: - Sync bridges

private final class ResultBox<U>: @unchecked Sendable {
    var value: Result<U, Error>!
}

private func blockOn<T>(_ operation: @escaping @Sendable () async -> Result<T, Error>) -> Result<T, Error> {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    Task {
        box.value = await operation()
        semaphore.signal()
    }
    semaphore.wait()
    return box.value
}

private func blockOnThrowing<T>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
    let result = blockOn { () -> Result<T, Error> in
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
    }
    switch result {
    case let .success(value): return value
    case let .failure(error): throw error
    }
}
