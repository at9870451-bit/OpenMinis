import { useEffect, useState } from "react";
import { api, failureText, onProgress, type Handoff, type Record_ } from "../api";
import { t } from "../i18n";
import { Capsule, Card, ErrorBox, Pill, Qr, Steps, useSteps } from "../ui";

export default function Phones() {
  const [records, setRecords] = useState<Record_[]>([]);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [qr, setQr] = useState<{ udid: string; handoff: Handoff } | null>(null);
  const { steps, apply, fail, reset } = useSteps([]);
  const load = () => api.records().then(setRecords).catch(() => {});
  useEffect(() => {
    load();
    const un = onProgress("renew", apply);
    return () => { un.then((f) => f()); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const renew = async (udid: string) => {
    setBusy(udid); setError(null); reset();
    try { await api.renew(udid); } catch (e) { fail(failureText(e)); setError(failureText(e)); }
    setBusy(null); load();
  };
  const share = async (udid: string) => {
    setError(null);
    try { setQr({ udid, handoff: await api.sharePairing(udid) }); } catch (e) { setError(failureText(e)); }
  };
  const now = Date.now() / 1000;
  return (
    <>
      <h1 className="page-title">{t("Phones")}</h1>
      <p className="page-sub">{t("free, Poki is signed 7 days at a time")}.</p>
      <ErrorBox error={error} />
      {records.length === 0 && <Card><span className="muted">{t("No iPhone set up from this computer yet.")}</span></Card>}
      {records.map((r) => {
        const days = Math.floor((r.profile_expires_at - now) / 86400);
        return (
          <Card key={r.udid}>
            <div className="row between">
              <div className="grow">
                <h2 style={{ margin: 0 }}>{r.phone_name}</h2>
                <div className="muted small">iOS {r.ios} · Poki {r.version} ({r.build}) · {r.team_name}{r.team_is_free ? " · free" : ""} · <span className="mono">{r.bundle_id}</span></div>
                {r.last_error && <div className="small" style={{ color: "var(--bad)", marginTop: 4 }}>{r.last_error}</div>}
              </div>
              <Pill tone={days < 0 ? "bad" : days <= 2 ? "warn" : "ok"}>{days < 0 ? t("expired") : `${days} ${t("days left")}`}</Pill>
              <Capsule onClick={() => renew(r.udid)} disabled={busy !== null}>{busy === r.udid ? t("Renewing…") : t("Renew")}</Capsule>
              <Capsule kind="ghost" onClick={() => share(r.udid)}>{t("Show pairing QR")}</Capsule>
              <Capsule kind="danger" sm onClick={() => api.forgetPhone(r.udid).then(load)}>{t("Forget")}</Capsule>
            </div>
            {busy === r.udid && steps.length > 0 && <><div className="hair" /><Steps steps={steps} /></>}
            {qr?.udid === r.udid && (
              <div className="row" style={{ marginTop: 14, alignItems: "flex-start" }}>
                <Qr svg={qr.handoff.qr_svg} />
                <div className="grow">
                  <p style={{ marginTop: 0 }}>{t("Scan this in Poki on the iPhone (same Wi-Fi).")}</p>
                  <code className="small" style={{ userSelect: "text" }}>{qr.handoff.link}</code>
                  <div style={{ marginTop: 10 }}><Capsule kind="ghost" sm onClick={() => { api.stopSharing(); setQr(null); }}>{t("Stop")}</Capsule></div>
                </div>
              </div>
            )}
          </Card>
        );
      })}
    </>
  );
}
