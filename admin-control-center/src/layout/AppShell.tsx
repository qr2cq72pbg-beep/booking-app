import { useState } from "react";
import { NavLink, Outlet } from "react-router-dom";
import { useAuth } from "../auth/AuthProvider";
import { BrandLogo } from "./BrandLogo";

const LINKS = [
  { to: "/", label: "Преглед", end: true },
  { to: "/businesses", label: "Бизниси", end: false },
  { to: "/subscriptions", label: "Претплати", end: false },
];

export function AppShell() {
  const { admin, signOut } = useAuth();
  const [open, setOpen] = useState(false);

  return (
    <div className="app-shell">
      {open ? <div className="backdrop" onClick={() => setOpen(false)} /> : null}
      <aside className={`sidebar ${open ? "open" : ""}`}>
        <div className="brand">
          <BrandLogo size={40} />
          <div>
            <div className="brand-mark">GT Termin</div>
            <div className="brand-sub">Control Center</div>
          </div>
        </div>
        <nav className="nav" onClick={() => setOpen(false)}>
          {LINKS.map((link) => (
            <NavLink key={link.to} to={link.to} end={link.end}>
              {link.label}
            </NavLink>
          ))}
        </nav>
        <div className="sidebar-foot">
          <div className="sidebar-email">{admin?.email || "Најавен"}</div>
          <button type="button" className="ghost-btn" onClick={() => void signOut()}>
            Одјава
          </button>
        </div>
      </aside>
      <main className="content">
        <div className="topbar">
          <button type="button" className="menu-btn" onClick={() => setOpen(true)} aria-label="Отвори мени">
            Мени
          </button>
          <span className="topbar-brand">
            <BrandLogo size={28} />
            <strong>GT Termin Admin</strong>
          </span>
        </div>
        <Outlet />
      </main>
    </div>
  );
}
