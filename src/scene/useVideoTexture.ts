import { useEffect, useMemo, useState } from "react";
import * as THREE from "three";

/**
 * A motion plate as a texture.
 *
 * Plates are muted, looping and inline, which is what lets them autoplay. Under
 * reduced motion no video is fetched at all: the caller falls back to the still
 * the plate was generated from, and the story stays fully readable.
 */
export function useVideoTexture(
  src: string,
  { enabled = true }: { enabled?: boolean } = {},
) {
  const [texture, setTexture] = useState<THREE.VideoTexture | null>(null);

  const video = useMemo(() => {
    if (!enabled || typeof document === "undefined") return null;
    const el = document.createElement("video");
    el.src = src;
    el.muted = true;
    el.loop = true;
    el.playsInline = true;
    el.preload = "auto";
    el.crossOrigin = "anonymous";
    return el;
  }, [src, enabled]);

  useEffect(() => {
    if (!video) return;

    const onReady = () => {
      const t = new THREE.VideoTexture(video);
      t.colorSpace = THREE.SRGBColorSpace;
      t.minFilter = THREE.LinearFilter;
      t.magFilter = THREE.LinearFilter;
      setTexture(t);
      void video.play().catch(() => {
        // Autoplay refused: the poster still carries the frame until a gesture
        // arrives, which the document-level primer below supplies.
      });
    };

    const prime = () => void video.play().catch(() => {});

    video.addEventListener("loadeddata", onReady);
    document.addEventListener("touchstart", prime, { once: true, passive: true });
    document.addEventListener("click", prime, { once: true });

    return () => {
      video.removeEventListener("loadeddata", onReady);
      document.removeEventListener("touchstart", prime);
      document.removeEventListener("click", prime);
      video.pause();
      video.removeAttribute("src");
      video.load();
    };
  }, [video]);

  return texture;
}
