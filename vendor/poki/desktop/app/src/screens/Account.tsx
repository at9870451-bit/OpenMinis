import { useEffect, useState } from "react";
import { api, failureText, type Account as AccountT, type AppInfo, type Team } from "../api";
import { t } from "../i18n";
import { Capsule, Card, ErrorBox, Field, Toggle } from "../ui";

export default function Account({ info }: { info: AppInfo | null }) {
  const [acct, setAcct] = useState<AccountT | null>(null);
  const [teams, setTeams] = useState<Team[]>([]);
  const [appleId, setAppleId] = useState("");
  const [password, setPassword] = useState("");
  const [keep, setKeep] = useState(true);
  const [code, setCode] = useState("");
  const [factor, setFactor] = useState<"trusted_device" | "sms" | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const load = () => api.account().then((a) => { setAcct(a); if (a.signed_in) api.teams().then(setTeams).catch((e) => setError(failureText(e))); }).catch((e) => setError(failureText(e)));
  useEffect(() => { load(); }, []);

  const signIn = async () => {
    setBusy(true); setError(null);
    try {
      const f = await api.signIn(appleId, password, keep);
      setFactor(f);
      if (!f) { setPassword(""); load(); }
    } catch (e) { setError(failureText(e)); }
    setBusy(false);
  };
  const finish = async () => {
    setBusy(true); setError(null);
    try { await api.finishSignIn(code); setFactor(null); setCode(""); setPassword(""); load(); } catch (e) { setError(failureText(e)); }
    setBusy(false);
  };
  const anisetteIsSystem = acct?.anisette.kind === "system";

  return (
    <>
      <h1 className="page-title">{t("Apple ID")}</h1>
      <p className="page-sub">{info?.os === "macos" ? "" : ""}</p>
      <ErrorBox error={error} />
      {acct?.signed_in ? (
        <Card>
          <div className="row between">
            <div className="grow"><h2 style={{ margin: 0 }}>{acct.name}</h2><div className="muted small">{acct.apple_id}{acct.password_kept ? ` · ${t("Keep me signed in for weekly renewal")}` : ""}</div></div>
            <Capsule kind="ghost" onClick={() => api.signOut().then(load)}>{t("Sign out")}</Capsule>
          </div>
          <div className="hair" />
          <h2>{t("Team")}</h2>
          {teams.map((tm) => (
            <label key={tm.team_id} className="row" style={{ padding: "6px 0" }}>
              <input type="radio" name="team" checked={acct.team_id === tm.team_id} onChange={() => api.chooseTeam(tm.team_id).then(load)} />
              <span className="grow">{tm.name} <span className="muted small">{tm.team_id} · {tm.is_free ? t("free, Poki is signed 7 days at a time") : t("paid")}</span></span>
            </label>
          ))}
        </Card>
      ) : factor ? (
        <Card>
          <h2>{t("Enter the code")}</h2>
          <p className="muted">{factor === "sms" ? t("Apple sent a code by text message.") : t("Apple sent a code to your devices.")}</p>
          <form className="row" onSubmit={(e) => { e.preventDefault(); finish(); }}>
            <input className="input mono" style={{ width: 160, letterSpacing: "0.2em" }} value={code} onChange={(e) => setCode(e.target.value.replace(/\D/g, "").slice(0, 6))} inputMode="numeric" autoFocus placeholder="000000" />
            <Capsule type="submit" disabled={busy || code.length !== 6}>{t("Continue")}</Capsule>
            <Capsule kind="ghost" onClick={() => setFactor(null)}>{t("Stop")}</Capsule>
          </form>
        </Card>
      ) : (
        <Card>
          <form className="stack" onSubmit={(e) => { e.preventDefault(); signIn(); }}>
            <Field label={t("Apple ID")}><input className="input" value={appleId} onChange={(e) => setAppleId(e.target.value)} autoComplete="username" placeholder="you@example.com" /></Field>
            <Field label={t("Password")}><input className="input" type="password" value={password} onChange={(e) => setPassword(e.target.value)} autoComplete="current-password" /></Field>
            <Toggle on={keep} onChange={setKeep} label={t("Keep me signed in for weekly renewal")} />
            <div><Capsule type="submit" disabled={busy || !appleId || !password}>{busy ? "…" : t("Sign in")}</Capsule></div>
            <p className="muted small" style={{ margin: 0 }}>Your Apple ID and password go to Apple only, over TLS pinned to Apple's root. {anisetteIsSystem ? "" : "The anisette server sees a machine identity, never your Apple ID or password."}</p>
          </form>
        </Card>
      )}
    </>
  );
}
