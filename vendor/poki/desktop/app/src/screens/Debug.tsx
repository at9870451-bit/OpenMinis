import { useEffect, useRef, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import { api, failureText, type PhoneRow } from "../api";
import { t } from "../i18n";
import { Capsule, Card, ErrorBox, useInterval } from "../ui";

export default function Debug() {
  const [rows, setRows] = useState<PhoneRow[]>([]);
  const [udid, setUdid] = useState("");
  const [filter, setFilter] = useState("Poki");
  const [running, setRunning] = useState(false);
  const [lines, setLines] = useState<string[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const box = useRef<HTMLDivElement>(null);
  useInterval(() => { api.phones().then((r) => { setRows(r); if (!udid && r[0]) setUdid(r[0].phone.udid); }).catch(() => setRows([])); }, 4000, [udid]);
  useEffect(() => {
    const un = listen<string[]>("log-lines", (e) => setLines((prev) => [...prev.slice(-4000), ...e.payload]));
    return () => { un.then((f) => f()); api.logsStop(); };
  }, []);
  useEffect(() => { if (box.current) box.current.scrollTop = box.current.scrollHeight; }, [lines]);
  const toggle = async () => {
    setError(null);
    if (running) { await api.logsStop(); setRunning(false); return; }
    try { setLines([]); await api.logsStart(udid, filter || null); setRunning(true); } catch (e) { setError(failureText(e)); }
  };
  const bundle = async () => {
    setError(null); setMsg(null);
    const { open } = await import("@tauri-apps/plugin-dialog");
    const dir = await open({ directory: true, multiple: false });
    if (!dir) return;
    try { const p = await api.supportBundle(udid || null, dir as string); setMsg(p); const { revealItemInDir } = await import("@tauri-apps/plugin-opener"); await revealItemInDir(p); } catch (e) { setError(failureText(e)); }
  };
  return (
    <>
      <h1 className="page-title">{t("Debug")}</h1>
      <p className="page-sub">{t("Support bundles can contain device identifiers, local paths and raw logs. Review the archive before sharing.")}</p>
      <ErrorBox error={error} />
      <Card>
        <div className="row">
          <select className="input" style={{ width: 220 }} value={udid} onChange={(e) => setUdid(e.target.value)}>{rows.map((r) => <option key={r.phone.udid} value={r.phone.udid}>{r.facts?.name ?? r.phone.udid}</option>)}</select>
          <input className="input grow" value={filter} onChange={(e) => setFilter(e.target.value)} placeholder={t("Filter")} />
          <Capsule onClick={toggle} disabled={!udid}>{running ? t("Stop") : t("Start")}</Capsule>
          <Capsule kind="ghost" onClick={() => setLines([])}>Clear</Capsule>
        </div>
        <div className="log" ref={box} style={{ marginTop: 12 }}>{lines.join("\n")}</div>
      </Card>
      <Card>
        <div className="row">
          <Capsule kind="ghost" onClick={bundle}>{t("Save support bundle…")}</Capsule>
          <Capsule kind="ghost" disabled={!udid} onClick={async () => { setError(null); setMsg(null); try { await api.mountDdi(udid); setMsg("Developer disk image mounted."); } catch (e) { setError(failureText(e)); } }}>{t("Mount developer disk image")}</Capsule>
          <Capsule kind="ghost" disabled={!udid} onClick={async () => { setError(null); try { await api.pair(udid); setMsg("Paired."); } catch (e) { setError(failureText(e)); } }}>{t("Pair")}</Capsule>
          <Capsule kind="ghost" disabled={!udid} onClick={async () => { setError(null); try { await api.devmode(udid); setMsg("Developer Mode is on."); } catch (e) { setError(failureText(e)); } }}>{t("Developer Mode")}: {t("Turn on")}</Capsule>
        </div>
        {msg && <p className="muted small" style={{ margin: "10px 0 0", userSelect: "text" }}>{msg}</p>}
      </Card>
    </>
  );
}
