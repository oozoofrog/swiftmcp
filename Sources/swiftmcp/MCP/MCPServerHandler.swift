// MCPServerHandler.swift
// JSON-RPC 2.0 디스패처
// stdin에서 줄 단위로 요청 읽기 → 응답 → stdout 출력

import Foundation

/// JSON-RPC 2.0 요청 모델
nonisolated struct JSONRPCRequest: Decodable, Sendable {
    let jsonrpc: String
    let method: String
    let id: JSONRPCIDValue?
    let params: JSONValue?
}

/// JSON-RPC 2.0 ID (문자열 또는 정수)
nonisolated enum JSONRPCIDValue: Codable, Sendable {
    case string(String)
    case integer(Int)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let str = try? container.decode(String.self) {
            self = .string(str)
        } else if let int = try? container.decode(Int.self) {
            self = .integer(int)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .integer(let i): try container.encode(i)
        case .null: try container.encodeNil()
        }
    }
}

/// 범용 JSON 값 타입 (Codable)
nonisolated enum JSONValue: Codable, Sendable {
    case string(String)
    case integer(Int)
    case double(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .integer(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .integer(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        case .null: try container.encodeNil()
        }
    }

    /// object에서 키 접근
    subscript(key: String) -> JSONValue? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }

    /// 문자열 값 추출
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

/// JSON-RPC 2.0 MCP 서버 핸들러
nonisolated struct MCPServerHandler: Sendable {

    /// stdio JSON-RPC 2.0 서버 루프 시작
    func serve() async throws {
        let tools = MCPTools()
        var initialized = false

        // stdin에서 줄 단위로 읽기
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // JSON 파싱
            guard let requestData = trimmed.data(using: .utf8) else {
                sendError(id: nil, code: -32700, message: "Parse error: invalid UTF-8")
                continue
            }

            let request: JSONRPCRequest
            do {
                request = try JSONDecoder().decode(JSONRPCRequest.self, from: requestData)
            } catch {
                sendError(id: nil, code: -32700, message: "Parse error: \(error.localizedDescription)")
                continue
            }

            guard request.jsonrpc == "2.0" else {
                sendError(id: request.id, code: -32600, message: "Invalid Request: jsonrpc must be '2.0'")
                continue
            }

            // 메서드 디스패치
            switch request.method {
            case "initialize":
                sendResult(id: request.id, result: tools.handleInitialize(params: request.params))
                initialized = true

            case "initialized":
                // notification — 응답 없음
                break

            case "tools/list":
                guard initialized else {
                    sendError(id: request.id, code: -32002, message: "Server not initialized")
                    continue
                }
                sendResult(id: request.id, result: tools.handleToolsList())

            case "tools/call":
                guard initialized else {
                    sendError(id: request.id, code: -32002, message: "Server not initialized")
                    continue
                }
                let result = await tools.handleToolsCall(params: request.params)
                sendResult(id: request.id, result: result)

            case "ping":
                sendResult(id: request.id, result: JSONValue.object([:]))

            default:
                sendError(id: request.id, code: -32601, message: "Method not found: \(request.method)")
            }
        }
    }

    // MARK: - Private

    private func sendResult(id: JSONRPCIDValue?, result: JSONValue) {
        var response: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "result": result
        ]
        if let id = id {
            response["id"] = encodeID(id)
        } else {
            response["id"] = .null
        }

        outputJSON(response)
    }

    private func sendError(id: JSONRPCIDValue?, code: Int, message: String) {
        var response: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "error": .object([
                "code": .integer(code),
                "message": .string(message)
            ])
        ]
        if let id = id {
            response["id"] = encodeID(id)
        } else {
            response["id"] = .null
        }

        outputJSON(response)
    }

    private func encodeID(_ id: JSONRPCIDValue) -> JSONValue {
        switch id {
        case .string(let s): return .string(s)
        case .integer(let i): return .integer(i)
        case .null: return .null
        }
    }

    private func outputJSON(_ dict: [String: JSONValue]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        if let data = try? encoder.encode(dict),
           let str = String(data: data, encoding: .utf8) {
            print(str)
            fflush(stdout)
        }
    }
}
