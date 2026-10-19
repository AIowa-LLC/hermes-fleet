/** Minimal KV surface used by the relay (structurally satisfied by Workers KV). */
export interface KVLike {
  get(key: string): Promise<string | null>;
  put(key: string, value: string, options?: { expirationTtl?: number }): Promise<void>;
  delete(key: string): Promise<void>;
}

/** Workers Rate Limiting binding surface. */
export interface RateLimitBinding {
  limit(options: { key: string }): Promise<{ success: boolean }>;
}

export interface Env {
  REGISTRY: KVLike;
  IP_LIMITER?: RateLimitBinding;
  REGISTER_LIMITER?: RateLimitBinding;
  SEND_LIMITER?: RateLimitBinding;

  // Secrets - supplied only through `wrangler secret put`.
  APNS_KEY_P8: string;
  APNS_KEY_ID: string;
  APNS_TEAM_ID: string;
  APNS_TOPIC: string;
  RELAY_STORAGE_KEY: string;

  // Optional non-secret tunables.
  REGISTRATION_TTL_SECONDS?: string;
}

export type ApnsEnvironment = "sandbox" | "production";
export type PushType = "alert" | "liveactivity" | "background";
export type TitleKey = "approval" | "clarify" | "done" | "cron";
export type LiveActivityEvent = "start" | "update" | "end";

/** Injectable side effects so tests are deterministic and offline. */
export interface Deps {
  fetch: (input: string, init: RequestInit) => Promise<Response>;
  /** Milliseconds since the epoch. */
  now: () => number;
  randomBytes: (length: number) => Uint8Array;
  /** Receives only route names and status codes. */
  log: (event: LogEvent) => void;
}

export interface LogEvent {
  route: string;
  status: number;
  /** Coarse machine-readable outcome such as `unregistered` or `rate_limited`. */
  outcome?: string;
}

export class HttpError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly extra: Record<string, unknown> = {},
    readonly headers: Record<string, string> = {},
  ) {
    super(message);
  }
}
