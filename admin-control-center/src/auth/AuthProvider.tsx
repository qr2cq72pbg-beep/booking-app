import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from "react";
import type { Session } from "@supabase/supabase-js";
import { fetchSession } from "../lib/adminApi";
import { supabase, supabaseConfigError } from "../lib/supabase";
import { AdminApiError, type AdminSession } from "../lib/types";

export type Gate = "booting" | "signed_out" | "checking" | "authorized" | "forbidden" | "not_configured" | "error";

type AuthContextValue = {
  session: Session | null;
  accessToken: string | null;
  admin: AdminSession | null;
  gate: Gate;
  gateMessage: string | null;
  signIn: (email: string, password: string) => Promise<void>;
  signOut: () => Promise<void>;
  refreshGate: () => Promise<void>;
};

const AuthContext = createContext<AuthContextValue | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [admin, setAdmin] = useState<AdminSession | null>(null);
  const [gate, setGate] = useState<Gate>("booting");
  const [gateMessage, setGateMessage] = useState<string | null>(null);

  const applyGate = useCallback(async (nextSession: Session | null) => {
    setSession(nextSession);
    if (!nextSession?.access_token) {
      setAdmin(null);
      setGate("signed_out");
      setGateMessage(null);
      return;
    }
    setGate("checking");
    try {
      const profile = await fetchSession(nextSession.access_token);
      setAdmin(profile);
      setGate("authorized");
      setGateMessage(null);
    } catch (error) {
      setAdmin(null);
      if (error instanceof AdminApiError && error.code === "forbidden") {
        setGate("forbidden");
        setGateMessage("This account is not on the platform administrator allowlist.");
        return;
      }
      if (error instanceof AdminApiError && error.code === "not_configured") {
        setGate("not_configured");
        setGateMessage(
          error.message ||
            "The platform_admins table has not been applied yet. The Control Center cannot authorize anyone until that SQL is run.",
        );
        return;
      }
      setGate("error");
      setGateMessage(
        error instanceof AdminApiError
          ? error.message || error.code
          : "Could not verify administrator access.",
      );
    }
  }, []);

  useEffect(() => {
    const configError = supabaseConfigError();
    if (configError || !supabase) {
      setGate("error");
      setGateMessage(configError || "Supabase client failed to start.");
      return;
    }
    const client = supabase;
    let cancelled = false;
    void client.auth.getSession().then(({ data }) => {
      if (!cancelled) void applyGate(data.session);
    });
    const { data: sub } = client.auth.onAuthStateChange((_event, next) => {
      void applyGate(next);
    });
    return () => {
      cancelled = true;
      sub.subscription.unsubscribe();
    };
  }, [applyGate]);

  const signIn = useCallback(async (email: string, password: string) => {
    if (!supabase) throw new Error("Supabase is not configured.");
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    if (error) throw new Error(error.message);
  }, []);

  const signOut = useCallback(async () => {
    if (supabase) await supabase.auth.signOut();
    setAdmin(null);
    setGate("signed_out");
  }, []);

  const refreshGate = useCallback(async () => {
    if (!supabase) {
      setGate("error");
      setGateMessage(supabaseConfigError() || "Supabase client failed to start.");
      return;
    }
    const { data } = await supabase.auth.getSession();
    await applyGate(data.session);
  }, [applyGate]);

  const value = useMemo<AuthContextValue>(
    () => ({
      session,
      accessToken: session?.access_token || null,
      admin,
      gate,
      gateMessage,
      signIn,
      signOut,
      refreshGate,
    }),
    [session, admin, gate, gateMessage, signIn, signOut, refreshGate],
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth(): AuthContextValue {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error("useAuth must be used within AuthProvider");
  return ctx;
}
