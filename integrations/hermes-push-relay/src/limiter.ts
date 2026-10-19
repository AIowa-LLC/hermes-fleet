import { HttpError, type RateLimitBinding } from "./types.ts";

export interface Limiter {
  /** Resolves true when the request identified by `key` may proceed. */
  allow(key: string): Promise<boolean>;
}

/**
 * Fixed-window limiter held in isolate memory. Used when a Workers Rate
 * Limiting binding is not configured (local dev, self-hosters) and by tests.
 * It is per-isolate best effort; the platform binding is the production path.
 */
export function memoryLimiter(limit: number, windowSeconds: number, now: () => number): Limiter {
  const windows = new Map<string, { start: number; count: number }>();
  return {
    async allow(key) {
      const t = now();
      const windowMs = windowSeconds * 1000;
      if (windows.size > 5000) {
        for (const [k, w] of windows) if (t - w.start >= windowMs) windows.delete(k);
        if (windows.size > 5000) windows.clear();
      }
      const w = windows.get(key);
      if (!w || t - w.start >= windowMs) {
        windows.set(key, { start: t, count: 1 });
        return true;
      }
      w.count += 1;
      return w.count <= limit;
    },
  };
}

/** Adapter over the Workers Rate Limiting binding; fails closed on errors. */
export function bindingLimiter(binding: RateLimitBinding): Limiter {
  return {
    async allow(key) {
      try {
        const { success } = await binding.limit({ key });
        return success;
      } catch {
        throw new HttpError(503, "rate_limiter_unavailable", "Rate limiter unavailable.");
      }
    },
  };
}
