import { Gallery } from "./Gallery";
import { BuyBlock } from "./BuyBlock";
import { Notes } from "./Notes";
import { Narrative } from "./Narrative";

/**
 * The product page that follows the film: gallery and buy block side by side,
 * then what is in the bottle and what it smells of, then the story. It is in
 * normal document flow, so it simply scrolls in once the film's track ends.
 */
export function ProductPage() {
  return (
    <main className="product" id="product">
      <div className="product__intro">
        <Gallery />
        <BuyBlock />
      </div>
      <Notes />
      <Narrative />
    </main>
  );
}
