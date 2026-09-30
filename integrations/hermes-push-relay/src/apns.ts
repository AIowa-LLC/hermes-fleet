import { APNS_HOSTS, JWT_MAX_AGE_SECONDS } from "./config.ts";
import { toBase64Url } from "./crypto.ts";
import type { ApnsEnvironment, Deps, Env, PushType } from "./types.ts";

const encoder = new TextEncoder();

export interface ApnsRequest {
  environment: ApnsEnvironment;
  deviceToken: string;
  topic: string;
  pushType: PushType;
  priority: 5 | 10;
  /** Absolute unix seconds (apns-expiration). */
  expiration: number;
  collapseId?: string;
  payload: string;
}

export interface ApnsResult {
  status: number;
  /** APNs `reason` enum string on failure (e.g. `Unregistered`). */
  reason?: string;
  apnsId?: string;
  retryAfter?: number;
}

function pemToPkcs8(pem: string): Uint8Array {
  const body = pem
    .replace(/-----BEGIN [A-Z ]*PRIVATE KEY-----/, "")
    .replace(/-----END [A-Z ]*PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  const binary = atob(body);
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
}

/**
 * Provider-token (ES256 JWT) cache. One instance lives per handler/isolate; the
 * token is reused for at most 50 minutes (APNs rejects tokens older than an
 * hour and throttles regeneration more often than every 20 minutes).
 */
export class ApnsAuth {
  private cached?: { token: string; issuedAt: number; keyId: string; teamId: string };
  private keyPromise?: { pem: string; key: Promise<CryptoKey> };

  constructor(private readonly deps: Pick<Deps, "now">) {}

  invalidate(): void {
    this.cached = undefined;
  }

  async token(env: Pick<Env, "APNS_KEY_P8" | "APNS_KEY_ID" | "APNS_TEAM_ID">): Promise<string> {
    const nowSec = Math.floor(this.deps.now() / 1000);
    const c = this.cached;
    if (
      c &&
      c.keyId === env.APNS_KEY_ID &&
      c.teamId === env.APNS_TEAM_ID &&
      nowSec - c.issuedAt < JWT_MAX_AGE_SECONDS
    ) {
      return c.token;
    }
    if (!this.keyPromise || this.keyPromise.pem !== env.APNS_KEY_P8) {
      this.keyPromise = {
        pem: env.APNS_KEY_P8,
        key: crypto.subtle.importKey(
          "pkcs8",
          pemToPkcs8(env.APNS_KEY_P8),
          { name: "ECDSA", namedCurve: "P-256" },
          false,
          ["sign"],
        ),
      };
    }
    const header = toBase64Url(encoder.encode(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID })));
    const claims = toBase64Url(encoder.encode(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: nowSec })));
    const signingInput = `${header}.${claims}`;
    const key = await this.keyPromise.key;
    // WebCrypto ECDSA emits the raw r||s form that JWS ES256 requires.
    const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, encoder.encode(signingInput));
    const token = `${signingInput}.${toBase64Url(new Uint8Array(sig))}`;
    this.cached = { token, issuedAt: nowSec, keyId: env.APNS_KEY_ID, teamId: env.APNS_TEAM_ID };
    return token;
  }
}

/** Sends one notification; the caller interprets the status/reason. */
export async function sendToApns(
  deps: Deps,
  auth: ApnsAuth,
  env: Pick<Env, "APNS_KEY_P8" | "APNS_KEY_ID" | "APNS_TEAM_ID">,
  req: ApnsRequest,
): Promise<ApnsResult> {
  const attempt = async (): Promise<ApnsResult> => {
    const jwt = await auth.token(env);
    const headers: Record<string, string> = {
      authorization: `bearer ${jwt}`,
      "apns-topic": req.topic,
      "apns-push-type": req.pushType,
      "apns-priority": String(req.priority),
      "apns-expiration": String(req.expiration),
      "content-type": "application/json",
    };
    if (req.collapseId) headers["apns-collapse-id"] = req.collapseId;
    const res = await deps.fetch(
      `${APNS_HOSTS[req.environment]}/3/device/${req.deviceToken}`,
      { method: "POST", headers, body: req.payload },
    );
    const result: ApnsResult = { status: res.status };
    const apnsId = res.headers.get("apns-id");
    if (apnsId) result.apnsId = apnsId;
    if (res.status !== 200) {
      try {
        const body = (await res.json()) as { reason?: unknown };
        if (typeof body.reason === "string" && /^[A-Za-z]{1,64}$/.test(body.reason)) {
          result.reason = body.reason;
        }
      } catch {
        // APNs error bodies are best effort.
      }
      const retry = Number(res.headers.get("retry-after"));
      if (Number.isFinite(retry) && retry > 0) result.retryAfter = retry;
    }
    return result;
  };

  let result = await attempt();
  if (result.status === 403 && result.reason === "ExpiredProviderToken") {
    auth.invalidate();
    result = await attempt();
  }
  return result;
}
