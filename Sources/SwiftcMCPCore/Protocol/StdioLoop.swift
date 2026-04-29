import Foundation

/// Reads newline-delimited JSON from stdin, dispatches to a `Server`, writes responses to stdout.
/// stdout writes are serialized through this actor so concurrent tool handlers cannot interleave.
public actor StdioLoop {
    private let server: Server
    private let stdin: FileHandle
    private let stdout: FileHandle

    public init(
        server: Server,
        stdin: FileHandle = .standardInput,
        stdout: FileHandle = .standardOutput
    ) {
        self.server = server
        self.stdin = stdin
        self.stdout = stdout
    }

    /// Run until stdin reaches EOF.
    public func run() async {
        for await line in linesFromStdin() {
            guard !line.isEmpty else { continue }
            let data = Data(line.utf8)
            // Fire-and-forget so a slow handler does not block the read loop.
            // Response order may differ from request order; clients match by id.
            Task { [server] in
                if let response = await server.handleInbound(data) {
                    self.write(response)
                }
            }
        }
    }

    private func write(_ data: Data) {
        var line = data
        line.append(0x0A) // newline terminator
        try? stdout.write(contentsOf: line)
    }

    /// Line-buffered async sequence over stdin. Yields each newline-terminated UTF-8 line
    /// (without the trailing newline). Terminates on EOF or read error.
    nonisolated private func linesFromStdin() -> AsyncStream<String> {
        AsyncStream { continuation in
            let handle = self.stdin
            let task = Task.detached {
                var buffer = Data()
                while !Task.isCancelled {
                    let chunk: Data
                    do {
                        chunk = try handle.read(upToCount: 4096) ?? Data()
                    } catch {
                        break
                    }
                    if chunk.isEmpty {
                        break // EOF
                    }
                    buffer.append(chunk)
                    while let nlIndex = buffer.firstIndex(of: 0x0A) {
                        let lineData = buffer[buffer.startIndex..<nlIndex]
                        if let line = String(data: Data(lineData), encoding: .utf8) {
                            continuation.yield(line)
                        }
                        buffer.removeSubrange(buffer.startIndex...nlIndex)
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
