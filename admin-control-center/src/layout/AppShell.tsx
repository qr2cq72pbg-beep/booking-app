import { useState } from "react";
import { NavLink, Outlet } from "react-router-dom";
import { useAuth } from "../auth/AuthProvider";

const LINKS = [
  { to: "/", label: "Overview", end: true },
  { to: "/businesses", label: "Businesses", end: false },
  { to: "/subscriptions", label: "Subscriptions", end: false },
];

export function AppShell() {
  const { admin, signOut } = useAuth();
  const [open, setOpen] = useState(false);

  return (
    <div className="app-shell">
      {open ? <div className="backdrop" onClick={() => setOpen(false)} /> : null}
      <aside className={`sidebar ${open ? "open" : ""}`}>
        <div className="brand">
          <div className="brand-mark">XBOOK</div>
          <div className="brand-sub">Control Center</div>
        </div>
        <nav className="nav" onClick={() => setOpen(false)}>
          {LINKS.map((link) => (
            <NavLink key={link.to} to={link.to} end={link.end}>
              {link.label}
            </NavLink>
          ))}
        </nav>
        <div className="sidebar-foot">
          <div className="sidebar-email">{admin?.email || "Signed in"}</div>
          <button type="button" className="ghost-btn" onClick={() => void signOut()}>
            Log out
          </button>
        </div>
      </aside>
      <main className="content">
        <div className="topbar">
          <button type="button" className="menu-btn" onClick={() => setOpen(true)}>
            Menu
          </button>
          <strong>Control Center</strong>
        </div>
        <Outlet />
      </main>
    </div>
  );
}
