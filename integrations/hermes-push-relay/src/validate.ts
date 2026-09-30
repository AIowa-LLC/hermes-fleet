import { MAX_EXPIRY_SECONDS, TITLE_KEYS } from "./config.ts";
import {
  HttpError,
  type ApnsEnvironment,
  type LiveActivityEvent,
  type PushType,
  type TitleKey,
} from "./types.ts";

const bad = (code: string, message: string) => new HttpError(400, code, message);

type Json = Record<string, unknown>;

/** Parses an object body and rejects any field outside `allowed`. */
export function parseObject(text: string, allowed: readonly string[]): Json {
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    throw bad("invalid_json", "Request body must be valid JSON.");
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw bad("invalid_json", "Request body must be a JSON object.");
  }
  for (const key of Object.keys(value)) {
    if (!allowed.includes(key)) throw bad("unknown_field", "Request contains an unsupported field.");
  }
  return value as Json;
}

function str(obj: Json, key: string, pattern: RegExp, maxLength: number, optional = false): string | undefined {
  const v = obj[key];
  if (v === undefined || v === null) {
    if (optional) return undefined;
    throw bad("invalid_field", `Missing field: ${key}.`);
  }
  if (typeof v !== "string" || v.length === 0 || v.length > maxLength || !pattern.test(v)) {
    throw bad("invalid_field", `Invalid field: ${key}.`);
  }
  return v;
}

const HEX = /^[0-9a-fA-F]+$/;
const RELAY_ID = /^[A-Za-z0-9_-]{22}$/;
const KEY_ID = /^[A-Za-z0-9._:-]+$/;
const BUNDLE = /^[A-Za-z0-9.-]+$/;
const BASE64URL = /^[A-Za-z0-9_-]+$/;
const COLLAPSE = /^[A-Za-z0-9._:-]+$/;
const ACTIVITY_ID = /^[A-Za-z0-9-]+$/;
const IDENT = /^[A-Za-z_][A-Za-z0-9_]*$/;

export function relayIdOk(id: string): boolean {
  return RELAY_ID.test(id);
}

export interface RegisterBody {
  deviceToken: string;
  environment: ApnsEnvironment;
  bundleId: string;
  relayKeyId: string;
}

export function parseRegister(text: string): RegisterBody {
  const o = parseObject(text, ["device_token", "environment", "bundle_id", "relay_key_id"]);
  const deviceToken = str(o, "device_token", HEX, 200) as string;
  if (deviceToken.length < 64) throw bad("invalid_field", "Invalid field: device_token.");
  const environment = o.environment;
  if (environment !== "sandbox" && environment !== "production") {
    throw bad("invalid_field", "Invalid field: environment.");
  }
  const relayKeyId = str(o, "relay_key_id", KEY_ID, 64) as string;
  // The key id is part of the registration identity and doubles as a
  // possession check, so it must carry at least 128 bits (22 base64url chars).
  if (relayKeyId.length < 22) throw bad("invalid_field", "Invalid field: relay_key_id.");
  return {
    deviceToken: deviceToken.toLowerCase(),
    environment,
    bundleId: str(o, "bundle_id", BUNDLE, 155) as string,
    relayKeyId: relayKeyId,
  };
}

export interface LiveActivityRegisterBody {
  relayDeviceId: string;
  kind: "push_to_start" | "update";
  token: string;
  activityId?: string;
}

export function parseLiveActivityRegister(text: string): LiveActivityRegisterBody {
  const o = parseObject(text, ["relay_device_id", "kind", "token", "activity_id"]);
  const relayDeviceId = str(o, "relay_device_id", RELAY_ID, 22) as string;
  const kind = o.kind;
  if (kind !== "push_to_start" && kind !== "update") throw bad("invalid_field", "Invalid field: kind.");
  const token = str(o, "token", HEX, 512) as string;
  if (token.length < 32) throw bad("invalid_field", "Invalid field: token.");
  const activityId = str(o, "activity_id", ACTIVITY_ID, 64, true);
  if (kind === "update" && !activityId) throw bad("invalid_field", "Missing field: activity_id.");
  if (kind === "push_to_start" && activityId) throw bad("invalid_field", "Invalid field: activity_id.");
  return {
    relayDeviceId,
    kind,
    token: token.toLowerCase(),
    ...(activityId ? { activityId } : {}),
  };
}

export interface SendBody {
  relayDeviceId: string;
  ciphertext: string;
  collapseId?: string;
  pushType: PushType;
  priority: 5 | 10;
  expiry: number;
  titleKey?: TitleKey;
  liveActivity?: { event: LiveActivityEvent; activityId?: string; attributesType?: string };
}

export function parseSend(text: string, nowSeconds: number): SendBody {
  const o = parseObject(text, [
    "relay_device_id",
    "ciphertext",
    "collapse_id",
    "push_type",
    "priority",
    "expiry",
    "alert",
    "liveactivity",
  ]);
  const relayDeviceId = str(o, "relay_device_id", RELAY_ID, 22) as string;
  const ciphertext = str(o, "ciphertext", BASE64URL, 6000) as string;
  const collapseId = str(o, "collapse_id", COLLAPSE, 64, true);

  const pushType = o.push_type;
  if (pushType !== "alert" && pushType !== "liveactivity" && pushType !== "background") {
    throw bad("invalid_field", "Invalid field: push_type.");
  }
  const priority = o.priority;
  if (priority !== 5 && priority !== 10) throw bad("invalid_field", "Invalid field: priority.");
  if (pushType === "background" && priority !== 5) {
    throw bad("invalid_field", "Background pushes must use priority 5.");
  }

  const expiry = o.expiry;
  if (typeof expiry !== "number" || !Number.isInteger(expiry)) {
    throw bad("invalid_field", "Invalid field: expiry.");
  }
  if (expiry <= nowSeconds) throw bad("expired", "Request expiry has passed.");
  if (expiry > nowSeconds + MAX_EXPIRY_SECONDS) {
    throw bad("expiry_too_far", "Request expiry is too far in the future.");
  }

  let titleKey: TitleKey | undefined;
  if (o.alert !== undefined) {
    if (typeof o.alert !== "object" || o.alert === null || Array.isArray(o.alert)) {
      throw bad("invalid_field", "Invalid field: alert.");
    }
    const alert = o.alert as Json;
    for (const k of Object.keys(alert)) {
      if (k !== "title_key") throw bad("unknown_field", "Alert only accepts title_key.");
    }
    const tk = alert.title_key;
    if (typeof tk !== "string" || !(TITLE_KEYS as string[]).includes(tk)) {
      throw bad("invalid_field", "Invalid field: alert.title_key.");
    }
    titleKey = tk as TitleKey;
  }

  let liveActivity: SendBody["liveActivity"];
  if (o.liveactivity !== undefined) {
    if (typeof o.liveactivity !== "object" || o.liveactivity === null || Array.isArray(o.liveactivity)) {
      throw bad("invalid_field", "Invalid field: liveactivity.");
    }
    const la = o.liveactivity as Json;
    for (const k of Object.keys(la)) {
      if (!["event", "activity_id", "attributes_type"].includes(k)) {
        throw bad("unknown_field", "Request contains an unsupported field.");
      }
    }
    const event = la.event;
    if (event !== "start" && event !== "update" && event !== "end") {
      throw bad("invalid_field", "Invalid field: liveactivity.event.");
    }
    const activityId = str(la, "activity_id", ACTIVITY_ID, 64, true);
    const attributesType = str(la, "attributes_type", IDENT, 64, true);
    if (event === "start" && !attributesType) throw bad("invalid_field", "Missing field: attributes_type.");
    if (event !== "start" && !activityId) throw bad("invalid_field", "Missing field: activity_id.");
    liveActivity = {
      event,
      ...(activityId ? { activityId } : {}),
      ...(attributesType ? { attributesType } : {}),
    };
  }

  if (pushType === "alert" && !titleKey) throw bad("invalid_field", "alert.title_key is required.");
  if (pushType === "alert" && liveActivity) throw bad("invalid_field", "liveactivity is not valid here.");
  if (pushType === "background" && (titleKey || liveActivity)) {
    throw bad("invalid_field", "Background pushes carry only ciphertext.");
  }
  if (pushType === "liveactivity") {
    if (!liveActivity) throw bad("invalid_field", "liveactivity is required.");
    if (liveActivity.event === "start" && !titleKey) throw bad("invalid_field", "alert.title_key is required.");
  }

  return {
    relayDeviceId,
    ciphertext,
    ...(collapseId ? { collapseId } : {}),
    pushType,
    priority,
    expiry,
    ...(titleKey ? { titleKey } : {}),
    ...(liveActivity ? { liveActivity } : {}),
  };
}
