import { useEffect, useState } from "react";
import { api, failureText, type Account, type AppInfo, type ChannelInfo, type UpdateInfo } from "../api";
import { setLang, t, useLang } from "../i18n";
import { Capsule, Card, Copy, displayVersion, ErrorBox, Field } from "../ui";

export default function Settings({ info }: { info: AppInfo | null }) {
  const lang = useLang();
  const [acct, setAcct] = useState<Account | null>(null);
  const [server, setServer] = useState("https://ani.sidestore.io");
  const [update, setUpdate] = useState<UpdateInfo | null>(null);
  const [updating, setUpdating] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [channels, setChannels] = useState<ChannelInfo[]>([]);
  const [prompt, setPrompt] = useState<string | null>(null);
  const load = () => api.account().then((a) => { setAcct(a); if (a.anisette.kind === "remote") setServer(a.anisette.url); }).catch(() => {});
  useEffect(() => { load(); api.channels().then(setChannels).catch((e) => setError(failureText(e))); api.agentPrompt().then(setPrompt).catch(() => {}); }, []);
  const chosen = channels.find((c) => c.selected);
  const system = acct?.anisette.kind === "system";
  return (
    <>
      <h1 className="page-title">{t("Settings")}</h1>
      <ErrorBox error={error} />
      <Card>
        <h2>{t("Language")}</h2>
        <div className="seg"><button className={lang === "en" ? "on" : ""} onClick={() => setLang("en")}>English</button><button className={lang === "zh-Hans" ? "on" : ""} onClick={() => setLang("zh-Hans")}>简体中文</button></div>
      </Card>
      <Card>
        <h2>{t("Anisette")}</h2>
        <p className="muted small">Apple's sign-in wants a machine identity. {info?.can_use_system_anisette ? "On a Mac it comes from macOS itself." : "On Windows a small anisette server provides one; it never sees your Apple ID or password. Run your own with Provision, or use the community server."}</p>
        <div className="row" style={{ alignItems: "flex-end" }}>
          {info?.can_use_system_anisette && <div className="seg"><button className={system ? "on" : ""} onClick={() => api.setAnisette({ kind: "system" }).then(load).catch((e) => setError(failureText(e)))}>{t("This Mac")}</button><button className={!system ? "on" : ""} onClick={() => api.setAnisette({ kind: "remote", url: server }).then(load).catch((e) => setError(failureText(e)))}>{t("Server")}</button></div>}
          {!system && <div className="grow"><Field label={t("Server")}><div className="row"><input className="input mono grow" value={server} onChange={(e) => setServer(e.target.value)} /><Capsule kind="ghost" onClick={() => api.setAnisette({ kind: "remote", url: server }).then(load).catch((e) => setError(failureText(e)))}>{t("Done")}</Capsule></div></Field></div>}
        </div>
      </Card>
      <Card>
        <h2>{t("Updates")}</h2>
        <p className="muted small">Beta</p>
        <div className="row" style={{ alignItems: "center" }}>
          <span className="muted small">{chosen?.latest ? `${t("Newest Poki")}: ${chosen.latest.version} (${chosen.latest.build})` : t("None published")}</span>
        </div>
        {chosen?.latest?.source_notice && <p className="muted small">{chosen.latest.source_notice}</p>}
      </Card>
      <Card>
        <h2>{t("Use an agent")}</h2>
        <p className="muted small">{t("An agent on this computer (Claude Code, Codex or another one) can do the setup with Poki Setup's command line tool. Copy these instructions and paste them into the agent; it tells you when to tap the phone or type your password.")}</p>
        <div className="row">{prompt && <Copy text={prompt} />}</div>
      </Card>
      <Card>
        <h2>{t("About")}</h2>
        <p className="muted small" style={{ userSelect: "text" }}>Poki Setup {displayVersion(info?.version)} · {info?.os} {info?.arch} · {info?.data_dir}</p>
        <div className="row">
          <Capsule kind="ghost" onClick={() => api.checkUpdate().then(setUpdate).catch((e) => setError(failureText(e)))}>{t("Check for updates")}</Capsule>
          {update && (update.newer ? <Capsule disabled={updating} onClick={() => { setUpdating(true); api.installUpdate().then(() => {}).catch((e) => setError(failureText(e))).finally(() => setUpdating(false)); }}>{updating ? t("Downloading…") : `${t("Install update")}: ${displayVersion(update.latest)}`}</Capsule> : <span className="muted">{t("Up to date")}</span>)}
          <Capsule kind="ghost" onClick={async () => { const { openUrl } = await import("@tauri-apps/plugin-opener"); openUrl("https://github.com/JosssphZhou/poki/blob/main/desktop/README.md"); }}>README</Capsule>
        </div>
        {update?.source_notice && <p className="muted small">{update.source_notice}</p>}
        <p className="muted small" style={{ marginBottom: 0 }}>AGPL-3.0. Sign-in protocol after SideStore's icloud-auth (MPL-2.0) and Sideloader (GPL-3.0); signer: apple-codesign (MPL-2.0); device: idevice (MIT); type: Geist (OFL). See THIRD_PARTY_NOTICES.md.</p>
      </Card>
    </>
  );
}
