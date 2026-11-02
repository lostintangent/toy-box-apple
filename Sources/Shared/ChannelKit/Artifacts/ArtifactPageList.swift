import Foundation

public struct ArtifactPageList: Equatable, Sendable {
    public private(set) var artifacts: [ChannelArtifact]
    public private(set) var selectedID: String

    public init(artifacts: [ChannelArtifact], opening artifact: ChannelArtifact) {
        self.artifacts = artifacts.newestFirst
        if !self.artifacts.contains(where: { $0.id == artifact.id }) { self.artifacts.insert(artifact, at: 0) }
        selectedID = artifact.id
    }

    public var index: Int? { artifacts.firstIndex { $0.id == selectedID } }
    public var selected: ChannelArtifact? { index.map { artifacts[$0] } }
    public var canShowPrevious: Bool { index.map { $0 > 0 } ?? false }
    public var canShowNext: Bool { index.map { $0 + 1 < artifacts.count } ?? false }

    @discardableResult
    public mutating func select(_ id: String) -> Bool {
        guard artifacts.contains(where: { $0.id == id }) else { return false }
        selectedID = id
        return true
    }

    @discardableResult
    public mutating func move(by offset: Int) -> Bool {
        guard let index, artifacts.indices.contains(index + offset) else { return false }
        selectedID = artifacts[index + offset].id
        return true
    }

    public mutating func update(_ artifacts: [ChannelArtifact]) {
        self.artifacts = artifacts.newestFirst
    }
}
