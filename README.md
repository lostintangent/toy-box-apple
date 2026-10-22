# Toy Box Channels for Mac

A native SwiftUI client for the public Toy Box Channels API. Requires macOS 15 or later and
Swift 6 Command Line Tools. No Xcode project or Xcode license is needed.

```sh
./script/run
```

The script builds with Command Line Tools, assembles and ad-hoc signs
`.build/Toy Box Channels.app`, and opens it. Use `./script/run --no-open` to build the bundle only.
The server defaults to `http://localhost:3100` and is configurable in Settings.

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools swift test
```

`ChannelKit` owns the Codable public domain, canonical reducer, transcript grouping, audience
policy, task math, attention, presence, and SVG paths. `ChannelClient` owns HTTP commands,
SSE framing, observation, reconnect, and observable detail/catalog stores. `ToyBoxChannels`
is the SwiftUI presentation.

The conformance fixtures are copied unchanged from the read-only Minecraft reference client.
Opt-in integration tests use its isolated demo server, never the live server:

```sh
# In a separate terminal, from the Minecraft reference repository:
bun run demo

# Here:
TOY_BOX_DEMO_URL=http://127.0.0.1:3210 DEVELOPER_DIR=/Library/Developer/CommandLineTools swift test
```

Management APIs are exposed by `ChannelAPI`. They require the v1 routes added to Toy Box for
this client. Message sends are single-attempt and carry a caller-owned UUID. Reconnection
resumes from the last applied durable revision, including revision zero. Reading does not
answer a pending request.

The parity and native interaction design are in [docs/spec.md](docs/spec.md).
