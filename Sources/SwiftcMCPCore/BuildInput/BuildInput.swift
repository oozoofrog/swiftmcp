import Foundation

/// Tagged union of supported analysis inputs. Each tool decodes a single `input` field
/// from its arguments and dispatches through `BuildArgsResolver` to obtain a flat
/// `ResolvedBuildArgs`. Stage 3.A: `file` + `directory`. Stage 3.B: `directory` +
/// `search_paths`. Stage 3.C: `swiftPMPackage`. Later sub-stages add `xcodeProject`,
/// `xcodeWorkspace`.
public enum BuildInput: Sendable, Equatable {
    case file(path: String, target: String? = nil)
    case directory(
        path: String,
        moduleName: String? = nil,
        target: String? = nil,
        searchPaths: [String] = []
    )
    case swiftPMPackage(
        path: String,
        targetName: String? = nil,
        configuration: String? = nil,
        target: String? = nil
    )
    case xcodeProject(
        path: String,
        targetName: String,
        configuration: String? = nil,
        target: String? = nil
    )
    case xcodeWorkspace(
        path: String,
        scheme: String,
        configuration: String? = nil,
        target: String? = nil
    )

    /// Decodes a `BuildInput` from a `JSONValue` representing an object whose keys
    /// pick the case (`file` / `directory` / `package`). Throws
    /// `MCPError.invalidParams` when the shape is wrong (missing key, multiple keys,
    /// empty path, …).
    public static func decode(_ value: JSONValue?) throws -> BuildInput {
        guard case .object(let dict) = value else {
            throw MCPError.invalidParams("`input` must be an object")
        }

        let caseKeys = ["file", "directory", "package", "project", "workspace"]
        let present = caseKeys.filter { dict[$0] != nil }
        guard present.count == 1 else {
            if present.isEmpty {
                throw MCPError.invalidParams(
                    "`input` must contain exactly one of: \(caseKeys.joined(separator: ", "))"
                )
            }
            throw MCPError.invalidParams(
                "`input` must contain exactly one of: \(caseKeys.joined(separator: ", ")) (got: \(present.joined(separator: ", ")))"
            )
        }

        let target = dict["target"]?.asString

        switch present[0] {
        case "file":
            guard let path = dict["file"]?.asString, !path.isEmpty else {
                throw MCPError.invalidParams("`input.file` must be a non-empty string")
            }
            return .file(path: path, target: target)

        case "directory":
            guard let path = dict["directory"]?.asString, !path.isEmpty else {
                throw MCPError.invalidParams("`input.directory` must be a non-empty string")
            }
            let moduleName = dict["module_name"]?.asString
            let searchPaths: [String]
            if case .array(let arr) = dict["search_paths"] {
                searchPaths = arr.compactMap { $0.asString }
            } else {
                searchPaths = []
            }
            return .directory(
                path: path,
                moduleName: moduleName,
                target: target,
                searchPaths: searchPaths
            )

        case "package":
            guard let path = dict["package"]?.asString, !path.isEmpty else {
                throw MCPError.invalidParams("`input.package` must be a non-empty string")
            }
            let targetName = dict["target_name"]?.asString.flatMap { $0.isEmpty ? nil : $0 }
            let configuration = dict["configuration"]?.asString.flatMap { $0.isEmpty ? nil : $0 }
            return .swiftPMPackage(
                path: path,
                targetName: targetName,
                configuration: configuration,
                target: target
            )

        case "project":
            guard let path = dict["project"]?.asString, !path.isEmpty else {
                throw MCPError.invalidParams("`input.project` must be a non-empty string")
            }
            guard let targetName = dict["target_name"]?.asString, !targetName.isEmpty else {
                throw MCPError.invalidParams("`input.target_name` is required for `input.project`")
            }
            let configuration = dict["configuration"]?.asString.flatMap { $0.isEmpty ? nil : $0 }
            return .xcodeProject(
                path: path,
                targetName: targetName,
                configuration: configuration,
                target: target
            )

        case "workspace":
            guard let path = dict["workspace"]?.asString, !path.isEmpty else {
                throw MCPError.invalidParams("`input.workspace` must be a non-empty string")
            }
            guard let scheme = dict["scheme"]?.asString, !scheme.isEmpty else {
                throw MCPError.invalidParams("`input.scheme` is required for `input.workspace`")
            }
            let configuration = dict["configuration"]?.asString.flatMap { $0.isEmpty ? nil : $0 }
            return .xcodeWorkspace(
                path: path,
                scheme: scheme,
                configuration: configuration,
                target: target
            )

        default:
            throw MCPError.invalidParams("`input` has no recognized case key")
        }
    }

    /// Optional explicit `target` carried by every case. `nil` means "host default".
    public var target: String? {
        switch self {
        case .file(_, let target): return target
        case .directory(_, _, let target, _): return target
        case .swiftPMPackage(_, _, _, let target): return target
        case .xcodeProject(_, _, _, let target): return target
        case .xcodeWorkspace(_, _, _, let target): return target
        }
    }

    /// JSON schema fragment for the `input` field. Reused across every input-accepting
    /// tool so the schema stays in one place. Tracks the current set of supported cases.
    public static let jsonSchemaProperty: JSONValue = .object([
        "type": .string("object"),
        "description": .string(
            "Discriminated input. Provide exactly one of: `file`, `directory`, `package`, `project`, `workspace`. Optional `target` triple applies to any case."
        ),
        "properties": .object([
            "file": .object([
                "type": .string("string"),
                "description": .string("Path to a single Swift source file (absolute or relative to CWD).")
            ]),
            "directory": .object([
                "type": .string("string"),
                "description": .string("Path to a directory of Swift sources. All top-level *.swift files are passed to swiftc in one invocation.")
            ]),
            "package": .object([
                "type": .string("string"),
                "description": .string("Path to a SwiftPM package directory (containing Package.swift). The resolver runs `swift package describe --type json` and selects either the named target or the first library target.")
            ]),
            "project": .object([
                "type": .string("string"),
                "description": .string("Path to a `.xcodeproj` directory. Requires `target_name` to identify the target to analyze. The resolver runs `xcodebuild build` once into a scratch directory and reads the SwiftFileList that swiftc would consume.")
            ]),
            "workspace": .object([
                "type": .string("string"),
                "description": .string("Path to a `.xcworkspace` directory. Requires `scheme` to identify the build scheme to analyze. Same xcodebuild-based resolution as `project`, just driven through `-workspace`/`-scheme` instead of `-project`/`-target`.")
            ]),
            "scheme": .object([
                "type": .string("string"),
                "description": .string("Scheme name to use with `workspace` inputs. Auto-generated schemes from referenced projects are visible here.")
            ]),
            "module_name": .object([
                "type": .string("string"),
                "description": .string("Module name for the directory case. Defaults to the directory's basename.")
            ]),
            "search_paths": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string("Additional `-I` import search paths (used with the directory case).")
            ]),
            "target_name": .object([
                "type": .string("string"),
                "description": .string("SwiftPM target to analyze. Required when the package has multiple library targets; defaults to the first library target otherwise.")
            ]),
            "configuration": .object([
                "type": .string("string"),
                "description": .string("Build configuration for SwiftPM dependency pre-builds: `debug` (default) or `release`.")
            ]),
            "target": .object([
                "type": .string("string"),
                "description": .string("Optional target triple, e.g. 'arm64-apple-macos14'.")
            ])
        ])
    ])
}
