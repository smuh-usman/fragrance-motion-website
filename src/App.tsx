import { useRef } from "react";
import { ScrollProvider } from "./scroll/ScrollProvider";
import { Film } from "./film/Film";

/**
 * The page is one fixed stage plus a tall, empty scroll track. Nothing scrolls
 * past the viewer; scroll is read as a position in the film and spent leading
 * the playhead. Chapter copy lives in ordinary semantic HTML above the film so
 * it stays crisp, selectable and readable to a screen reader in document order.
 */
export default function App() {
  const track = useRef<HTMLDivElement>(null);

  return (
    <ScrollProvider trackRef={track}>
      <Film />
      <div ref={track} className="track" aria-hidden="true" />
    </ScrollProvider>
  );
}
