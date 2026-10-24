import { useAuth } from "../auth/AuthProvider";

export function BlockedPage({
  title,
  body,
}: {
  title: string;
  body: string;
}) {
  const { signOut, refreshGate, session } = useAuth();

  return (
    <div className="auth-screen">
      <div className="auth-card">
        <div className="brand-mark" style={{ color: "var(--navy)" }}>XBOOK</div>
        <h1>{title}</h1>
        <p className="lede">{body}</p>
        {session?.user?.email ? (
          <p className="muted">Signed in as {session.user.email}</p>
        ) : null}
        <button className="primary-btn" type="button" onClick={() => void refreshGate()}>
          Try again
        </button>
        <button className="text-btn" type="button" onClick={() => void signOut()}>
          Log out
        </button>
      </div>
    </div>
  );
}
