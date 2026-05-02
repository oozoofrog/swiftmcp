import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Reads newline-delimited JSON from stdin, dispatches to a `Server`, writes responses to stdout.
/// stdout writes are serialized through this actor so concurrent tool handlers cannot interleave.
public actor StdioLoop {
    private let server: Server
    private let stdin: FileHandle
    private let stdout: FileHandle
    /// Cached fd for direct write(2) calls. Foundation's
    /// `FileHandle.write(contentsOf:)` on stdout-as-pipe was observed (Swift
    /// 6.3.x / macOS 26) to delay delivery to the reader until process exit
    /// — short JSON-RPC responses sat invisible to the parent until EOF.
    /// Going straight to the kernel write syscall bypasses whatever
    /// userspace bookkeeping caused the holdback.
    private let stdoutFD: Int32

    public init(
        server: Server,
        stdin: FileHandle = .standardInput,
        stdout: FileHandle = .standardOutput
    ) {
        self.server = server
        self.stdin = stdin
        self.stdout = stdout
        self.stdoutFD = stdout.fileDescriptor
    }

    /// Run until stdin reaches EOF. All in-flight handlers are awaited before returning,
    /// so the process does not exit while a response is still being formed.
    public func run() async {
        await withTaskGroup(of: Void.self) { group in
            for await line in linesFromStdin() {
                guard !line.isEmpty else { continue }
                let data = Data(line.utf8)
                // Each message gets its own child task so a slow handler does not block reads.
                // Response order may differ from request order; clients match by id.
                group.addTask { [server, self] in
                    if let response = await server.handleInbound(data) {
                        await self.write(response)
                    }
                }
            }
            await group.waitForAll()
        }
    }

    private func write(_ data: Data) {
        var line = data
        line.append(0x0A) // newline terminator
        #if canImport(Darwin)
        // Loop until every byte lands; write(2) can return short on pipes
        // under signal interruption or buffer pressure. We retry on EINTR
        // and silently drop on other errors — JSON-RPC ids let the client
        // detect a dropped frame on its own clock.
        line.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var remaining = raw.count
            var cursor = base
            while remaining > 0 {
                let written = Darwin.write(stdoutFD, cursor, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return
                }
                cursor = cursor.advanced(by: written)
                remaining -= written
            }
        }
        #else
        try? stdout.write(contentsOf: line)
        #endif
    }

    /// Line-buffered async sequence over stdin. Yields each newline-terminated UTF-8 line
    /// (without the trailing newline). Terminates on EOF or read error.
    ///
    /// We use the raw `read(2)` syscall instead of
    /// `FileHandle.read(upToCount:)` — Foundation's FileHandle reader on
    /// macOS was observed (Swift 6.3 / macOS 26) to delay returning short
    /// pipe reads until either a 4 KB chunk filled or the writer closed
    /// stdin. That meant a single 41-byte JSON-RPC request (e.g. `ping`)
    /// from a live client (Claude Code, Codex CLI) sat invisible to the
    /// server until the client gave up and disconnected — Claude Code's
    /// "✘ Failed to connect" surfaces directly from this. Going to the
    /// kernel directly removes the userspace bookkeeping that caused the
    /// holdback.
    nonisolated private func linesFromStdin() -> AsyncStream<String> {
        let stdinFD = self.stdin.fileDescriptor
        return AsyncStream { continuation in
            let task = Task.detached {
                var buffer = [UInt8]()
                let chunkCapacity = 4096
                var rawChunk = [UInt8](repeating: 0, count: chunkCapacity)
                while !Task.isCancelled {
                    let n = rawChunk.withUnsafeMutableBufferPointer { ptr -> Int in
                        guard let base = ptr.baseAddress else { return 0 }
                        return Darwin.read(stdinFD, base, chunkCapacity)
                    }
                    if n == 0 {
                        break // EOF
                    }
                    if n < 0 {
                        if errno == EINTR { continue }
                        break
                    }
                    buffer.append(contentsOf: rawChunk[..<n])
                    while let nlIndex = buffer.firstIndex(of: 0x0A) {
                        let lineBytes = Array(buffer[..<nlIndex])
                        if let line = String(bytes: lineBytes, encoding: .utf8) {
                            continuation.yield(line)
                        }
                        buffer.removeSubrange(0...nlIndex)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
