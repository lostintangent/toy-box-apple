import Foundation

public func agentHandleFromName(_ name: String) -> String {
    let decomposed = name.decomposedStringWithCompatibilityMapping.unicodeScalars
        .filter { !CharacterSet.nonBaseCharacters.contains($0) }
    let lowered = String(String.UnicodeScalarView(decomposed)).lowercased()
    // Each run of anything but a-z and 0-9 becomes one hyphen, and none lead or trail.
    var normalized = String.UnicodeScalarView()
    var separates = false
    for scalar in lowered.unicodeScalars {
        guard ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) else {
            separates = !normalized.isEmpty
            continue
        }
        if separates { normalized.append("-") }
        separates = false
        normalized.append(scalar)
    }
    let truncated = String(String(normalized).prefix(48)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    if truncated == "everyone" { return "everyone-agent" }
    return truncated.isEmpty ? "teammate" : truncated
}

public func agentMatchesMentionQuery(_ agent: ChannelAgent, query: String) -> Bool {
    let normalized = query.lowercased()
    return normalized.isEmpty || [agentHandleFromName(agent.name), agent.name, agent.role ?? ""]
        .contains { $0.lowercased().contains(normalized) }
}
