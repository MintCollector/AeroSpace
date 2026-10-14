import Common

/// `[workspace-sections]`: workspaces are rows of side-by-side sections, left to right. Sections are containers of the
/// workspace's tree, so they switch with the workspace
struct WorkspaceSections: ConvenienceMutable, Equatable, Sendable {
    /// Left to right
    var sections: [WorkspaceSection] = []
    /// Where new windows go
    var defaultSection: String = ""
    /// The workspaces that have sections. nil: every workspace
    var workspaces: [String]? = nil

    func applies(to workspace: String) -> Bool { workspaces?.contains(workspace) ?? true }
    func index(of section: String) -> Int? { sections.firstIndex { $0.name == section } }
    var totalWidth: Int { sections.reduce(0) { $0 + $1.width } }
}

struct WorkspaceSection: ConvenienceMutable, Equatable, Sendable {
    var name: String = ""
    /// Relative to the other sections' widths
    var width: Int = 1
    /// Without windows, the section gives its width to the others. Otherwise it keeps an empty slot
    var collapse: Bool = true
}

private let workspaceSectionsParser: [String: any ParserProtocol<WorkspaceSections>] = [
    "sections": Parser(\.sections, parseSectionList),
    "default": Parser(\.defaultSection, parseString),
    "workspaces": Parser(\.workspaces, parseWorkspaceNames),
]

private let sectionParser: [String: any ParserProtocol<WorkspaceSection>] = [
    "name": Parser(\.name, parseString),
    "width": Parser(\.width, parsePositiveWidth),
    "collapse": Parser(\.collapse, parseBool),
]

func parseWorkspaceSections(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> WorkspaceSections? {
    let errorsBefore = c.errors.count
    let result = parseTable(raw, WorkspaceSections(), workspaceSectionsParser, backtrace, &c)
    if c.errors.count > errorsBefore { return nil }
    let names = result.sections.map(\.name)
    if names.count < 2 {
        c.errors.append(.init(backtrace + .key("sections"), "Expected at least two sections"))
    } else if let index = names.firstIndex(where: { $0.isEmpty || $0.contains(where: \.isWhitespace) }) {
        // A section's name is a command argument: move-node-to-section <name>
        c.errors.append(.init(backtrace + .key("sections") + .index(index) + .key("name"), "Expected a name without spaces"))
    } else if Set(names).count != names.count {
        c.errors.append(.init(backtrace + .key("sections"), "Expected each section to have its own name"))
    } else if !names.contains(result.defaultSection) {
        c.errors.append(.init(backtrace + .key("default"), "Expected the name of a section: \(names.joined(separator: ", "))"))
    } else {
        return result
    }
    return nil
}

private func parseSectionList(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> [WorkspaceSection] {
    guard let array = parseTomlArray(raw, backtrace).getOrNil(appendErrorTo: &c.errors) else { return [] }
    return array.enumerated().map { index, rawSection in
        parseTable(rawSection, WorkspaceSection(), sectionParser, backtrace + .index(index), &c)
    }
}

private func parsePositiveWidth(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<Int> {
    parseInt(raw, backtrace).filter(.init(backtrace, "Expected a positive width")) { $0 > 0 }
}

private func parseWorkspaceNames(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<[String]?> {
    parseArrayOfStrings(raw, backtrace).map { Optional($0) }
}
