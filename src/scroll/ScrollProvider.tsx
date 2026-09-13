import {
  createContext,
  useContext,
  useEffect,
  useMemo,
  useRef,
  type ReactNode,
  type RefObject,
} from "react";
import gsap from "gsap";
import { ScrollTrigger } from "gsap/ScrollTrigger";
import Lenis from "lenis";

gsap.registerPlugin(ScrollTrigger);

/**
 * Scroll is the only clock in this experience: it drives camera, parallax,
 * shader parameters and video time. The progress value therefore lives in a
 * ref, never in React state, so a frame costs no reconciliation.
 */
type ScrollState = {
  /** Eased 0..1 across the whole track. */
  progress: RefObject<number>;
  /** Raw, unsmoothed 0..1 - for anything that must not lag the scrollbar. */
  raw: RefObject<number>;
  reducedMotion: boolean;
};

const ScrollContext = createContext<ScrollState | null>(null);

export const useScroll = () => {
  const ctx = useContext(ScrollContext);
  if (!ctx) throw new Error("useScroll must be used inside <ScrollProvider>");
  return ctx;
};

export function ScrollProvider({
  children,
  trackRef,
}: {
  children: ReactNode;
  trackRef: RefObject<HTMLElement>;
}) {
  const progress = useRef(0);
  const raw = useRef(0);

  const reducedMotion = useMemo(
    () =>
      typeof window !== "undefined" &&
      window.matchMedia("(prefers-reduced-motion: reduce)").matches,
    [],
  );

  useEffect(() => {
    const track = trackRef.current;
    if (!track) return;

    // Reduced motion keeps the story readable without smoothing or scrubbing:
    // the scene reads its progress straight from the scrollbar.
    if (reducedMotion) {
      const trigger = ScrollTrigger.create({
        trigger: track,
        start: "top top",
        end: "bottom bottom",
        onUpdate: (self) => {
          progress.current = self.progress;
          raw.current = self.progress;
        },
      });
      return () => trigger.kill();
    }

    const lenis = new Lenis({ autoRaf: false, lerp: 0.09 });
    lenis.on("scroll", ScrollTrigger.update);

    const tick = (time: number) => lenis.raf(time * 1000);
    gsap.ticker.add(tick);
    gsap.ticker.lagSmoothing(0);

    const eased = { value: 0 };
    const tween = gsap.to(eased, {
      value: 1,
      ease: "none",
      scrollTrigger: {
        trigger: track,
        start: "top top",
        end: "bottom bottom",
        scrub: 0.45,
        onUpdate: (self) => {
          raw.current = self.progress;
        },
      },
      onUpdate: () => {
        progress.current = eased.value;
      },
    });

    return () => {
      tween.scrollTrigger?.kill();
      tween.kill();
      gsap.ticker.remove(tick);
      lenis.destroy();
    };
  }, [trackRef, reducedMotion]);

  const value = useMemo<ScrollState>(
    () => ({ progress, raw, reducedMotion }),
    [reducedMotion],
  );

  return (
    <ScrollContext.Provider value={value}>{children}</ScrollContext.Provider>
  );
}

/** Remap a 0..1 progress value onto a sub-range, clamped, with smoothstep. */
export const band = (p: number, start: number, end: number) => {
  const t = Math.min(1, Math.max(0, (p - start) / (end - start)));
  return t * t * (3 - 2 * t);
};

/** Linear remap onto a sub-range, clamped. No easing. */
export const linear = (p: number, start: number, end: number) =>
  Math.min(1, Math.max(0, (p - start) / (end - start)));
