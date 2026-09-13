import { useMemo, useRef } from "react";
import { useFrame, useThree } from "@react-three/fiber";
import { useTexture } from "@react-three/drei";
import * as THREE from "three";
import { band, linear, useScroll } from "../scroll/ScrollProvider";
import { ACTS } from "./acts";
import { BOTTLE, frameY, plateU, plateV } from "./bottle";
import { Cutout, type CutoutHandle } from "./Cutout";
import { CoverHalf, type CoverHandle } from "./CoverPanel";
import { FlatPlane, type FlatPlaneHandle } from "./FlatPlane";
import { Stream, type StreamHandle } from "./Stream";
import { Vessel, type VesselHandle } from "./Vessel";
import { useVideoTexture } from "./useVideoTexture";
import { CEREMONY, LOST_IN_KASHMIR, STUDIO_GROUND } from "./assets";

/**
 * The opening: a bottle opened, filled and closed again, entirely from the
 * brand's own photographs.
 *
 * The bottle is never regenerated and never distorted. Every piece is a plate
 * cut from the one packshot and positioned in that packshot's own pixel
 * coordinates, so the cap sits where it was photographed, the cover halves hinge
 * on the silhouette they already occupy, and a closed bottle at the end of the
 * act is the supplied image rather than a reconstruction of it.
 *
 * The only generated asset in the whole act is the liquid, which was rendered on
 * black with no product in frame.
 */

/** Drops the rig below centre so the lifted cap has headroom. */
const RIG_DROP = 0.11;

/**
 * The act, beat by beat, as fractions of its own length. Written out rather
 * than inlined because the overlaps are the choreography: the ingredients begin
 * arriving before the cap has finished lifting, they start dissolving before
 * the last one lands, and the cover opens while the liquid is still gathering.
 * Nothing here waits its turn.
 */
const BEAT = {
  lift: [0.05, 0.16],
  orbit: [0.10, 0.42],
  dissolve: [0.41, 0.55],
  mix: [0.44, 0.62],
  coverOpen: [0.55, 0.66],
  pour: [0.60, 0.80],
  coverClose: [0.80, 0.89],
  capClose: [0.87, 0.97],
} as const;

/**
 * The cast, and the orbit each one rides in on. They travel as a ring around
 * the bottle rather than as five objects sliding to five marks: `turn` is how
 * far round each one sweeps on its way in, and `phase` offsets where in that
 * sweep it passes behind the glass.
 */
const INGREDIENTS = [
  { key: "pineapple", theta: 2.35, turn: 0.46, phase: 0.0, size: 0.27, dir: 1, delay: 0.0 },
  { key: "grapefruit", theta: 0.10, turn: -0.42, phase: 1.1, size: 0.20, dir: -1, delay: 0.03 },
  { key: "vanilla", theta: 3.70, turn: 0.40, phase: 2.4, size: 0.28, dir: 1, delay: 0.06 },
  { key: "palosanto", theta: 5.05, turn: -0.50, phase: 3.6, size: 0.22, dir: -1, delay: 0.09 },
  { key: "grapefruitHalf", theta: 1.25, turn: 0.52, phase: 4.9, size: 0.15, dir: 1, delay: 0.12 },
] as const;

/** Three instances of the one liquid plate, so it reads as a swirl not a loop. */
const RIBBONS = [
  { theta: 0.0, radius: 0.44, size: 0.78, dir: 1, delay: 0.0 },
  { theta: 2.2, radius: 0.36, size: 0.66, dir: -1, delay: 0.07 },
  { theta: 4.3, radius: 0.28, size: 0.92, dir: 1, delay: 0.14 },
] as const;

export function Ceremony() {
  const { progress, reducedMotion } = useScroll();
  const { camera, size } = useThree();

  const tex = useTexture({
    cover: LOST_IN_KASHMIR.bottleCut,
    clean: LOST_IN_KASHMIR.bottleClean,
    cap: LOST_IN_KASHMIR.cap,
    nozzle: LOST_IN_KASHMIR.nozzle,
    pineapple: CEREMONY.pineapple,
    grapefruit: CEREMONY.grapefruit,
    grapefruitHalf: CEREMONY.grapefruitHalf,
    vanilla: CEREMONY.vanilla,
    palosanto: CEREMONY.palosanto,
  });
  for (const t of Object.values(tex)) t.colorSpace = THREE.SRGBColorSpace;

  const liquid = useVideoTexture(CEREMONY.ribbons, { enabled: !reducedMotion });

  const ground = useMemo(() => new THREE.Color(STUDIO_GROUND), []);
  const aspects = useMemo(
    () => ({
      cap: BOTTLE.cap.w / BOTTLE.cap.h,
      nozzle: BOTTLE.nozzle.w / BOTTLE.nozzle.h,
      pineapple: ratio(tex.pineapple),
      grapefruit: ratio(tex.grapefruit),
      grapefruitHalf: ratio(tex.grapefruitHalf),
      vanilla: ratio(tex.vanilla),
      palosanto: ratio(tex.palosanto),
    }),
    [tex],
  );

  const vessel = useRef<VesselHandle>(null);
  const halves = useRef<(CoverHandle | null)[]>([]);
  const cap = useRef<FlatPlaneHandle>(null);
  const nozzle = useRef<FlatPlaneHandle>(null);
  const stream = useRef<StreamHandle>(null);
  const items = useRef<(CutoutHandle | null)[]>([]);
  const ribbons = useRef<(CutoutHandle | null)[]>([]);

  // The packshot frame's height in world units. Everything in the act is
  // measured against this, so the whole rig scales as one photograph.
  const frameHeight = () => {
    const cam = camera as THREE.PerspectiveCamera;
    const visible = 2 * Math.tan((cam.fov * Math.PI) / 180 / 2) * cam.position.z;
    const byWidth =
      (visible * (size.width / size.height) * 0.52) /
      (BOTTLE.frame.w / BOTTLE.frame.h);
    return Math.min(visible * 0.78, byWidth);
  };

  const plateHeight = () => frameHeight() * (BOTTLE.plate.h / BOTTLE.frame.h);
  const plateWidth = () => frameHeight() * (BOTTLE.plate.w / BOTTLE.frame.h);

  useFrame((state) => {
    const p = progress.current ?? 0;
    const t = state.clock.elapsedTime;
    const c = linear(p, 0, ACTS.ceremonyEnd);

    const Hf = frameHeight();
    const k = Hf / BOTTLE.frame.h; // world units per packshot pixel
    const drop = Hf * RIG_DROP;
    // A point in packshot pixels, placed in the world.
    const wx = (px: number) => (px - BOTTLE.frame.w / 2) * k;
    const wy = (py: number) => (BOTTLE.frame.h / 2 - py) * k - drop;

    // The act hands over to the leaf occlusion, fading as that takes the frame.
    const alive = 1 - band(p, ACTS.ceremonyEnd - 0.03, ACTS.ceremonyEnd + 0.04);

    const lift = band(c, ...BEAT.lift) - band(c, ...BEAT.capClose);
    const open = band(c, ...BEAT.coverOpen) - band(c, ...BEAT.coverClose);
    const fill = band(c, BEAT.pour[0] + 0.05, BEAT.pour[1]);

    const glassCx = wx((BOTTLE.glass.x0 + BOTTLE.glass.x1) / 2);
    const glassCy = wy(frameY((BOTTLE.glass.y0 + BOTTLE.glass.y1) / 2));
    const neckY = wy(frameY(BOTTLE.collar.y1));

    // --- the vessel ------------------------------------------------------
    if (vessel.current) {
      const u = vessel.current.u;
      u.uOpacity.value = alive;
      u.uTime.value = t;
      u.uFilling.value = band(c, BEAT.pour[0], BEAT.pour[0] + 0.06) *
        (1 - band(c, BEAT.pour[1], BEAT.pour[1] + 0.06));
      u.uSurface.value =
        plateV(BOTTLE.level.empty + (BOTTLE.level.full - BOTTLE.level.empty) * fill);
      vessel.current.mesh.position.y = wy(frameY(BOTTLE.plate.h / 2));
    }

    // --- the cover -------------------------------------------------------
    const swing = Math.pow(open, 0.6) * 1.22;
    halves.current.forEach((half, i) => {
      if (!half) return;
      const side = i === 0 ? -1 : 1;
      half.u.uOpacity.value = alive;
      // Turning toward the viewer takes each face out of the key light.
      half.u.uShade.value = 0.62 + 0.38 * Math.cos(swing);
      const mesh = half.mesh;
      mesh.rotation.y = side * swing;
      // A hair of travel outward as well as round, so the two part rather than
      // merely rotate in place.
      mesh.position.set(
        wx(side < 0 ? BOTTLE.glass.x0 : BOTTLE.glass.x1) + side * open * Hf * 0.05,
        glassCy,
        0,
      );
    });

    // --- the neck and the cap --------------------------------------------
    if (nozzle.current) {
      const u = nozzle.current.material.uniforms;
      // Brought up quickly under the rising cap: it is real metal that was
      // always there, not something that arrives.
      u.uOpacity.value = band(c, BEAT.lift[0] + 0.01, BEAT.lift[0] + 0.05) *
        (1 - band(c, BEAT.capClose[1] - 0.05, BEAT.capClose[1])) * alive;
      const mesh = nozzle.current.mesh;
      // The vessel writes depth across the whole plate, so anything standing on
      // the neck has to be queued after it or it is simply painted over.
      mesh.renderOrder = 5;
      mesh.position.set(
        wx(BOTTLE.nozzle.cx),
        wy(BOTTLE.nozzle.base - BOTTLE.nozzle.h / 2),
        0.004,
      );
    }

    if (cap.current) {
      const u = cap.current.material.uniforms;
      u.uOpacity.value = alive;
      const mesh = cap.current.mesh;
      mesh.renderOrder = 8;
      // Rises straight off the collar, drifts a little and turns slightly, the
      // way a lifted lid does, then comes back down the same path.
      mesh.position.set(
        wx(BOTTLE.cap.x + BOTTLE.cap.w / 2) + lift * Hf * 0.03,
        wy(BOTTLE.cap.y + BOTTLE.cap.h / 2) + lift * Hf * 0.16,
        lift * 0.25,
      );
      mesh.rotation.z = lift * 0.16 + Math.sin(t * 0.5) * 0.012 * lift;
    }

    // --- the ingredients -------------------------------------------------
    INGREDIENTS.forEach((ing, i) => {
      const handle = items.current[i];
      if (!handle) return;

      const enter = band(c, BEAT.orbit[0] + ing.delay, BEAT.orbit[1] + ing.delay);
      const melt = band(c, BEAT.dissolve[0] + ing.delay * 0.5, BEAT.dissolve[1] + ing.delay * 0.5);

      handle.u.uOpacity.value = enter * alive;
      handle.u.uDissolve.value = melt;

      // Revolving, not sliding: each one sweeps part of a turn on its way in
      // and keeps turning once it arrives, so the ring is never still.
      const theta = ing.theta + enter * ing.turn * Math.PI * 2 + t * 0.11 * ing.dir;
      // Drawn in as the liquid forms, and lifted toward the neck as it goes.
      const radius = Hf * (0.96 - 0.38 * enter - 0.12 * melt);
      const rise = melt * (neckY - glassCy) * 0.75;

      const mesh = handle.mesh;
      mesh.position.set(
        glassCx + Math.cos(theta) * radius * 0.72,
        glassCy + Math.sin(theta) * radius * 0.62 + rise + Math.sin(t * 0.3 + i) * 0.006 * Hf,
        Math.sin(theta + ing.phase) * Hf * 0.36,
      );
      mesh.rotation.z = theta * 0.35 + Math.sin(t * 0.22 + i) * 0.03;
      mesh.userData.scale = (1 - melt * 0.3) * (1 + Math.sin(theta + ing.phase) * 0.1);
      mesh.userData.stretch = 0.34 + 0.66 * Math.abs(Math.cos(theta * 1.35 + ing.phase));
      // Half the ring passes behind the glass. Ordering rather than depth,
      // because these are unlit cutouts that must never z-fight the bottle.
      mesh.renderOrder = mesh.position.z < 0 ? 1 : 6;
    });

    // --- the liquid ------------------------------------------------------
    RIBBONS.forEach((rib, i) => {
      const handle = ribbons.current[i];
      if (!handle) return;

      const inn = band(c, BEAT.mix[0] + rib.delay, BEAT.mix[0] + 0.14 + rib.delay);
      const merge = band(c, BEAT.mix[1] - 0.12, BEAT.mix[1]);
      const sink = band(c, BEAT.pour[0] - 0.02, BEAT.pour[0] + 0.12);
      handle.u.uOpacity.value = inn * (1 - sink) * 0.92 * alive;

      // Gathering: the three swirls tighten into one mass at the neck, then go
      // down it. The spin accelerates as the radius closes, which is what makes
      // the merge read as mixing rather than as three clips fading out.
      const theta = rib.theta + t * (0.5 + merge * 2.4) * rib.dir;
      const radius = Hf * rib.radius * (1 - merge * 0.82);
      const climb = merge * (neckY - glassCy);

      const mesh = handle.mesh;
      mesh.position.set(
        glassCx + Math.cos(theta) * radius,
        glassCy + Math.sin(theta) * radius * 0.5 + climb - sink * Hf * 0.12,
        Math.sin(theta) * Hf * 0.2,
      );
      mesh.rotation.z = theta * 0.6;
      mesh.userData.scale = rib.size * (0.8 + inn * 0.2) * (1 - merge * 0.42) * (1 - sink * 0.4);
      mesh.userData.stretch = 1;
      mesh.renderOrder = mesh.position.z < 0 ? 1 : 7;
    });

    // --- the pour --------------------------------------------------------
    if (stream.current) {
      const u = stream.current.u;
      u.uTime.value = t;
      u.uHead.value = band(c, BEAT.pour[0], BEAT.pour[0] + 0.07);
      u.uOpacity.value =
        band(c, BEAT.pour[0], BEAT.pour[0] + 0.05) *
        (1 - band(c, BEAT.pour[1] - 0.07, BEAT.pour[1])) * alive;

      // Spans the neck down to the surface, so it shortens as the bottle fills.
      const topPx = frameY(BOTTLE.collar.y1);
      const surfacePx = frameY(
        BOTTLE.level.empty + (BOTTLE.level.full - BOTTLE.level.empty) * fill,
      );
      const height = Math.max(0.001, (surfacePx - topPx) * k);
      stream.current.mesh.scale.set(118 * k, height, 1);
      stream.current.mesh.position.set(wx(BOTTLE.nozzle.cx), wy((topPx + surfacePx) / 2), 0.02);
    }
  });

  const glassW = (BOTTLE.glass.x1 - BOTTLE.glass.x0) * (frameHeight() / BOTTLE.frame.h);
  const glassH = (BOTTLE.glass.y1 - BOTTLE.glass.y0) * (frameHeight() / BOTTLE.frame.h);
  const coverV: [number, number] = [plateV(BOTTLE.glass.y1), plateV(BOTTLE.glass.y0)];

  return (
    <>
      <Vessel
        ref={vessel}
        map={tex.clean}
        ground={ground}
        width={plateWidth()}
        height={plateHeight()}
        z={-0.012}
      />

      {/* The two halves are cut at the bottle's own axis, which measurement
          puts exactly on u = 0.5, so closed they rejoin into the packshot. */}
      <CoverHalf
        ref={(h) => {
          halves.current[0] = h;
        }}
        map={tex.cover}
        side={-1}
        width={glassW / 2}
        height={glassH}
        uvMin={[plateU(BOTTLE.glass.x0), coverV[0]]}
        uvMax={[0.5, coverV[1]]}
      />
      <CoverHalf
        ref={(h) => {
          halves.current[1] = h;
        }}
        map={tex.cover}
        side={1}
        width={glassW / 2}
        height={glassH}
        uvMin={[0.5, coverV[0]]}
        uvMax={[plateU(BOTTLE.glass.x1), coverV[1]]}
      />

      <FlatPlane
        ref={nozzle}
        color={tex.nozzle}
        aspect={aspects.nozzle}
        worldHeight={frameHeight() * (BOTTLE.nozzle.h / BOTTLE.frame.h)}
        feather={0.004}
      />

      <FlatPlane
        ref={cap}
        color={tex.cap}
        aspect={aspects.cap}
        worldHeight={frameHeight() * (BOTTLE.cap.h / BOTTLE.frame.h)}
        feather={0.008}
      />

      {INGREDIENTS.map((ing, i) => (
        <Cutout
          key={ing.key}
          ref={(h) => {
            items.current[i] = h;
          }}
          map={tex[ing.key as keyof typeof tex]}
          aspect={aspects[ing.key as keyof typeof aspects]}
          worldHeight={frameHeight() * ing.size}
          renderOrder={6}
        />
      ))}

      {liquid && (
        <>
          {RIBBONS.map((_, i) => (
            <Cutout
              key={i}
              ref={(h) => {
                ribbons.current[i] = h;
              }}
              map={liquid}
              aspect={1}
              worldHeight={frameHeight()}
              mode="luma"
              gain={2.4}
              colorize={0.48}
              renderOrder={7}
            />
          ))}
          <Stream ref={stream} map={liquid} />
        </>
      )}
    </>
  );
}

function ratio(texture: THREE.Texture) {
  const image = texture.image as { width?: number; height?: number } | undefined;
  return image?.width && image?.height ? image.width / image.height : 1;
}
