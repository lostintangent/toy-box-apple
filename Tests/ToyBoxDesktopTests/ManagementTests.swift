import AppKit
@testable import ChannelClient
import ChannelKit
import Foundation
import SwiftUI
import Synchronization
import Testing
@testable import ToyBoxDesktop

@MainActor
@Suite("Management validation and presentation", .serialized)
struct ManagementTests {
    @Test func aCommittedDeletionFollowedBy500IsReadBackWithoutReplayingDelete() async throws {
        let fixture = try ManagementRecoveryFixture()
        defer { fixture.close() }
        let recovery = ManagementWriteRecovery()
        let catalog = ChannelCatalogStore(api: fixture.api)
        do {
            try await fixture.api.deleteChannel(id: "deleted-channel")
            Issue.record("The fixture must report an uncertain deletion.")
        } catch {
            #expect(recovery.record(error))
        }
        #expect(recovery.blocksWrites)
        recovery.clearError()
        #expect(recovery.error == ManagementRecoveryState.uncertaintyMessage)
        recovery.finishReview()
        #expect(recovery.blocksWrites)
        await recovery.check(catalog: catalog, channelId: "deleted-channel") { current in
            current.channelWasDeleted ? "The channel is absent." : "The channel is present."
        }
        #expect(recovery.result?.channelWasDeleted == true)
        #expect(recovery.state == .reconciled("The channel is absent."))
        #expect(recovery.blocksWrites)
        #expect(fixture.requests == ["DELETE /api/v1/channels/deleted-channel", "GET /api/v1/channels"])
    }

    @Test func failedReconciliationKeepsWritesBlockedUntilAnExplicitReview() async throws {
        let fixture = try ManagementRecoveryFixture(catalogStatus: 500)
        defer { fixture.close() }
        let recovery = ManagementWriteRecovery()
        let catalog = ChannelCatalogStore(api: fixture.api)
        recovery.record(ChannelAPIError.http(status: 500, message: "Management failed."))
        await recovery.check(catalog: catalog, channelId: nil) { _ in "Catalog refreshed." }
        guard case .checkFailed(let message) = recovery.state else {
            Issue.record("A failed read must not be presented as reconciliation.")
            return
        }
        #expect(message.contains("HTTP 500"))
        #expect(recovery.blocksWrites)
        #expect(recovery.result == nil)
        recovery.finishReview()
        #expect(recovery.blocksWrites)
        fixture.allowCatalogRead()
        await recovery.check(catalog: catalog, channelId: nil) { _ in "Catalog refreshed." }
        #expect(recovery.blocksWrites)
        #expect(recovery.state == .reconciled("Catalog refreshed."))
        recovery.finishReview()
        #expect(!recovery.blocksWrites)
        #expect(recovery.error == nil)
        #expect(fixture.requests == ["GET /api/v1/channels", "GET /api/v1/channels"])
    }

    @Test func domainRejectionsKeepTheirUserFacingMessageWithoutBlockingEditing() {
        let recovery = ManagementWriteRecovery()
        let error = ChannelAPIError.http(status: 422, message: "The mention is already in use.")
        #expect(!recovery.record(error))
        #expect(!recovery.blocksWrites)
        #expect(recovery.error == error.localizedDescription)
        #expect(recovery.result == nil)
    }

    @Test func unexpectedManagementFailuresRequireAReadBeforeAnotherWrite() {
        #expect(ManagementRecoveryState.isRequired(
            after: ChannelAPIError.http(status: 500, message: "Management failed.")))
        #expect(ManagementRecoveryState.isRequired(
            after: ChannelAPIError.http(status: 503, message: "Service unavailable.")))
        #expect(!ManagementRecoveryState.isRequired(
            after: ChannelAPIError.http(status: 422, message: "This provider cannot change.")))
        #expect(!ManagementRecoveryState.isRequired(
            after: ChannelAPIError.http(status: 404, message: "Member not found.")))
        #expect(!ManagementRecoveryState.isRequired(after: ChannelAPIError.invalidMessage("Invalid name.")))
    }

    private struct ManagementRecoveryFixture {
        let api: ChannelAPI
        private let session: URLSession
        private let host: String

        init(catalogStatus: Int = 200, memberStatus: Int = 500) throws {
            let fixtureHost = "management-\(UUID().uuidString.lowercased()).invalid"
            host = fixtureHost
            ManagementRecoveryProtocol.fixtures.withLock {
                $0[fixtureHost] = .init(catalogStatus: catalogStatus, memberStatus: memberStatus)
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ManagementRecoveryProtocol.self]
            session = URLSession(configuration: configuration)
            api = try ChannelAPI(serverURL: "https://\(fixtureHost)", session: session)
        }

        var requests: [String] {
            ManagementRecoveryProtocol.fixtures.withLock { $0[host]?.requests ?? [] }
        }

        func allowCatalogRead() {
            ManagementRecoveryProtocol.fixtures.withLock { $0[host]?.catalogStatus = 200 }
        }

        func close() {
            session.invalidateAndCancel()
            ManagementRecoveryProtocol.fixtures.withLock { _ = $0.removeValue(forKey: host) }
        }
    }

    private final class ManagementRecoveryProtocol: URLProtocol, @unchecked Sendable {
        struct Fixture: Sendable {
            var catalogStatus: Int
            let memberStatus: Int
            var requests: [String] = []
        }
        static let fixtures = Mutex<[String: Fixture]>([:])

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url, let host = url.host else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            let status = Self.fixtures.withLock { fixtures -> Int? in
                guard var fixture = fixtures[host] else { return nil }
                fixture.requests.append("\(request.httpMethod ?? "GET") \(url.path)")
                fixtures[host] = fixture
                if request.httpMethod == "GET" { return fixture.catalogStatus }
                return request.httpMethod == "POST" ? fixture.memberStatus : 500
            }
            guard let status, let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            let body: String
            switch status {
            case 200:
                body = ##"{"version":1,"channels":[],"members":[],"working":[],"lead":{"name":"Lead","role":"Coordinates the channel.","avatar":{"mark":"M12 3L15 9L21 10L16.5 14.5L18 21L12 18L6 21L7.5 14.5L3 10L9 9Z","color":"#1E3A8A","ink":"#FACC15"}}}"##
            case 201:
                body = #"{"version":1,"member":{"id":"moss","name":"Moss"}}"#
            default:
                body = #"{"error":"Management failed."}"#
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    @Test func clearingMemberModelDoesNotRequireCatalogChoicesOrACompatibleDefault() throws {
        let api = try ChannelAPI(serverURL: "http://localhost:3210")
        var model: ModelConfiguration? = .init(provider: "copilot", name: "existing-model")
        let fields = ModelSelectionFields(
            model: Binding(get: { model }, set: { model = $0 }),
            api: api, provider: "copilot", allowsInheritance: true,
            memberScope: (channelId: "channel", agentId: "member"))
        #expect(fields.isSelectionEnabled)
        #expect(fields.selection.wrappedValue == "copilot/existing-model")
        fields.selection.wrappedValue = ""
        #expect(model == nil)
        #expect(fields.selection.wrappedValue == "")

        let leadFields = ModelSelectionFields(model: .constant(nil), api: api,
                                              provider: nil, allowsInheritance: false)
        #expect(!leadFields.isSelectionEnabled)
    }

    @Test func missingModelEndpointHasAnHonestCapabilityMessage() {
        let missing = ChannelAPIError.http(status: 404, message: "Channel not found.")
        #expect(ModelSelectionFields<EmptyView>.catalogErrorMessage(missing, memberScoped: false)
                == "Models aren't available on this server.")
        #expect(ModelSelectionFields<EmptyView>.catalogErrorMessage(missing, memberScoped: true)
                .contains("Channel not found."))
        let disconnected = ChannelAPIError.disconnected
        #expect(ModelSelectionFields<EmptyView>.catalogErrorMessage(disconnected, memberScoped: false)
                .contains(disconnected.localizedDescription))
    }

    @Test func taskDiffTextMeetsSmallTextContrastInBothAppearances() throws {
        for scheme in [ColorScheme.light, .dark] {
            let colors = ChannelTaskColors.changes(in: scheme)
            let backgrounds: [Double] = scheme == .light
                ? [1, 246.0 / 255.0] : [30.0 / 255.0, 38.0 / 255.0, 51.0 / 255.0]
            for color in [colors.added, colors.removed] {
                let rgb = try #require(NSColor(color).usingColorSpace(.sRGB))
                let foreground = 0.2126 * linear(rgb.redComponent)
                    + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
                for background in backgrounds {
                    let surface = linear(background)
                    let ratio = (max(foreground, surface) + 0.05) / (min(foreground, surface) + 0.05)
                    #expect(ratio >= 4.5)
                }
            }
        }
    }

    @Test func purposeExpansionAppearsOnlyBeyondFourLines() {
        let short = "Build a welcoming workshop where the team's work is clear at a glance."
        #expect(!OverviewPurpose.requiresExpansion(short, width: 288, fontSize: 13))
        #expect(!OverviewPurpose.requiresExpansion("First\nSecond\nThird\nFourth", width: 288, fontSize: 13))
        #expect(OverviewPurpose.requiresExpansion("First\nSecond\nThird\nFourth\nFifth", width: 288, fontSize: 13))
        #expect(OverviewPurpose.requiresExpansion("First\nSecond\nThird\nFourth\n", width: 288, fontSize: 13))
        #expect(OverviewPurpose.requiresExpansion(String(repeating: short + " ", count: 4),
                                                 width: 288, fontSize: 13))
        #expect(OverviewPurpose.requiresExpansion(short, width: 80, fontSize: 13))
        #expect(OverviewPurpose.requiresExpansion(short, width: 288, fontSize: 40))
        #expect(!OverviewPurpose.requiresExpansion(short, width: 0, fontSize: 13))
    }

    @Test(arguments: [248, 296, 368])
    func truncatedPurposeEndsAtAWordAndLeavesRoomForMore(_ width: Int) throws {
        let purpose = String(repeating: "Build a beautifully designed native Mac client for channels. ", count: 6)
        #expect(OverviewPurpose.truncated("A short purpose.", width: CGFloat(width), fontSize: 13) == nil)
        let prefix = try #require(OverviewPurpose.truncated(purpose, width: CGFloat(width), fontSize: 13))
        #expect(!prefix.isEmpty)
        #expect(purpose.hasPrefix(prefix))
        #expect(prefix.last.map { !$0.isWhitespace } == true)
        let next = purpose[purpose.index(purpose.startIndex, offsetBy: prefix.count)]
        #expect(next.isWhitespace)
        #expect(!OverviewPurpose.requiresExpansion(prefix + "\u{2026} More", width: CGFloat(width), fontSize: 13))
        let longer = purpose.prefix(prefix.count + 12)
        #expect(OverviewPurpose.requiresExpansion(longer + "\u{2026} More", width: CGFloat(width), fontSize: 13))
    }

    @Test func emptyAndOversizedNamesAreRejected() {
        #expect(MemberValidation.nameError(" \n ", agents: []) == "Enter an agent name.")
        #expect(MemberValidation.nameError(String(repeating: "a", count: 80), agents: []) == nil)
        #expect(MemberValidation.nameError(String(repeating: "a", count: 81), agents: []) != nil)
        #expect(MemberValidation.nameError(String(repeating: "\u{1F680}", count: 40), agents: []) == nil)
        #expect(MemberValidation.nameError(String(repeating: "\u{1F680}", count: 41), agents: []) != nil)
    }

    @Test func duplicateMentionsUseTheCanonicalHandle() {
        let agents = [ChannelAgent.lead(id: "channel"), ChannelAgent(id: "member", name: "Caf\u{00E9} Critic")]
        #expect(MemberValidation.nameError(" lead ", agents: agents) != nil)
        #expect(MemberValidation.nameError("CAFE-critic", agents: agents) != nil)
        #expect(MemberValidation.nameError("Caf\u{00E9} Critic", agents: agents, excludingID: "member") == nil)
        #expect(MemberValidation.nameError("Another critic", agents: agents) == nil)
    }

    @Test func finishingMemberCreationDismissesOnlyTheMatchingSheet() {
        let presenter = ManagementPresenter()
        presenter.present(.addMember(channelId: "channel", name: "Moss"))
        presenter.finishAddingMember(channelId: "channel")
        #expect(presenter.flow == nil)

        presenter.present(.editChannel(channelId: "another"))
        presenter.finishAddingMember(channelId: "channel")
        #expect(presenter.flow == .editChannel(channelId: "another"))

        presenter.present(.addMember(channelId: "another", name: "Finch"))
        presenter.finishAddingMember(channelId: "channel")
        #expect(presenter.flow == .addMember(channelId: "another", name: "Finch"))
    }

    @Test func inlineCreationReturnsTheMemberWithoutDismissingAnUnrelatedSheet() async throws {
        let fixture = try ManagementRecoveryFixture(memberStatus: 201)
        defer { fixture.close() }
        let store = ChannelStore(id: "channel", api: fixture.api, sendJournal: nil)
        let channel = Channel(id: store.id, name: "Workshop", model: .init(provider: "test", name: "test"),
                              updatedAt: "2026-10-25T12:00:00Z")
        _ = try store.apply(.init(type: "snapshot", state: .init(
            revision: 1, channel: channel, lead: .lead(id: store.id))))
        let presenter = ManagementPresenter()
        presenter.present(.addMember(channelId: "channel", name: "Finch"))
        let member = try await presenter.createMentionMember(name: "Moss", store: store)
        #expect(member == ChannelMember(id: "moss", name: "Moss"))
        #expect(presenter.flow == .addMember(channelId: "channel", name: "Finch"))
        #expect(fixture.requests == ["POST /api/v1/channels/channel/members"])
    }

    @Test func inlineCreationRefusesAnUnconnectedStore() async throws {
        let api = try ChannelAPI(serverURL: "http://localhost:3210")
        let store = ChannelStore(id: "not-connected", api: api)
        let presenter = ManagementPresenter()
        presenter.present(.addMember(channelId: "not-connected", name: "Finch"))
        do {
            _ = try await presenter.createMentionMember(name: "Moss", store: store)
            Issue.record("Disconnected inline creation must fail before making a request.")
        } catch let error as ChannelAPIError {
            #expect(error == .disconnected)
        }
        #expect(presenter.flow == .addMember(channelId: "not-connected", name: "Finch"))
    }

    @Test(arguments: [280, 328])
    func siblingTasksShareOneStatusColumnOnTheContentRail(_ width: Int) throws {
        let siblings = try TaskListRender([
            .init(id: "leaf", title: "Standalone task", status: "done"),
            .init(id: "parent", title: "Parent task", status: "blocked", children: [
                .init(id: "child", title: "Child task")
            ]),
            .init(id: "trailing-leaf", title: "Another standalone task")
        ], width: width)
        let rail = TaskListRender.padding
        let leaf = try #require(siblings.minX(where: TaskListRender.isGreen))
        let parent = try #require(siblings.minX(where: TaskListRender.isRed))
        #expect(abs(leaf - rail) < 1.5)
        #expect(abs(parent - leaf) < 1)
        let ink = try #require(siblings.minX(where: TaskListRender.isInk))
        #expect(ink >= rail - 1, "Nothing may hang left of the status column, found ink at \(ink)")

        let depth = try TaskListRender([
            .init(id: "parent", title: "Parent task", children: [
                .init(id: "nested-parent", title: "Nested parent", status: "blocked", children: [
                    .init(id: "grandchild", title: "Nested leaf", status: "done")
                ])
            ])
        ], width: width)
        let nested = try #require(depth.minX(where: TaskListRender.isRed))
        let grandchild = try #require(depth.minX(where: TaskListRender.isGreen))
        #expect(abs(nested - rail - OverviewTaskList.depthIndent) < 1.5)
        #expect(abs(grandchild - nested - OverviewTaskList.depthIndent) < 1)
    }

    @Test func taskStatusDeterminesInitialDisclosureAndSubtaskProgress() {
        #expect(!OverviewTaskRow.isExpandedByDefault(status: "done"))
        for status in ["pending", "in_progress", "blocked"] {
            #expect(OverviewTaskRow.isExpandedByDefault(status: status))
        }
        for status in ["in_progress", "blocked"] {
            #expect(OverviewTaskRow.showsProgress(status: status, hasChildren: true))
        }
        for status in ["pending", "done"] {
            #expect(!OverviewTaskRow.showsProgress(status: status, hasChildren: true))
        }
        #expect(!OverviewTaskRow.showsProgress(status: "in_progress", hasChildren: false))
    }

    @Test func taskTimingUsesHoursExpandedSpeechAndOnlySchedulesVisibleRows() {
        for (minutes, text, spoken) in [
            (0, "0m", "0 minutes"), (1, "1m", "1 minute"), (59, "59m", "59 minutes"),
            (60, "1h", "1 hour"), (86, "1h 26m", "1 hour 26 minutes"), (2941, "49h 1m", "49 hours 1 minute")
        ] {
            let presentation = OverviewTaskTimingPresentation(timing: .init(elapsedMinutes: minutes))
            #expect(presentation.elapsedText == text)
            #expect(presentation.elapsedHelp == "Elapsed: \(spoken)")
            #expect(presentation.checkInText == nil)
            #expect(presentation.checkInHelp == nil)
            #expect(presentation.spoken == "\(spoken) elapsed")
        }
        let upcoming = OverviewTaskTimingPresentation(timing: .init(elapsedMinutes: 86, checkInMinutes: 31))
        #expect(upcoming.elapsedText == "1h 26m")
        #expect(upcoming.checkInText == "31m")
        #expect(upcoming.checkInHelp == "Check-in in 31 minutes")
        #expect(upcoming.spoken == "1 hour 26 minutes elapsed, check-in in 31 minutes")
        let due = OverviewTaskTimingPresentation(timing: .init(elapsedMinutes: 60, checkInMinutes: 0))
        #expect(due.checkInText == "0m")
        #expect(due.checkInHelp == "Check-in due")
        #expect(due.spoken == "1 hour elapsed, check-in due")

        let start = Date(timeIntervalSince1970: 1_792_800_000)
        #expect(Array(OverviewTaskMinuteSchedule(isVisible: false).entries(from: start, mode: .normal)) == [start])
        let ticks = Array(OverviewTaskMinuteSchedule(isVisible: true).entries(from: start, mode: .normal).prefix(3))
        #expect(ticks.count == 3)
        #expect(ticks[1].timeIntervalSince(ticks[0]) == 60)
        #expect(ticks[2].timeIntervalSince(ticks[1]) == 60)
    }

    @Test(arguments: ["in_progress", "done"])
    func aParentsChevronWrapsWithTheLastWordOfItsTitle(_ status: String) throws {
        let title = "Polish the onboarding flow for teammates"
        let lastWord = ("teammates" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
        let titleWidth = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
        // The title alone fits its line, but its count and chevron don't.
        let titleStart = OverviewTaskRow.statusSize + OverviewTaskRow.titleGap
        let width = Int((titleStart + titleWidth + 3).rounded(.up))
        let render = try TaskListRender([
            .init(id: "parent", title: title, status: status, children: [
                .init(id: "child", title: "Child", status: "in_progress")
            ])
        ], width: width)
        // Two title lines below the row's top padding, stopping short of the child row.
        let rowBottom = TaskListRender.padding + 5 + 2 * OverviewTaskRow.statusSize + 3
        let lines = render.inkLines(fromX: TaskListRender.padding + titleStart, toY: rowBottom)
        try #require(lines.count == 2, "Expected the title to wrap once, found \(lines.count) lines")
        #expect(lines[1].width > lastWord * 0.8,
                "The chevron wrapped without the title's last word: the second line is \(lines[1].width) wide")
    }

    @Test func taskDisclosureRespondsToKeyboardStatusAndChannelChanges() async throws {
        let tasks = TaskStatusHost.Tasks()
        tasks.status = "done"
        let host = TaskWindow(TaskStatusHost(tasks: tasks)
            .environment(\.overviewTaskFocusInteractions, .automatic))
        defer { host.window.close() }
        let right = String(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!)
        let left = String(UnicodeScalar(UInt16(NSLeftArrowFunctionKey))!)
        try await host.waitForDisclosure(expanded: false)

        try host.press("\t", keyCode: 48)
        try host.press(right, keyCode: 124)
        try await host.waitForDisclosure(expanded: true)
        try host.press(right, keyCode: 124)
        try await host.waitForDisclosure(expanded: true)
        try host.press(left, keyCode: 123)
        try await host.waitForDisclosure(expanded: false)
        try host.press(" ", keyCode: 49)
        try await host.waitForDisclosure(expanded: true)
        try host.press(" ", keyCode: 49)
        try await host.waitForDisclosure(expanded: false)
        tasks.status = "in_progress"
        try await host.waitForDisclosure(expanded: true)
        tasks.status = "done"
        try await host.waitForDisclosure(expanded: false)
        try host.press(right, keyCode: 124)
        try await host.waitForDisclosure(expanded: true)
        tasks.channelId = "other"
        try await host.waitForDisclosure(expanded: false)
        try host.press(right, keyCode: 124)
        try await host.waitForDisclosure(expanded: true)
        tasks.channelId = "tasks"
        try await host.waitForDisclosure(expanded: false)
        tasks.status = "in_progress"
        try await host.waitForDisclosure(expanded: true)
    }

    @Test func slotsFollowAnItemWithinAVisitAndGoByPositionAcrossVisits() {
        struct Item: Identifiable { let id: String }
        func items(_ ids: String...) -> [Item] { ids.map(Item.init) }
        let slots = OverviewSlots()

        let first = slots.entries(items("x", "y"), in: "a")
        #expect(first.map(\.id) == [0, 1])
        let added = slots.entries(items("w", "x", "y"), in: "a")
        #expect(added.map(\.id) == [2, 0, 1])
        #expect(added.dropFirst().map(\.key) == first.map(\.key))
        #expect(Set(added.map(\.key)).count == 3)

        let other = slots.entries(items("p", "x"), in: "b")
        #expect(other.map(\.id) == [0, 1])
        #expect(Set(other.map(\.key)).isDisjoint(with: added.map(\.key)))
        let back = slots.entries(items("x", "y"), in: "a")
        #expect(back.map(\.id) == [0, 1])
        #expect(Set(back.map(\.key)).isDisjoint(with: added.map(\.key)))
    }

    @Test func itemStateReadsFreshForAnotherItemAndDropsItsLateResults() {
        var state = OverviewItemState(0)
        state["a"] = 1
        #expect(state["a"] == 1)
        #expect(state["b"] == 0)
        state.update("a") { $0 += 1 }
        #expect(state["a"] == 2)
        state["b"] = 5
        state.update("a") { $0 = 9 }
        #expect(state["a"] == 0)
        #expect(state["b"] == 5)
    }

    @Test func longTextReturnSubmitsWhileOptionReturnBreaksTheLine() async throws {
        let field = LongTextHost.Model()
        let host = TaskWindow(LongTextHost(model: field), size: NSSize(width: 480, height: 300))
        defer { host.window.close() }
        try await host.waitUntil { host.window.firstResponder is NSText }
        try host.press("a", keyCode: 0)
        try host.press("\r", keyCode: 36, modifiers: .option)
        try host.press("b", keyCode: 11)
        #expect(field.text == "a\nb")
        #expect(field.submits == 0)

        try host.press("\r", keyCode: 36)
        #expect(field.text == "a\nb")
        #expect(field.submits == 1)
    }

    @Test func folderRowOffersRevealOnlyForAnOpenableFolder() throws {
        func inkRightEdge(_ availability: ChannelFolderAvailability) throws -> Int {
            let renderer = ImageRenderer(content:
                OverviewFolderRow(directory: "/srv/work", availability: availability, channelURL: { nil })
                    .frame(width: 280, alignment: .leading)
                    .background(Color.white)
                    .environment(\.colorScheme, .light))
            renderer.scale = 2
            let bitmap = try RenderedPixels(try #require(renderer.cgImage))
            var edge = -1
            for x in 0..<bitmap.pixelsWide {
                for y in 0..<bitmap.pixelsHigh {
                    let color = bitmap.colorAt(x: x, y: y)
                    if color.redComponent + color.greenComponent + color.blueComponent < 2.55 { edge = x }
                }
            }
            return edge
        }

        let remote = try inkRightEdge(.remote(host: "build.example.com"))
        let missing = try inkRightEdge(.missing)
        #expect(remote > 0)
        #expect(abs(missing - remote) <= 2)
        // The reveal arrow follows the path 4 points later and is about 14 points wide.
        #expect(try inkRightEdge(.openable) > remote + 24)
    }

    @Test func folderRowAbbreviatesOnlyAPathOnThisMac() {
        let home = NSHomeDirectory() + "/Desktop/toy-box"
        #expect(OverviewFolderRow.shownPath(home, availability: .openable) == "~/Desktop/toy-box")
        #expect(OverviewFolderRow.shownPath(home, availability: .missing) == "~/Desktop/toy-box")
        #expect(OverviewFolderRow.shownPath(home, availability: .remote(host: "build.example.com")) == home)
    }

    @Test func routineSchedulesUseReadableSummariesAndKeepUnknownSyntax() throws {
        let weekdays = try cronSummary("0 9 * * 1-5")
        #expect(RoutineScheduleSummary.text(for: "0 9 * * 1-5") == weekdays)
        #expect(RoutineScheduleSummary.text(for: "H 9 * * *") == "H 9 * * *")
        #expect(RoutineScheduleSummary.text(for: "not a schedule") == "not a schedule")
    }

    @Test func theTeamKeepsTheLeadFirstAndSortsMembersLikeFinder() {
        let roster = [ChannelAgent(id: "lead", name: "Zed"), ChannelAgent(id: "b", name: "agent 10"),
                      ChannelAgent(id: "a", name: "Agent 2"), ChannelAgent(id: "c", name: "Ada")]
        #expect(OverviewTeamList.ordered(roster).map(\.id) == ["lead", "c", "a", "b"])
        #expect(OverviewTeamList.ordered([]).isEmpty)
    }

    /// A row creates its pop-up button only while it shows the menu, so revealing it must not move the row.
    @Test func aHiddenRowMenuTakesTheSpaceOfAShownOne() {
        func size(isVisible: Bool) -> NSSize {
            NSHostingView(rootView: HStack(spacing: 6) {
                Text("Routine")
                OverviewRowMenu(title: "Actions for Routine", isVisible: isVisible) { Button("Run Now") {} }
            }).fittingSize
        }
        #expect(size(isVisible: false) == size(isVisible: true))
    }

    /// A sheet's long text field, counting the submissions its Return key makes.
    struct LongTextHost: View {
        @Observable final class Model {
            var text = ""
            var submits = 0
        }

        @Bindable var model: Model
        @FocusState private var focused: Bool

        var body: some View {
            Form {
                ManagementLongTextField(title: "Role", prompt: "What this agent owns", text: $model.text, lines: 5...10)
                    .focused($focused)
                    .onSubmit { model.submits += 1 }
            }
            .formStyle(.grouped)
            .onAppear { focused = true }
        }
    }

    /// A live parent task whose status the test changes, as a channel snapshot would.
    struct TaskStatusHost: View {
        @Observable final class Tasks {
            var status = "in_progress"
            var channelId = "tasks"
        }

        let tasks: Tasks

        var body: some View {
            var channel = Channel(id: tasks.channelId, name: "Tasks", model: .init(provider: "test", name: "test"),
                                  latestSequence: 1, seenThrough: 1, updatedAt: "2026-10-22T08:00:00Z")
            channel.tasks = [.init(id: "parent", title: "Parent task", status: tasks.status, children: [
                .init(id: "child", title: "Blocked child", status: "blocked")
            ])]
            return OverviewTaskList(state: ChannelState(revision: 1, channel: channel, lead: .lead(id: channel.id)),
                                    onArtifactOpen: { _ in })
                .frame(width: 280, height: 120, alignment: .topLeading)
                .background(Color.white)
                .environment(\.colorScheme, .light)
        }
    }

    @Test func theWorkingPulseIsCommittedOnceForTheRenderServerToRun() throws {
        let view = OverviewEllipsisPulseView()
        view.frame = NSRect(x: 0, y: 0, width: 11, height: 4.5)
        view.show(.init(size: 9, color: Color.red.resolve(in: EnvironmentValues()), scale: 2))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 20), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        let start = CACurrentMediaTime()
        window.contentView?.addSubview(view)
        let attached = CACurrentMediaTime()
        view.layoutSubtreeIfNeeded()

        // The window's renderer draws the symbol, and the mask's segments decide each dot's opacity.
        #expect(view.subviews.count == 1 && view.subviews.first is NSHostingView<AnyView>)
        #expect(view.subviews.first?.frame == view.bounds)
        let mask = try #require(view.layer?.mask)
        #expect(mask.frame == view.bounds)
        #expect(mask.sublayers?.count == 3 && mask.sublayers == view.segments)
        var begins: [CFTimeInterval] = []
        var edges: [CGFloat] = []
        for segment in view.segments {
            #expect(segment.frame.minY == 0 && segment.frame.height == view.bounds.height)
            #expect(segment.opacity == OverviewEllipsisPulseView.rest)
            let fade = try #require(segment.animation(forKey: "fade") as? CABasicAnimation)
            #expect(fade.fromValue as? Float == 1 && fade.toValue as? Float == 0.25)
            #expect(fade.duration == 0.3125)
            let pulse = try #require(segment.animation(forKey: "pulse") as? CAKeyframeAnimation)
            #expect((pulse.values as? [NSNumber])?.map(\.floatValue) == [0.25, 1, 0.25, 0.25])
            #expect(pulse.keyTimes?.map(\.doubleValue) == [0, 0.1875, 0.375, 1])
            #expect(abs(pulse.duration - 5.0 / 3) < 0.0001)
            #expect(pulse.repeatCount == .infinity)
            #expect(pulse.preferredFrameRateRange.maximum == 30)
            begins.append(pulse.beginTime)
            edges.append(segment.frame.minX)
            edges.append(segment.frame.maxX)
        }
        // The first dot rises as the fade to rest ends, and the others follow a third of a second apart.
        #expect(begins[0] >= view.segments[0].convertTime(start, from: nil) + 0.3125)
        #expect(begins[0] <= view.segments[0].convertTime(attached, from: nil) + 0.3125)
        #expect(abs(begins[1] - begins[0] - 1.0 / 3) < 0.0001)
        #expect(abs(begins[2] - begins[1] - 1.0 / 3) < 0.0001)
        // Each segment starts where the last ends, from one side of the symbol to the other.
        #expect(edges.first == 0 && edges.last == 11)
        #expect(edges[1] == edges[2] && edges[3] == edges[4])
    }

    @Test(arguments: [1.0, 2.0])
    func everyTextSizeSplitsTheEllipsisBetweenItsDots(displayScale: Double) throws {
        for textScale in stride(from: 0.85, through: 1.4, by: 0.05) {
            let rendering = try #require(OverviewEllipsisPulseView.rendering(size: 9 * textScale, scale: displayScale))
            let ink = OverviewEllipsisPulseView.columnInk(in: rendering.image)
            let width = CGFloat(rendering.image.width) / displayScale
            #expect(rendering.splits.count == 2, "\(textScale) at \(displayScale)x")
            for (index, split) in rendering.splits.enumerated() {
                #expect(abs(split - width * CGFloat(index + 1) / 3) < 1, "\(textScale) at \(displayScale)x")
                // A split crosses no ink. At 1x, with no empty column, it runs beside the faintest one.
                let pixel = split * displayScale, column = Int(pixel)
                let crossesNoInk = ink[column] == 0
                let besideFaintest = pixel == pixel.rounded()
                    && min(ink[column - 1], ink[column]) == ink[column - 2...column + 1].min()
                #expect(crossesNoInk || (displayScale == 1 && besideFaintest), "\(textScale) at \(displayScale)x")
            }
        }
    }

    /// Hosts a view in a window that counts as key, so typed keys reach the focused control.
    @MainActor private struct TaskWindow {
        final class KeyWindow: NSWindow {
            override var isKeyWindow: Bool { true }
            override var canBecomeKey: Bool { true }
        }

        let window: NSWindow
        let view: NSView

        init(_ content: some View, size: NSSize = NSSize(width: 280, height: 120)) {
            view = NSHostingView(rootView: content)
            window = KeyWindow(contentRect: NSRect(origin: .zero, size: size),
                               styleMask: [.borderless], backing: .buffered, defer: false)
            // ARC owns the window, so closing must not release it a second time.
            window.isReleasedWhenClosed = false
            window.contentView = view
            // SwiftUI builds its key view loop only for an ordered-in window, so keep it out of sight.
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            window.orderFrontRegardless()
            _ = window.makeFirstResponder(view)
        }

        func press(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) throws {
            window.sendEvent(try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)))
        }

        func waitForDisclosure(expanded: Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
            try await waitUntil(sourceLocation: sourceLocation) {
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let image = bitmap.cgImage else { return false }
                let pixels = try RenderedPixels(image)
                var hasParent = false
                for y in stride(from: 0, to: pixels.pixelsHigh, by: 2) {
                    for x in stride(from: 0, to: pixels.pixelsWide, by: 2) {
                        let color = pixels.colorAt(x: x, y: y)
                        if TaskListRender.isRed(color) { return expanded }
                        if TaskListRender.isInk(color) { hasParent = true }
                    }
                }
                return hasParent && !expanded
            }
        }

        func waitUntil(sourceLocation: SourceLocation = #_sourceLocation, _ condition: () throws -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(30)
            while try !condition() {
                try #require(ContinuousClock.now < deadline, "The hosted control never reached the expected state.",
                             sourceLocation: sourceLocation)
                view.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    @MainActor private struct TaskListRender {
        static let padding: CGFloat = 8
        let bitmap: RenderedPixels

        init(_ tasks: [ChannelTask], width: Int) throws {
            var channel = Channel(id: "tasks", name: "Tasks", model: .init(provider: "test", name: "test"),
                                  latestSequence: 1, seenThrough: 1, updatedAt: "2026-10-22T08:00:00Z")
            channel.tasks = tasks
            let state = ChannelState(revision: 1, channel: channel, lead: .lead(id: channel.id))
            let renderer = ImageRenderer(content:
                OverviewTaskList(state: state, onArtifactOpen: { _ in })
                    .frame(width: CGFloat(width))
                    .padding(Self.padding)
                    .background(Color.white)
                    .environment(\.colorScheme, .light))
            renderer.scale = 2
            bitmap = try RenderedPixels(try #require(renderer.cgImage))
        }

        func minX(where matches: (RenderedPixels.Pixel) -> Bool) -> CGFloat? {
            for x in 0..<bitmap.pixelsWide {
                for y in 0..<bitmap.pixelsHigh {
                    if matches(bitmap.colorAt(x: x, y: y)) {
                        return CGFloat(x) / 2
                    }
                }
            }
            return nil
        }

        /// The horizontal ink extent of each text line at or right of `fromX`, down to `toY` points.
        func inkLines(fromX: CGFloat, toY: CGFloat) -> [(minX: CGFloat, width: CGFloat)] {
            var rows: [(y: Int, minX: Int, maxX: Int)] = []
            for y in 0..<min(bitmap.pixelsHigh, Int(toY * 2)) {
                let xs = (Int(fromX * 2)..<bitmap.pixelsWide).filter { x in
                    Self.isInk(bitmap.colorAt(x: x, y: y))
                }
                if let first = xs.first, let last = xs.last { rows.append((y, first, last)) }
            }
            var lines: [(minX: Int, maxX: Int, lastY: Int)] = []
            for row in rows {
                if let line = lines.last, row.y - line.lastY <= 2 {
                    lines[lines.count - 1] = (min(line.minX, row.minX), max(line.maxX, row.maxX), row.y)
                } else {
                    lines.append((row.minX, row.maxX, row.y))
                }
            }
            return lines.map { (CGFloat($0.minX) / 2, CGFloat($0.maxX - $0.minX) / 2) }
        }

        static func isGreen(_ color: RenderedPixels.Pixel) -> Bool {
            color.greenComponent - color.redComponent > 0.08 && color.greenComponent - color.blueComponent > 0.08
        }

        static func isRed(_ color: RenderedPixels.Pixel) -> Bool {
            color.redComponent - color.greenComponent > 0.3 && color.redComponent - color.blueComponent > 0.3
        }

        static func isInk(_ color: RenderedPixels.Pixel) -> Bool {
            (color.redComponent + color.greenComponent + color.blueComponent) / 3 < 0.8
        }
    }

    private struct RenderedPixels {
        struct Pixel {
            let redComponent: Double
            let greenComponent: Double
            let blueComponent: Double
        }

        let pixelsWide: Int
        let pixelsHigh: Int
        private let bytes: [UInt8]

        init(_ image: CGImage) throws {
            pixelsWide = image.width
            pixelsHigh = image.height
            let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(
                    data: buffer.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                    space: colorSpace,
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return true
            }
            try #require(drawn)
            self.bytes = bytes
        }

        func colorAt(x: Int, y: Int) -> Pixel {
            let offset = (y * pixelsWide + x) * 4
            return Pixel(redComponent: Double(bytes[offset]) / 255,
                         greenComponent: Double(bytes[offset + 1]) / 255,
                         blueComponent: Double(bytes[offset + 2]) / 255)
        }
    }

    private func linear(_ component: Double) -> Double {
        component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
    }
}
