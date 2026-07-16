import { cp, mkdir, rm } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const gameDirectory = resolve(root, "public", "game");
const files = ["index.html", "manifest.webmanifest", "service-worker.js"];

await rm(gameDirectory, { recursive: true, force: true });
await mkdir(gameDirectory, { recursive: true });
await Promise.all([
  ...files.map((file) => cp(resolve(root, file), resolve(gameDirectory, file))),
  cp(resolve(root, "assets"), resolve(gameDirectory, "assets"), { recursive: true }),
]);
