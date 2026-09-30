import { ApnsAuth, sendToApns, type ApnsResult } from "./apns.ts";
import {
  ALERT_COPY,
  DEFAULT_REGISTRATION_TTL_SECONDS,
  FALLBACK_LIMITS,
  MAX_APNS_PAYLOAD_BYTES,
  MAX_REQUEST_BYTES,
} from "./config.ts";
import { deriveStorageKeys, type StorageKeys } from "./crypto.ts";
import { bindingLimiter, memoryLimiter, type Limiter } from "./limiter.ts";
import { Registry, type StoredRegistration } from "./registry.ts";
import { HttpError, type Deps, type Env, type LogEvent } from "./types.ts";
import {
  parseLiveActivityRegister,
  parseRegister,
  parseSend,
  relayIdOk,
  type SendBody,
} from "./validate.ts";

const encoder = new TextEncoder();
const RESERVED_ROUTE = "not_found";

const SECURITY_HEADERS: Record<string, string> = {
  "content-type": "application/json; charset=utf-8",
  "cache-control": "no-store",
  "strict-transport-security": "max-age=31536000",
  "x-content-type-options": "nosniff",
};

function json(status: number, body: unknown, extra: Record<string, string> = {}): Response {
  if (status === 204) return new Response(null, { status, headers: { ...SECURITY_HEADERS, ...extra } });
  return new Response(JSON.stringify(body), { status, headers: { ...SECURITY_HEADERS, ...extra } });
}

export const defaultDeps = (): Deps => ({
  fetch: (input, init) => fetch(input, init),
  now: () => Date.now(),
  randomBytes: (n) => crypto.getRandomValues(new Uint8Array(n)),
  // Route + status only. Never add request data here.
  log: (event) => console.log(JSON.stringify(event)),
});

interface Limiters {
  ip: Limiter;
  register: Limiter;
  send: Limiter;
}

export interface Handler {
  fetch(request: Request, env: Env): Promise<Response>;
}

export function createHandler(overrides: Partial<Deps> = {}): Handler {
  const deps: Deps = { ...defaultDeps(), ...overrides };
  const apnsAuth = new ApnsAuth(deps);
  const memory: Limiters = {
    ip: memoryLimiter(FALLBACK_LIMITS.ip.limit, FALLBACK_LIMITS.ip.windowSeconds, deps.now),
    register: memoryLimiter(FALLBACK_LIMITS.register.limit, FALLBACK_LIMITS.register.windowSeconds, deps.now),
    send: memoryLimiter(FALLBACK_LIMITS.send.limit, FALLBACK_LIMITS.send.windowSeconds, deps.now),
  };
  let keyCache: { secret: string; keys: Promise<StorageKeys> } | undefined;

  const limitersFor = (env: Env): Limiters => ({
    ip: env.IP_LIMITER ? bindingLimiter(env.IP_LIMITER) : memory.ip,
    register: env.REGISTER_LIMITER ? bindingLimiter(env.REGISTER_LIMITER) : memory.register,
    send: env.SEND_LIMITER ? bindingLimiter(env.SEND_LIMITER) : memory.send,
  });

  const storageKeys = (env: Env): Promise<StorageKeys> => {
    if (!keyCache || keyCache.secret !== env.RELAY_STORAGE_KEY) {
      keyCache = { secret: env.RELAY_STORAGE_KEY, keys: deriveStorageKeys(env.RELAY_STORAGE_KEY) };
    }
    return keyCache.keys;
  };

  async function readBody(request: Request): Promise<string> {
    const type = request.headers.get("content-type") ?? "";
    if (!/^application\/json(\s*;.*)?$/i.test(type)) {
      throw new HttpError(415, "unsupported_media_type", "Content-Type must be application/json.");
    }
    const declared = Number(request.headers.get("content-length") ?? "0");
    if (Number.isFinite(declared) && declared > MAX_REQUEST_BYTES) {
      throw new HttpError(413, "payload_too_large", "Request body too large.");
    }
    const text = await request.text();
    if (encoder.encode(text).length > MAX_REQUEST_BYTES) {
      throw new HttpError(413, "payload_too_large", "Request body too large.");
    }
    return text;
  }

  function bearer(request: Request): string {
    const header = request.headers.get("authorization") ?? "";
    const m = /^Bearer ([A-Za-z0-9_-]{16,128})$/.exec(header);
    if (!m) throw new HttpError(401, "missing_capability", "A send capability is required.");
    return m[1] as string;
  }

  const bearerOptional = (request: Request): string | undefined => {
    const m = /^Bearer ([A-Za-z0-9_-]{16,128})$/.exec(request.headers.get("authorization") ?? "");
    return m?.[1];
  };

  function ttlSeconds(env: Env): number {
    const n = Number(env.REGISTRATION_TTL_SECONDS);
    return Number.isInteger(n) && n >= 3600 ? n : DEFAULT_REGISTRATION_TTL_SECONDS;
  }

  const nowSec = () => Math.floor(deps.now() / 1000);

  // ---------------------------------------------------------------- register
  async function register(request: Request, env: Env, limiters: Limiters, ip: string): Promise<Response> {
    if (!(await limiters.register.allow(`reg:${ip}`))) throw rateLimited();
    const body = parseRegister(await readBody(request));
    if (body.bundleId !== env.APNS_TOPIC) {
      throw new HttpError(400, "bundle_id_not_allowed", "This relay does not serve that bundle id.");
    }
    const registry = new Registry(env.REGISTRY, await storageKeys(env), deps);
    const ttl = ttlSeconds(env);
    const expiresAt = nowSec() + ttl;
    const existing = await registry.findByToken(body.environment, body.bundleId, body.deviceToken);

    if (existing) {
      const presented = bearerOptional(request);
      if (presented && (await registry.verifyCapability(existing.record, presented))) {
        // Idempotent upsert: skip the KV write unless the record needs renewing.
        const remaining = existing.record.expiresAt - nowSec();
        if (remaining >= ttl / 2 && existing.record.relayKeyId === body.relayKeyId) {
          return json(200, { relay_device_id: existing.id, expires_at: existing.record.expiresAt });
        }
        const renewed: StoredRegistration = { ...existing.record, relayKeyId: body.relayKeyId, expiresAt };
        await registry.create(existing.id, renewed, body.deviceToken);
        return json(200, { relay_device_id: existing.id, expires_at: expiresAt });
      }
      // Same token without proof of the current capability: this is a fresh
      // install (or someone who learned the token). Rotate the capability so
      // any previously issued sender can no longer push to this device.
      const capability = registry.newCapability();
      const rotated: StoredRegistration = {
        v: 1,
        environment: body.environment,
        bundleId: body.bundleId,
        relayKeyId: body.relayKeyId,
        capHash: await registry.capabilityHash(capability),
        sealed: await registry.sealSecrets(existing.id, { deviceToken: body.deviceToken }),
        expiresAt,
      };
      await registry.create(existing.id, rotated, body.deviceToken);
      return json(201, { relay_device_id: existing.id, expires_at: expiresAt, send_capability: capability });
    }

    const id = registry.newDeviceId();
    const capability = registry.newCapability();
    const record: StoredRegistration = {
      v: 1,
      environment: body.environment,
      bundleId: body.bundleId,
      relayKeyId: body.relayKeyId,
      capHash: await registry.capabilityHash(capability),
      sealed: await registry.sealSecrets(id, { deviceToken: body.deviceToken }),
      expiresAt,
    };
    await registry.create(id, record, body.deviceToken);
    return json(201, { relay_device_id: id, expires_at: expiresAt, send_capability: capability });
  }

  // -------------------------------------------------------------- unregister
  async function unregister(request: Request, env: Env, id: string): Promise<Response> {
    if (!relayIdOk(id)) throw new HttpError(404, "unknown_device", "Unknown relay device.");
    const capability = bearer(request);
    const registry = new Registry(env.REGISTRY, await storageKeys(env), deps);
    const record = await registry.get(id);
    if (!record) {
      // Idempotent: deleting something already gone is success.
      await registry.verifyCapability(null, capability);
      return json(204, null);
    }
    if (!(await registry.verifyCapability(record, capability))) throw invalidCapability();
    await registry.remove(id, record);
    return json(204, null);
  }

  // ----------------------------------------------------- live activity tokens
  async function liveActivityRegister(request: Request, env: Env): Promise<Response> {
    const body = parseLiveActivityRegister(await readBody(request));
    const capability = bearer(request);
    const registry = new Registry(env.REGISTRY, await storageKeys(env), deps);
    const record = await registry.get(body.relayDeviceId);
    if (!record) throw new HttpError(404, "unknown_device", "Unknown relay device.");
    if (!(await registry.verifyCapability(record, capability))) throw invalidCapability();
    const secrets = await registry.openSecrets(body.relayDeviceId, record);
    const unchanged =
      body.kind === "push_to_start"
        ? secrets.startToken === body.token
        : secrets.activityTokens?.some((a) => a.id === body.activityId && a.token === body.token);
    if (!unchanged) {
      const next = Registry.withActivityToken(secrets, body.kind, body.token, body.activityId);
      record.sealed = await registry.sealSecrets(body.relayDeviceId, next);
      await registry.update(body.relayDeviceId, record);
    }
    return json(200, { relay_device_id: body.relayDeviceId, expires_at: record.expiresAt });
  }

  // -------------------------------------------------------------------- send
  function buildPayload(body: SendBody): string {
    const hf = { v: 1, ct: body.ciphertext };
    const alert = body.titleKey
      ? { title: ALERT_COPY[body.titleKey].title, body: ALERT_COPY[body.titleKey].body }
      : undefined;
    let payload: Record<string, unknown>;
    if (body.pushType === "alert") {
      const copy = ALERT_COPY[body.titleKey as keyof typeof ALERT_COPY];
      payload = {
        aps: {
          alert,
          sound: "default",
          "mutable-content": 1,
          category: copy.category,
        },
        hf,
      };
    } else if (body.pushType === "background") {
      payload = { aps: { "content-available": 1 }, hf };
    } else {
      const la = body.liveActivity as NonNullable<SendBody["liveActivity"]>;
      const aps: Record<string, unknown> = {
        timestamp: nowSec(),
        event: la.event,
        "content-state": { ct: body.ciphertext },
      };
      if (alert) aps.alert = alert;
      if (la.event === "start") {
        aps["attributes-type"] = la.attributesType;
        aps.attributes = {};
      }
      payload = { aps };
    }
    return JSON.stringify(payload);
  }

  async function send(request: Request, env: Env, limiters: Limiters): Promise<Response> {
    const body = parseSend(await readBody(request), nowSec());
    const capability = bearer(request);
    const registry = new Registry(env.REGISTRY, await storageKeys(env), deps);
    const record = await registry.get(body.relayDeviceId);
    if (!record) {
      await registry.verifyCapability(null, capability);
      throw new HttpError(404, "unknown_device", "Unknown relay device.");
    }
    if (!(await registry.verifyCapability(record, capability))) throw invalidCapability();
    if (!(await limiters.send.allow(`cap:${body.relayDeviceId}`))) throw rateLimited();

    const payload = buildPayload(body);
    if (encoder.encode(payload).length > MAX_APNS_PAYLOAD_BYTES) {
      throw new HttpError(413, "payload_too_large", "Payload exceeds the 3.5 KB relay limit.");
    }

    const secrets = await registry.openSecrets(body.relayDeviceId, record);
    let target = secrets.deviceToken;
    let topic = record.bundleId;
    if (body.pushType === "liveactivity") {
      const la = body.liveActivity as NonNullable<SendBody["liveActivity"]>;
      const token =
        la.event === "start"
          ? secrets.startToken
          : secrets.activityTokens?.find((a) => a.id === la.activityId)?.token;
      if (!token) throw new HttpError(404, "unknown_activity", "No live activity token registered.");
      target = token;
      topic = `${record.bundleId}.push-type.liveactivity`;
    }

    let result: ApnsResult;
    try {
      result = await sendToApns(deps, apnsAuth, env, {
        environment: record.environment,
        deviceToken: target,
        topic,
        pushType: body.pushType,
        priority: body.priority,
        expiration: body.expiry,
        ...(body.collapseId ? { collapseId: body.collapseId } : {}),
        payload,
      });
    } catch {
      throw new HttpError(502, "apns_unavailable", "APNs could not be reached.");
    }

    if (result.status === 200) {
      return json(200, { status: "accepted", ...(result.apnsId ? { apns_id: result.apnsId } : {}) });
    }
    if (result.status === 410) {
      if (body.pushType === "liveactivity") {
        const la = body.liveActivity as NonNullable<SendBody["liveActivity"]>;
        const next =
          la.event === "start"
            ? { ...secrets, startToken: undefined }
            : { ...secrets, activityTokens: secrets.activityTokens?.filter((a) => a.id !== la.activityId) };
        record.sealed = await registry.sealSecrets(body.relayDeviceId, next);
        await registry.update(body.relayDeviceId, record);
        throw new HttpError(410, "activity_unregistered", "The live activity token is no longer valid.");
      }
      await registry.remove(body.relayDeviceId, record);
      throw new HttpError(410, "unregistered", "The device token is no longer valid; registration removed.");
    }
    if (result.status === 429) {
      throw new HttpError(429, "apns_throttled", "APNs is throttling this relay.", {}, {
        "retry-after": String(result.retryAfter ?? 30),
      });
    }
    if (result.status === 401 || result.status === 403) {
      apnsAuth.invalidate();
      throw new HttpError(502, "relay_misconfigured", "The relay's APNs credentials were rejected.");
    }
    if (result.status >= 500) throw new HttpError(502, "apns_unavailable", "APNs is unavailable.");
    throw new HttpError(422, "apns_rejected", "APNs rejected the notification.", {
      ...(result.reason ? { reason: result.reason } : {}),
    });
  }

  const invalidCapability = () => new HttpError(401, "invalid_capability", "The send capability is not valid.");
  const rateLimited = () =>
    new HttpError(429, "rate_limited", "Too many requests.", {}, { "retry-after": "60" });

  // ------------------------------------------------------------------ router
  async function route(request: Request, env: Env, log: (r: string) => void): Promise<Response> {
    const url = new URL(request.url);
    if (url.protocol !== "https:") throw new HttpError(400, "https_required", "HTTPS is required.");
    for (const secret of ["APNS_KEY_P8", "APNS_KEY_ID", "APNS_TEAM_ID", "APNS_TOPIC", "RELAY_STORAGE_KEY"] as const) {
      if (!env[secret]) throw new HttpError(500, "relay_misconfigured", "The relay is not configured.");
    }
    const path = url.pathname.replace(/\/+$/, "") || "/";
    const method = request.method.toUpperCase();
    const ip = request.headers.get("cf-connecting-ip") ?? "unknown";
    const limiters = limitersFor(env);

    const allow = (methods: string[]) => {
      if (!methods.includes(method)) {
        throw new HttpError(405, "method_not_allowed", "Method not allowed.", {}, { allow: methods.join(", ") });
      }
    };

    if (path === "/healthz") {
      log("health");
      allow(["GET"]);
      return json(200, { status: "ok" });
    }
    if (path === "/v1/register") {
      log("register");
      allow(["POST"]);
      if (!(await limiters.ip.allow(`ip:${ip}`))) throw rateLimited();
      return register(request, env, limiters, ip);
    }
    if (path === "/v1/send") {
      log("send");
      allow(["POST"]);
      if (!(await limiters.ip.allow(`ip:${ip}`))) throw rateLimited();
      return send(request, env, limiters);
    }
    if (path === "/v1/liveactivity/register") {
      log("liveactivity_register");
      allow(["POST"]);
      if (!(await limiters.ip.allow(`ip:${ip}`))) throw rateLimited();
      return liveActivityRegister(request, env);
    }
    const del = /^\/v1\/register\/([^/]+)$/.exec(path);
    if (del) {
      log("unregister");
      allow(["DELETE"]);
      if (!(await limiters.ip.allow(`ip:${ip}`))) throw rateLimited();
      return unregister(request, env, decodeURIComponent(del[1] as string));
    }
    log(RESERVED_ROUTE);
    throw new HttpError(404, "not_found", "Not found.");
  }

  return {
    async fetch(request, env) {
      let routeName = RESERVED_ROUTE;
      let response: Response;
      let outcome: string | undefined;
      try {
        response = await route(request, env, (r) => (routeName = r));
      } catch (err) {
        if (err instanceof HttpError) {
          outcome = err.code;
          response = json(err.status, { error: err.code, message: err.message, ...err.extra }, err.headers);
        } else {
          // Never surface (or log) the underlying error: it could embed request data.
          outcome = "internal_error";
          response = json(500, { error: "internal_error", message: "Internal error." });
        }
      }
      const event: LogEvent = { route: routeName, status: response.status };
      if (outcome) event.outcome = outcome;
      deps.log(event);
      return response;
    },
  };
}
