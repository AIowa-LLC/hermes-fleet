import { createHandler, type Handler } from "../src/app.ts";
import { toBase64Url, toHex } from "../src/crypto.ts";
import type { Deps, Env, KVLike, LogEvent, RateLimitBinding } from "../src/types.ts";

export const TOPIC = "com.example.fleet.test";
export const BASE = "https://relay.example.test";

/** In-memory KV that records every write so tests can inspect persisted state. */
export class FakeKV implements KVLike {
  readonly data = new Map<string, { value: string; ttl?: number }>();
  puts = 0;
  async get(key: string) {
    return this.data.get(key)?.value ?? null;
  }
  async put(key: string, value: string, options?: { expirationTtl?: number }) {
    this.puts += 1;
    const entry: { value: string; ttl?: number } = { value };
    if (options?.expirationTtl !== undefined) entry.ttl = options.expirationTtl;
    this.data.set(key, entry);
  }
  async delete(key: string) {
    this.data.delete(key);
  }
  /** Every key and value concatenated, for "never persisted" assertions. */
  dump(): string {
    return [...this.data.entries()].map(([k, v]) => `${k}=${v.value}`).join("\n");
  }
}

export interface ApnsCall {
  url: string;
  headers: Record<string, string>;
  body: string;
}

export interface ApnsStub {
  calls: ApnsCall[];
  /** Queue of responses; the last one repeats. */
  responses: Array<{ status: number; reason?: string; headers?: Record<string, string>; throws?: boolean }>;
  fetch: Deps["fetch"];
}

export function makeApnsStub(): ApnsStub {
  const stub: ApnsStub = {
    calls: [],
    responses: [{ status: 200, headers: { "apns-id": "00000000-0000-4000-8000-000000000000" } }],
    fetch: async (input, init) => {
      stub.calls.push({
        url: input,
        headers: { ...(init.headers as Record<string, string>) },
        body: String(init.body ?? ""),
      });
      const next = stub.responses.length > 1 ? stub.responses.shift()! : stub.responses[0]!;
      if (next.throws) throw new Error("network down");
      return new Response(next.reason ? JSON.stringify({ reason: next.reason }) : "", {
        status: next.status,
        headers: next.headers ?? {},
      });
    },
  };
  return stub;
}

export async function generateP8(): Promise<{ pem: string; publicKey: CryptoKey }> {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, [
    "sign",
    "verify",
  ])) as CryptoKeyPair;
  const der = new Uint8Array((await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer);
  let bin = "";
  for (const b of der) bin += String.fromCharCode(b);
  const b64 = btoa(bin).replace(/(.{64})/g, "$1\n");
  return {
    pem: `-----BEGIN PRIVATE KEY-----\n${b64}\n-----END PRIVATE KEY-----`,
    publicKey: pair.publicKey,
  };
}

export const randomHex = (bytes: number) => toHex(crypto.getRandomValues(new Uint8Array(bytes)));
export const randomB64 = (bytes: number) => toBase64Url(crypto.getRandomValues(new Uint8Array(bytes)));

export interface Harness {
  handler: Handler;
  env: Env;
  kv: FakeKV;
  apns: ApnsStub;
  logs: LogEvent[];
  consoleLines: string[];
  clock: { ms: number };
  publicKey: CryptoKey;
  call(
    method: string,
    path: string,
    body?: unknown,
    headers?: Record<string, string>,
  ): Promise<{ status: number; json: any; headers: Headers }>;
  register(overrides?: Record<string, unknown>, headers?: Record<string, string>): Promise<{
    status: number;
    json: any;
    deviceToken: string;
  }>;
}

export async function makeHarness(
  envOverrides: Partial<Env> = {},
  depsOverrides: Partial<Deps> = {},
): Promise<Harness> {
  const kv = new FakeKV();
  const apns = makeApnsStub();
  const logs: LogEvent[] = [];
  const consoleLines: string[] = [];
  const clock = { ms: 1_800_000_000_000 };
  const { pem, publicKey } = await generateP8();
  const env: Env = {
    REGISTRY: kv,
    APNS_KEY_P8: pem,
    APNS_KEY_ID: "KEYID12345",
    APNS_TEAM_ID: "TEAMID1234",
    APNS_TOPIC: TOPIC,
    RELAY_STORAGE_KEY: randomB64(32),
    ...envOverrides,
  };
  const handler = createHandler({
    fetch: apns.fetch,
    now: () => clock.ms,
    log: (e) => {
      logs.push(e);
      consoleLines.push(JSON.stringify(e));
    },
    ...depsOverrides,
  });

  const h: Harness = {
    handler,
    env,
    kv,
    apns,
    logs,
    consoleLines,
    clock,
    publicKey,
    async call(method, path, body, headers = {}) {
      const init: RequestInit = { method, headers: { ...headers } };
      if (body !== undefined) {
        (init.headers as Record<string, string>)["content-type"] ??= "application/json";
        init.body = typeof body === "string" ? body : JSON.stringify(body);
      }
      const res = await handler.fetch(new Request(`${BASE}${path}`, init), env);
      const text = await res.text();
      return { status: res.status, json: text ? JSON.parse(text) : null, headers: res.headers };
    },
    async register(overrides = {}, headers = {}) {
      const deviceToken = (overrides.device_token as string | undefined) ?? randomHex(32);
      const res = await h.call(
        "POST",
        "/v1/register",
        {
          device_token: deviceToken,
          environment: "sandbox",
          bundle_id: TOPIC,
          relay_key_id: "key-1",
          ...overrides,
        },
        headers,
      );
      return { ...res, deviceToken };
    },
  };
  return h;
}

export function sendBody(relayDeviceId: string, overrides: Record<string, unknown> = {}, nowMs = 1_800_000_000_000) {
  return {
    relay_device_id: relayDeviceId,
    ciphertext: randomB64(120),
    push_type: "alert",
    priority: 10,
    expiry: Math.floor(nowMs / 1000) + 300,
    alert: { title_key: "approval" },
    ...overrides,
  };
}

export const auth = (capability: string) => ({ authorization: `Bearer ${capability}` });

/** Re-export so tests can build alternate rate-limit stubs. */
export type { RateLimitBinding };
