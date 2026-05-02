import Foundation

/// Findings produced by `swift-api-digester -diagnose-sdk`. The tool emits a
/// flat text report with twelve labeled sections; this struct mirrors them as
/// individual string arrays so callers can scan the categories they care about
/// without re-parsing the raw text.
public struct ApiDigesterFindings: Sendable, Codable, Equatable {
    public var removedDecls: [String] = []
    public var movedDecls: [String] = []
    public var renamedDecls: [String] = []
    public var typeChanges: [String] = []
    public var declAttributeChanges: [String] = []
    public var fixedLayoutTypeChanges: [String] = []
    public var protocolConformanceChanges: [String] = []
    public var protocolRequirementChanges: [String] = []
    public var classInheritanceChanges: [String] = []
    public var genericSignatureChanges: [String] = []
    public var rawRepresentableChanges: [String] = []
    public var others: [String] = []

    public var totalFindings: Int {
        removedDecls.count
            + movedDecls.count
            + renamedDecls.count
            + typeChanges.count
            + declAttributeChanges.count
            + fixedLayoutTypeChanges.count
            + protocolConformanceChanges.count
            + protocolRequirementChanges.count
            + classInheritanceChanges.count
            + genericSignatureChanges.count
            + rawRepresentableChanges.count
            + others.count
    }

    /// Per-section finding counts keyed by the section title swift-api-digester
    /// emits. Useful for at-a-glance summaries in the tool response.
    public var byCategory: [String: Int] {
        [
            "Removed Decls": removedDecls.count,
            "Moved Decls": movedDecls.count,
            "Renamed Decls": renamedDecls.count,
            "Type Changes": typeChanges.count,
            "Decl Attribute changes": declAttributeChanges.count,
            "Fixed-layout Type Changes": fixedLayoutTypeChanges.count,
            "Protocol Conformance Change": protocolConformanceChanges.count,
            "Protocol Requirement Change": protocolRequirementChanges.count,
            "Class Inheritance Change": classInheritanceChanges.count,
            "Generic Signature Changes": genericSignatureChanges.count,
            "RawRepresentable Changes": rawRepresentableChanges.count,
            "Others": others.count
        ]
    }
}

/// Parses the text output of `swift-api-digester -diagnose-sdk` into
/// `ApiDigesterFindings`. The text format is documented (loosely) by the tool
/// itself: a fixed set of 12 sections, each headed by `/* <Title> */`, with
/// finding lines in between.
public enum ApiDigesterParser {
    /// Internal section identifier — driven by the swift-api-digester header
    /// title. Unknown titles map to `.others` so a future toolchain renaming
    /// a section doesn't silently drop findings.
    private enum Section {
        case removed, moved, renamed, type, declAttribute, fixedLayout
        case protocolConformance, protocolRequirement, classInheritance
        case genericSignature, rawRepresentable, others

        init(headerTitle: String) {
            switch headerTitle {
            case "Removed Decls": self = .removed
            case "Moved Decls": self = .moved
            case "Renamed Decls": self = .renamed
            case "Type Changes": self = .type
            case "Decl Attribute changes": self = .declAttribute
            case "Fixed-layout Type Changes": self = .fixedLayout
            case "Protocol Conformance Change": self = .protocolConformance
            case "Protocol Requirement Change": self = .protocolRequirement
            case "Class Inheritance Change": self = .classInheritance
            case "Generic Signature Changes": self = .genericSignature
            case "RawRepresentable Changes": self = .rawRepresentable
            default: self = .others
            }
        }
    }

    public static func parse(_ text: String) -> ApiDigesterFindings {
        var findings = ApiDigesterFindings()
        var currentSection: Section? = nil

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if let title = parseSectionHeader(line) {
                currentSection = Section(headerTitle: title)
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let section = currentSection else { continue }
            append(trimmed, to: section, into: &findings)
        }
        return findings
    }

    private static func append(
        _ finding: String,
        to section: Section,
        into findings: inout ApiDigesterFindings
    ) {
        switch section {
        case .removed: findings.removedDecls.append(finding)
        case .moved: findings.movedDecls.append(finding)
        case .renamed: findings.renamedDecls.append(finding)
        case .type: findings.typeChanges.append(finding)
        case .declAttribute: findings.declAttributeChanges.append(finding)
        case .fixedLayout: findings.fixedLayoutTypeChanges.append(finding)
        case .protocolConformance: findings.protocolConformanceChanges.append(finding)
        case .protocolRequirement: findings.protocolRequirementChanges.append(finding)
        case .classInheritance: findings.classInheritanceChanges.append(finding)
        case .genericSignature: findings.genericSignatureChanges.append(finding)
        case .rawRepresentable: findings.rawRepresentableChanges.append(finding)
        case .others: findings.others.append(finding)
        }
    }

    /// Returns the title of a `/* … */` section header line, or nil when the
    /// line isn't a header. Defensive against inner whitespace variations.
    private static func parseSectionHeader(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/*"), trimmed.hasSuffix("*/") else { return nil }
        let inner = trimmed
            .dropFirst(2)   // drop "/*"
            .dropLast(2)    // drop "*/"
        return inner.trimmingCharacters(in: .whitespaces)
    }
}
