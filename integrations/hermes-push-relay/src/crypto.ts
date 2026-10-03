const encoder = new TextEncoder();
const decoder = new TextDecoder();

export function toBase64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function fromBase64Url(value: string): Uint8Array {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (value.length % 4)) % 4);
  const binary = atob(padded);
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
}

export function toHex(bytes: Uint8Array): string {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

/** Constant-time equality for equal-length byte strings. */
export function constantTimeEqual(a: Uint8Array, b: Uint8Array): boolean {
  let diff = a.length ^ b.length;
  const len = Math.max(a.length, b.length);
  for (let i = 0; i < len; i++) diff |= (a[i] ?? 0) ^ (b[i] ?? 0);
  return diff === 0;
}

/** Keys derived from the single RELAY_STORAGE_KEY secret via HKDF-SHA256. */
export interface StorageKeys {
  /** AES-256-GCM key sealing device/activity tokens at rest. */
  aes: CryptoKey;
  /** HMAC-SHA256 key for token index hashes and capability verifiers. */
  mac: CryptoKey;
}

export async function deriveStorageKeys(secret: string): Promise<StorageKeys> {
  let raw: Uint8Array;
  try {
    raw = fromBase64Url(secret.trim());
  } catch {
    throw new Error("RELAY_STORAGE_KEY must be base64/base64url");
  }
  if (raw.length < 32) throw new Error("RELAY_STORAGE_KEY must decode to at least 32 bytes");
  const base = await crypto.subtle.importKey("raw", raw, "HKDF", false, ["deriveKey"]);
  const salt = encoder.encode("hermes-push-relay/v1");
  const aes = await crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt, info: encoder.encode("aes-gcm-seal") },
    base,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"],
  );
  const mac = await crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt, info: encoder.encode("hmac-index") },
    base,
    { name: "HMAC", hash: "SHA-256", length: 256 },
    false,
    ["sign"],
  );
  return { aes, mac };
}

/** Keyed hash (salted by the secret-derived key) of a labelled value. */
export async function keyedHash(keys: StorageKeys, label: string, value: string): Promise<Uint8Array> {
  const sig = await crypto.subtle.sign("HMAC", keys.mac, encoder.encode(`${label}\u0000${value}`));
  return new Uint8Array(sig);
}

export async function seal(
  keys: StorageKeys,
  plaintext: string,
  aad: string,
  randomBytes: (n: number) => Uint8Array,
): Promise<string> {
  const iv = randomBytes(12);
  const ct = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv, additionalData: encoder.encode(aad) },
    keys.aes,
    encoder.encode(plaintext),
  );
  const out = new Uint8Array(iv.length + ct.byteLength);
  out.set(iv, 0);
  out.set(new Uint8Array(ct), iv.length);
  return toBase64Url(out);
}

export async function unseal(keys: StorageKeys, sealed: string, aad: string): Promise<string> {
  const raw = fromBase64Url(sealed);
  const iv = raw.slice(0, 12);
  const ct = raw.slice(12);
  const pt = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv, additionalData: encoder.encode(aad) },
    keys.aes,
    ct,
  );
  return decoder.decode(pt);
}
