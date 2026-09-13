/**
 * The film, and the numbers that make scroll lead it well.
 *
 * The plate is re-encoded from the supplied master with a two-frame GOP, which
 * is what makes scrubbing smooth: at the master's default keyframe spacing the
 * decoder has to walk forward from a distant keyframe on every seek, and the
 * picture visibly lurches. Two frames costs about a megabyte over a normal
 * encode and removes the lurch entirely.
 */
export const FILM = {
  src: "/assets/lost-in-kashmir/ceremony.mp4",
  poster: "/assets/lost-in-kashmir/ceremony-poster.jpg",
  /** Fallback only; the real value comes from the decoded metadata. */
  duration: 12.0417,
  /** 24fps, as supplied. */
  frame: 1 / 24,
  /**
   * How hard the playhead chases the scroll, per second. Around seven the film
   * feels led rather than dragged: high enough that it never feels disconnected
   * from the hand, low enough that a flick of the wheel glides instead of
   * snapping.
   */
  follow: 7,
  /**
   * A beat of stillness at each end of the track, so the film rests on a closed
   * bottle before it starts and after it finishes instead of opening mid-move.
   */
  hold: 0.06,
} as const;
