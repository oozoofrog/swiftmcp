import Foundation

public let MCPProtocolVersion = "2025-11-25"

// MARK: - initialize

public struct InitializeParams: Codable, Sendable, Equatable {
    public let protocolVersion: String
    public let capabilities: JSONValue
    public let clientInfo: ClientInfo

    public struct ClientInfo: Codable, Sendable, Equatable {
        public let name: String
        public let title: String?
        public let version: String?
    }
}

public struct InitializeResult: Codable, Sendable, Equatable {
    public let protocolVersion: String
    public let capabilities: ServerCapabilities
    public let serverInfo: ServerInfo
    public let instructions: String?

    public struct ServerCapabilities: Codable, Sendable, Equatable {
        public let tools: ToolsCapability?

        public struct ToolsCapability: Codable, Sendable, Equatable {
            public let listChanged: Bool?

            public init(listChanged: Bool? = nil) {
                self.listChanged = listChanged
            }
        }

        public init(tools: ToolsCapability? = nil) {
            self.tools = tools
        }
    }

    public struct ServerInfo: Codable, Sendable, Equatable {
        public let name: String
        public let title: String?
        public let version: String

        public init(name: String, title: String? = nil, version: String) {
            self.name = name
            self.title = title
            self.version = version
        }
    }

    public init(
        protocolVersion: String,
        capabilities: ServerCapabilities,
        serverInfo: ServerInfo,
        instructions: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.serverInfo = serverInfo
        self.instructions = instructions
    }
}

// MARK: - tools

public struct ToolDefinition: Codable, Sendable, Equatable {
    public let name: String
    public let title: String?
    public let description: String
    public let inputSchema: JSONValue

    public init(name: String, title: String? = nil, description: String, inputSchema: JSONValue) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct ListToolsParams: Codable, Sendable, Equatable {
    public let cursor: String?

    public init(cursor: String? = nil) {
        self.cursor = cursor
    }
}

public struct ListToolsResult: Codable, Sendable, Equatable {
    public let tools: [ToolDefinition]
    public let nextCursor: String?

    public init(tools: [ToolDefinition], nextCursor: String? = nil) {
        self.tools = tools
        self.nextCursor = nextCursor
    }
}

public struct CallToolParams: Codable, Sendable, Equatable {
    public let name: String
    public let arguments: JSONValue?

    public init(name: String, arguments: JSONValue? = nil) {
        self.name = name
        self.arguments = arguments
    }
}

public struct CallToolResult: Codable, Sendable, Equatable {
    public let content: [ContentItem]
    public let isError: Bool

    public init(content: [ContentItem], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }
}

public struct ContentItem: Codable, Sendable, Equatable {
    public let type: String
    public let text: String?

    public init(type: String, text: String? = nil) {
        self.type = type
        self.text = text
    }

    public static func text(_ text: String) -> ContentItem {
        ContentItem(type: "text", text: text)
    }
}

// MARK: - notifications

public struct CancelledParams: Codable, Sendable, Equatable {
    public let requestId: JSONRPCID
    public let reason: String?

    public init(requestId: JSONRPCID, reason: String? = nil) {
        self.requestId = requestId
        self.reason = reason
    }
}
