---
name: release
description: Merge a reviewed change into main with its release note, ship a Mac or iPhone version, or change how they're signed, packaged and distributed. Use when merging a member's branch, writing or reviewing CHANGELOG.md bullets, tagging a release, checking a release run, or changing signing, in-app updates, TestFlight, bundling or release workflows.
---

# Release

Lead merges every change and ships every version. Core owns the tooling, and
[references/distribution.md](references/distribution.md) explains signing, notarization, in-app
updates, TestFlight and recovery. Read it before changing any of them.

## Merge a change

1. **Review it against its outcome and the spec.** A hand-off is a claim until its proof matches,
   so open the screenshots and check that the tests cover the promise.
2. **Merge it into `main` with `git merge --no-ff`** once main's CI is green.
3. **Add its release note in the same merge** if the user will notice it, following the rules
   below.

## Write release notes

- **They're written at merge time.** Add the bullet to that platform's next unreleased
  `## Mac X.Y.Z` or `## iPhone X.Y.Z` entry in `CHANGELOG.md`, under `### Features` or
  `### Bugs/Polish`, creating the entry if the newest one has shipped. A release is then only a
  tag.
- **Each bullet leads with what the user gains, in plain words.** Name the moment they'll notice
  it and why it matters, never how it works. If a reader who never saw the code couldn't say why
  they'd care, rewrite it.

  | Not | But |
  | --- | --- |
  | Quick Send, menu bar replies and notification replies now finish the moment you send, and a message that can't go out waits in its channel. | Sending from Quick Send, the menu bar or a notification is now instant, and if your connection drops or your server is asleep, Toy Box sends your message as soon as it can, so nothing you send gets lost. |
  | A request waiting for you can now be read aloud, from the channel list or the conversation. | A request waiting for you can now be read aloud, so you can hear it while you do something else, even with your phone locked. |

- **Leave out internals and mechanics.** No internal names such as the outbox, and no placement,
  glyphs, colors, counts or gestures unless they're the point.
- **Write one bullet per gain,** folding changes that serve the same one together. Each
  platform's notes stand on their own, never compared to the web or the other app.

## Ship a version

1. **Reread every unreleased bullet** against the rules above, then ask the user. Tags need their
   approval.
2. **Tag main's head and push the tag.** Use a lightweight tag named for the unreleased
   `CHANGELOG.md` entry: `vX.Y.Z` ships the Mac to GitHub Releases, where the app's updater finds
   it, and `mobile-vX.Y.Z` ships the phone to TestFlight. A manual workflow run on `main` is a dry
   run that publishes nothing.
3. **Watch each run to the end** with `gh run watch <id> --exit-status`. TestFlight takes about 20
   minutes. On a failure, read `gh run view <id> --log-failed`, then fix the cause or route it to
   its owner.
4. **Confirm what shipped.** The GitHub Release carries the zip, its checksum and the appcast, and
   the TestFlight run passed.
5. **Tell the user,** naming what still needs a try on a real device.

Never alter the user's installed validation bundle or microphone permission state to test a
release.
