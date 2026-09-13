/**
 * Every visual in the prototype traces back to the brand's own photography.
 *
 * `packshot` and `campaign` are the supplied stills, untouched, and they are
 * what the viewer actually reads: the real bottle, the real label.
 * `campaignDepth` is estimated from `campaign` by scripts/depth.mjs.
 * `leaf` and `citrus` are crops of `campaign`, matted in KeyedPlane.
 */
export const LOST_IN_KASHMIR = {
  packshot: "/assets/lost-in-kashmir/packshot.png",
  /**
   * The packshot cropped at the collar and matted off the studio sweep by
   * scripts/bottle-plates.mjs. Cropping at the collar is what lets the cap lift
   * at all: the original cap is simply never in the picture, so nothing has to
   * be painted out from behind it.
   */
  bottleCut: "/assets/lost-in-kashmir/bottle-body-cut.png",
  /**
   * The same plate with the printed type lifted off by a harmonic fill, which
   * is what the empty vessel behind the cover is graded from. The type itself is
   * never reconstructed - it stays on the cover, in its original pixels.
   */
  bottleClean: "/assets/lost-in-kashmir/bottle-clean.png",
  /** The sprayer under the cap, built from the collar's own gold. */
  nozzle: "/assets/lost-in-kashmir/nozzle.png",
  /** The cap, matted off the same frame, free to lift away. */
  cap: "/assets/lost-in-kashmir/cap.png",
  campaign: "/assets/lost-in-kashmir/campaign.png",
  campaignDepth: "/assets/lost-in-kashmir/campaign-depth.png",
  /** The canopy cluster, used only as a soft cast shadow. */
  leaf: "/assets/lost-in-kashmir/leaf.png",
  /**
   * One leaf, cut from beside the cut lemon. A cluster can only ever read as a
   * screen-wide smear when it travels; a single leaf reads as a leaf. It also
   * mattes far better: this one is deep green against yellow fruit, where the
   * cluster is half backlit and its sunlit leaves barely clear the key.
   */
  leafSingle: "/assets/lost-in-kashmir/leaf-single.png",
  /** The single leaf again, with its matte baked into the alpha channel. */
  leafCutout: "/assets/lost-in-kashmir/leaf-cutout.png",
  citrus: "/assets/lost-in-kashmir/citrus.png",
} as const;

/** Pixel dimensions of the campaign still every crop is measured against. */
const CAMPAIGN_W = 1082;
const CAMPAIGN_H = 1440;

/**
 * A pixel crop of the still, expressed as the UV rectangle it occupies.
 * Textures are flipped on Y, so image row 0 lands at v = 1.
 */
const uvRect = (
  x: number,
  y: number,
  w: number,
  h: number,
): [number, number, number, number] => [
  x / CAMPAIGN_W,
  1 - (y + h) / CAMPAIGN_H,
  (x + w) / CAMPAIGN_W,
  1 - y / CAMPAIGN_H,
];

/**
 * Environment plates: motion generated from crops of the campaign still that
 * contain no product at all. Each is blended back into the exact rectangle it
 * was cut from, so generated pixels only ever touch foliage, stone and light.
 * The bottle and its typography are never inside a generated frame.
 */
export const PLATES = {
  canopy: {
    src: "/assets/lost-in-kashmir/canopy.mp4",
    rect: uvRect(0, 0, 1082, 460),
    feather: 0.16,
  },
  shadows: {
    src: "/assets/lost-in-kashmir/shadows.mp4",
    rect: uvRect(200, 1150, 676, 290),
    feather: 0.3,
  },
} as const;

/**
 * The page ground, sampled from the packshot's own studio background so the
 * plate has nothing to sit on: measured corners run #d9d7d6 to #ebe9e7 across
 * the sweep, and this is their middle.
 */
export const STUDIO_GROUND = "#e0dedd";

/** Sampled from the bottle glass and the campaign's citrus and sea. */
export const PALETTE = {
  bottleGreen: "#5d7d52",
  deepGreen: "#2f4a2c",
  citrus: "#e8c33f",
  sea: "#12539a",
  ink: "#22261f",
  signal: "#c8402f",
} as const;

/**
 * The opening ceremony's cast. Everything but `ribbons` is matted from the
 * brand's own flat-lay; `ribbons` was generated on black with no product in
 * frame and is screen-blended, never keyed.
 */
export const CEREMONY = {
  pineapple: "/assets/lost-in-kashmir/ingredients/pineapple.png",
  grapefruit: "/assets/lost-in-kashmir/ingredients/grapefruit.png",
  grapefruitHalf: "/assets/lost-in-kashmir/ingredients/grapefruit-half.png",
  vanilla: "/assets/lost-in-kashmir/ingredients/vanilla.png",
  palosanto: "/assets/lost-in-kashmir/ingredients/palosanto.png",
  ribbons: "/assets/lost-in-kashmir/ribbons.mp4",
} as const;
