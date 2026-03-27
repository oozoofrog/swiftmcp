// MCPTools.swift
// swiftmcp MCP 서버의 7개 tool 정의 및 실행 로직
// run, install, search, list, init, cache_clean, registry_update

import Foundation

/// MCP tools 정의 및 핸들러
nonisolated struct MCPTools: Sendable {

    // MARK: - initialize 핸들러

    func handleInitialize(params: JSONValue?) -> JSONValue {
        return .object([
            "protocolVersion": .string("2024-11-05"),
            "capabilities": .object([
                "tools": .object([:])
            ]),
            "serverInfo": .object([
                "name": .string("swiftmcp"),
                "version": .string("1.0.0")
            ])
        ])
    }

    // MARK: - tools/list 핸들러

    func handleToolsList() -> JSONValue {
        let tools: [JSONValue] = [
            makeTool(
                name: "run",
                description: "MCP 서버를 레지스트리에서 즉시 실행합니다",
                properties: [
                    "name": ("string", "실행할 MCP 서버 이름", true),
                    "args": ("string", "전달할 추가 인수 (공백 구분)", false)
                ]
            ),
            makeTool(
                name: "install",
                description: "MCP 서버를 다운로드하여 캐시에 설치합니다 (실행하지 않음)",
                properties: [
                    "name": ("string", "설치할 MCP 서버 이름", true)
                ]
            ),
            makeTool(
                name: "search",
                description: "레지스트리에서 MCP 서버를 검색합니다",
                properties: [
                    "query": ("string", "검색어 (이름 또는 설명에서 대소문자 무관 검색)", true)
                ]
            ),
            makeTool(
                name: "list",
                description: "설치된 MCP 서버 목록을 반환합니다",
                properties: [:]
            ),
            makeTool(
                name: "init",
                description: "새 MCP 서버 Swift 프로젝트를 생성합니다",
                properties: [
                    "name": ("string", "프로젝트 이름", true),
                    "description": ("string", "프로젝트 설명", false),
                    "output": ("string", "출력 디렉토리 경로", false)
                ]
            ),
            makeTool(
                name: "cache_clean",
                description: "캐시를 삭제합니다",
                properties: [
                    "name": ("string", "삭제할 특정 패키지 이름 (미지정 시 전체 삭제)", false)
                ]
            ),
            makeTool(
                name: "registry_update",
                description: "레지스트리를 강제 갱신합니다 (캐시 무시)",
                properties: [:]
            )
        ]

        return .object(["tools": .array(tools)])
    }

    // MARK: - tools/call 핸들러

    func handleToolsCall(params: JSONValue?) async -> JSONValue {
        guard let toolName = params?["name"]?.stringValue else {
            return makeError("tool name이 필요합니다")
        }

        let arguments = params?["arguments"]

        switch toolName {
        case "run":
            return await handleRun(arguments: arguments)
        case "install":
            return await handleInstall(arguments: arguments)
        case "search":
            return await handleSearch(arguments: arguments)
        case "list":
            return await handleList()
        case "init":
            return await handleInit(arguments: arguments)
        case "cache_clean":
            return await handleCacheClean(arguments: arguments)
        case "registry_update":
            return await handleRegistryUpdate()
        default:
            return makeError("알 수 없는 tool: \(toolName)")
        }
    }

    // MARK: - Tool 구현

    private func handleRun(arguments: JSONValue?) async -> JSONValue {
        guard let name = arguments?["name"]?.stringValue else {
            return makeError("name 인수가 필요합니다")
        }

        return makeText("swiftmcp run \(name) — MCP 서버는 직접 실행해야 합니다.\n사용법: swiftmcp run \(name)")
    }

    private func handleInstall(arguments: JSONValue?) async -> JSONValue {
        guard let name = arguments?["name"]?.stringValue else {
            return makeError("name 인수가 필요합니다")
        }

        let registryClient = RegistryClient()
        let registry: RegistryEntry
        do {
            registry = try await registryClient.fetch()
        } catch {
            return makeError("레지스트리 로드 실패: \(error.localizedDescription)")
        }

        guard let entry = registry.servers[name] else {
            return makeError("Package not found in registry: '\(name)'. Try: swiftmcp search <query>")
        }

        let binaryResolver = BinaryResolver()
        let cacheManager = CacheManager()

        do {
            let (url, version) = try await binaryResolver.resolve(entry: entry)

            if let cached = cacheManager.cachedBinaryPath(name: name, version: version) {
                return makeText("'\(name)@\(version)'이 이미 설치되어 있습니다.\n경로: \(cached)")
            }

            let binaryPath = try await cacheManager.download(
                url: url,
                name: name,
                version: version,
                executableName: entry.executable
            )
            return makeText("설치 완료!\nInstalled to: \(binaryPath)")
        } catch {
            return makeError("설치 실패: \(error.localizedDescription)")
        }
    }

    private func handleSearch(arguments: JSONValue?) async -> JSONValue {
        guard let query = arguments?["query"]?.stringValue else {
            return makeError("query 인수가 필요합니다")
        }

        let registryClient = RegistryClient()
        let registry: RegistryEntry
        do {
            registry = try await registryClient.fetch()
        } catch {
            return makeError("레지스트리 로드 실패: \(error.localizedDescription)")
        }

        let lowercased = query.lowercased()
        let results = registry.servers.filter { name, entry in
            name.lowercased().contains(lowercased) ||
            entry.description.lowercased().contains(lowercased)
        }

        if results.isEmpty {
            return makeText("No results found for '\(query)'.")
        }

        var output = "검색 결과 (\(results.count)개):\n"
        for (name, entry) in results.sorted(by: { $0.key < $1.key }) {
            output += "\n  \(name)\n"
            output += "  설명: \(entry.description)\n"
            output += "  저장소: \(entry.repo)\n"
            output += "  실행: swiftmcp run \(name)\n"
        }

        return makeText(output)
    }

    private func handleList() async -> JSONValue {
        let cacheManager = CacheManager()
        let packages = cacheManager.listInstalledPackages()

        if packages.isEmpty {
            return makeText("No packages installed.\n설치하려면: swiftmcp install <name>")
        }

        var output = "설치된 MCP 서버 (\(packages.count)개):\n"
        for pkg in packages {
            output += "\n  \(pkg.name)@\(pkg.version)\n"
            output += "  경로: \(pkg.binaryPath)\n"
        }

        return makeText(output)
    }

    private func handleInit(arguments: JSONValue?) async -> JSONValue {
        guard let name = arguments?["name"]?.stringValue else {
            return makeError("name 인수가 필요합니다")
        }

        let description = arguments?["description"]?.stringValue ?? "A Swift MCP server"
        let output = arguments?["output"]?.stringValue ?? FileManager.default.currentDirectoryPath

        let projectDir = "\(output)/\(name)"
        let fm = FileManager.default

        do {
            try fm.createDirectory(atPath: projectDir, withIntermediateDirectories: true)
            try fm.createDirectory(atPath: "\(projectDir)/Sources/\(name)", withIntermediateDirectories: true)
            try fm.createDirectory(atPath: "\(projectDir)/Sources/\(name)/Tools", withIntermediateDirectories: true)
            try fm.createDirectory(atPath: "\(projectDir)/.github/workflows", withIntermediateDirectories: true)
        } catch {
            return makeError("디렉토리 생성 실패: \(error.localizedDescription)")
        }

        let templates = ProjectTemplates(projectName: name, projectDescription: description)
        let files: [(String, String)] = [
            ("\(projectDir)/Package.swift", templates.packageSwift()),
            ("\(projectDir)/Sources/\(name)/main.swift", templates.mainSwift()),
            ("\(projectDir)/Sources/\(name)/MCPProtocol.swift", templates.mcpProtocolSwift()),
            ("\(projectDir)/Sources/\(name)/Tools/SampleTool.swift", templates.sampleToolSwift()),
            ("\(projectDir)/.github/workflows/release.yml", templates.githubActionsYml()),
            ("\(projectDir)/registry-entry.json", templates.registryEntryJson()),
            ("\(projectDir)/README.md", templates.readmeMd()),
            ("\(projectDir)/.gitignore", templates.gitignore()),
        ]

        for (path, content) in files {
            do {
                try content.write(toFile: path, atomically: true, encoding: .utf8)
            } catch {
                return makeError("파일 생성 실패 (\(path)): \(error.localizedDescription)")
            }
        }

        return makeText("프로젝트 '\(name)' 생성 완료!\n위치: \(projectDir)\n\n다음 단계:\n  cd \(name)\n  swift build")
    }

    private func handleCacheClean(arguments: JSONValue?) async -> JSONValue {
        let cacheManager = CacheManager()

        if let name = arguments?["name"]?.stringValue {
            do {
                try cacheManager.clean(name: name)
                return makeText("'\(name)' 캐시 삭제 완료.")
            } catch {
                return makeError("캐시 삭제 실패: \(error.localizedDescription)")
            }
        } else {
            do {
                try cacheManager.cleanAll()
                return makeText("전체 캐시 삭제 완료.")
            } catch {
                return makeError("캐시 삭제 실패: \(error.localizedDescription)")
            }
        }
    }

    private func handleRegistryUpdate() async -> JSONValue {
        let registryClient = RegistryClient()
        do {
            let registry = try await registryClient.forceFetch()
            return makeText("레지스트리 갱신 완료. 서버 \(registry.servers.count)개 등록됨.")
        } catch {
            return makeError("레지스트리 갱신 실패: \(error.localizedDescription)")
        }
    }

    // MARK: - 헬퍼

    private func makeTool(
        name: String,
        description: String,
        properties: [String: (String, String, Bool)]
    ) -> JSONValue {
        var propsObject: [String: JSONValue] = [:]
        var required: [JSONValue] = []

        for (propName, (type, desc, isRequired)) in properties {
            propsObject[propName] = .object([
                "type": .string(type),
                "description": .string(desc)
            ])
            if isRequired {
                required.append(.string(propName))
            }
        }

        var schema: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(propsObject)
        ]

        if !required.isEmpty {
            schema["required"] = .array(required)
        }

        return .object([
            "name": .string(name),
            "description": .string(description),
            "inputSchema": .object(schema)
        ])
    }

    private func makeText(_ text: String) -> JSONValue {
        return .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(text)
                ])
            ])
        ])
    }

    private func makeError(_ message: String) -> JSONValue {
        return .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string("오류: \(message)")
                ])
            ]),
            "isError": .bool(true)
        ])
    }
}
