import { useRef } from "react";
import { useFrame, useThree } from "@react-three/fiber";
import { useTexture } from "@react-three/drei";
import * as THREE from "three";
import { band, linear, useScroll } from "../scroll/ScrollProvider";
import { ACTS } from "./acts";
import { Backdrop, type BackdropHandle } from "./Backdrop";
import { DepthPlane, type DepthPlaneHandle } from "./DepthPlane";
import { KeyedPlane, type KeyedPlaneHandle } from "./KeyedPlane";
import { Ceremony } from "./Ceremony";
import { useVideoTexture } from "./useVideoTexture";
import { LOST_IN_KASHMIR, PLATES } from "./assets";

/**
 * One continuous take, in four acts, with scroll as the only clock.
 *
 *   ceremony the cap lifts off a sprayer, the ingredients revolve in and
 *            dissolve, the liquid mixes, the printed cover splits open on an
 *            empty bottle and it fills - see Ceremony.tsx
 *   reveal  a leaf passes the lens close enough to fill the frame, and the
 *           scene change happens hidden behind it
 *   world   the campaign photograph, alive and dimensional, travelled through
 *   exit    one citrus swells to macro until its skin is the whole viewport,
 *           an abstract yellow field for the next fragrance to arrive in
 */
export function Scene() {
  const { progress, reducedMotion } = useScroll();
  const { camera } = useThree();

  const textures = useTexture({
    campaign: LOST_IN_KASHMIR.campaign,
    depth: LOST_IN_KASHMIR.campaignDepth,
    leafSingle: LOST_IN_KASHMIR.leafCutout,
    citrus: LOST_IN_KASHMIR.citrus,
  });

  // Depth is data, not colour: leaving it in sRGB would bend the displacement.
  textures.depth.colorSpace = THREE.NoColorSpace;
  textures.campaign.colorSpace = THREE.SRGBColorSpace;
  textures.leafSingle.colorSpace = THREE.SRGBColorSpace;
  textures.citrus.colorSpace = THREE.SRGBColorSpace;

  // Motion arrives only as environment plates. Under reduced motion none are
  // fetched and the still simply stays still, which loses nothing but movement.
  const canopy = useVideoTexture(PLATES.canopy.src, { enabled: !reducedMotion });
  const shadows = useVideoTexture(PLATES.shadows.src, {
    enabled: !reducedMotion,
  });

  const campaignAspect = aspectOf(textures.campaign, 0.8);
  const leafSingleAspect = aspectOf(textures.leafSingle, 1.12);
  const citrusAspect = aspectOf(textures.citrus, 1);

  const nearLeaf = useRef<KeyedPlaneHandle>(null);
  const backLeaf = useRef<KeyedPlaneHandle>(null);
  const world = useRef<DepthPlaneHandle>(null);
  const backdrop = useRef<BackdropHandle>(null);
  const occluder = useRef<KeyedPlaneHandle>(null);
  const macro = useRef<KeyedPlaneHandle>(null);

  useFrame((state) => {
    const p = progress.current ?? 0;
    const t = state.clock.elapsedTime;
    const cam = camera as THREE.PerspectiveCamera;

    // The world waits behind the ceremony the whole time; the reveal only stops
    // hiding it. Everything before that beat fades out under the leaf.
    const revealed = linear(p, 0.628, 0.668);
    const studioAlive = 1 - revealed;

    // --- act 1: the studio, and its invasion -----------------------------
    if (nearLeaf.current) {
      const enter = band(p, 0.52, 0.62);
      const u = nearLeaf.current.material.uniforms;
      u.uOpacity.value = enter * studioAlive;
      const mesh = nearLeaf.current.mesh;
      mesh.userData.scale = 0.62;
      mesh.position.x = -1.5 + enter * 0.85;
      mesh.position.y = 0.55 + Math.sin(t * 0.22) * 0.03;
      mesh.rotation.z = -0.5 + enter * 0.16 + Math.sin(t * 0.19) * 0.015;
    }

    if (backLeaf.current) {
      const enter = band(p, 0.56, 0.645);
      const u = backLeaf.current.material.uniforms;
      u.uOpacity.value = enter * 0.9 * studioAlive;
      const mesh = backLeaf.current.mesh;
      mesh.userData.scale = 0.45;
      mesh.position.x = 1.5 - enter * 0.55;
      mesh.position.y = -0.35 + Math.cos(t * 0.16) * 0.03;
      mesh.rotation.z = 2.6 - enter * 0.2;
    }

    // --- act 2: the leaf that hides the cut ------------------------------
    if (occluder.current) {
      const sweep = linear(p, ACTS.revealStart, ACTS.revealEnd);
      const u = occluder.current.material.uniforms;
      // Present only across the sweep, opaque in the middle where it is doing
      // the actual work of covering the change.
      u.uOpacity.value = Math.min(1, band(p, 0.545, 0.595) * 1.2) *
        (1 - band(p, 0.655, 0.695));
      const mesh = occluder.current.mesh;
      // Travels from behind the bottle to past the lens, growing as it comes.
      mesh.userData.scale = 1.1 + Math.pow(sweep, 1.7) * 13;
      mesh.position.z = -0.4 + sweep * 3.1;
      mesh.position.x = -0.8 + sweep * 0.9;
      mesh.position.y = 0.3 - sweep * 0.5;
      mesh.rotation.z = -0.35 + sweep * 0.55;
    }

    // --- act 3: inside the photograph ------------------------------------
    if (backdrop.current) {
      // Clears away under the citrus so the exit is one surface, not a stack of
      // competing rectangles.
      backdrop.current.material.uniforms.uOpacity.value =
        revealed * (1 - band(p, 0.905, 0.975));
    }

    if (world.current) {
      const u = world.current.material.uniforms;
      u.uOpacity.value = revealed * (1 - band(p, 0.905, 0.975));

      // Forward travel through the scene. Small: the parallax has to stay
      // plausible, so the camera walks rather than flies.
      const travel = band(p, 0.665, ACTS.worldEnd);
      world.current.mesh.position.z = -0.35 + travel * 0.5;

      // Defocus only while pushing into the citrus, never while reading.
      u.uBlurAmount.value = band(p, ACTS.worldEnd, 0.955) * 3.2;
      u.uFocus.value = 0.62;
      u.uExposure.value = 1 + band(p, 0.88, 1) * 0.12;

      // A generated plate is never pixel-identical to the still it was cut
      // from, so the moment of substitution is spent where nothing can be
      // seen: entirely behind the occluding leaf, which is opaque across
      // roughly 0.60 to 0.67. By the time the leaf clears, the environment is
      // already moving and there is no cross-fade for the eye to catch.
      const alive = band(p, 0.575, 0.628);
      u.uMixA.value = alive;
      u.uMixB.value = alive * 0.9;
    }

    // Camera drift belongs to act 3 alone: a hand-held breath, not a ride.
    const inWorld = band(p, 0.655, 0.70) * (1 - band(p, 0.945, 1));
    cam.position.x = Math.sin(t * 0.13) * 0.045 * inWorld;
    cam.position.y = Math.cos(t * 0.11) * 0.03 * inWorld;
    cam.lookAt(0, 0, 0);

    // --- act 4: out through the citrus skin ------------------------------
    if (macro.current) {
      const push = linear(p, ACTS.worldEnd, 1);
      const u = macro.current.material.uniforms;
      u.uOpacity.value = band(p, ACTS.worldEnd, 0.90);
      const mesh = macro.current.mesh;
      u.uExposure.value = 1.12;

      // Starts as one fruit sitting in the basket, ends as a field of citrus
      // skin. How far it grows is a composition decision, not a resolution one:
      // pushed to six times the viewport the frame lands inside a single shaded
      // patch of peel and reads as brown mud, however sharp the source is.
      // Stopping near one and a half keeps the pores, the curve and the sunlit
      // edge all in shot, which is what makes it read as citrus at all.
      mesh.userData.scale = 0.3 + Math.pow(push, 1.8) * 2.9;
      mesh.position.z = -0.3 + push * 1.9;
      // Drifts down and left, which brings the sunlit upper right of the fruit
      // into the centre of frame as it swells.
      mesh.position.x = 0.5 - push * 0.62;
      mesh.position.y = -0.4 - push * 0.15;
    }
  });

  return (
    <>
      <Ceremony />

      {/* The world is mounted from the start so the reveal never waits on a
          decode; it is simply invisible until the leaf hides the change. */}
      <Backdrop
        ref={backdrop}
        color={textures.campaign}
        aspect={campaignAspect}
        z={-1.4}
      />

      <DepthPlane
        ref={world}
        color={textures.campaign}
        depth={textures.depth}
        aspect={campaignAspect}
        depthScale={0.55}
        fit="contain"
        fill={1.02}
        z={-0.35}
        plateA={{
          texture: canopy,
          rect: PLATES.canopy.rect,
          feather: PLATES.canopy.feather,
        }}
        plateB={{
          texture: shadows,
          rect: PLATES.shadows.rect,
          feather: PLATES.shadows.feather,
        }}
      />




      <KeyedPlane
        ref={backLeaf}
        color={textures.leafSingle}
        aspect={leafSingleAspect}
        mode="alpha"
        position={[1.9, -0.35, -0.1]}
      />


      <KeyedPlane
        ref={nearLeaf}
        color={textures.leafSingle}
        aspect={leafSingleAspect}
        mode="alpha"
        feather={0.16}
        position={[-2.4, 0.55, 0.9]}
      />


      <KeyedPlane
        ref={occluder}
        color={textures.leafSingle}
        aspect={leafSingleAspect}
        mode="alpha"
        feather={0.1}
        position={[-0.8, 0.3, -0.4]}
      />

      <KeyedPlane
        ref={macro}
        color={textures.citrus}
        aspect={citrusAspect}
        mode="oval"
        feather={0.09}
        position={[0.5, -0.4, -0.3]}
      />
    </>
  );
}

function aspectOf(texture: THREE.Texture, fallback: number) {
  const image = texture.image as { width?: number; height?: number } | undefined;
  if (image?.width && image?.height) return image.width / image.height;
  return fallback;
}
