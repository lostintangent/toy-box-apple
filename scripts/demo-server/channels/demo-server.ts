// An isolated public-API fixture for client tests and screenshots. No agents or model calls.
import http, { type ServerResponse } from 'node:http';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { type Snapshot as FixtureSnapshot } from './types.ts';

/** The exported public Channel snapshot; this fixture server treats it as plain JSON. */
type Snapshot = Record<string, any>;
type Resource = { type: string; content: string | Buffer };

export const fixturePath = path.join(import.meta.dir, '..', '..', '..', 'Tests', 'Shared', 'ChannelKitTests', 'Fixtures', 'channel-snapshot.json');

const defaultReplies = ['Near the entrance, so visitors can find it', 'Beside the team desks, for quick access',
  'Near the entrance, with a quiet reading nook beside the team desks'];
const designReplies = [
  'Confirm the review, but keep read receipts open until paging finishes',
  'Hold the publish until the notarization ticket is stapled and QA signs off',
  'Ship the Mac build to GitHub Releases now and post the notes in the team channel',
  'Not yet',
];

// TOY_BOX_DEMO_REPLIES=0|2|4|short sets the request's choices. "short" is two labels that fit in
// one row beside Reply; four includes an 80-unit label.
function demoReplies(): string[] | undefined {
  const count = process.env.TOY_BOX_DEMO_REPLIES;
  if (count === undefined) return defaultReplies;
  if (count === '0') return undefined;
  if (count === '2') return designReplies.slice(0, 2);
  if (count === '4') return designReplies;
  if (count === 'short') return ['Yes', 'Not yet'];
  throw new Error(`TOY_BOX_DEMO_REPLIES must be 0, 2, 4, or short, not "${count}"`);
}

// TOY_BOX_DEMO_BOOKMARKS=empty starts with no bookmarks.
export function demoBookmarks(seeded: number[]): number[] {
  const value = process.env.TOY_BOX_DEMO_BOOKMARKS;
  if (value === undefined) return seeded;
  if (value === 'empty') return [];
  throw new Error(`TOY_BOX_DEMO_BOOKMARKS must be empty, not "${value}"`);
}

const avatarImage = fs.readFileSync(path.join(import.meta.dir, '..', 'fixtures', 'channel-avatar.png'));

type Avatar = NonNullable<FixtureSnapshot['channel']['avatar']>;

// A project icon, served as the server stores one under a name that hashes its content, or a mark
// on its color.
function avatarFor(kind: string, channelID: string): Avatar | undefined {
  if (kind === 'mark') return { mark: 'M4 17 9 12l4 4 7-8', color: '#2f855a' };
  if (kind !== 'image') return undefined;
  const hash = createHash('sha256').update(avatarImage).digest('hex').slice(0, 16);
  return { image: `/api/serve/machine/demo/.toy-box/channels/${channelID}/avatar-${hash}.png` };
}

// TOY_BOX_DEMO_AVATAR=image|mark gives the channel an avatar. Without it, the channel shows its #.
function demoAvatar(channelID: string): Avatar | undefined {
  const value = process.env.TOY_BOX_DEMO_AVATAR;
  if (value === undefined) return undefined;
  const chosen = avatarFor(value, channelID);
  if (!chosen) throw new Error(`TOY_BOX_DEMO_AVATAR must be image or mark, not "${value}"`);
  return chosen;
}

// The fixture stays byte-identical to the reference export, so the demo adds the replies its
// library request would carry, any avatar, and bookmarks the lead's handoff to two agents, which
// only a bookmark keeps in the Yours view, and the request.
export function loadDemoFixture(): FixtureSnapshot {
  const snapshot: FixtureSnapshot = JSON.parse(fs.readFileSync(fixturePath, 'utf8'));
  const replies = demoReplies();
  for (const message of [snapshot.request, ...snapshot.messages]) {
    if (message?.id !== 'fixture-request') continue;
    if (replies) message.replies = replies;
    else delete message.replies;
  }
  snapshot.bookmarks = demoBookmarks([9, 15]);
  const avatar = demoAvatar(snapshot.channel.id);
  if (avatar) snapshot.channel.avatar = avatar;
  return snapshot;
}

const fixture = loadDemoFixture();

/** `olderMessages` reaches messages the snapshot no longer holds, so they can be bookmarked too. */
export function createDemoServer(initial: Snapshot = fixture, now = Date.now(), olderMessages: Snapshot[] = []) {
  let snapshot = structuredClone(initial);
  // Keep the exported fixture immutable, but make its history recent on each demo launch.
  const dates: { value: Record<string, string>; key: string; time: number }[] = [];
  const dateKeys = new Set(['timestamp', 'updatedAt', 'sharedAt', 'wakeAt']);
  function collectDates(value: unknown) {
    if (!value || typeof value !== 'object') return;
    for (const [key, child] of Object.entries(value)) {
      if (dateKeys.has(key) && typeof child === 'string' && Number.isFinite(Date.parse(child))) {
        dates.push({ value: value as Record<string, string>, key, time: Date.parse(child) });
      } else collectDates(child);
    }
  }
  collectDates(snapshot);
  const history = dates.filter(({ key }) => key !== 'wakeAt');
  if (history.length) {
    const offset = now - Math.max(...history.map(({ time }) => time));
    for (const { value, key, time } of dates) value[key] = new Date(time + offset).toISOString();
  }
  const clients = new Set<ServerResponse>();
  const replayHistory: Snapshot[] = [];
  // Like the server, a repeated ID returns its stored message, even after the snapshot drops it.
  const storedMessages = new Map<string, Snapshot>(snapshot.messages.map((message: Snapshot) => [message.id, message]));
  const watchers = new Map<string, Set<ServerResponse>>();
  let resourceRevision = 1;
  const resourceEvent = (url: string) => ({ type: resources.has(url) ? "changed" : "deleted", timestamp: resourceRevision });
  const publishResource = (url: string) => { resourceRevision++; for (const watcher of watchers.get(url) ?? []) watcher.write(`data: ${JSON.stringify(resourceEvent(url))}\n\n`); };
  const channelPath = `/api/v1/channels/${encodeURIComponent(snapshot.channel.id)}`;
  const resources = new Map<string, Resource>(snapshot.artifacts.map((artifact: Snapshot) => [artifact.url, {
    type: 'text/markdown; charset=utf-8',
    content: `# ${artifact.title}\n\nThis public Channel artifact is part of the canonical client fixture.\n\nThe workshop keeps the public conversation, shared work, and team presence visible together.\n`,
  }]));
  const previewImage = snapshot.messages.flatMap((message: Snapshot) => message.attachments ?? [])
    .find((attachment: Snapshot) => typeof attachment === 'object' && attachment.mimeType === 'image/png');
  for (const message of snapshot.messages) {
    for (const {url} of message.attachments ?? []) {
      if (url?.startsWith('/api/serve/') && previewImage) resources.set(url, {
        type: 'image/png', content: Buffer.from(previewImage.base64, 'base64'),
      });
    }
  }
  const serveAvatar = (avatar: Avatar | undefined) => {
    if (avatar && 'image' in avatar) resources.set(avatar.image, { type: 'image/png', content: avatarImage });
  };
  serveAvatar(snapshot.channel.avatar);
  const json = (response: ServerResponse, status: number, value: unknown) => {
    response.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
    response.end(JSON.stringify(value));
  };
  const resumed = () => ({ type: 'resumed', presence: snapshot.presence });
  const send = (client: ServerResponse, event: Snapshot) => {
    client.write(`data: ${JSON.stringify(event)}\n\n`);
  };
  const changeListeners = new Set<() => void>();
  const publish = (event: Snapshot) => {
    if ('revision' in event) {
      replayHistory.push(structuredClone(event));
      if (replayHistory.length > 500) replayHistory.shift();
    }
    for (const client of clients) send(client, event);
    for (const listener of changeListeners) listener();
  };
  const server = http.createServer(async (request, response) => {
    const url = new URL(request.url ?? '/', 'http://localhost');
    const pathname = url.pathname;
    if (request.method === 'GET' && pathname === '/api/v1/channels') {
      return json(response, 200, { channels: [snapshot.channel], members: snapshot.members });
    }
    if (request.method === 'GET' && pathname.startsWith('/api/watch/')) {
      const url = pathname.replace('/api/watch/', '/api/serve/');
      response.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache' });
      const subscribed = watchers.get(url) ?? new Set(); watchers.set(url, subscribed); subscribed.add(response);
      response.write(`data: ${JSON.stringify(resourceEvent(url))}\n\n`);
      response.on('close', () => { subscribed.delete(response); if (!subscribed.size) watchers.delete(url); });
      return;
    }
    if (request.method === 'GET' && resources.has(pathname)) {
      const resource = resources.get(pathname)!;
      response.writeHead(200, { 'Content-Type': resource.type });
      response.end(resource.content);
      return;
    }
    if (request.method === 'GET' && pathname === channelPath) {
      response.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache' });
      const cursor = url.searchParams.get('after');
      const after = cursor == null ? NaN : Number(cursor);
      const valid = Number.isSafeInteger(after) && after >= 0;
      const replay = valid ? replayHistory.filter(({ revision }) => revision > after && revision <= snapshot.revision) : [];
      if (valid && replay.length === snapshot.revision - after
          && replay.every(({ revision }, index) => revision === after + index + 1)) {
        for (const event of replay) send(response, event);
        send(response, resumed());
      } else send(response, { type: 'snapshot', state: snapshot });
      clients.add(response);
      response.on('close', () => clients.delete(response));
      return;
    }
    if (request.method === 'POST' && [ `${channelPath}/messages`, `${channelPath}/read` ].includes(pathname)) {
      let length = 0;
      const chunks: Buffer[] = [];
      try {
        for await (const chunk of request) {
          length += chunk.length;
          // Ten images at the composer's 1.5 MB each, as base64.
          if (length > 32 << 20) { json(response, 413, { error: 'Message is too large.' }); return; }
          chunks.push(chunk);
        }
        if (request.headers['content-type']?.split(';')[0]?.trim() !== 'application/json') {
          json(response, 400, { error: 'Expected a JSON request.' }); return;
        }
        const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        if (pathname.endsWith('/read')) {
          if (!body || typeof body !== 'object' || Array.isArray(body)
              || Object.keys(body).some((key) => key !== 'sequence')
              || !Number.isInteger(body.sequence) || body.sequence < 0) {
            json(response, 400, { error: 'Expected a non-negative sequence.' }); return;
          }
          const previous = snapshot.channel.seenThrough;
          snapshot.channel.seenThrough = Math.max(previous,
            Math.min(body.sequence, snapshot.channel.latestSequence));
          if (snapshot.channel.seenThrough !== previous) {
            snapshot.revision++;
            publish({ type: 'read', revision: snapshot.revision,
              seenThrough: snapshot.channel.seenThrough });
          }
          json(response, 200, { seenThrough: snapshot.channel.seenThrough });
          return;
        }
        const uploads = body?.attachments ?? [];
        if (!body || typeof body !== 'object' || Array.isArray(body)
            || Object.keys(body).some((key) => !['id', 'content', 'attachments'].includes(key))
            || typeof body.id !== 'string' || !body.id.trim() || body.id.length > 255
            || typeof body.content !== 'string' || body.content.length > 12000
            || !Array.isArray(uploads) || !uploads.every((upload: Snapshot) => typeof upload?.base64 === 'string'
              && typeof upload.mimeType === 'string' && /^image\/[a-z0-9.+-]+$/.test(upload.mimeType))
            || (!body.content.trim() && !uploads.length)) {
          json(response, 400, { error: 'Expected a user message with id and content.' }); return;
        }
        const stored = storedMessages.get(body.id);
        if (stored) { json(response, 201, stored); return; }
        const timestamp = new Date().toISOString();
        const sequence = snapshot.channel.latestSequence + 1;
        // Like the server, each upload becomes a file named by its type, echoed in the order sent.
        const taken = new Set<string>();
        const attachments = uploads.map(({ mimeType, base64 }: Snapshot) => {
          const extension = mimeType.slice('image/'.length).split('+')[0];
          let name = `image.${extension}`;
          for (let suffix = 2; taken.has(name); suffix++) name = `image-${suffix}.${extension}`;
          taken.add(name);
          const url = `/api/serve/attachments/${encodeURIComponent(body.id)}/${name}`;
          resources.set(url, { type: mimeType, content: Buffer.from(base64, 'base64') });
          return { name, url, mimeType };
        });
        const message = { id: body.id, content: body.content.trim(), sender: { type: 'user' }, sequence, timestamp,
          ...(attachments.length ? { attachments } : {}) };
        storedMessages.set(message.id, message);
        snapshot.messages.push(message);
        snapshot.messages = snapshot.messages.slice(-100);
        snapshot.revision++;
        Object.assign(snapshot.channel, { latestSequence: sequence, requestSequence: null, updatedAt: timestamp });
        snapshot.request = null;
        publish({ type: 'message', revision: snapshot.revision, message });
        json(response, 201, message);
      } catch { json(response, 400, { error: 'Invalid JSON message.' }); }
      return;
    }
    if (request.method === 'DELETE' && pathname.startsWith(`${channelPath}/artifacts/`)) {
      const encoded = pathname.slice(`${channelPath}/artifacts/`.length);
      let artifactId: string;
      try { artifactId = decodeURIComponent(encoded); }
      catch { json(response, 400, { error: 'Invalid Channel request.' }); return; }
      if (!artifactId || encoded.includes('/')) { json(response, 400, { error: 'Invalid Channel request.' }); return; }
      const artifact = snapshot.artifacts.find(({ id }: Snapshot) => id === artifactId);
      if (!artifact) { json(response, 404, { error: 'Artifact not found.' }); return; }
      const unlink = (tasks: Snapshot[]): Snapshot[] => tasks.map(({ artifactId: linked, children, ...task }) => ({
        ...task,
        ...(linked && linked !== artifactId ? { artifactId: linked } : {}),
        ...(children ? { children: unlink(children) } : {}),
      }));
      snapshot.channel.tasks = unlink(snapshot.channel.tasks);
      snapshot.artifacts = snapshot.artifacts.filter(({ id }: Snapshot) => id !== artifactId);
      const timestamp = new Date().toISOString();
      const sequence = snapshot.channel.latestSequence + 1;
      const message = {
        id: crypto.randomUUID(), sequence, timestamp, sender: { type: 'system' },
        content: { type: 'artifact_removed', actor: { type: 'user' }, artifact: { id: artifact.id, file: artifact.file, title: artifact.title, url: artifact.url } },
      };
      storedMessages.set(message.id, message);
      snapshot.messages = [...snapshot.messages, message].slice(-100);
      snapshot.revision++;
      Object.assign(snapshot.channel, { latestSequence: sequence, updatedAt: timestamp });
      publish({ type: 'message', revision: snapshot.revision, message });
      response.writeHead(204);
      response.end();
      return;
    }
    // Changes the avatar as the lead does, announced by a system message as a rename is.
    // `?avatar=image|mark` picks one, and otherwise it switches between them.
    if (request.method === 'POST' && pathname === '/demo/avatar') {
      const kind = url.searchParams.get('avatar') ?? (snapshot.channel.avatar?.image ? 'mark' : 'image');
      const next = avatarFor(kind, snapshot.channel.id);
      if (!next) { json(response, 400, { error: 'Expected avatar=image or avatar=mark.' }); return; }
      serveAvatar(next);
      const timestamp = new Date().toISOString();
      const sequence = snapshot.channel.latestSequence + 1;
      const message = {
        id: crypto.randomUUID(), sequence, timestamp, sender: { type: 'system' },
        content: { type: 'channel_avatar_changed', actor: { type: 'agent', agentId: snapshot.lead.id }, avatar: next },
      };
      storedMessages.set(message.id, message);
      snapshot.messages = [...snapshot.messages, message].slice(-100);
      snapshot.revision++;
      Object.assign(snapshot.channel, { avatar: next, latestSequence: sequence, updatedAt: timestamp });
      publish({ type: 'message', revision: snapshot.revision, message });
      json(response, 201, message);
      return;
    }
    const bookmarkPath = `${channelPath}/bookmarks/`;
    if ((request.method === 'PUT' || request.method === 'DELETE') && pathname.startsWith(bookmarkPath)) {
      const segment = pathname.slice(bookmarkPath.length);
      const sequence = Number(segment);
      if (!/^[1-9]\d*$/.test(segment) || !Number.isSafeInteger(sequence)) {
        json(response, 400, { error: 'Invalid Channel request.' }); return;
      }
      const bookmarked = request.method === 'PUT';
      const current: number[] = snapshot.bookmarks;
      if (current.includes(sequence) !== bookmarked) {
        const message = [...olderMessages, ...snapshot.messages].find((candidate) => candidate.sequence === sequence);
        if (bookmarked && (!message || message.sender.type === 'system')) {
          json(response, 422, { error: 'Bookmark a user or agent message in this Channel.' }); return;
        }
        snapshot.bookmarks = bookmarked ? [...current, sequence].sort((left, right) => left - right)
          : current.filter((bookmark) => bookmark !== sequence);
        snapshot.revision++;
        publish({ type: 'bookmarks', bookmarks: snapshot.bookmarks, revision: snapshot.revision });
      }
      response.writeHead(204);
      response.end();
      return;
    }
    if (request.method === 'GET' && (pathname === '/' || pathname === '/demo-preview')) {
      response.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      response.end('<!doctype html><title>Toy Box workshop demo</title><main style="font:18px system-ui;max-width:640px;margin:12vh auto;padding:24px"><h1>Toy Box workshop demo</h1><p>This is an isolated client fixture. It never starts agents or contacts a model provider.</p><p>In a real channel, this action opens the Toy Box workspace or the channel preview.</p></main>');
      return;
    }
    json(response, 404, { error: 'Channel not found.' });
  });
  const heartbeat = setInterval(() => { for (const client of [...clients, ...[...watchers.values()].flatMap((set) => [...set])]) client.write(': keepalive\n\n'); }, 5000);
  heartbeat.unref();
  return {
    server,
    snapshot: () => structuredClone(snapshot),
    /** Calls `listener` after each change the channel's streams hear. */
    onChange(listener: () => void) { changeListeners.add(listener); },
    replace(next: Snapshot) {
      snapshot = structuredClone(next);
      replayHistory.length = 0;
      storedMessages.clear();
      for (const message of snapshot.messages) storedMessages.set(message.id, message);
      publish({ type: 'snapshot', state: snapshot });
    },
    setResource(url: string, content: string, type = 'text/markdown; charset=utf-8') { resources.set(url, { type, content }); publishResource(url); },
    deleteResource(url: string) { resources.delete(url); publishResource(url); },
    async close() {
      clearInterval(heartbeat);
      for (const client of [...clients, ...[...watchers.values()].flatMap((set) => [...set])]) client.end();
      await new Promise<void>((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
    },
  };
}

export type DemoServer = ReturnType<typeof createDemoServer>;
