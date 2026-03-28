// InitCommand.swift
// `mcpswx init` 인터랙티브 TUI 프로젝트 생성기
// MCP 서버 스켈레톤 프로젝트를 생성한다.

import ArgumentParser
import Foundation

/// MCP 서버 스켈레톤 프로젝트를 생성하는 커맨드
struct InitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "새 MCP 서버 Swift 프로젝트를 생성합니다.",
        usage: "mcpswx init [--name <name>] [--non-interactive]"
    )

    @Option(name: .long, help: "프로젝트 이름")
    var name: String?

    @Option(name: .long, help: "프로젝트 설명")
    var description: String?

    @Flag(name: .long, help: "비대화형 모드 (기본값 사용, stdin 입력 없음)")
    var nonInteractive: Bool = false

    @Option(name: .long, help: "출력 디렉토리 (기본: 현재 디렉토리)")
    var output: String?

    mutating func run() async throws {
        let stderr = StderrWriter()
        let isTTY = isatty(STDIN_FILENO) != 0

        // 프로젝트 이름 결정
        let projectName: String
        if let providedName = name {
            projectName = providedName
        } else if nonInteractive || !isTTY {
            stderr.writeError("비대화형 모드에서는 --name이 필수입니다.")
            throw ExitCode.failure
        } else {
            // 인터랙티브 모드
            let menu = InteractiveMenu()
            projectName = menu.prompt("프로젝트 이름을 입력하세요:", defaultValue: "my-mcp-server")
        }

        // 프로젝트 설명 결정
        let projectDescription: String
        if let providedDesc = description {
            projectDescription = providedDesc
        } else if nonInteractive || !isTTY {
            projectDescription = "A Swift MCP server"
        } else {
            let menu = InteractiveMenu()
            projectDescription = menu.prompt(
                "프로젝트 설명을 입력하세요:",
                defaultValue: "A Swift MCP server"
            )
        }

        // 출력 디렉토리 결정
        let outputDir: String
        if let providedOutput = output {
            outputDir = providedOutput
        } else {
            outputDir = FileManager.default.currentDirectoryPath
        }

        let projectDir = "\(outputDir)/\(projectName)"

        stderr.write("")
        stderr.write("프로젝트 생성 중: \(projectName)")
        stderr.write("위치: \(projectDir)")
        stderr.write("")

        // 디렉토리 생성
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: projectDir, withIntermediateDirectories: true)
            try fm.createDirectory(atPath: "\(projectDir)/Sources/\(projectName)", withIntermediateDirectories: true)
            try fm.createDirectory(atPath: "\(projectDir)/Sources/\(projectName)/Tools", withIntermediateDirectories: true)
            try fm.createDirectory(atPath: "\(projectDir)/.github/workflows", withIntermediateDirectories: true)
        } catch {
            stderr.writeError("디렉토리 생성 실패: \(error)")
            throw ExitCode.failure
        }

        // 파일 생성
        let templates = ProjectTemplates(projectName: projectName, projectDescription: projectDescription)

        let filesToCreate: [(path: String, content: String)] = [
            ("\(projectDir)/Package.swift", templates.packageSwift()),
            ("\(projectDir)/Sources/\(projectName)/main.swift", templates.mainSwift()),
            ("\(projectDir)/Sources/\(projectName)/MCPProtocol.swift", templates.mcpProtocolSwift()),
            ("\(projectDir)/Sources/\(projectName)/Tools/SampleTool.swift", templates.sampleToolSwift()),
            ("\(projectDir)/.github/workflows/release.yml", templates.githubActionsYml()),
            ("\(projectDir)/registry-entry.json", templates.registryEntryJson()),
            ("\(projectDir)/README.md", templates.readmeMd()),
            ("\(projectDir)/.gitignore", templates.gitignore()),
        ]

        for (path, content) in filesToCreate {
            do {
                try content.write(toFile: path, atomically: true, encoding: .utf8)
                stderr.write("  생성됨: \(path.replacingOccurrences(of: projectDir + "/", with: ""))")
            } catch {
                stderr.writeError("파일 생성 실패 (\(path)): \(error)")
                throw ExitCode.failure
            }
        }

        stderr.write("")
        stderr.write("프로젝트 생성 완료!")
        stderr.write("")
        stderr.write("다음 단계:")
        stderr.write("  cd \(projectName)")
        stderr.write("  swift build")
        stderr.write("  .build/debug/\(projectName)")
    }
}
