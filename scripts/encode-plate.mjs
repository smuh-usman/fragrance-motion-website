/**
 * Encode a raw Higgsfield motion plate into a web-ready loop plus its poster.
 *
 *   node scripts/encode-plate.mjs raw/campaign-plate.mp4 lost-in-kashmir/world
 *
 * Produces, under public/assets/<target>/:
 *   <name>.mp4         desktop, H.264 yuv420p, no audio, faststart
 *   <name>-mobile.mp4  height capped at 720
 *   <name>-poster.jpg  first frame of the encoded clip, so the still the
 *                      browser paints matches the frame it decodes
 *
 * These plates LOOP on their own clock rather than being scrubbed by scroll, so
 * a short GOP is insurance, not a requirement. If they are ever welded to the
 * scrollbar (scroll -> currentTime), drop to `-g 1 -keyint_min 1` so every
 * frame is a keyframe: seeking to an arbitrary time is what scrubbing does
 * constantly, and on a long GOP it judders.
 */
import { execFileSync } from "node:child_process";
import { mkdirSync } from "node:fs";
import { basename, dirname, extname, join } from "node:path";

const [source, target] = process.argv.slice(2);
if (!source || !target) {
  console.error("usage: node scripts/encode-plate.mjs <source.mp4> <assets/relative/name>");
  process.exit(1);
}

const outDir = join("public/assets", dirname(target));
const name = basename(target, extname(target));
mkdirSync(outDir, { recursive: true });

const desktop = join(outDir, `${name}.mp4`);
const mobile = join(outDir, `${name}-mobile.mp4`);
const poster = join(outDir, `${name}-poster.jpg`);

const ffmpeg = (args) => execFileSync("ffmpeg", ["-y", ...args], { stdio: "inherit" });

const encode = (out, scale, crf) =>
  ffmpeg([
    "-i", source,
    ...(scale ? ["-vf", scale] : []),
    "-an",
    "-c:v", "libx264",
    "-profile:v", "high",
    "-pix_fmt", "yuv420p",
    "-crf", String(crf),
    "-g", "8",
    "-keyint_min", "8",
    "-sc_threshold", "0",
    "-movflags", "+faststart",
    out,
  ]);

encode(desktop, null, 20);
encode(mobile, "scale=-2:min(720\\,ih)", 23);

// Poster comes off the encoded clip, never the source.
ffmpeg(["-i", desktop, "-frames:v", "1", "-q:v", "3", poster]);

console.log(`\n${desktop}\n${mobile}\n${poster}`);
