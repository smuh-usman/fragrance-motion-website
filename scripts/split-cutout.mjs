/**
 * Split a segmented RGBA cutout into one file per object.
 *
 * Hand-picked crop rectangles bleed into neighbouring objects, because the
 * elements in a flat-lay overlap each other's bounding boxes even when their
 * silhouettes do not. This finds the actual connected regions in the alpha
 * channel instead and crops each to its own true bounds.
 *
 *   node scripts/split-cutout.mjs raw/ing-cut.png public/assets/.../ingredients
 */
import { execFileSync } from "node:child_process";
import { mkdirSync } from "node:fs";
import { join } from "node:path";

const [source, outDir] = process.argv.slice(2);
if (!source || !outDir) {
  console.error("usage: node scripts/split-cutout.mjs <rgba.png> <out-dir>");
  process.exit(1);
}

const dims = execFileSync("ffprobe", [
  "-v", "error", "-select_streams", "v:0",
  "-show_entries", "stream=width,height", "-of", "csv=p=0", source,
]).toString().trim().split(",").map(Number);
const [W, H] = dims;

// The alpha channel as one byte per pixel.
const alpha = execFileSync("ffmpeg", [
  "-v", "error", "-i", source, "-vf", "alphaextract,format=gray",
  "-f", "rawvideo", "-pix_fmt", "gray", "-",
], { maxBuffer: 1 << 28 });

const ALPHA_MIN = 40;      // below this a pixel is background
const MIN_AREA = 1500;     // ignore specks and matte noise
const labels = new Int32Array(W * H).fill(-1);
const boxes = [];

// Iterative flood fill; a recursive one blows the stack on regions this size.
for (let start = 0; start < W * H; start++) {
  if (labels[start] !== -1 || alpha[start] < ALPHA_MIN) continue;

  const id = boxes.length;
  const stack = [start];
  labels[start] = id;
  let minX = W, minY = H, maxX = 0, maxY = 0, area = 0;

  while (stack.length) {
    const p = stack.pop();
    const x = p % W, y = (p / W) | 0;
    area++;
    if (x < minX) minX = x;
    if (x > maxX) maxX = x;
    if (y < minY) minY = y;
    if (y > maxY) maxY = y;

    for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
      const nx = x + dx, ny = y + dy;
      if (nx < 0 || ny < 0 || nx >= W || ny >= H) continue;
      const q = ny * W + nx;
      if (labels[q] !== -1 || alpha[q] < ALPHA_MIN) continue;
      labels[q] = id;
      stack.push(q);
    }
  }

  boxes.push({ id, minX, minY, maxX, maxY, area });
}

const kept = boxes
  .filter((b) => b.area >= MIN_AREA)
  .sort((a, b) => b.area - a.area);

mkdirSync(outDir, { recursive: true });
console.log(`${source}: ${W}x${H}, ${kept.length} objects\n`);

kept.forEach((b, i) => {
  const pad = 3;
  const x = Math.max(0, b.minX - pad);
  const y = Math.max(0, b.minY - pad);
  const w = Math.min(W - x, b.maxX - b.minX + 1 + pad * 2);
  const h = Math.min(H - y, b.maxY - b.minY + 1 + pad * 2);
  const out = join(outDir, `part-${String(i).padStart(2, "0")}.png`);

  execFileSync("ffmpeg", [
    "-y", "-v", "error", "-i", source,
    "-vf", `crop=${w}:${h}:${x}:${y}`, out,
  ]);
  console.log(`  part-${String(i).padStart(2, "0")}  ${w}x${h} at ${x},${y}  area ${b.area}`);
});
