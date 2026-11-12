// Official GT Termin app icon (white rounded T on a blue gradient square).
export function BrandLogo({ size = 40 }: { size?: number }) {
  return (
    <img
      className="brand-logo"
      src={`${import.meta.env.BASE_URL}gt-termin-icon.png`}
      width={size}
      height={size}
      alt=""
      aria-hidden="true"
      draggable={false}
    />
  );
}
