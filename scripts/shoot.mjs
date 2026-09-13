/**
 * Screenshot the experience at a series of scroll positions.
 *
 * The whole page is one fixed stage driven by scroll, so the only way to
 * inspect it is to park the scrollbar at a given fraction of the track, let the
 * eased progress settle, and capture. Frames land in raw/shots/.
 *
 *   node scripts/shoot.mjs                 # default sweep
 *   node scripts/shoot.mjs 0.46 0.50 0.54  # specific positions
 */
import { chromium } from "playwright";
import { mkdirSync } from "node:fs";

const positions = process.argv.slice(2).map(Number);
const sweep = positions.length
  ? positions
  : [0, 0.1, 0.2, 0.3, 0.4, 0.45, 0.5, 0.55, 0.6, 0.7, 0.8, 0.9, 1];

mkdirSync("raw/shots", { recursive: true });

const browser = await chromium.launch();
const page = await browser.newPage({
  viewport: { width: 1440, height: 900 },
  deviceScaleFactor: 1,
});

const errors = [];
page.on("console", (m) => m.type() === "error" && errors.push(m.text()));
page.on("pageerror", (e) => errors.push(String(e)));

await page.goto("http://localhost:5173/", { waitUntil: "networkidle" });

// Video plates need a gesture in some engines, and the scene needs a beat to
// compile shaders and decode the first frames.
await page.mouse.click(720, 450);
await page.waitForTimeout(2500);

for (const p of sweep) {
  await page.evaluate((frac) => {
    const max = document.body.scrollHeight - window.innerHeight;
    window.scrollTo({ top: max * frac, behavior: "instant" });
  }, p);

  // Lenis eases toward the target and the scrub tween lags behind it, so the
  // frame is only truthful once both have settled. On a fifteen-viewport track
  // a jump can be thousands of pixels, and settling takes noticeably longer
  // than it looks like it should - at 1400ms the fill still read half done at
  // a position where it is complete.
  await page.waitForTimeout(Number(process.env.SETTLE) || 2600);

  const name = `raw/shots/p${String(Math.round(p * 100)).padStart(3, "0")}.png`;
  await page.screenshot({ path: name });
  console.log(name);
}

if (errors.length) {
  console.log("\nconsole errors:");
  for (const e of [...new Set(errors)]) console.log("  " + e);
}

await browser.close();
