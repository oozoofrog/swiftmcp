import Foundation

/// Tagged union of supported analysis inputs. Each tool decodes a single `input` field
/// from its arguments and dispatches through `BuildArgsResolver` to obtain a flat
/// `ResolvedBuildArgs`. Stage 3.A implements `file` + `directory`; later sub-stages add
/// `swiftPMPackage`, `xcodeProject`, `xcodeWorkspace`.
public enum BuildInput: Sendable, Equatable {
    case file(path: String, target: String? = nil)
    case directory(
        path: String,
        moduleName: String? = nil,
        target: String? = nil,
        searchPaths: [String] = []
    )

    /// Decodes a `BuildInput` from a `JSONValue` representing an object whose keys
    /// pick the case (`file` / `directory`). Throws `MCPError.invalidParams` when the
    /// shape is wrong (missing key, multiple keys, empty path, …).
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

        case "package", "project", "workspace":
            throw MCPError.invalidParams(
                "`input.\(present[0])` is not yet supported in this stage"
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
        }
    }

    /// JSON schema fragment for the `input` field. Reused across every file/directory-
    /// accepting tool so the schema stays in one place. Stage 3.A advertises only the
    /// `file` and `directory` cases; later sub-stages extend this.
    public static let jsonSchemaProperty: JSONValue = .object([
        "type": .string("object"),
        "description": .string(
            "Discriminated input. Provide exactly one of: `file`, `directory`. Optional `target` triple applies to any case."
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
            "module_name": .object([
                "type": .string("string"),
                "description": .string("Module name for the directory case. Defaults to the directory's basename.")
            ]),
            "search_paths": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string("Additional `-I` import search paths (used with the directory case).")
            ]),
            "target": .object([
                "type": .string("string"),
                "description": .string("Optional target triple, e.g. 'arm64-apple-macos14'.")
            ])
        ])
    ])
}
