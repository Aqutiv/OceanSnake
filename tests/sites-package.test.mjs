import assert from "node:assert/strict";
import { access, readFile } from "node:fs/promises";
import { resolve } from "node:path";
import test from "node:test";

const root = resolve(import.meta.dirname, "..");

test("Sites build includes the complete static PWA", async () => {
  const files = [
    "dist/server/index.js",
    "dist/.openai/hosting.json",
    "dist/client/game/index.html",
    "dist/client/game/manifest.webmanifest",
    "dist/client/game/service-worker.js",
    "dist/client/game/assets/ocean-snake-idle-loop-256.webp",
    "dist/client/game/assets/pwa-icon-192.png",
  ];

  await Promise.all(files.map((file) => access(resolve(root, file))));
  const [gameHtml, serviceWorker] = await Promise.all([
    readFile(resolve(root, "dist/client/game/index.html"), "utf8"),
    readFile(resolve(root, "dist/client/game/service-worker.js"), "utf8"),
  ]);

  assert.match(gameHtml, /<link rel="manifest" href="manifest\.webmanifest">/);
  assert.match(gameHtml, /src="assets\/ocean-snake-idle-loop-256\.webp"/);
  assert.match(serviceWorker, /"\.\/assets\/ocean-snake-idle-loop-256\.webp"/);
  assert.match(serviceWorker, /"\.\/assets\/pwa-icon-192\.png"/);
});
