import { useEffect, useState } from "react";
import { api, failureText, type AppInfo, type UpdateInfo } from "./api";
import { t, useLang } from "./i18n";
import Setup from "./screens/Setup";
import Phones from "./screens/Phones";
import Account from "./screens/Account";
import Relay from "./screens/Relay";
import Debug from "./screens/Debug";
import Settings from "./screens/Settings";
import { listen } from "@tauri-apps/api/event";
import { Capsule, displayVersion } from "./ui";

type Page = "setup" | "phones" | "account" | "relay" | "debug" | "settings";
const pages: { id: Page; label: string; icon: string }[] = [
  { id: "setup", label: "Set up", icon: "M12 2l8 4.5v11L12 22l-8-4.5v-11L12 2zm0 2.3L6 7.7v8.6l6 3.4 6-3.4V7.7l-6-3.4z" },
  { id: "phones", label: "Phones", icon: "M8 2h8a2 2 0 012 2v16a2 2 0 01-2 2H8a2 2 0 01-2-2V4a2 2 0 012-2zm0 2v16h8V4H8zm3 13h2v2h-2z" },
  { id: "account", label: "Apple ID", icon: "M12 12a4 4 0 100-8 4 4 0 000 8zm0 2c-4 0-8 2-8 5v1h16v-1c0-3-4-5-8-5z" },
  { id: "relay", label: "Relay", icon: "M4 14a4 4 0 014-4h1a5 5 0 019.6 1.2A3.5 3.5 0 0118 18H8a4 4 0 01-4-4z" },
  { id: "debug", label: "Debug", icon: "M12 3a5 5 0 015 5v1h2v2h-2v2a5 5 0 01-.5 2.2L19 17l-1.4 1.4-2.2-2.2A5 5 0 0112 18a5 5 0 01-3.4-1.8l-2.2 2.2L5 17l2.5-1.8A5 5 0 017 13v-2H5V9h2V8a5 5 0 015-5z" },
  { id: "settings", label: "Settings", icon: "M12 8a4 4 0 110 8 4 4 0 010-8zm8.9 5.3l-1.9-.4a7 7 0 000-1.8l1.9-.4-.7-2.6-1.8.7a7 7 0 00-1.3-1.3l.7-1.8-2.6-.7-.4 1.9a7 7 0 00-1.8 0l-.4-1.9-2.6.7.7 1.8a7 7 0 00-1.3 1.3l-1.8-.7-.7 2.6 1.9.4a7 7 0 000 1.8l-1.9.4.7 2.6 1.8-.7a7 7 0 001.3 1.3l-.7 1.8 2.6.7.4-1.9a7 7 0 001.8 0l.4 1.9 2.6-.7-.7-1.8a7 7 0 001.3-1.3l1.8.7.7-2.6z" },
];

export default function App() {
  useLang();
  const [page, setPage] = useState<Page>("setup");
  const [info, setInfo] = useState<AppInfo | null>(null);
  useEffect(() => {
    api.appInfo().then((i) => {
      setInfo(i);
      if (i.os === "macos" || i.os === "windows") document.body.classList.add("vibrant");
    });
    const un = listen("renew-requested", () => setPage("phones"));
    return () => { un.then((f) => f()); };
  }, []);
  // Poki Setup's own updates: checked at launch and every six hours, offered once per version.
  const [update, setUpdate] = useState<UpdateInfo | null>(null);
  const [dismissed, setDismissed] = useState<string | null>(null);
  const [updating, setUpdating] = useState(false);
  const [updateError, setUpdateError] = useState<string | null>(null);
  useEffect(() => {
    const check = () => api.checkUpdate().then(setUpdate).catch(() => {});
    const first = setTimeout(check, 5000);
    const every = setInterval(check, 6 * 3600 * 1000);
    return () => { clearTimeout(first); clearInterval(every); };
  }, []);
  const restartToUpdate = () => {
    setUpdating(true);
    setUpdateError(null);
    api.installUpdate()
      .then((r) => { if (!r.relaunching) setUpdateError(t("The installer is open. Finish it to update Poki Setup.")); })
      .catch((e) => setUpdateError(failureText(e)))
      .finally(() => setUpdating(false));
  };
  const win = info?.os !== "macos";
  return (
    <div className="app">
      <div className="drag" />
      <aside className={`sidebar ${win ? "win" : ""}`}>
        <div className="brand"><img src="/icon.png" alt="" /><div><b>Poki Setup</b><small>{t("for iPhone")}</small></div></div>
        <nav className="nav">
          {pages.map((p) => (
            <div key={p.id}>
              {p.id === "relay" && <div className="group">{t("Advanced")}</div>}
              <button className={page === p.id ? "on" : ""} onClick={() => setPage(p.id)}>
                <svg viewBox="0 0 24 24" fill="currentColor"><path d={p.icon} /></svg>{t(p.label)}
              </button>
            </div>
          ))}
        </nav>
        <div className="foot">{info?.version ? displayVersion(info.version) : "…"}</div>
      </aside>
      <main className={`content ${win ? "win" : ""}`}>
        {update?.newer && update.latest && dismissed !== update.latest && (
          <div className="update-bar" role="status">
            <span>{t("Poki Setup {v} is available.").replace("{v}", displayVersion(update.latest))}{updateError ? ` ${updateError}` : ""}</span>
            <Capsule sm disabled={updating} onClick={restartToUpdate}>{updating ? t("Updating…") : t("Restart to Update")}</Capsule>
            <Capsule sm kind="ghost" disabled={updating} onClick={() => setDismissed(update.latest)}>{t("Later")}</Capsule>
          </div>
        )}
        {page === "setup" && <Setup goAccount={() => setPage("account")} />}
        {page === "phones" && <Phones />}
        {page === "account" && <Account info={info} />}
        {page === "relay" && <Relay />}
        {page === "debug" && <Debug />}
        {page === "settings" && <Settings info={info} />}
      </main>
    </div>
  );
}
