import { useRef } from "react";
import { ScrollProvider } from "./scroll/ScrollProvider";
import { Film } from "./film/Film";
import { Header } from "./product/Header";
import { ProductPage } from "./product/ProductPage";
import { SiteFooter } from "./product/SiteFooter";

/**
 * The film is the page's hero, not the page.
 *
 * Scroll still drives it exactly as before, through ScrollProvider and Film
 * untouched: the hero wrapper takes its height from the film's own track, and
 * the stage pins inside that wrapper. When the track is exhausted the stage
 * releases and the product below it scrolls into view in normal document flow.
 */
export default function App() {
  const track = useRef<HTMLDivElement>(null);

  return (
    <ScrollProvider trackRef={track}>
      <Header />
      <div className="hero">
        <Film />
        <div ref={track} className="track" aria-hidden="true" />
      </div>
      <ProductPage />
      <SiteFooter />
    </ScrollProvider>
  );
}
