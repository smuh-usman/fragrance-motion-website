import type { PerspectiveCamera } from "three";

/**
 * Scale needed for a 1x1 plane sitting `planeZ` in front of the camera to cover
 * the viewport, in the CSS `object-fit: cover` sense: fill both axes, crop the
 * overflowing one, never letterbox.
 */
export function coverScale(
  camera: PerspectiveCamera,
  planeZ: number,
  viewportAspect: number,
  imageAspect: number,
) {
  const distance = Math.abs(camera.position.z - planeZ);
  const visibleHeight =
    2 * Math.tan((camera.fov * Math.PI) / 180 / 2) * distance;
  const visibleWidth = visibleHeight * viewportAspect;

  let height = visibleHeight;
  let width = height * imageAspect;

  if (width < visibleWidth) {
    width = visibleWidth;
    height = width / imageAspect;
  }

  return { width, height };
}

/**
 * The opposite fit: show the whole frame and accept empty space around it.
 *
 * The campaign photography is portrait, and the depth story it tells runs
 * vertically (stone underfoot, fruit and bottle at eye level, sea and sky
 * above). Cover-cropping that into a landscape viewport throws away both ends
 * of exactly the axis that matters, so the frame is contained and its edges are
 * bled into rather than cropped.
 */
export function containScale(
  camera: PerspectiveCamera,
  planeZ: number,
  viewportAspect: number,
  imageAspect: number,
  fill = 1,
) {
  const distance = Math.abs(camera.position.z - planeZ);
  const visibleHeight =
    2 * Math.tan((camera.fov * Math.PI) / 180 / 2) * distance;
  const visibleWidth = visibleHeight * viewportAspect;

  let height = visibleHeight * fill;
  let width = height * imageAspect;

  if (width > visibleWidth * fill) {
    width = visibleWidth * fill;
    height = width / imageAspect;
  }

  return { width, height };
}
