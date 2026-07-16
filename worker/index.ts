import handler from "vinext/server/app-router-entry";

interface Env {
  ASSETS: Fetcher;
}

interface ExecutionContext {
  waitUntil(promise: Promise<unknown>): void;
  passThroughOnException(): void;
}

const worker = {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);

    // The game is a static PWA copied verbatim to /game. Redirecting keeps its
    // manifest and service worker in the top-level browsing context.
    if (url.pathname === "/") {
      return Response.redirect(new URL("/game/", url), 302);
    }

    return handler.fetch(request, env, ctx);
  },
};

export default worker;
