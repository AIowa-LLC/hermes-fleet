import { describe, expect, it, vi } from "vitest";
import { defaultDeps } from "../src/app.ts";
import { ALERT_COPY, MAX_APNS_PAYLOAD_BYTES } from "../src/config.ts";
import { fromBase64Url } from "../src/crypto.ts";
import { auth, makeHarness, randomB64, randomHex, sendBody, TOPIC } from "./helpers.ts";

async function registered(h: Awaited<ReturnType<typeof makeHarness>>) {
  const res = await h.register();
  expect(res.status).toBe(201);
  return {
    id: res.json.relay_device_id as string,
    cap: res.json.send_capability as string,
    deviceToken: res.deviceToken,
    keyId: res.keyId,
  };
}

describe("register / unregister", () => {
  it("registers a device and returns id, expiry and a 256-bit capability", async () => {
    const h = await makeHarness();
    const res = await h.register();
    expect(res.status).toBe(201);
    expect(res.json.relay_device_id).toMatch(/^[A-Za-z0-9_-]{22}$/);
    expect(res.json.expires_at).toBe(1_800_000_000 + 60 * 24 * 3600);
    expect(fromBase64Url(res.json.send_capability)).toHaveLength(32);
  });

  it("validates fields and the bundle id", async () => {
    const h = await makeHarness();
    expect((await h.register({ environment: "staging" })).status).toBe(400);
    expect((await h.register({ device_token: "zz" })).status).toBe(400);
    expect((await h.register({ relay_key_id: "bad key!" })).status).toBe(400);
    // Short key ids are refused: the id is part of the registration identity.
    expect((await h.register({ relay_key_id: "key-1" })).status).toBe(400);
    expect((await h.register({ extra: "x" })).json.error).toBe("unknown_field");
    const other = await h.register({ bundle_id: "com.example.other" });
    expect(other.status).toBe(400);
    expect(other.json.error).toBe("bundle_id_not_allowed");
  });

  it("requires JSON content type and rejects oversized bodies", async () => {
    const h = await makeHarness();
    const wrongType = await h.call("POST", "/v1/register", "{}", { "content-type": "text/plain" });
    expect(wrongType.status).toBe(415);
    const big = await h.call("POST", "/v1/register", JSON.stringify({ pad: "x".repeat(9000) }));
    expect(big.status).toBe(413);
  });

  it("is an idempotent upsert: presenting the capability does not write or re-issue", async () => {
    const h = await makeHarness();
    const first = await registered(h);
    const putsAfterFirst = h.kv.puts;
    const again = await h.register(
      { device_token: first.deviceToken, relay_key_id: first.keyId },
      auth(first.cap),
    );
    expect(again.status).toBe(200);
    expect(again.json.relay_device_id).toBe(first.id);
    expect(again.json.send_capability).toBeUndefined();
    expect(h.kv.puts).toBe(putsAfterFirst);
  });

  it("renews the TTL once half the lifetime has elapsed", async () => {
    const h = await makeHarness();
    const first = await registered(h);
    h.clock.ms += 35 * 24 * 3600 * 1000;
    const again = await h.register(
      { device_token: first.deviceToken, relay_key_id: first.keyId },
      auth(first.cap),
    );
    expect(again.status).toBe(200);
    expect(again.json.expires_at).toBe(1_800_000_000 + (35 + 60) * 24 * 3600);
    expect(again.json.send_capability).toBeUndefined();
  });

  it("rotates the capability only for the same token AND key id without proof", async () => {
    const h = await makeHarness();
    const first = await registered(h);
    const second = await h.register({ device_token: first.deviceToken, relay_key_id: first.keyId });
    expect(second.status).toBe(201);
    expect(second.json.relay_device_id).toBe(first.id);
    expect(second.json.send_capability).not.toBe(first.cap);
    const oldCap = await h.call("POST", "/v1/send", sendBody(first.id), auth(first.cap));
    expect(oldCap.status).toBe(401);
    const newCap = await h.call("POST", "/v1/send", sendBody(first.id), auth(second.json.send_capability));
    expect(newCap.status).toBe(200);
  });

  it("does not let someone who only knows the device token disturb an existing registration", async () => {
    const h = await makeHarness();
    const legit = await registered(h);
    // Attacker knows the token but not the registration's key id.
    const attacker = await h.register({ device_token: legit.deviceToken });
    expect(attacker.status).toBe(201);
    expect(attacker.json.relay_device_id).not.toBe(legit.id);
    // The legitimate capability keeps working and is not rotated.
    const res = await h.call("POST", "/v1/send", sendBody(legit.id), auth(legit.cap));
    expect(res.status).toBe(200);
    // Capabilities are per registration: the attacker's does not open the legit one.
    const cross = await h.call("POST", "/v1/send", sendBody(legit.id), auth(attacker.json.send_capability));
    expect(cross.status).toBe(401);
  });

  it("keeps registrations for the same device token independent per gateway", async () => {
    const h = await makeHarness();
    const token = randomHex(32);
    const gwA = await h.register({ device_token: token });
    const gwB = await h.register({ device_token: token });
    expect(gwA.json.relay_device_id).not.toBe(gwB.json.relay_device_id);
    expect((await h.call("DELETE", `/v1/register/${gwA.json.relay_device_id}`, undefined, auth(gwA.json.send_capability))).status).toBe(204);
    // Removing gateway A leaves gateway B's registration working.
    const res = await h.call("POST", "/v1/send", sendBody(gwB.json.relay_device_id), auth(gwB.json.send_capability));
    expect(res.status).toBe(200);
    expect(h.apns.calls[0]!.url.endsWith(`/3/device/${token}`)).toBe(true);
    expect((await h.call("POST", "/v1/send", sendBody(gwA.json.relay_device_id), auth(gwA.json.send_capability))).status).toBe(404);
  });

  it("unregisters with the capability and is idempotent afterwards", async () => {
    const h = await makeHarness();
    const r = await registered(h);
    expect((await h.call("DELETE", `/v1/register/${r.id}`, undefined, auth("x".repeat(43)))).status).toBe(401);
    expect(h.kv.data.size).toBe(2);
    expect((await h.call("DELETE", `/v1/register/${r.id}`, undefined, auth(r.cap))).status).toBe(204);
    expect(h.kv.data.size).toBe(0);
    expect((await h.call("DELETE", `/v1/register/${r.id}`, undefined, auth(r.cap))).status).toBe(204);
    const send = await h.call("POST", "/v1/send", sendBody(r.id), auth(r.cap));
    expect(send.status).toBe(404);
    expect(send.json.error).toBe("unknown_device");
  });
});

describe("send", () => {
  it("forwards a generic alert with opaque ciphertext and minimal APNs headers", async () => {
    const h = await makeHarness();
    const r = await registered(h);
    const body = sendBody(r.id, { collapse_id: "req-1" });
    const res = await h.call("POST", "/v1/send", body, auth(r.cap));
    expect(res.status).toBe(200);
    expect(res.json.status).toBe("accepted");
    expect(h.apns.calls).toHaveLength(1);
    const call = h.apns.calls[0]!;
    expect(call.url).toBe(`https://api.sandbox.push.apple.com/3/device/${r.deviceToken}`);
    expect(call.headers["apns-topic"]).toBe(TOPIC);
    expect(call.headers["apns-push-type"]).toBe("alert");
    expect(call.headers["apns-priority"]).toBe("10");
    expect(call.headers["apns-expiration"]).toBe(String(body.expiry));
    expect(call.headers["apns-collapse-id"]).toBe("req-1");
    expect(call.headers.authorization).toMatch(/^bearer [\w-]+\.[\w-]+\.[\w-]+$/);
    const payload = JSON.parse(call.body);
    expect(payload).toEqual({
      aps: {
        alert: { title: ALERT_COPY.approval.title, body: ALERT_COPY.approval.body },
        sound: "default",
        "mutable-content": 1,
        category: "hf.approval",
      },
      hf: { v: 1, ct: body.ciphertext },
    });
  });

  it("uses the production host for production registrations", async () => {
    const h = await makeHarness();
    const reg = await h.register({ environment: "production" });
    await h.call("POST", "/v1/send", sendBody(reg.json.relay_device_id), auth(reg.json.send_capability));
    expect(h.apns.calls[0]!.url.startsWith("https://api.push.apple.com/3/device/")).toBe(true);
  });

  it("builds alert copy only from the fixed title_key table", async () => {
    const h = await makeHarness();
    const r = await registered(h);
    for (const key of Object.keys(ALERT_COPY) as Array<keyof typeof ALERT_COPY>) {
      h.apns.calls.length = 0;
      const res = await h.call("POST", "/v1/send", sendBody(r.id, { alert: { title_key: key } }), auth(r.cap));
      expect(res.status).toBe(200);
      const alert = JSON.parse(h.apns.calls[0]!.body).aps.alert;
      expect(alert).toEqual({ title: ALERT_COPY[key].title, body: ALERT_COPY[key].body });
    }
    const unknownKey = await h.call("POST", "/v1/send", sendBody(r.id, { alert: { title_key: "rm -rf" } }), auth(r.cap));
    expect(unknownKey.status).toBe(400);
    // Client-supplied free text is refused outright, never forwarded.
    const freeText = await h.call(
      "POST",
      "/v1/send",
      sendBody(r.id, { alert: { title_key: "done", title: "Secret plan", body: "hi" } }),
      auth(r.cap),
    );
    expect(freeText.status).toBe(400);
    expect(freeText.json.error).toBe("unknown_field");
    const topLevelText = await h.call("POST", "/v1/send", sendBody(r.id, { body: "leak" }), auth(r.cap));
    expect(topLevelText.status).toBe(400);
    expect(h.apns.calls.some((c) => c.body.includes("Secret plan") || c.body.includes("leak"))).toBe(false);
  });

  it("rejects payloads over 3.5 KB and any oversized request", async () => {
    const h = await makeHarness();
    const r = await registered(h);
    // 4000 base64url chars pass field validation but push the APNs payload past 3.5 KB.
    const tooBig = await h.call("POST", "/v1/send", sendBody(r.id, { ciphertext: randomB64(3000) }), auth(r.cap));
    expect(tooBig.status).toBe(413);
    expect(tooBig.json.error).toBe("payload_too_large");
    const justFits = await h.call("POST", "/v1/send", sendBody(r.id, { ciphertext: randomB64(1500) }), auth(r.cap));
    expect(justFits.status).toBe(200);
    expect(new TextEncoder().encode(h.apns.calls.at(-1)!.body).length).toBeLessThanOrEqual(MAX_APNS_PAYLOAD_BYTES);
    const huge = await h.call("POST", "/v1/send", sendBody(r.id, { ciphertext: randomB64(9000) }), auth(r.cap));
    expect(huge.status).toBe(413);
    expect(h.apns.calls).toHaveLength(1);
  });

  it("rejects missing or bad capabilities without contacting APNs", async () => {
    const h = await makeHarness();
    const r = await registered(h);
    const missing = await h.call("POST", "/v1/send", sendBody(r.id));
    expect(missing.status).toBe(401);
    expect(missing.json.error).toBe("missing_capability");
    const wrong = await h.call("POST", "/v1/send", sendBody(r.id), auth(randomB64(32)));
    expect(wrong.status).toBe(401);
    expect(wrong.json.error).toBe("invalid_capability");
    // A capability from another registration is not valid for this device.
    const other = await registered(h);
    const cross = await h.call("POST", "/v1/send", sendBody(r.id), auth(other.cap));
    expect(cross.status).toBe(401);
    const malformed = await h.call("POST", "/v1/send", sendBody(r.id), { authorization: "Basic abc" });
    expect(malformed.status).toBe(401);
    expect(h.apns.calls).toHaveLength(0);
  });

  it("enforces expiry: expired and too-far-future requests are rejected", async () => {
    const h = await makeHarness();
    const r = await registered(h);
    const now = 1_800_000_000;
    const expired = await h.call("POST", "/v1/send", sendBody(r.id, { expiry: now - 1 }), auth(r.cap));
    expect(expired.status).toBe(400);
    expect(expired.json.error).toBe("expired");
    const zero = await h.call("POST", "/v1/send", sendBody(r.id, { expiry: 0 }), auth(r.cap));
    expect(zero.json.error).toBe("expired");
    const far = await h.call("POST", "/v1/send", sendBody(r.id, { expiry: now + 3 * 24 * 3600 }), auth(r.cap));
    expect(far.json.error).toBe("expiry_too_far");
    // A captured request cannot be replayed once its expiry passes.
    const body = sendBody(r.id, { expiry: now + 60 });
    expect((await h.call("POST", "/v1/send", body, auth(r.cap))).status).toBe(200);
    h.clock.ms += 61_000;
    expect((await h.call("POST", "/v1/send", body, auth(r.cap))).json.error).toBe("expired");
    expect(h.apns.calls).toHaveLength(1);
  });

  it("validates push types, priority and background rules", async () => {
    const h = await makeHarness();
    const r = await registered(h);
    const send = (o: Record<string, unknown>) => h.call("POST", "/v1/send", sendBody(r.id, o), auth(r.cap));
    expect((await send({ push_type: "voip" })).status).toBe(400);
    expect((await send({ priority: 7 })).status).toBe(400);
    expect((await send({ alert: undefined })).status).toBe(400);
    expect((await send({ push_type: "background", priority: 10, alert: undefined })).status).toBe(400);
    expect((await send({ push_type: "background", priority: 5 })).status).toBe(400); // alert not allowed
    const bg = await send({ push_type: "background", priority: 5, alert: undefined });
    expect(bg.status).toBe(200);
    const call = h.apns.calls.at(-1)!;
    expect(call.headers["apns-push-type"]).toBe("background");
    expect(call.headers["apns-priority"]).toBe("5");
    expect(JSON.parse(call.body).aps).toEqual({ "content-available": 1 });
    expect((await send({ collapse_id: "x".repeat(65) })).status).toBe(400);
    expect((await send({ ciphertext: "not base64url!" })).status).toBe(400);
  });

  it("supports a sealed background withdrawal that reuses the alert's collapse id", async () => {
    const h = await makeHarness();
    const r = await registered(h);
    const collapse = "req-7f3a9c21";
    const alert = await h.call("POST", "/v1/send", sendBody(r.id, { collapse_id: collapse }), auth(r.cap));
    expect(alert.status).toBe(200);
    const withdrawCt = randomB64(96);
    const withdraw = await h.call(
      "POST",
      "/v1/send",
      sendBody(r.id, {
        push_type: "background",
        priority: 5,
        alert: undefined,
        collapse_id: collapse,
        ciphertext: withdrawCt,
      }),
      auth(r.cap),
    );
    expect(withdraw.status).toBe(200);
    const [alertCall, withdrawCall] = h.apns.calls as [(typeof h.apns.calls)[0], (typeof h.apns.calls)[0]];
    expect(withdrawCall.url).toBe(alertCall.url); // same device token
    expect(withdrawCall.headers["apns-collapse-id"]).toBe(collapse);
    expect(withdrawCall.headers["apns-collapse-id"]).toBe(alertCall.headers["apns-collapse-id"]);
    expect(withdrawCall.headers["apns-push-type"]).toBe("background");
    expect(withdrawCall.headers["apns-priority"]).toBe("5");
    expect(withdrawCall.headers["apns-topic"]).toBe(TOPIC);
    expect(JSON.parse(withdrawCall.body)).toEqual({
      aps: { "content-available": 1 },
      hf: { v: 1, ct: withdrawCt },
    });
    // APNs rules: a background push may not claim priority 10, and carries no visible alert.
    const hot = await h.call(
      "POST",
      "/v1/send",
      sendBody(r.id, { push_type: "background", priority: 10, alert: undefined, collapse_id: collapse }),
      auth(r.cap),
    );
    expect(hot.status).toBe(400);
    expect(h.apns.calls).toHaveLength(2);
  });

  it("removes the registration on 410 Unregistered and returns a typed error", async () => {
    const h = await makeHarness();
    const r = await registered(h);
    h.apns.responses = [{ status: 410, reason: "Unregistered" }];
    const res = await h.call("POST", "/v1/send", sendBody(r.id), auth(r.cap));
    expect(res.status).toBe(410);
    expect(res.json.error).toBe("unregistered");
    expect(h.kv.data.size).toBe(0);
    const next = await h.call("POST", "/v1/send", sendBody(r.id), auth(r.cap));
    expect(next.status).toBe(404);
  });

  it("maps other APNs outcomes to typed errors", async () => {
    const h = await makeHarness();
    const r = await registered(h);
    const send = () => h.call("POST", "/v1/send", sendBody(r.id), auth(r.cap));
    h.apns.responses = [{ status: 400, reason: "BadDeviceToken" }];
    let res = await send();
    expect(res.status).toBe(422);
    expect(res.json).toMatchObject({ error: "apns_rejected", reason: "BadDeviceToken" });
    expect(h.kv.data.size).toBe(2); // only 410 deletes
    h.apns.responses = [{ status: 429, reason: "TooManyRequests", headers: { "retry-after": "12" } }];
    res = await send();
    expect(res.status).toBe(429);
    expect(res.headers.get("retry-after")).toBe("12");
    h.apns.responses = [{ status: 503 }];
    expect((await send()).json.error).toBe("apns_unavailable");
    h.apns.responses = [{ status: 500, throws: true }];
    expect((await send()).status).toBe(502);
    h.apns.responses = [{ status: 403, reason: "InvalidProviderToken" }];
    expect((await send()).json.error).toBe("relay_misconfigured");
  });

  it("retries once with a fresh provider token after ExpiredProviderToken", async () => {
    const h = await makeHarness();
    const r = await registered(h);
    h.apns.responses = [{ status: 403, reason: "ExpiredProviderToken" }, { status: 200 }];
    h.clock.ms += 1000; // ensures the refreshed JWT differs from the cached one
    const res = await h.call("POST", "/v1/send", sendBody(r.id), auth(r.cap));
    expect(res.status).toBe(200);
    expect(h.apns.calls).toHaveLength(2);
    expect(h.apns.calls[0]!.headers.authorization).not.toBe(h.apns.calls[1]!.headers.authorization);
  });
});

describe("rate limiting", () => {
  it("limits sends per capability", async () => {
    const h = await makeHarness();
    const r = await registered(h);
    const other = await registered(h);
    let limited: any;
    for (let i = 0; i < 31; i++) {
      const res = await h.call("POST", "/v1/send", sendBody(r.id), auth(r.cap));
      if (res.status === 429) limited = res;
    }
    expect(limited.json.error).toBe("rate_limited");
    expect(limited.headers.get("retry-after")).toBe("60");
    expect(h.apns.calls).toHaveLength(30);
    // Another registration is unaffected by this capability's budget.
    expect((await h.call("POST", "/v1/send", sendBody(other.id), auth(other.cap))).status).toBe(200);
    // The window resets.
    h.clock.ms += 61_000;
    expect((await h.call("POST", "/v1/send", sendBody(r.id), auth(r.cap))).status).toBe(200);
  });

  it("limits registrations per client address", async () => {
    const h = await makeHarness();
    const statuses: number[] = [];
    for (let i = 0; i < 12; i++) statuses.push((await h.register()).status);
    expect(statuses.filter((s) => s === 201)).toHaveLength(10);
    expect(statuses.filter((s) => s === 429)).toHaveLength(2);
  });

  it("uses the platform rate-limit bindings when configured and fails closed on errors", async () => {
    const seen: string[] = [];
    const h = await makeHarness({
      IP_LIMITER: { limit: async ({ key }) => (seen.push(key), { success: true }) },
      REGISTER_LIMITER: { limit: async () => ({ success: false }) },
    });
    const res = await h.register();
    expect(res.status).toBe(429);
    expect(seen).toEqual(["ip:unknown"]);

    const broken = await makeHarness({
      IP_LIMITER: {
        limit: async () => {
          throw new Error("binding down");
        },
      },
    });
    expect((await broken.register()).status).toBe(503);
  });
});

describe("live activity tokens", () => {
  it("stores push-to-start and update tokens sealed, and routes updates to them", async () => {
    const h = await makeHarness();
    const r = await registered(h);
    const startToken = randomHex(40);
    const updateToken = randomHex(40);
    const reg = (o: Record<string, unknown>) =>
      h.call("POST", "/v1/liveactivity/register", { relay_device_id: r.id, ...o }, auth(r.cap));
    expect((await reg({ kind: "push_to_start", token: startToken })).status).toBe(200);
    expect((await reg({ kind: "update", token: updateToken })).status).toBe(400); // activity_id required
    expect((await reg({ kind: "update", token: updateToken, activity_id: "act-1" })).status).toBe(200);
    const putsBefore = h.kv.puts;
    expect((await reg({ kind: "update", token: updateToken, activity_id: "act-1" })).status).toBe(200);
    expect(h.kv.puts).toBe(putsBefore); // idempotent
    expect(h.kv.dump()).not.toContain(startToken);
    expect(h.kv.dump()).not.toContain(updateToken);

    const upd = await h.call(
      "POST",
      "/v1/send",
      sendBody(r.id, {
        push_type: "liveactivity",
        alert: undefined,
        liveactivity: { event: "update", activity_id: "act-1" },
      }),
      auth(r.cap),
    );
    expect(upd.status).toBe(200);
    const call = h.apns.calls.at(-1)!;
    expect(call.url.endsWith(`/3/device/${updateToken}`)).toBe(true);
    expect(call.headers["apns-topic"]).toBe(`${TOPIC}.push-type.liveactivity`);
    expect(call.headers["apns-push-type"]).toBe("liveactivity");
    const aps = JSON.parse(call.body).aps;
    expect(aps.event).toBe("update");
    expect(Object.keys(aps["content-state"])).toEqual(["ct"]);

    const start = await h.call(
      "POST",
      "/v1/send",
      sendBody(r.id, {
        push_type: "liveactivity",
        alert: { title_key: "approval" },
        liveactivity: { event: "start", attributes_type: "FleetActivityAttributes" },
      }),
      auth(r.cap),
    );
    expect(start.status).toBe(200);
    expect(h.apns.calls.at(-1)!.url.endsWith(`/3/device/${startToken}`)).toBe(true);
    expect(JSON.parse(h.apns.calls.at(-1)!.body).aps["attributes-type"]).toBe("FleetActivityAttributes");

    const missing = await h.call(
      "POST",
      "/v1/send",
      sendBody(r.id, {
        push_type: "liveactivity",
        alert: undefined,
        liveactivity: { event: "end", activity_id: "nope" },
      }),
      auth(r.cap),
    );
    expect(missing.status).toBe(404);
    expect(missing.json.error).toBe("unknown_activity");
  });

  it("requires the capability and drops a token on 410 without deleting the device", async () => {
    const h = await makeHarness();
    const r = await registered(h);
    const token = randomHex(40);
    const denied = await h.call(
      "POST",
      "/v1/liveactivity/register",
      { relay_device_id: r.id, kind: "push_to_start", token },
      auth(randomB64(32)),
    );
    expect(denied.status).toBe(401);
    await h.call(
      "POST",
      "/v1/liveactivity/register",
      { relay_device_id: r.id, kind: "update", token, activity_id: "a1" },
      auth(r.cap),
    );
    h.apns.responses = [{ status: 410, reason: "Unregistered" }];
    const res = await h.call(
      "POST",
      "/v1/send",
      sendBody(r.id, {
        push_type: "liveactivity",
        alert: undefined,
        liveactivity: { event: "update", activity_id: "a1" },
      }),
      auth(r.cap),
    );
    expect(res.status).toBe(410);
    expect(res.json.error).toBe("activity_unregistered");
    expect(h.kv.data.size).toBe(2);
    h.apns.responses = [{ status: 200 }];
    expect((await h.call("POST", "/v1/send", sendBody(r.id), auth(r.cap))).status).toBe(200);
  });
});

describe("content-blindness", () => {
  it("never persists or logs the ciphertext, capability, or plaintext device token", async () => {
    const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});
    const consoleErr = vi.spyOn(console, "error").mockImplementation(() => {});
    const consoleWarn = vi.spyOn(console, "warn").mockImplementation(() => {});
    try {
      // Real default logger, so what the Worker would emit is what gets inspected.
      const h = await makeHarness({}, { log: defaultDeps().log });
      const r = await registered(h);
      const liveToken = randomHex(40);
      const ciphertexts: string[] = [];
      for (let i = 0; i < 3; i++) {
        const body = sendBody(r.id, { ciphertext: randomB64(200) });
        ciphertexts.push(body.ciphertext);
        expect((await h.call("POST", "/v1/send", body, auth(r.cap))).status).toBe(200);
      }
      const badCap = randomB64(32);
      await h.call("POST", "/v1/send", sendBody(r.id), auth(badCap)); // failure path
      await h.call(
        "POST",
        "/v1/liveactivity/register",
        { relay_device_id: r.id, kind: "push_to_start", token: liveToken },
        auth(r.cap),
      );

      // Persisted state after registration, sends, and live-activity registration.
      const stored = h.kv.dump();
      for (const secret of [...ciphertexts, r.cap, r.deviceToken, r.deviceToken.toUpperCase(), liveToken]) {
        expect(stored).not.toContain(secret);
      }
      expect([...h.kv.data.keys()].map((k) => k.split(":")[0]).sort()).toEqual(["d", "t"]);
      for (const entry of h.kv.data.values()) expect(entry.ttl).toBeGreaterThanOrEqual(60);

      // Exercise the cleanup paths too, then inspect everything that was logged.
      h.apns.responses = [{ status: 410, reason: "Unregistered" }];
      await h.call("POST", "/v1/send", sendBody(r.id), auth(r.cap));
      const r2 = await registered(h);
      await h.call("DELETE", `/v1/register/${r2.id}`, undefined, auth(r2.cap));

      const logged = [
        ...consoleSpy.mock.calls.flat(),
        ...consoleErr.mock.calls.flat(),
        ...consoleWarn.mock.calls.flat(),
      ].map(String);
      expect(logged.length).toBeGreaterThan(5);
      const all = logged.join("\n");
      for (const secret of [...ciphertexts, r.cap, badCap, r.deviceToken, r2.cap, r2.deviceToken, liveToken, r.id, r2.id]) {
        expect(all).not.toContain(secret);
      }
      for (const line of logged) {
        expect(Object.keys(JSON.parse(line)).every((k) => ["route", "status", "outcome"].includes(k))).toBe(true);
      }
    } finally {
      consoleSpy.mockRestore();
      consoleErr.mockRestore();
      consoleWarn.mockRestore();
    }
  });

  it("does not echo request data in error responses", async () => {
    const h = await makeHarness();
    const secretish = randomB64(24);
    const res = await h.call("POST", "/v1/register", `{"device_token":"${secretish}"`);
    expect(JSON.stringify(res.json)).not.toContain(secretish);
  });

  it("stores the salted token hash index, not the token, and seals the token at rest", async () => {
    const h = await makeHarness();
    const r = await registered(h);
    const keys = [...h.kv.data.keys()];
    expect(keys.some((k) => k.startsWith("t:") && !k.includes(r.deviceToken))).toBe(true);
    expect(h.kv.dump()).not.toContain(r.keyId); // key id is sealed, not stored in clear
    const record = JSON.parse(h.kv.data.get(`d:${r.id}`)!.value);
    expect(Object.keys(record).sort()).toEqual(
      ["bundleId", "capHash", "environment", "expiresAt", "sealed", "v"].sort(),
    );
    // A different storage key produces different index keys (salted).
    const h2 = await makeHarness();
    await h2.register({ device_token: r.deviceToken, relay_key_id: r.keyId });
    const idx1 = keys.find((k) => k.startsWith("t:"));
    const idx2 = [...h2.kv.data.keys()].find((k) => k.startsWith("t:"));
    expect(idx1).not.toBe(idx2);
  });
});

describe("transport and routing", () => {
  it("requires HTTPS, rejects unknown routes and wrong methods, and sets security headers", async () => {
    const h = await makeHarness();
    const http = await h.handler.fetch(new Request("http://relay.example.test/healthz"), h.env);
    expect(http.status).toBe(400);
    expect((await h.call("GET", "/nope")).status).toBe(404);
    const wrong = await h.call("GET", "/v1/send");
    expect(wrong.status).toBe(405);
    expect(wrong.headers.get("allow")).toBe("POST");
    const ok = await h.call("GET", "/healthz");
    expect(ok.json).toEqual({ status: "ok" });
    expect(ok.headers.get("cache-control")).toBe("no-store");
    expect(ok.headers.get("strict-transport-security")).toBeTruthy();
  });

  it("fails closed when the relay is not configured", async () => {
    const h = await makeHarness({ APNS_KEY_P8: "" });
    const res = await h.call("GET", "/healthz");
    expect(res.status).toBe(500);
    expect(res.json.error).toBe("relay_misconfigured");
  });

  it("rejects a weak storage key without leaking details", async () => {
    const h = await makeHarness({ RELAY_STORAGE_KEY: "c2hvcnQ" });
    const res = await h.register();
    expect(res.status).toBe(500);
    expect(res.json.error).toBe("internal_error");
  });
});
