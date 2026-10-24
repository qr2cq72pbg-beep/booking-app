import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import App from "./App";
import "./index.css";

function showBootError(message: string) {
  const root = document.getElementById("root");
  if (!root) return;
  root.innerHTML = "";
  const wrap = document.createElement("div");
  wrap.className = "auth-screen";
  const card = document.createElement("div");
  card.className = "auth-card";
  const title = document.createElement("h1");
  title.textContent = "Control Center failed to start";
  const body = document.createElement("p");
  body.className = "lede";
  body.textContent = message;
  card.append(title, body);
  wrap.append(card);
  root.append(wrap);
}

try {
  const rootEl = document.getElementById("root");
  if (!rootEl) {
    throw new Error("Missing #root element.");
  }
  createRoot(rootEl).render(
    <StrictMode>
      <App />
    </StrictMode>,
  );
} catch (error) {
  const message =
    error instanceof Error ? error.message : "The Control Center could not render.";
  showBootError(message);
}
