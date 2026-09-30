import type { TitleKey } from "./types.ts";

/**
 * Fixed alert copy. This table is the ONLY source of visible notification
 * text: senders pick a key, never supply strings. The device's Notification
 * Service Extension replaces the body after decrypting the sealed payload.
 */
export const ALERT_COPY: Readonly<
  Record<TitleKey, { title: string; body: string; category: string }>
> = Object.freeze({
  approval: {
    title: "Approval needed",
    body: "Open Hermes Fleet to review.",
    category: "hf.approval",
  },
  clarify: {
    title: "Your agent has a question",
    body: "Open Hermes Fleet to answer.",
    category: "hf.clarify",
  },
  done: {
    title: "Task finished",
    body: "Open Hermes Fleet to see the result.",
    category: "hf.done",
  },
  cron: {
    title: "Scheduled job finished",
    body: "Open Hermes Fleet to see the result.",
    category: "hf.cron",
  },
});

export const TITLE_KEYS = Object.keys(ALERT_COPY) as TitleKey[];

/** Request body cap for every endpoint. */
export const MAX_REQUEST_BYTES = 8 * 1024;
/** Maximum serialized APNs payload the relay will forward (3.5 KB). */
export const MAX_APNS_PAYLOAD_BYTES = 3584;
/** Maximum distance in the future a send `expiry` may be (24 h). */
export const MAX_EXPIRY_SECONDS = 24 * 60 * 60;
/** Default registration lifetime (60 days) and Workers KV minimum TTL. */
export const DEFAULT_REGISTRATION_TTL_SECONDS = 60 * 24 * 60 * 60;
export const KV_MIN_TTL_SECONDS = 60;
/** Refresh JWT well inside APNs' 60 minute limit (and beyond its 20 minute floor). */
export const JWT_MAX_AGE_SECONDS = 50 * 60;
/** Maximum live-activity update tokens retained per registration. */
export const MAX_ACTIVITY_TOKENS = 8;

export const APNS_HOSTS = {
  production: "https://api.push.apple.com",
  sandbox: "https://api.sandbox.push.apple.com",
} as const;

/** Fallback (per-isolate) limiter settings when a rate-limit binding is absent. */
export const FALLBACK_LIMITS = {
  ip: { limit: 120, windowSeconds: 60 },
  register: { limit: 10, windowSeconds: 60 },
  send: { limit: 30, windowSeconds: 60 },
} as const;
