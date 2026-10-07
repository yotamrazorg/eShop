import { defineConfig } from "@playwright/test";
import * as fs from "fs";

/**
 * Browser-level E2E tests for the milestone-1 native-host deployment.
 *
 * Only Catalog.API is deployed (http://127.0.0.1:5222, Production). This config is
 * deliberately separate from the repo-root playwright.config.ts (which targets the
 * full-stack WebApp on :5045 and belongs to a later milestone) and does NOT start the
 * AppHost; the already-running Catalog.API is expected (run-app: run + healthcheck).
 *
 * Run from the repo root or this directory:
 *   npx playwright test --config=.mcode/frontend-tests/playwright.config.ts
 *
 * Env:
 *   CATALOG_API_URL   base URL (default http://127.0.0.1:5222)
 *   PW_CHROME_PATH    optional Chrome/Chromium executable (for sandboxes without the
 *                     Playwright browser cache)
 */
const chromePath = process.env.PW_CHROME_PATH;
const reportFile = process.env.MCODE_DIR
  ? `${process.env.MCODE_DIR}/fe_testing/playwright-results.json`
  : "playwright-results.json";

export default defineConfig({
  testDir: ".",
  testMatch: "**/*.spec.ts",
  timeout: 30000,
  retries: 1,
  workers: 1,
  use: {
    baseURL: process.env.CATALOG_API_URL ?? "http://127.0.0.1:5222",
    headless: true,
    screenshot: "on",
    // video needs the ffmpeg binary (npx playwright install ffmpeg), absent on the sandbox
    video: process.env.PW_VIDEO === "1" ? "retain-on-failure" : "off",
    trace: "retain-on-failure",
    launchOptions: {
      ...(chromePath && fs.existsSync(chromePath) ? { executablePath: chromePath } : {}),
      args: ["--no-sandbox"],
    },
  },
  reporter: [["list"], ["json", { outputFile: reportFile }]],
});
