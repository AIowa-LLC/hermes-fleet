import { KV_MIN_TTL_SECONDS, MAX_ACTIVITY_TOKENS } from "./config.ts";
import {
  constantTimeEqual,
  fromBase64Url,
  keyedHash,
  seal,
  toBase64Url,
  toHex,
  unseal,
  type StorageKeys,
} from "./crypto.ts";
import type { ApnsEnvironment, Deps, KVLike } from "./types.ts";

/**
 * Everything the relay persists about a registration. There is deliberately no
 * gateway identifier, no ciphertext, no plaintext token and no capability
 * secret: the capability is kept only as a keyed hash and every APNs token is
 * AES-GCM sealed under a key derived from RELAY_STORAGE_KEY.
 */
export interface StoredRegistration {
  v: 1;
  environment: ApnsEnvironment;
  bundleId: string;
  relayKeyId: string;
  /** base64url HMAC(capability). */
  capHash: string;
  /** base64url iv||AES-GCM(JSON of TokenSecrets), AAD = relay_device_id. */
  sealed: string;
  /** Unix seconds. */
  expiresAt: number;
}

export interface TokenSecrets {
  deviceToken: string;
  startToken?: string;
  activityTokens?: Array<{ id: string; token: string }>;
}

const recordKey = (id: string) => `d:${id}`;

export class Registry {
  constructor(
    private readonly kv: KVLike,
    private readonly keys: StorageKeys,
    private readonly deps: Pick<Deps, "now" | "randomBytes">,
  ) {}

  newDeviceId(): string {
    return toBase64Url(this.deps.randomBytes(16));
  }

  newCapability(): string {
    return toBase64Url(this.deps.randomBytes(32));
  }

  async capabilityHash(capability: string): Promise<string> {
    return toBase64Url(await keyedHash(this.keys, "cap", capability));
  }

  /** Constant-time capability check against the stored verifier. */
  async verifyCapability(record: StoredRegistration | null, capability: string): Promise<boolean> {
    // Always compute the hash and compare, even when the record is missing, so
    // response timing does not reveal whether a device id exists.
    const presented = await keyedHash(this.keys, "cap", capability);
    const stored = record ? fromBase64Url(record.capHash) : new Uint8Array(32);
    const equal = constantTimeEqual(presented, stored);
    return record !== null && equal;
  }

  private async indexKey(environment: ApnsEnvironment, bundleId: string, deviceToken: string) {
    const h = await keyedHash(this.keys, "token-index", `${environment}\u0000${bundleId}\u0000${deviceToken}`);
    return `t:${toHex(h)}`;
  }

  private ttlFor(expiresAt: number): number {
    const remaining = expiresAt - Math.floor(this.deps.now() / 1000);
    return Math.max(KV_MIN_TTL_SECONDS, remaining);
  }

  async get(id: string): Promise<StoredRegistration | null> {
    const raw = await this.kv.get(recordKey(id));
    if (!raw) return null;
    try {
      const rec = JSON.parse(raw) as StoredRegistration;
      if (rec.v !== 1) return null;
      // KV TTL is best effort on the read path; enforce expiry ourselves.
      if (rec.expiresAt <= Math.floor(this.deps.now() / 1000)) return null;
      return rec;
    } catch {
      return null;
    }
  }

  async openSecrets(id: string, record: StoredRegistration): Promise<TokenSecrets> {
    return JSON.parse(await unseal(this.keys, record.sealed, id)) as TokenSecrets;
  }

  async sealSecrets(id: string, secrets: TokenSecrets): Promise<string> {
    return seal(this.keys, JSON.stringify(secrets), id, this.deps.randomBytes);
  }

  async findByToken(
    environment: ApnsEnvironment,
    bundleId: string,
    deviceToken: string,
  ): Promise<{ id: string; record: StoredRegistration } | null> {
    const id = await this.kv.get(await this.indexKey(environment, bundleId, deviceToken));
    if (!id) return null;
    const record = await this.get(id);
    return record ? { id, record } : null;
  }

  /** Writes the record and (re)writes the salted token-hash index entry. */
  async create(id: string, record: StoredRegistration, deviceToken: string): Promise<void> {
    const ttl = this.ttlFor(record.expiresAt);
    await this.kv.put(recordKey(id), JSON.stringify(record), { expirationTtl: ttl });
    await this.kv.put(await this.indexKey(record.environment, record.bundleId, deviceToken), id, {
      expirationTtl: ttl,
    });
  }

  /** Rewrites the record only (used for activity tokens; TTL unchanged). */
  async update(id: string, record: StoredRegistration): Promise<void> {
    await this.kv.put(recordKey(id), JSON.stringify(record), { expirationTtl: this.ttlFor(record.expiresAt) });
  }

  async remove(id: string, record: StoredRegistration): Promise<void> {
    try {
      const { deviceToken } = await this.openSecrets(id, record);
      await this.kv.delete(await this.indexKey(record.environment, record.bundleId, deviceToken));
    } catch {
      // A record that cannot be opened still gets deleted below; its index
      // entry expires with its TTL.
    }
    await this.kv.delete(recordKey(id));
  }

  /** Adds/replaces an activity token, evicting the oldest beyond the cap. */
  static withActivityToken(
    secrets: TokenSecrets,
    kind: "push_to_start" | "update",
    token: string,
    activityId?: string,
  ): TokenSecrets {
    if (kind === "push_to_start") return { ...secrets, startToken: token };
    const list = (secrets.activityTokens ?? []).filter((a) => a.id !== activityId);
    list.push({ id: activityId as string, token });
    while (list.length > MAX_ACTIVITY_TOKENS) list.shift();
    return { ...secrets, activityTokens: list };
  }
}
