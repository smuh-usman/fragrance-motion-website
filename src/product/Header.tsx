const LOGO = "/assets/lost-in-kashmir/product/logo.gif";

const NAV = [
  { label: "The Perfume", href: "#product" },
  { label: "Olfactive Notes", href: "#notes" },
  { label: "Description", href: "#description" },
];

/**
 * The shop's own header. It sits above the film in normal flow, so the film's
 * opening frame is never covered by navigation, and it scrolls away with the
 * hero rather than floating over the product page it belongs to.
 */
export function Header() {
  return (
    <header className="site-header" id="top">
      <a className="site-header__brand" href="#top">
        <img src={LOGO} alt="Imaginary Fragrances" width={170} height={85} />
      </a>
      <nav className="site-header__nav" aria-label="Product">
        <ul>
          {NAV.map((item) => (
            <li key={item.href}>
              <a href={item.href}>{item.label}</a>
            </li>
          ))}
        </ul>
      </nav>
    </header>
  );
}
