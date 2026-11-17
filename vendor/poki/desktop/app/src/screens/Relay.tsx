import { useEffect, useState } from "react";
import { api, failureText, onProgress, type CfAccount, type Deployed, type WorkerStatus } from "../api";
import { t } from "../i18n";
import { Capsule, Card, Copy, ErrorBox, Field, Pill, Qr, Steps, useSteps } from "../ui";

export default function Relay() {
  const [relay, setRelay] = useState<Deployed | null>(null);
  const [token, setToken] = useState("");
  const [accounts, setAccounts] = useState<CfAccount[]>([]);
  const [accountId, setAccountId] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [up, setUp] = useState<boolean | null>(null);
  const [qr, setQr] = useState<string | null>(null);
  const [worker, setWorker] = useState<WorkerStatus | null>(null);
  const [saved, setSaved] = useState(false);
  const open = async (url: string) => { const { openUrl } = await import("@tauri-apps/plugin-opener"); openUrl(url); };
  const { steps, apply, fail, reset } = useSteps([{ id: "relay", title: "Deploy" }]);
  useEffect(() => {
    api.relayState().then(setRelay);
    api.relayWorker().then(setWorker).catch(() => {});
    api.relayTokenSaved().then(setSaved).catch(() => {});
    const un = onProgress("relay", apply);
    return () => { un.then((f) => f()); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  const lookup = async () => {
    setError(null);
    try { const a = await api.relayAccounts(token); setAccounts(a); setAccountId(a[0]?.id ?? ""); } catch (e) { setError(failureText(e)); }
  };
  const deploy = async () => {
    setBusy(true); setError(null); reset(); apply({ job: "relay", kind: "step", id: "relay", title: "Deploy" });
    try { const d = await api.relayDeploy(token, accountId); setRelay(d); setSaved(true); api.relayWorker().then(setWorker).catch(() => {}); setToken(""); setAccounts([]); apply({ job: "relay", kind: "done", id: "relay", detail: d.address }); }
    catch (e) { fail(failureText(e)); setError(failureText(e)); }
    setBusy(false);
  };
  return (
    <>
      <h1 className="page-title">{t("Relay")}</h1>
      <p className="page-sub">Poki has no shared relay: this deploys the Worker to your own Cloudflare account, so screenshots and taps pass only through a Worker you control.</p>
      <ErrorBox error={error} />
      {relay && (
        <Card>
          <div className="row between">
            <div className="grow"><h2 style={{ margin: 0 }}>{t("Your relay")}</h2><code className="small" style={{ userSelect: "text" }}>{relay.address}</code><div className="muted small">{relay.account_name}</div></div>
            {up !== null && <Pill tone={up ? "ok" : "bad"}>{t(up ? "Answering" : "Not answering")}</Pill>}
            <Copy text={relay.address} />
            <Capsule kind="ghost" sm onClick={() => api.relayCheck(relay.address).then(setUp)}>{t("Check")}</Capsule>
            <Capsule kind="ghost" sm onClick={() => api.qrSvg(relay.phone_link).then(setQr)}>{t("Show QR for the phone")}</Capsule>
          </div>
          {qr && <div className="row" style={{ marginTop: 14, alignItems: "flex-start" }}><Qr svg={qr} /><div className="grow"><p style={{ marginTop: 0 }}>In Poki on the iPhone, open Connect and scan this, or type the address under Relay address.</p><code className="small" style={{ userSelect: "text" }}>{relay.phone_link}</code></div></div>}
        </Card>
      )}
      {worker && (
        <Card>
          <h2>{t("Relay code")}</h2>
          <p className="muted small">{worker.source === "built in" ? t("Built into Poki Setup") : `${t("From release")} ${worker.source}`}. {t("Poki Setup deploys the relay from the same release as the Poki on your iPhone.")}</p>
          {worker.update_available && <p><Pill tone="warn">{t("Relay update available")}</Pill></p>}
          <div className="row">
            <Capsule kind="ghost" sm onClick={() => open(worker.download_url)}>{t("Download worker.js")}</Capsule>
            <Capsule kind="ghost" sm onClick={() => open(worker.guide_url)}>{t("Deploy it yourself")}</Capsule>
          </div>
        </Card>
      )}
      <Card>
        <h2>{t("Deploy to my Cloudflare account")}</h2>
        <p className="muted small">Make a token at dash.cloudflare.com/profile/api-tokens with the "Edit Cloudflare Workers" template. Poki Setup keeps it in Credential Manager so you can update the relay later. The Worker runs inside Workers Paid's included amounts; see deploy/cf-relay/DEPLOY.md.</p>
        <div className="stack">
          <Field label={t("Cloudflare API token")}><div className="row">{saved ? <span className="muted grow">{t("Saved in Credential Manager")} <Capsule kind="ghost" sm onClick={() => api.relayForgetToken().then(() => { setSaved(false); setAccounts([]); })}>{t("Forget")}</Capsule></span> : <input className="input mono grow" type="password" value={token} onChange={(e) => setToken(e.target.value)} />}<Capsule kind="ghost" onClick={lookup} disabled={!saved && token.length < 20}>{t("Continue")}</Capsule></div></Field>
          {accounts.length > 0 && (
            <Field label="Account"><select className="input" value={accountId} onChange={(e) => setAccountId(e.target.value)}>{accounts.map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}</select></Field>
          )}
          {accounts.length > 0 && <div><Capsule onClick={deploy} disabled={busy || !accountId}>{busy ? t("Deploying…") : t("Deploy")}</Capsule></div>}
          {(busy || steps[0].state !== "todo") && <Steps steps={steps} />}
        </div>
      </Card>
    </>
  );
}
