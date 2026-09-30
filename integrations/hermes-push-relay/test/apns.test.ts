import { describe, expect, it } from "vitest";
import { ApnsAuth } from "../src/apns.ts";
import { fromBase64Url } from "../src/crypto.ts";
import { generateP8 } from "./helpers.ts";

const decode = (part: string) => JSON.parse(new TextDecoder().decode(fromBase64Url(part)));

describe("APNs provider token", () => {
  it("signs a verifiable ES256 JWT with kid and iss/iat claims", async () => {
    const { pem, publicKey } = await generateP8();
    const clock = { ms: 1_800_000_000_000 };
    const auth = new ApnsAuth({ now: () => clock.ms });
    const jwt = await auth.token({ APNS_KEY_P8: pem, APNS_KEY_ID: "KEYID12345", APNS_TEAM_ID: "TEAMID1234" });
    const [h, c, s] = jwt.split(".") as [string, string, string];
    expect(decode(h)).toEqual({ alg: "ES256", kid: "KEYID12345" });
    expect(decode(c)).toEqual({ iss: "TEAMID1234", iat: 1_800_000_000 });
    const sig = fromBase64Url(s);
    expect(sig).toHaveLength(64); // raw r||s, as JWS requires
    const ok = await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      publicKey,
      sig,
      new TextEncoder().encode(`${h}.${c}`),
    );
    expect(ok).toBe(true);
  });

  it("caches the token and refreshes it at 50 minutes", async () => {
    const { pem } = await generateP8();
    const clock = { ms: 1_800_000_000_000 };
    const auth = new ApnsAuth({ now: () => clock.ms });
    const env = { APNS_KEY_P8: pem, APNS_KEY_ID: "KEYID12345", APNS_TEAM_ID: "TEAMID1234" };
    const first = await auth.token(env);
    clock.ms += 49 * 60 * 1000;
    expect(await auth.token(env)).toBe(first);
    clock.ms += 2 * 60 * 1000; // 51 minutes since issue
    const refreshed = await auth.token(env);
    expect(refreshed).not.toBe(first);
    expect(decode(refreshed.split(".")[1] as string).iat).toBe(1_800_000_000 + 51 * 60);
  });
});
