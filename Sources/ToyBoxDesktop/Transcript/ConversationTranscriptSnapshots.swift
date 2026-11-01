import ChannelClient
import ChannelKit
import SwiftUI
import ToyBoxUI

/// Snapshot mode's transcript states: each lands the transcript somewhere a reader can, checks it landed
/// right, and marks the state ready or failed for the capture.
extension ConversationTranscript {
    func prepareSnapshot(using proxy: ScrollViewProxy) async {
        guard let snapshot, let name = snapshot.requestedState, name.hasPrefix("transcript-") else { return }
        let deadline = Date.now.addingTimeInterval(10)
        while !hasLanded && Date.now < deadline {
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { return }
        }
        guard hasLanded else {
            snapshot.failState(name, message: "The transcript did not finish its initial landing.")
            return
        }
        var revealOutcome: RevealProgress.Outcome?
        switch name {
        case "transcript-find":
            prepareFind()
            find.present()
            find.query = "the"
            _ = await waitForSnapshotLayout { !find.isSearching }
        case "transcript-start":
            guard let first = rows.first else { break }
            jump(to: first.id, anchor: .top, using: proxy)
            // A follow that overrides the jump lands after it, so the start must still hold a moment later.
            let landed = await waitForSnapshotLayout { pendingJump == nil && showsStart(of: first) }
            do { try await Task.sleep(for: .milliseconds(300)) }
            catch { return }
            guard landed, showsStart(of: first) else {
                let top = transcriptFrameIDs(of: first).compactMap { frames[$0]?.rect.minY }.min()
                snapshot.failState(name, message: "The first row's top is at \(String(describing: top)) "
                                   + "with a \(viewport.bottomGap)-point bottom gap.")
                return
            }
        case "transcript-latest":
            scrollToLatest(using: proxy)
            do { try await Task.sleep(for: .milliseconds(200)) }
            catch { return }
            guard await waitForSnapshotLayout(until: { isAtBottom }) else {
                snapshot.failState(name, message: "Latest landing left a \(viewport.bottomGap)-point bottom gap.")
                return
            }
            if let last = store.state?.messages.last(where: { message in
                rows.contains { $0.messages.contains { $0.id == message.id } }
            }) {
                guard let frame = frames.values.first(where: { $0.sequence == last.sequence }),
                      frame.rect.maxY <= viewport.height + 0.5,
                      viewport.readSequence(in: frames) == last.sequence else {
                    let detail = String(describing: frames.values.first { $0.sequence == last.sequence })
                    snapshot.failState(name, message: "Latest message \(last.sequence) is not in the unobscured "
                                       + "viewport of height \(viewport.height). Frame: \(detail).")
                    return
                }
            }
        case "transcript-yours":
            interaction.messageView = .yours
            await Task.yield()
            scrollToLatest(using: proxy)
        case "transcript-request":
            guard let sequence = store.state?.channel.requestSequence else {
                snapshot.failState(name, message: "The channel has no pending request.")
                return
            }
            revealOutcome = await reveal(sequence: sequence, using: proxy)
        case "transcript-attachments":
            guard let message = store.state?.messages.last(where: { $0.attachments?.isEmpty == false }) else {
                snapshot.failState(name, message: "The channel has no message with attachments.")
                return
            }
            revealOutcome = await reveal(sequence: message.sequence, using: proxy)
        case "transcript-viewer":
            await openViewerSnapshot(name, using: proxy)
            return
        case "transcript-catchup":
            await validateCatchUpSnapshot(name)
            return
        case "transcript-paging":
            await validatePagingSnapshot(using: proxy)
            return
        default:
            snapshot.failState(name, message: "Unknown transcript snapshot state.")
            return
        }
        if case .failed(let message)? = revealOutcome { snapshot.failState(name, message: message) }
        else { snapshot.markStateReady(name) }
    }

    /// Opens the latest message with images in the viewer, on its second image when it has several.
    func openViewerSnapshot(_ name: String, using proxy: ScrollViewProxy) async {
        guard let snapshot else { return }
        guard let viewer, let state = store.state, let message = state.messages.last(where: {
            $0.attachments?.contains(where: \.isImage) == true
        }) else {
            snapshot.failState(name, message: "The window has no image viewer or the channel has no images.")
            return
        }
        await reveal(sequence: message.sequence, using: proxy)
        let images = (message.attachments ?? []).filter(\.isImage)
        viewer.open(images: images, at: min(1, images.count - 1), source: TranscriptImageSource(message: message, agents: state.agents),
                    api: store.api)
        let loaded = await waitForSnapshotLayout {
            viewer.items[viewer.index]?.image != nil || viewer.items[viewer.index]?.failure != nil
        }
        do { try await Task.sleep(for: .milliseconds(600)) }
        catch { return }
        // Live Text joins once the image has settled, so the capture shows what a reader sees.
        if loaded && ImageViewer.readsText {
            _ = await waitForSnapshotLayout { viewer.items[viewer.index]?.analysis != nil }
            do { try await Task.sleep(for: ImageViewerLiveTextView.settleDelay + .milliseconds(400)) }
            catch { return }
        }
        if !loaded { snapshot.failState(name, message: "The viewer's image did not load.") }
        else if let failure = viewer.items[viewer.index]?.failure { snapshot.failState(name, message: failure) }
        else { snapshot.markStateReady(name) }
    }

    func validatePagingSnapshot(using proxy: ScrollViewProxy) async {
        guard let snapshot else { return }
        let name = "transcript-paging"
        defer { isRevealing = false }
        for page in 1...4 {
            guard store.hasOlderMessages, let first = rows.first,
                  let oldest = store.state?.messages.first?.sequence else {
                snapshot.failState(name, message: "Paging validation requires four older history pages.")
                return
            }
            isRevealing = true
            proxy.scrollTo(first.id, anchor: .top)
            guard await waitForSnapshotLayout(until: {
                viewport.topVisibleFrame(in: pagingFrames)?.frame.sequence == oldest
            }), let anchor = viewport.topVisibleFrame(in: pagingFrames) else {
                snapshot.failState(name, message: "The oldest message did not enter the viewport.")
                return
            }
            isRevealing = false
            await loadOlder()
            guard store.historyError == nil, let newOldest = store.state?.messages.first?.sequence,
                  newOldest < oldest else {
                snapshot.failState(name, message: store.historyError ?? "History did not prepend an older page.")
                return
            }
            guard await waitForSnapshotLayout(until: {
                pagingAnchor == nil && frames[anchor.id]?.historyStart == newOldest
            }) else {
                let detail = "Frame: \(String(describing: frames[anchor.id])). Pending: \(String(describing: pagingAnchor))."
                snapshot.failState(name, message: "Page \(page) did not restore \(anchor.id). \(detail)")
                return
            }
            do { try await Task.sleep(for: .milliseconds(200)) }
            catch { return }
            guard let restored = frames[anchor.id] else {
                snapshot.failState(name, message: "The anchored message left the measured layout.")
                return
            }
            let positioned = TranscriptCoordinates.viewportFrame(restored, top: window.viewportTop ?? viewport.top)
            let displacement = abs(positioned.rect.maxY - anchor.frame.rect.maxY)
            guard displacement <= 2 else {
                let detail = "From \(anchor.frame.rect.maxY) to \(positioned.rect.maxY)."
                snapshot.failState(name, message: "Page \(page) moved \(anchor.id) by \(displacement) points. \(detail)")
                return
            }
            print("Transcript paging page \(page): \(anchor.id), displacement \(displacement) points.")
        }
        snapshot.markStateReady(name)
    }

    /// The card lands where the New divider would have, 20 points down unless the unread messages are too
    /// short to scroll that far, and its summary arrives without moving its top. While the card is in view
    /// nothing above it changes, so its top holds exactly when the clip view's offset does.
    func validateCatchUpSnapshot(_ name: String) async {
        guard let snapshot else { return }
        guard let catchUp else {
            snapshot.failState(name, message: "The channel isn't eligible for a catch-up summary.")
            return
        }
        guard await waitForSnapshotLayout(within: 5, until: { pendingJump == nil && catchUp.top != nil }) else {
            snapshot.failState(name, message: "The catch-up card never laid out.")
            return
        }
        do { try await Task.sleep(for: .milliseconds(150)) }
        catch { return }
        let wasLoading = catchUp.session.isGenerating
        let landedAtBottom = isAtBottom
        guard let landed = catchUp.top, let offset = window.scrollOffset else { return }
        guard landedAtBottom || abs(landed - 20) <= 1 else {
            snapshot.failState(name, message: "The card landed at \(landed), not 20 points below the viewport's top.")
            return
        }
        _ = await waitForSnapshotLayout(within: 20) { !catchUp.session.isGenerating }
        guard catchUp.session.summary != nil else {
            snapshot.failState(name, message: "The summary collapsed or never arrived.")
            return
        }
        do { try await Task.sleep(for: .milliseconds(600)) }
        catch { return }
        guard let top = catchUp.top, let settled = window.scrollOffset, abs(settled - offset) <= 1 else {
            snapshot.failState(name, message: "The transcript scrolled from \(offset) to "
                               + "\(String(describing: window.scrollOffset)) when the summary arrived.")
            return
        }
        print("Transcript catch-up landed at \(landed)\(landedAtBottom ? " at the bottom" : "") while "
              + "\(wasLoading ? "loading" : "ready") and settled at \(top), scrolled \(offset) then \(settled).")
        snapshot.markStateReady(name)
    }

    func waitForSnapshotLayout(within seconds: TimeInterval = 5, until predicate: () -> Bool) async -> Bool {
        let deadline = Date.now.addingTimeInterval(seconds)
        while !predicate() && Date.now < deadline {
            do { try await Task.sleep(for: .milliseconds(40)) }
            catch { return false }
        }
        return predicate()
    }
}
