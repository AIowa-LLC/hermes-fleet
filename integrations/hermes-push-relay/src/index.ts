import { createHandler } from "./app.ts";
import type { Env } from "./types.ts";

const handler = createHandler();

export default {
  fetch(request: Request, env: Env): Promise<Response> {
    return handler.fetch(request, env);
  },
};
