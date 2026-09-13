/**
 * The packshot's pixel geometry, measured off the frame by
 * scripts/bottle-plates.mjs rather than eyeballed.
 *
 * Everything in the ceremony - the cap, the two cover halves, the vessel behind
 * them, the sprayer, the liquid surface - is positioned from these numbers, so
 * every piece shares one reference frame and lands exactly where it was
 * photographed. Getting this wrong is invisible in code and glaring on screen:
 * a cover that opens a few pixels off its own silhouette reads instantly as a
 * composite rather than as a bottle.
 */
export const BOTTLE = {
  /** The packshot as supplied. */
  frame: { w: 820, h: 898 },
  /** Where the plates are cropped: just above the collar. */
  bodyTop: 296,
  /** The cropped plates: bottle-body-cut.png and bottle-clean.png. */
  plate: { w: 820, h: 602 },
  /** The glass body in plate pixels. This is what the cover is made of. */
  glass: { x0: 164, x1: 656, y0: 49, y1: 528 },
  /** The gold collar in plate pixels. It belongs to the neck and never moves. */
  collar: { x0: 331, x1: 485, y0: 21, y1: 48 },
  /** The cap in frame pixels, matted off the same shot. */
  cap: { x: 200, y: 10, w: 380, h: 293 },
  /** The sprayer, drawn at frame scale and standing on the collar. */
  nozzle: { w: 120, h: 112, cx: 408, base: 334 },
  /**
   * How full the bottle reads at each end of the fill, in plate pixels. Liquid
   * stops short of the shoulder because a bottle filled to its brim reads as a
   * glass of water rather than as perfume.
   */
  level: { empty: 528, full: 74 },
} as const;

/** A plate pixel row as a texture coordinate. Textures are flipped on Y. */
export const plateV = (y: number) => 1 - y / BOTTLE.plate.h;
/** A plate pixel column as a texture coordinate. */
export const plateU = (x: number) => x / BOTTLE.plate.w;
/** A plate pixel row in the coordinates of the whole packshot frame. */
export const frameY = (plateRow: number) => plateRow + BOTTLE.bodyTop;
