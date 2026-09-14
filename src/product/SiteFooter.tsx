const LOGO = "/assets/lost-in-kashmir/product/logo.gif";
const PAYMENTS = "/assets/lost-in-kashmir/product/payment-icons.jpg";

export function SiteFooter() {
  return (
    <footer className="site-footer">
      <img
        className="site-footer__logo"
        src={LOGO}
        alt="Imaginary Fragrances"
        width={170}
        height={85}
      />
      <p className="site-footer__note">
        © Imaginary Fragrances — extrait de parfum, 32% concentration
      </p>
      <img
        className="site-footer__payments"
        src={PAYMENTS}
        alt="Payment methods accepted at checkout"
        width={1875}
        height={300}
      />
    </footer>
  );
}
