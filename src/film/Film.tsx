import { useEffect, useRef } from "react";
import { band, useScroll } from "../scroll/ScrollProvider";
import { FILM } from "./timing";

/**
 * The ceremony, played by scroll.
 *
 * Scroll does not set the playhead directly. It sets a target, and the playhead
 * is eased toward it with a critically damped follow, so a flick of the wheel
 * does not snap the film and letting go lets it glide to rest. Raw scrubbing
 * reads as a filmstrip being dragged; this reads as a film that scroll is
 * leading. The cost is a few frames of lag, which is the point.
 *
 * The plate is a portrait film in a landscape viewport, and neither of the
 * usual answers works: cropping to fill would cut the bottle off top and bottom
 * at three times scale, and a flat pillarbox clashes as soon as the cover
 * splits, because the halves and the flying ingredients reach the frame edge
 * and the margin is still studio grey. So the margin is lit by the film itself
 * - a thumbnail of the current frame, blown up and blurred behind it, which
 * matches whatever the frame happens to be doing. It is drawn from the same
 * video element, so there is only ever one decode and one seek.
 */
export function Film() {
  const { raw, reducedMotion } = useScroll();

  const video = useRef<HTMLVideoElement>(null);
  const bleed = useRef<HTMLCanvasElement>(null);
  const opening = useRef<HTMLDivElement>(null);
  const closing = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const v = video.current;
    if (!v) return;

    // Some engines will not decode or seek a video that has never been played.
    // A muted play/pause on the first gesture costs nothing and is inaudible.
    const prime = () => {
      void v.play().then(() => v.pause()).catch(() => {});
    };
    document.addEventListener("pointerdown", prime, { once: true });
    document.addEventListener("touchstart", prime, { once: true, passive: true });

    // Reduced motion keeps the poster and the words, and never moves the film.
    if (reducedMotion) {
      let frame = 0;
      const paint = () => {
        const p = raw.current ?? 0;
        // Mapped the same way as the film's own clock, so the words arrive at
        // the same points on the track whether or not the picture is moving.
        setType(Math.min(1, Math.max(0, (p - FILM.hold) / (1 - FILM.hold * 2))));
        frame = requestAnimationFrame(paint);
      };
      frame = requestAnimationFrame(paint);
      return () => {
        cancelAnimationFrame(frame);
        document.removeEventListener("pointerdown", prime);
        document.removeEventListener("touchstart", prime);
      };
    }

    const ctx = bleed.current?.getContext("2d", { alpha: false }) ?? null;
    let time = 0;
    let last = performance.now();
    let frame = 0;

    const paint = (now: number) => {
      const dt = Math.min(0.1, (now - last) / 1000);
      last = now;

      const duration = Number.isFinite(v.duration) && v.duration > 0 ? v.duration : FILM.duration;
      const p = raw.current ?? 0;

      // A beat of stillness at each end, so the film rests on a closed bottle
      // before it starts and after it finishes rather than beginning mid-move.
      const t = Math.min(1, Math.max(0, (p - FILM.hold) / (1 - FILM.hold * 2)));
      const want = t * duration;

      // Critically damped follow, framed in seconds so it behaves the same on a
      // 120Hz display as on a 60Hz one.
      time += (want - time) * (1 - Math.exp(-dt * FILM.follow));

      // Only ask for a seek when the browser is not already serving one, and
      // only when it is worth more than half a frame. Queueing seeks on a video
      // that is still seeking is what makes scrubbed video stutter.
      if (!v.seeking && v.readyState >= 1 && Math.abs(v.currentTime - time) > FILM.frame * 0.5) {
        v.currentTime = time;
      }

      if (ctx && v.readyState >= 2) {
        const c = ctx.canvas;
        ctx.drawImage(v, 0, 0, c.width, c.height);
      }

      setType(t);
      frame = requestAnimationFrame(paint);
    };

    frame = requestAnimationFrame(paint);
    return () => {
      cancelAnimationFrame(frame);
      document.removeEventListener("pointerdown", prime);
      document.removeEventListener("touchstart", prime);
    };

    function setType(t: number) {
      if (opening.current) {
        const out = band(t, 0.02, 0.14);
        opening.current.style.opacity = String(1 - out);
        // The stylesheet centres this block with a translate, and writing
        // transform here replaces that rather than adding to it, so the -50%
        // has to be restated every frame or the words jump to the right.
        opening.current.style.transform = `translate3d(-50%, ${-out * 26}px, 0)`;
      }
      if (closing.current) {
        const inn = band(t, 0.80, 0.94);
        closing.current.style.opacity = String(inn);
        closing.current.style.transform = `translate3d(-50%, ${(1 - inn) * 22}px, 0)`;
      }
    }
  }, [raw, reducedMotion]);

  return (
    <div className="stage">
      {/* Sized to a thumbnail on purpose: blown up to fill the viewport it is
          already soft, so the blur only has to finish the job. */}
      <canvas ref={bleed} className="bleed" width={64} height={114} aria-hidden="true" />

      <video
        ref={video}
        className="film"
        src={FILM.src}
        poster={FILM.poster}
        preload="auto"
        muted
        playsInline
        // Never played as a video: scroll owns the playhead.
        disablePictureInPicture
        aria-label="Lost in Kashmir — the bottle opens, its ingredients become liquid, and it fills."
      />

      <header className="chrome">
        <span className="wordmark">
          imaginary
          <br />
          fragrances
        </span>
      </header>

      <div className="copy">
        <div className="chapter chapter--opening" ref={opening}>
          <h1>
            Every fragrance
            <br />
            is a story
          </h1>
        </div>

        <div className="chapter chapter--closing" ref={closing}>
          <h2>Lost in Kashmir</h2>
          <p>A place you can wear.</p>
        </div>
      </div>
    </div>
  );
}
