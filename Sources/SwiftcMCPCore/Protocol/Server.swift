import Foundation

/// MCP server. Owns the tool registry and dispatches inbound JSON-RPC messages.
public actor Server {
    public struct Info: Sendable {
        public let name: String
        public let title: String?
        public let version: String
        public let instructions: String?

        public init(
            name: String,
            title: String? = nil,
            version: String,
            instructions: String? = nil
        ) {
            self.name = name
            self.title = title
            self.version = version
            self.instructions = instructions
        }
    }

    public enum LifecycleState: Sendable, Equatable {
        case awaitingInitialize
        case initializeAcknowledged
        case ready
    }

    private let info: Info
    private let registry: ToolRegistry
    private(set) var state: LifecycleState = .awaitingInitialize
    private var inFlightTasks: [JSONRPCID: Task<Data?, Never>] = [:]

    public init(info: Info, registry: ToolRegistry) {
        self.info = info
        self.registry = registry
    }

    /// Process one inbound message.
    /// Returns the encoded response data for requests, or `nil` for notifications, parse-only failures
    /// where no response is meaningful, and **cancelled requests** (per the cancellation utility, the
    /// server SHOULD NOT send a response for a cancelled request).
    public func handleInbound(_ data: Data) async -> Data? {
        let inbound: JSONRPCInbound
        do {
            inbound = try JSONDecoder().decode(JSONRPCInbound.self, from: data)
        } catch {
            return encodeResponse(.failure(id: nil, error: .parseError("\(error)")))
        }

        guard inbound.jsonrpc == "2.0" else {
            if let id = inbound.id {
                return encodeResponse(.failure(id: id, error: .invalidRequest("jsonrpc must be \"2.0\"")))
            }
            return nil
        }

        if inbound.isNotification {
            await handleNotification(method: inbound.method, params: inbound.params)
            return nil
        }

        guard let id = inbound.id else { return nil }

        // Run the request inside a Task we register, so an inbound notifications/cancelled
        // can find it by id and cancel it. The Task body inherits this actor's isolation.
        let task = Task { [self] in
            await self.executeRequest(id: id, method: inbound.method, params: inbound.params)
        }
        inFlightTasks[id] = task
        let response = await task.value
        inFlightTasks.removeValue(forKey: id)
        return response
    }

    private func executeRequest(id: JSONRPCID, method: String, params: JSONValue?) async -> Data? {
        do {
            let result = try await handleRequest(method: method, params: params)
            // If cancellation arrived while the handler was running but before it threw,
            // swallow the response to honor the spec.
            if Task.isCancelled {
                return nil
            }
            return encodeResponse(.success(id: id, result: result))
        } catch is CancellationError {
            // Per MCP cancellation utility, do not send a response for a cancelled request.
            return nil
        } catch let mcp as MCPError {
            return encodeResponse(.failure(id: id, error: mcp.asJSONRPCError))
        } catch let json as JSONRPCErrorObject {
            return encodeResponse(.failure(id: id, error: json))
        } catch {
            if Task.isCancelled {
                return nil
            }
            return encodeResponse(.failure(id: id, error: .internalError("\(error)")))
        }
    }

    // MARK: - Request dispatch

    private func handleRequest(method: String, params: JSONValue?) async throws -> JSONValue {
        switch method {
        case "initialize":
            return try await initialize(params: params)
        case "ping":
            return .object([:])
        case "tools/list":
            return try await listTools(params: params)
        case "tools/call":
            return try await callTool(params: params)
        default:
            throw MCPError.methodNotFound(method)
        }
    }

    private func handleNotification(method: String, params: JSONValue?) async {
        switch method {
        case "notifications/initialized":
            state = .ready
        case "notifications/cancelled":
            // Locate the in-flight request and cancel its Task. Best-effort: if the
            // request already completed and was unregistered, the notification is ignored.
            if let params, let cancelled: CancelledParams = try? decodeOptionalParams(params) {
                inFlightTasks[cancelled.requestId]?.cancel()
            }
        default:
            // Per JSON-RPC, unknown notifications are silently ignored.
            break
        }
    }

    // MARK: - Method implementations

    private func initialize(params: JSONValue?) async throws -> JSONValue {
        let _: InitializeParams = try decodeParams(params)
        state = .initializeAcknowledged
        let result = InitializeResult(
            protocolVersion: MCPProtocolVersion,
            capabilities: .init(tools: .init(listChanged: false)),
            serverInfo: .init(name: info.name, title: info.title, version: info.version),
            instructions: info.instructions
        )
        return try encodeJSON(result)
    }

    private func listTools(params: JSONValue?) async throws -> JSONValue {
        // Cursor is optional; pagination is not used while tool count stays small.
        let _: ListToolsParams? = try decodeOptionalParams(params)
        let tools = await registry.list()
        return try encodeJSON(ListToolsResult(tools: tools, nextCursor: nil))
    }

    private func callTool(params: JSONValue?) async throws -> JSONValue {
        let p: CallToolParams = try decodeParams(params)
        do {
            let result = try await registry.call(name: p.name, arguments: p.arguments)
            return try encodeJSON(result)
        } catch let mcp as MCPError {
            switch mcp {
            case .invalidParams, .methodNotFound:
                throw mcp
            case .toolExecutionFailed(let message):
                let errorResult = CallToolResult(
                    content: [.text(message)],
                    isError: true
                )
                return try encodeJSON(errorResult)
            case .internalError:
                throw mcp
            }
        } catch {
            // Unknown tool-side error → tool result with isError, not JSON-RPC error,
            // per the channel-mapping policy.
            let errorResult = CallToolResult(
                content: [.text("\(error)")],
                isError: true
            )
            return try encodeJSON(errorResult)
        }
    }

    // MARK: - Encoding

    private func encodeResponse(_ response: JSONRPCResponse) -> Data {
        do {
            return try JSONEncoder().encode(response)
        } catch {
            // Encoder failure is exceptional; emit a hardcoded JSON-RPC fallback so the
            // client still receives a well-formed envelope.
            let fallback = #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Encoding failure"}}"#
            return Data(fallback.utf8)
        }
    }
}
