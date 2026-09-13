/**
 * Where one act hands over to the next, as fractions of the whole scroll.
 *
 *   0.00 - 0.58  the ceremony: the cap lifts off a sprayer, the ingredients
 *                revolve in and dissolve into liquid, the liquid mixes, the
 *                printed cover splits open on an empty bottle, the bottle fills
 *                and the cover and cap close over it
 *   0.58 - 0.66  a leaf passes the lens and the scene changes behind it
 *   0.66 - 0.88  the campaign photograph, travelled through
 *   0.88 - 1.00  one citrus swells until its skin is the whole viewport
 *
 * The ceremony takes well over half the track because it carries nine beats. It
 * had four when it ran to 0.46, and keeping that length while adding the split
 * cover and the fill would have turned choreography into a flicker.
 */
export const ACTS = {
  /** The bottle opened, filled and closed again. */
  ceremonyEnd: 0.58,
  revealStart: 0.58,
  revealEnd: 0.66,
  worldEnd: 0.88,
} as const;
