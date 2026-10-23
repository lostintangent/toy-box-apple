import Foundation
import FoundationModels
import ImageIO
import Vision

/// Image descriptions for VoiceOver: one or two plain sentences, checked against on-device text
/// recognition so they never quote text, numbers or names the image doesn't show.
enum AltTextPrompt {
    /// Bump when instructions, schema or validation change, so cached descriptions are redone.
    static let version = 2
    static let maximumCharacters = 160
    static let maximumRecognizedCharacters = 500
    static let minimumSide = 24
    static let minimumArea = 4_096

    static let instructions = """
    You describe an image from a team chat for someone using VoiceOver.
    Say what kind of image it is and what it clearly shows, in one or two plain sentences of at most \
    25 words in total. Don't start with "Image of" or "Picture of".
    Describe only what is visible. Never guess what people are doing or feeling, what is happening \
    outside the image, or why.
    Never guess names, numbers or text. Mention text only if it appears in the recognized text you \
    are given, and copy it exactly.
    If the image is blank, unreadable or too small to make out, choose the kind "unclear".
    """

    static let kinds = ["photo", "screenshot", "diagram", "chart", "illustration", "document", "unclear"]

    static func prompt(recognizedText: String) -> String {
        let text = recognizedText.isEmpty ? "(none)" : recognizedText
        return "Text recognized in the image, possibly partial:\n\(text)\n\nDescribe this image."
    }

    /// Images too small to describe, like spacers and tracking pixels, are skipped without the model.
    static func isTooSmall(width: Int, height: Int) -> Bool {
        min(width, height) < minimumSide || width * height < minimumArea
    }

    /// The description as VoiceOver should read it, or nil when it's unclear, too long, or mentions
    /// text, numbers or names that text recognition didn't find.
    static func validated(kind: String, description: String, recognizedText: String) -> AltText? {
        guard kind.lowercased() != "unclear" else { return nil }
        var text = description.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacing(/\s+/, with: " ")
        text = text.replacing(/^(?i:(?:an?\s+|the\s+)?(?:image|picture|photo)\s+of\s+|this\s+(?:image|picture)\s+shows\s+|the\s+(?:image|picture)\s+shows\s+)/, with: "")
        guard let first = text.first, !text.lowercased().hasPrefix("unclear") else { return nil }
        text = first.uppercased() + text.dropFirst()

        let sentences = Grounding.sentences(text)
        if sentences.count > 2 { text = sentences.prefix(2).joined(separator: " ") }
        if text.count > maximumCharacters, let lead = sentences.first, lead.count <= maximumCharacters {
            text = String(lead)
        }
        guard text.count <= maximumCharacters, text.count >= 8 else { return nil }
        if !".!?".contains(text.last!) { text += "." }

        guard Grounding.literalsSupported(text, corpus: recognizedText, names: commonNames) else { return nil }
        guard !guessesActivity(text, recognizedText: recognizedText) else { return nil }
        return AltText(text: text)
    }

    static let commonNames: Set<String> = ["mac", "macos", "iphone", "ipad"]

    /// Whether a description reads an activity or a mood into the image, like "team members in a
    /// meeting", that its own text doesn't state. A listener can't check it, so it doesn't ship.
    static func guessesActivity(_ text: String, recognizedText: String) -> Bool {
        let recognized = Grounding.Vocabulary(recognizedText)
        return Grounding.words(in: text).contains { inferredWords.contains($0) && !recognized.contains($0) }
    }

    static let inferredWords: Set<String> = [
        "meeting", "meetings", "discussing", "discussion", "discussions", "collaborating", "collaboration",
        "brainstorming", "celebrating", "celebration", "debating", "arguing", "presenting", "presentation",
        "working", "busy", "happy", "sad", "excited", "frustrated", "relaxing", "enjoying", "productive",
    ]
}

struct AltTextOutcome: Sendable {
    var text: AltText?
    var cacheable: Bool
    var kind: String?
    var rawDescription: String?
    var recognizedText = ""
    var error: String?
    var duration: Duration = .zero
    /// How long Vision took to read the image's text, part of `duration`.
    var recognition: Duration = .zero
}

struct AltTextGeneration: Sendable {
    let model: SystemLanguageModel

    func run(_ url: URL) async -> AltTextOutcome {
        let start = ContinuousClock.now
        var outcome = await generate(url)
        outcome.duration = ContinuousClock.now - start
        return outcome
    }

    private func generate(_ url: URL) async -> AltTextOutcome {
        guard let size = Self.pixelSize(url) else {
            return AltTextOutcome(text: nil, cacheable: true, error: "Unreadable image")
        }
        guard !AltTextPrompt.isTooSmall(width: size.width, height: size.height) else {
            return AltTextOutcome(text: nil, cacheable: true, error: "Too small: \(size.width)×\(size.height)")
        }

        let reading = ContinuousClock.now
        let recognized = await Self.recognizedText(url)
        var outcome = AltTextOutcome(text: nil, cacheable: true, recognizedText: recognized)
        outcome.recognition = ContinuousClock.now - reading
        do {
            let session = LanguageModelSession(model: model, instructions: Instructions(AltTextPrompt.instructions))
            let prompt = AltTextPrompt.prompt(recognizedText: catchUpTruncated(recognized, limit: AltTextPrompt.maximumRecognizedCharacters))
            let response = try await session.respond(
                generating: AltTextContent.self,
                options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 120)
            ) {
                prompt
                Attachment(imageURL: url)
            }
            outcome.kind = response.content.kind
            outcome.rawDescription = response.content.description
            outcome.text = AltTextPrompt.validated(kind: response.content.kind,
                                                   description: response.content.description,
                                                   recognizedText: recognized)
        } catch {
            outcome.error = String(describing: error)
            outcome.cacheable = GenerationFailure(error) == .refused
        }
        return outcome
    }

    static func pixelSize(_ url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    /// Lines of text Vision finds in the image, most confident first, joined by newlines.
    static func recognizedText(_ url: URL) async -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        guard let observations = try? await request.perform(on: url) else { return "" }
        return observations
            .filter { $0.confidence >= 0.3 }
            .map(\.transcript)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n")
    }
}

struct AltTextContent: Generable {
    var kind: String
    var description: String

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: Self.self, description: "A short image description for VoiceOver", properties: [
            .init(name: "kind", description: "What kind of image this is", type: String.self,
                  guides: [.anyOf(AltTextPrompt.kinds)]),
            .init(name: "description", description: """
                One or two plain sentences, at most 25 words, saying only what the image visibly shows.
                """, type: String.self),
        ])
    }

    init(_ content: GeneratedContent) throws {
        kind = try content.value(String.self, forProperty: "kind")
        description = try content.value(String.self, forProperty: "description")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: ["kind": kind, "description": description])
    }
}
