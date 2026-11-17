// A stand-in for Tauri's bridge so the page can be looked at in a plain browser (VITE_MOCK=1).
// Nothing here ships: main.tsx imports it only in that mode.
const now = Math.floor(Date.now() / 1000);
const facts = { udid: "00008150-000829EA2183C01C", name: "Zhehan's iPhone", product_type: "iPhone18,1", ios: "26.1", build: "23B81", developer_mode: true, paired_with_this_computer: true, can_pair_on_device: false, wifi_address: "192.168.1.23" };
const record = { udid: facts.udid, phone_name: facts.name, ios: "26.1", apple_id: "zh…@example.com", team_id: "ABCDE12345", team_name: "Zhehan Zhang", team_is_free: true, bundle_id: "nz.zheha.poki.ABCDE12345", version: "0.2.7", build: "70", release_tag: "ios-v0.2.7", signed_at: now - 86400 * 5, profile_expires_at: now + 86400 * 2, last_error: null, pairing_handed_off: true };
const answers: Record<string, unknown> = {
  app_info: { version: "0.2.0", os: (new URLSearchParams(location.search).get("os") ?? "windows"), arch: "aarch64", data_dir: "~/Library/Application Support/nz.Poki.Poki Setup", can_use_system_anisette: true },
  phones: [{ phone: { udid: facts.udid, link: { kind: "usb" } }, facts, error: null, record }],
  account: { signed_in: true, apple_id: "zhehan@example.com", name: "Zhehan Zhang", team_id: "ABCDE12345", password_kept: true, anisette: { kind: "system" }, pending_factor: null },
  teams: [{ team_id: "ABCDE12345", name: "Zhehan Zhang", kind: "Individual", is_free: true }],
  records: [record],
  relay_state: { account_id: "x", account_name: "Zhehan's account", address: "https://poki-relay.zhehan.workers.dev", first_deploy: false, deployed_at: now, phone_link: "poki://setup?relay=https%3A%2F%2Fpoki-relay.zhehan.workers.dev" },
  connectors: [{ name: "Claude", url: `https://poki-relay.zhehan.workers.dev/v1/${"a".repeat(52)}/${"s".repeat(43)}/mcp`, added_at: now, last_check: { at: now, ok: true, relay_ok: true, phone_online: true, tools: ["look", "do", "screenshot"], detail: "Working: 12 tools through the phone." } }],
  connector_snippets: [["Claude Code", "claude mcp add --transport http poki \"https://…/mcp\""]],
  agent_prompt: "You are setting up Poki on my iPhone (or iPad) with Poki Setup's command line tool…",
  check_update: { current: "0.2.2-300", latest: "0.2.2-300", url: null, newer: false, channel: "stable" },
  install_update: { path: "", relaunching: false },
  channels: [
    { id: "stable", title: "Stable", selected: false, latest: null },
    { id: "beta", title: "Beta", selected: true, latest: { tag: "ios-v0.2.7", version: "0.2.7", build: "70", published_at: "", ipa_name: "Poki-external-0.2.7-70.ipa", channel: "beta" } },
    { id: "alpha", title: "Alpha", selected: false, latest: { tag: "ios-alpha-0.2.7-110", version: "0.2.7", build: "110", published_at: "", ipa_name: "Poki-external-0.2.7-110.ipa", channel: "alpha" } },
    { id: "pre-alpha", title: "Pre-alpha", selected: false, latest: { tag: "ios-prealpha-0.2.7-252", version: "0.2.7", build: "252", published_at: "", ipa_name: "Poki-external-0.2.7-252.ipa", channel: "pre-alpha" } },
  ],
  qr_svg: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><rect width="10" height="10" fill="#fff"/><rect x="1" y="1" width="3" height="3"/><rect x="6" y="1" width="3" height="3"/><rect x="1" y="6" width="3" height="3"/></svg>',
};
(window as unknown as { __TAURI_INTERNALS__: unknown }).__TAURI_INTERNALS__ = {
  invoke: async (cmd: string) => (cmd.startsWith("plugin:") ? 1 : answers[cmd] ?? null),
  transformCallback: () => Math.floor(Math.random() * 1e9),
  metadata: { currentWindow: { label: "main" }, currentWebview: { label: "main" } },
  convertFileSrc: (p: string) => p,
};
export {};
