# Original Poki pages embedded in Amore

Upstream: JosssphZhou/poki, revision 69585293051fee03c7ad110f037d8f4dd2a4e96f.
The original ChatView, ConnectionView, SetupStepPage, SetupGuide, AppModel,
ChatModel, PokiCore and Rust launcher are built as one isolated `Poki` module.
This is not the earlier MCP/Rootfs replacement screen.

Minimal host changes are tracked by scripts/prepare-poki-port.py:
- Remove the upstream @main App entry, export a lazy Amore entry factory.
- Bridge the original C/ObjC headers through the framework umbrella header.
- Use the original external-connection variant (no unauthorized VPN entitlement).
- Namespace resource/defaults paths and replace branding with Amore artwork.
- Do not start the self-updater or automatically download a large DDI on entry.
  DDI download/pairing/automation remain real original buttons and state checks.
- Keep system permission prompts, pairing approval and real failure results.

The original module requires iOS 18. Amore's original iOS 16+ pages remain
available; no existing history or plugin records are migrated or deleted.
Original automatic screen-reading/touch functions cannot be used until the
owner completes Developer Mode, pairing, local connection and UI Automation.
Simulator compilation is not proof these Apple services work on a real phone.

Code: AGPL-3.0-only and upstream third-party terms, see LICENSE,
THIRD_PARTY_NOTICES.md and UPSTREAM.json. Poki brand assets are NOT licensed
by the code license; they are omitted/replaced. Do not present this as Poki.
