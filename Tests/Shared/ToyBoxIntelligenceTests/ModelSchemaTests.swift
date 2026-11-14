import Foundation
import FoundationModels
import Testing
@testable import ChannelIntelligence

struct ModelSchemaTests {
    @Test(arguments: [false, true])
    func catchUpSchemaMatchesTheOriginalModelInput(needsYou: Bool) throws {
        let change = """
            {
              "additionalProperties": false,
              "description": "One meaningful change",
              "properties": {
                "sources": {
                  "description": "Numbers of the unread messages this change comes from",
                  "items": {"type": "integer"}, "maxItems": 4, "minItems": 1, "type": "array"
                },
                "summary": {
                  "description": "One past-tense sentence of at most 16 words naming who did what. Only facts from the cited messages.",
                  "type": "string"
                }
              },
              "required": ["sources", "summary"], "title": "CatchUpChangeContent",
              "type": "object", "x-order": ["sources", "summary"]
            }
            """
        let waiting = """
            "needsYou": {
              "description": "One sentence of at most 20 words that opens with the waiting message's speaker and says exactly what they asked you to do, answer or decide. The ask often comes last, after an update. Don't add how to reply. Use only the waiting message.",
              "type": "string"
            },
            """
        let expected = """
            {
              "$defs": {"CatchUpChangeContent": \(change)},
              "additionalProperties": false,
              "description": "What changed since the reader's last visit",
              "properties": {
                \(needsYou ? waiting : "")
                "changes": {
                  "description": "At most three meaningful changes from the unread messages, most important first. Empty when nothing meaningful happened.",
                  "items": {"$ref": "#/$defs/CatchUpChangeContent"}, "maxItems": 3, "type": "array"
                }
              },
              "required": \(needsYou ? #"["needsYou", "changes"]"# : #"["changes"]"#),
              "title": "\(needsYou ? "CatchUpWithRequestContent" : "CatchUpContent")",
              "type": "object",
              "x-order": \(needsYou ? #"["needsYou", "changes"]"# : #"["changes"]"#)
            }
            """
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let baseline = try JSONDecoder().decode(GenerationSchema.self, from: Data(expected.utf8))
        #expect(try encoder.encode(CatchUpSchema.schema(needsYou: needsYou)) == encoder.encode(baseline))
    }

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
