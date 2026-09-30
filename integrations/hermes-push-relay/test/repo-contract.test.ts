import SwaggerParser from "@apidevtools/swagger-parser";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { TITLE_KEYS } from "../src/config.ts";

const here = dirname(fileURLToPath(import.meta.url));
const relayDir = resolve(here, "..");
const repoRoot = resolve(relayDir, "../..");
const read = (p: string) => readFileSync(p, "utf8");

function walk(dir: string, out: string[] = []): string[] {
  for (const name of readdirSync(dir)) {
    if (name === "node_modules" || name === ".wrangler" || name === ".wrangler-dry-run") continue;
    const p = join(dir, name);
    if (statSync(p).isDirectory()) walk(p, out);
    else out.push(p);
  }
  return out;
}

describe("OpenAPI spec", () => {
  it("validates and matches the implementation's enums", async () => {
    const api: any = await SwaggerParser.validate(join(relayDir, "openapi.yaml"));
    expect(Object.keys(api.paths).sort()).toEqual(
      ["/healthz", "/v1/liveactivity/register", "/v1/register", "/v1/register/{relay_device_id}", "/v1/send"].sort(),
    );
    const send = api.components.schemas.SendRequest;
    expect([...send.properties.alert.properties.title_key.enum].sort()).toEqual([...TITLE_KEYS].sort());
    expect(send.properties.push_type.enum).toEqual(["alert", "liveactivity", "background"]);
  });
});

describe("secret hygiene", () => {
  it("wrangler.toml holds no secrets, account ids, routes, or resource ids", () => {
    const toml = read(join(relayDir, "wrangler.toml"));
    const active = toml
      .split("\n")
      .filter((l) => !l.trim().startsWith("#"))
      .join("\n");
    expect(active).not.toMatch(/account_id|routes?\s*=|zone_id|database_id|\bid\s*=|preview_id/);
    expect(active).not.toMatch(/APNS_KEY_P8\s*=|RELAY_STORAGE_KEY\s*=|BEGIN [A-Z ]*PRIVATE KEY/);
  });

  it("no tracked relay file contains private-key material or bearer secrets", () => {
    for (const file of walk(relayDir)) {
      if (file.endsWith("package-lock.json")) continue;
      const text = read(file);
      // Tests build PEM headers at runtime; a literal header must never be committed.
      expect(text, file).not.toMatch(/-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*[A-Za-z0-9+/]{40}/);
      expect(text, file).not.toMatch(/\.p8\b.*[A-Za-z0-9+/]{60}/);
    }
  });
});

describe("documentation", () => {
  const selfHost = join(repoRoot, "docs/push-relay-self-host.md");
  const relayReadme = join(relayDir, "README.md");

  it("links the self-host doc and relay README from docs/README.md", () => {
    const docsReadme = read(join(repoRoot, "docs/README.md"));
    expect(docsReadme).toContain("(push-relay-self-host.md)");
    expect(docsReadme).toContain("(../integrations/hermes-push-relay/README.md)");
  });

  it("has resolvable relative links in the new and updated docs", () => {
    for (const file of [selfHost, relayReadme, join(repoRoot, "PRIVACY.md"), join(repoRoot, "docs/README.md")]) {
      const text = read(file);
      for (const m of text.matchAll(/\]\((?!https?:|mailto:|#)([^)#\s]+)(#[^)]*)?\)/g)) {
        const target = resolve(dirname(file), m[1] as string);
        expect(existsSync(target), `${file} -> ${m[1]}`).toBe(true);
      }
    }
  });

  it("PRIVACY.md discloses what the relay sees and cannot see", () => {
    const privacy = read(join(repoRoot, "PRIVACY.md"));
    expect(privacy).toMatch(/## Push notification relay/);
    expect(privacy).toMatch(/push token/i);
    expect(privacy).toMatch(/cannot see/i);
  });

  it("README documents the maintainer-only deploy checklist and threat model", () => {
    const text = read(relayReadme);
    expect(text).toMatch(/## Maintainer-only deployment checklist/);
    expect(text).toMatch(/wrangler secret put APNS_KEY_P8/);
    expect(text).toMatch(/## Threat model/);
    for (const topic of [/relay compromise/i, /replay/i, /spam/i]) expect(text).toMatch(topic);
  });
});
