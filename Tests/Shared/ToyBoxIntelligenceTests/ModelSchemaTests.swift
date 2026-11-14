import Foundation
import FoundationModels
import Testing
@testable import ToyBoxIntelligence

struct ModelSchemaTests {
    @Test(arguments: [false, true])
    func generatedChangesDecodeDirectlyIntoTheDraft(needsYou: Bool) throws {
        let waiting = needsYou ? #""needsYou": "Lead asked you to approve the design.","# : ""
        let content = try GeneratedContent(json: """
            {\(waiting)"changes": [
              {"sources": [12, 15], "summary": "Ada finished the design."},
              {"sources": [19], "summary": "Moss shipped the client."}
            ]}
            """)
        #expect(try CatchUpSchema.draft(content) == CatchUpDraft(
            needsYou: needsYou ? "Lead asked you to approve the design." : nil,
            changes: [.init(summary: "Ada finished the design.", sources: [12, 15]),
                      .init(summary: "Moss shipped the client.", sources: [19])]))
    }

    @Test(arguments: [
        #"{"changes":[]}"#,
        #"{"changes":[],"needsYou":null}"#,
        #"{"changes":[],"needsYou":42}"#,
    ])
    func emptyChangesDecodeWithoutAValidWaitingRequest(json: String) throws {
        #expect(try CatchUpSchema.draft(GeneratedContent(json: json))
                == CatchUpDraft(needsYou: nil, changes: []))
    }

    @Test(arguments: [
        #"{}"#,
        #"{"changes":"not an array"}"#,
        #"{"changes":[{"sources":[12]}]}"#,
        #"{"changes":[{"summary":"Ada finished the design."}]}"#,
        #"{"changes":[{"sources":["twelve"],"summary":"Ada finished the design."}]}"#,
    ])
    func malformedChangesAreRejected(json: String) throws {
        let content = try GeneratedContent(json: json)
        #expect(throws: (any Error).self) { try CatchUpSchema.draft(content) }
    }
}
