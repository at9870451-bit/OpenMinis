import { useEffect, useState } from "react";
import { api, failureKind, failureText, onProgress, type Account, type Handoff, type PhoneRow } from "../api";
import { t } from "../i18n";
import { Capsule, Card, ErrorBox, Pill, Qr, Steps, useInterval, useSteps } from "../ui";

const STEPS = [
  { id: "phone", title: "Phone" }, { id: "pair", title: "Pairing" }, { id: "devmode", title: "Developer Mode" },
  { id: "account", title: "Account" }, { id: "release", title: "Release" }, { id: "sign", title: "Signing" },
  { id: "install", title: "Install" }, { id: "pairing_file", title: "Pairing file" },
];

export default function Setup({ goAccount }: { goAccount: () => void }) {
  const [rows, setRows] = useState<PhoneRow[] | null>(null);
  const [listError, setListError] = useState<{ kind: string; text: string } | null>(null);
  const [account, setAccount] = useState<Account | null>(null);
  const [running, setRunning] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // Set when the Apple Account is at its certificate limit: the person decides whether to replace it.
  const [certQuestion, setCertQuestion] = useState(false);
  const [result, setResult] = useState<{ notes: string[]; handoff: Handoff | null; name: string; version: string } | null>(null);
  const { steps, apply, fail, reset } = useSteps(STEPS);
  const [chosen, setChosen] = useState<string | null>(null);
  const [localIpa, setLocalIpa] = useState<string | null>(null);
  const pickIpa = async () => {
    const { open } = await import("@tauri-apps/plugin-dialog");
    const f = await open({ multiple: false, filters: [{ name: "IPA", extensions: ["ipa"] }] });
    setLocalIpa((f as string | null) ?? null);
  };

  useInterval(() => {
    if (running) return;
    api.phones().then((r) => { setRows(r); setListError(null); }).catch((e) => { setRows([]); setListError({ kind: failureKind(e), text: failureText(e) }); });
    api.account().then(setAccount).catch(() => {});
  }, 3000, [running]);

  useEffect(() => {
    const un = onProgress("install", apply);
    return () => { un.then((f) => f()); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const phone = rows?.find((r) => r.phone.udid === chosen) ?? rows?.find((r) => r.phone.link.kind === "usb") ?? rows?.[0] ?? null;

  const start = async () => {
    if (!phone) return;
    setRunning(true); setError(null); setResult(null); setCertQuestion(false); reset();
    try {
      const r = await api.install(phone.phone.udid, false, localIpa);
      setResult({ notes: r.notes, handoff: r.handoff, name: r.record.phone_name, version: r.record.version });
    } catch (e) {
      const text = failureText(e);
      fail(text); setError(text);
      setCertQuestion(failureKind(e) === "certificate_limit");
    } finally {
      setRunning(false);
    }
  };

  return (
    <>
      <div className="hero" style={{ marginBottom: 24 }}>
        <img className="bear" src="/icon.png" alt="" />
        <div>
          <h1>{t("Set up Poki on this iPhone")}</h1>
          <p className="page-sub" style={{ margin: 0 }}>{t("Connect the iPhone with a cable to set it up; this works on every iOS version.")}</p>
        </div>
      </div>

      <Card>
        {listError && listError.kind === "usbmuxd" && <div className="note">{listError.text}</div>}
        {!phone && !listError && <div className="row"><span className="muted">{rows === null ? t("Looking for an iPhone…") : t("Plug the iPhone in with a cable and unlock it.")}</span></div>}
        {rows && rows.length > 1 && (
          <div className="seg" style={{ marginBottom: 12 }}>
            {rows.map((r) => <button key={r.phone.udid} className={phone?.phone.udid === r.phone.udid ? "on" : ""} onClick={() => setChosen(r.phone.udid)}>{r.facts?.name ?? r.phone.udid.slice(0, 8)}</button>)}
          </div>
        )}
        {phone && (
          <div className="row between">
            <div className="grow">
              <h2 style={{ margin: 0 }}>{phone.facts?.name ?? t("Phone")}</h2>
              <div className="muted small">
                {phone.facts ? `${phone.facts.product_type} · iOS ${phone.facts.ios}` : phone.error}
                {phone.record && <> · {t("Poki is installed.")} {phone.record.version}</>}
              </div>
            </div>
            {phone.facts && <Pill tone={phone.facts.paired_with_this_computer ? "ok" : "warn"}>{t(phone.facts.paired_with_this_computer ? "paired" : "not paired")}</Pill>}
            {phone.facts && <Pill tone={phone.facts.developer_mode ? "ok" : "warn"}>{t("Developer Mode")} {t(phone.facts.developer_mode ? "on" : "off")}</Pill>}
          </div>
        )}
        <div className="hair" />
        {account && !account.signed_in ? (
          <div className="row between">
            <span>{t("Sign in with your Apple ID first.")}</span>
            <Capsule onClick={goAccount}>{t("Sign in")}</Capsule>
          </div>
        ) : (
          <div className="row between">
            <span className="muted small grow">{account?.name ?? account?.apple_id ?? ""}{account?.team_id ? ` · ${t("Team")} ${account.team_id}` : ""}</span>
            <span className="muted small">{localIpa ? localIpa.split(/[\\/]/).pop() : t("Latest release")}</span>
            <Capsule kind="ghost" sm onClick={localIpa ? () => setLocalIpa(null) : pickIpa} disabled={running}>{localIpa ? t("Use the latest release") : t("Use an IPA file…")}</Capsule>
            <Capsule big={false} onClick={start} disabled={!phone || running || !account?.signed_in}>{running ? t("Setting up…") : t("Set up Poki")}</Capsule>
          </div>
        )}
      </Card>

      {(running || steps.some((s) => s.state !== "todo")) && (
        <Card>
          <Steps steps={steps} />
          <ErrorBox error={error} />
          {certQuestion && !running && (
            <div style={{ display: "flex", gap: 8, marginTop: 12 }}>
              <Capsule kind="danger" onClick={async () => { try { await api.approveCertificateReplacement(); await start(); } catch (e) { setError(failureText(e)); } }}>{t("Replace Certificate")}</Capsule>
              <Capsule kind="ghost" onClick={() => setCertQuestion(false)}>{t("Cancel")}</Capsule>
            </div>
          )}
        </Card>
      )}

      {result && (
        <Card white>
          <h2>{t("Done")}</h2>
          <p style={{ margin: 0 }}>Poki {result.version} · {result.name}</p>
          {result.notes.map((n, i) => <p key={i} className="muted small" style={{ margin: "6px 0 0" }}>{n}</p>)}
          {result.handoff && (
            <div className="row" style={{ marginTop: 14, alignItems: "flex-start" }}>
              <Qr svg={result.handoff.qr_svg} />
              <div className="grow">
                <p style={{ marginTop: 0 }}>{t("Scan this with the iPhone's Camera (same Wi-Fi). Poki opens and takes the pairing file.")}</p>
                <code className="small" style={{ userSelect: "text" }}>{result.handoff.link}</code>
              </div>
            </div>
          )}
        </Card>
      )}
    </>
  );
}
