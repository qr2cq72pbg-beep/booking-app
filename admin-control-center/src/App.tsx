import { BrowserRouter, Navigate, Route, Routes } from "react-router-dom";
import { AuthProvider, useAuth } from "./auth/AuthProvider";
import { AppShell } from "./layout/AppShell";
import { BlockedPage } from "./pages/BlockedPage";
import { BusinessDetailPage } from "./pages/BusinessDetailPage";
import { BusinessesPage } from "./pages/BusinessesPage";
import { LoginPage } from "./pages/LoginPage";
import { OverviewPage } from "./pages/OverviewPage";
import { SubscriptionsPage } from "./pages/SubscriptionsPage";

function Gate() {
  const { gate, gateMessage } = useAuth();

  if (gate === "booting" || gate === "checking") {
    return (
      <div className="auth-screen">
        <div className="auth-card">
          <div className="brand-mark" style={{ color: "var(--navy)" }}>XBOOK</div>
          <p className="lede">Checking administrator access…</p>
        </div>
      </div>
    );
  }

  if (gate === "signed_out") return <LoginPage />;

  if (gate === "forbidden") {
    return (
      <BlockedPage
        title="Unauthorized"
        body={
          gateMessage ||
          "This account is not a platform administrator. Business owners cannot access the Control Center."
        }
      />
    );
  }

  if (gate === "not_configured") {
    return (
      <BlockedPage
        title="Allowlist not configured"
        body={
          gateMessage ||
          "platform_admins has not been applied in Supabase yet. Do not grant access by making this user a business owner."
        }
      />
    );
  }

  if (gate === "error") {
    return (
      <BlockedPage
        title="Control Center unavailable"
        body={gateMessage || "Administrator verification failed."}
      />
    );
  }

  return (
    <Routes>
      <Route element={<AppShell />}>
        <Route path="/" element={<OverviewPage />} />
        <Route path="/businesses" element={<BusinessesPage />} />
        <Route path="/businesses/:businessId" element={<BusinessDetailPage />} />
        <Route path="/subscriptions" element={<SubscriptionsPage />} />
      </Route>
      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
  );
}

export default function App() {
  return (
    <BrowserRouter>
      <AuthProvider>
        <Gate />
      </AuthProvider>
    </BrowserRouter>
  );
}
