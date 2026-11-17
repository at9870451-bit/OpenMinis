# Open-source notices

The root AGPL-3.0-only license covers original Poki code. Poki's brand assets, including the Poki bear, are not covered; see [BRAND.md](BRAND.md). Third-party code retains its respective copyright notices and license terms.

## idevice

Poki MCP uses [jkcoxson/idevice](https://github.com/jkcoxson/idevice) at commit `89702099f4d7552f704f93b4526756abda319ceb`, downloaded by setup into `.deps/idevice`. The upstream library and command-line tools are MIT licensed. The complete notice is retained in [native/bridge/LICENSE.idevice](native/bridge/LICENSE.idevice).

[native/bridge/src/stream.rs](native/bridge/src/stream.rs) adapts code from the pinned upstream [tools/src/coredevice_stream.rs](https://github.com/jkcoxson/idevice/blob/89702099f4d7552f704f93b4526756abda319ceb/tools/src/coredevice_stream.rs). The rest of the bridge calls upstream protocol APIs. The pinned [upstream license](https://github.com/jkcoxson/idevice/blob/89702099f4d7552f704f93b4526756abda319ceb/LICENSE.txt) remains applicable to that code.

PokiLauncher ([native/launcher](native/launcher)), which the iPhone app links, builds against the same idevice revision with [native/patches/idevice-xctest-run-over-rsd.patch](native/patches/idevice-xctest-run-over-rsd.patch) applied. The patch adds `run_over_rsd` to `idevice/src/services/dvt/xctest/mod.rs`; it adapts the steps of upstream `XCUITestService::run` in the same file to an RSD tunnel the caller already holds. The pinned upstream MIT license applies to that code. [native/launcher/fetch-idevice.sh](native/launcher/fetch-idevice.sh) applies the patch to a separate copy in `.deps/idevice-launcher`, so setup's `.deps/idevice` stays unmodified.

[native/bridge/src/pasteboard.rs](native/bridge/src/pasteboard.rs) also references the pinned upstream [pasteboard service protocol](https://github.com/jkcoxson/idevice/blob/89702099f4d7552f704f93b4526756abda319ceb/idevice/src/services/core_device/pasteboard_service.rs). Poki builds the upstream `idevice-tools` and `idevice_id` executables during setup; their dependencies are listed separately from those of Poki's native bridge in the [dependency inventory](docs/third-party-dependencies.md).

## Meta idb

The simulator adapter's XPC, accessibility, and HID wire-format work references [facebook/idb](https://github.com/facebook/idb) at commit `5c1044388339006c798c5a6c3c267816e6808297`. The complete MIT notice is retained in [native/LICENSE.idb](native/LICENSE.idb).

Relevant protocol and interface references at that revision include:

- [SimulatorDigitizerHIDTransport.swift](https://github.com/facebook/idb/blob/5c1044388339006c798c5a6c3c267816e6808297/FBSimulatorControl/HID/SimulatorDigitizerHIDTransport.swift), for the digitizer service transport.
- [SimulatorIndigoHID.swift](https://github.com/facebook/idb/blob/5c1044388339006c798c5a6c3c267816e6808297/FBSimulatorControl/HID/SimulatorIndigoHID.swift) and [SimulatorPurpleHID.swift](https://github.com/facebook/idb/blob/5c1044388339006c798c5a6c3c267816e6808297/FBSimulatorControl/HID/SimulatorPurpleHID.swift), for event formats and workspace messages.
- [AccessibilityClient.m](https://github.com/facebook/idb/blob/5c1044388339006c798c5a6c3c267816e6808297/SimulatorFrameworkBridge/Runtime/AccessibilityClient.m) and [AXPTranslatorRequest.h](https://github.com/facebook/idb/blob/5c1044388339006c798c5a6c3c267816e6808297/PrivateHeaders/AccessibilityPlatformTranslation/AXPTranslatorRequest.h), for the accessibility transport and request interface.

Poki MCP's simulator helper is a local implementation using these protocol references. It does not bundle the idb executable or Apple frameworks. The idb license is retained to preserve attribution for the referenced implementation and interfaces.

## BlueBubbles Server

The optional `bin/setup-channels` command downloads the unmodified [BlueBubbles Server 1.9.12](https://github.com/BlueBubblesApp/bluebubbles-server/releases/tag/v1.9.12) release from BlueBubblesApp. BlueBubbles is licensed under Apache-2.0; its complete upstream license is retained in [docs/licenses/BlueBubbles-LICENSE](docs/licenses/BlueBubbles-LICENSE). Its packaged dependencies retain their respective notices. The installer pins the official release asset's SHA-256 digest and preserves the app bundle, including its third-party notices. The application archive is not stored in this repository.

## Appium WebDriverAgent

The on-phone runner is built from [appium/WebDriverAgent](https://github.com/appium/WebDriverAgent) v16.15.3 (commit `02cb92f0e93c8b021443bcbb8eeb80932c113220`), vendored as a git submodule at [native/ios-runner/WebDriverAgent](native/ios-runner/WebDriverAgent). WebDriverAgent is BSD-3-Clause licensed (Copyright (c) 2015-present, Facebook, Inc.); its complete license is in the submodule's [LICENSE](https://github.com/appium/WebDriverAgent/blob/02cb92f0e93c8b021443bcbb8eeb80932c113220/LICENSE) and is shipped unchanged with the source. The submodule itself is not edited. Poki changes WebDriverAgent's code and the built runner app at build time, in three places:

- [native/ios-runner/patches/wda-poki-runner.patch](native/ios-runner/patches/wda-poki-runner.patch) modifies `WebDriverAgentRunner/UITestingUITests.m`. The runner's test starts WebDriverAgent's server only when the Poki launcher sets `POKI_LAUNCHER`, and while it runs it shows a "Poki is using this iPhone" screen. The build applies the patch before `xcodebuild` (`.github/workflows/ios-runner.yml`). The file keeps its original copyright header.
- [native/ios-runner/host](native/ios-runner/host) builds PokiRunnerHost, a library that `install.sh` adds to the built runner app and loads before XCTRunner's own code. Opened by hand, the runner then starts no test and sends people to Poki.
- [native/ios-runner/branding](native/ios-runner/branding) replaces the built app's icon, display name and launch screen.

## WebRTC

The Poki app's Voice tab links Google's [WebRTC](https://webrtc.googlesource.com/src) through the unmodified prebuilt framework from [stasel/WebRTC](https://github.com/stasel/WebRTC) 155.0.0 (Swift Package Manager, `native/ios-app/project.yml`). WebRTC is BSD-3-Clause licensed (Copyright (c) 2011, The WebRTC project authors); its license and patent grant ship inside the framework (`WebRTC.xcframework/LICENSE`). The framework is downloaded at build time and not stored in this repository.

## JavaScript packages

The exact installed versions come from `package-lock.json`. These packages provide the MCP server/client transports, image processing and input validation:

| Repository | Packages and locked versions | License |
| --- | --- | --- |
| [Model Context Protocol TypeScript SDK](https://github.com/modelcontextprotocol/typescript-sdk) | `@modelcontextprotocol/client`, `core`, `server` 2.4.0; `@modelcontextprotocol/node` 2.1.2 | Package metadata declares Apache-2.0. The upstream license also retains MIT for contributions without relicensing consent; its complete text is preserved in [third_party/LICENSE.typescript-sdk](third_party/LICENSE.typescript-sdk). |
| [sharp](https://github.com/lovell/sharp/tree/e0624568686516209c434de2d3c0ef6688f0811d) | `sharp` and applicable `@img/sharp-*` packages 0.34.5 | Apache-2.0; full text in [third_party/LICENSE.sharp](third_party/LICENSE.sharp). |
| [Zod](https://github.com/colinhacks/zod/tree/b500a2ee95134f81d74da7911d7378dd2853d042) | `zod` 4.6.7 | MIT; full text in [third_party/LICENSE.zod](third_party/LICENSE.zod). |

The [dependency inventory](docs/third-party-dependencies.md#npm-packages) names every locked npm package, its source repository, declared license and platform conditions. It includes transitive packages such as Hono, EventSource, jose and cross-spawn.

## libvips and bundled image libraries

`npm ci` selects sharp's prebuilt packages for the installing machine. On macOS arm64, `@img/sharp-libvips-darwin-arm64` 1.2.4 supplies libvips 8.17.3 and its bundled image libraries. The package is distributed by [sharp-libvips at commit 20b5e899954907a3039d6e3d4c200aaa0ec52c4c](https://github.com/lovell/sharp-libvips/tree/20b5e899954907a3039d6e3d4c200aaa0ec52c4c), with LGPL-3.0-or-later package metadata. Its components retain their own licenses.

The upstream component notices are retained in [third_party/NOTICE.sharp-libvips.md](third_party/NOTICE.sharp-libvips.md). The [bundle inventory](docs/third-party-dependencies.md#image-libraries-in-the-macos-arm64-libvips-package) lists the versions reported by that package, source repositories and component terms. This includes libvips, libheif, libexif, librsvg, GLib, Pango, Cairo, FreeType, libpng, libwebp and the other reported libraries.

## Rust packages

The native bridge directly depends on [Tokio](https://github.com/tokio-rs/tokio), [Serde](https://github.com/serde-rs/serde), [serde_json](https://github.com/serde-rs/json), [rust-plist](https://github.com/ebarnard/rust-plist), [futures-util](https://github.com/rust-lang/futures-rs), [uuid](https://github.com/uuid-rs/uuid) and idevice. PokiLauncher directly depends on idevice (with the patch above), Tokio, Serde, serde_json and rust-plist, and the iPhone app ships it with its whole `aarch64-apple-ios` graph. Their licenses and those of every resolved normal/build dependency in the macOS arm64 graphs and the launcher's iOS graph are listed in the [Rust inventory](docs/third-party-dependencies.md#rust-packages). It identifies packages used by the bridge, the upstream tools, or both. Cryptographic and other bundled code retains the notices supplied by its owning crate; the combined AWS-LC, BoringSSL and OpenSSL terms from the checked `aws-lc-sys` packages are also retained in [third_party/LICENSE.aws-lc](third_party/LICENSE.aws-lc).

## iPhone app Live Activity

The iPhone app's Live Activity ([native/ios-app/Shared](native/ios-app/Shared), [native/ios-app/PokiWidgets/PokiWidgetsBundle.swift](native/ios-app/PokiWidgets/PokiWidgetsBundle.swift) and [native/ios-app/Poki/Activity/ActivityController.swift](native/ios-app/Poki/Activity/ActivityController.swift)) ports code from three projects. Each file names its source in its header.

- [Clarklevis1995/dsh-mobile](https://github.com/Clarklevis1995/dsh-mobile/tree/ebe19764a412e8b0505d156f5bb13b2fc23c3bd6) at commit `ebe19764`, copyright 2026 Chaofan Li, under the [MIT license](third_party/LICENSE.dsh-mobile): the widget's structure (`AgentLiveActivityWidget.swift`), the Allow and Deny intents with their bridge into the app (`AgentApprovalIntents.swift`), the latest-wins update worker, ordered operation tail and update policy (`AgentLiveActivityManager.swift`), and the attribute layout (`AgentActivityAttributes.swift`). Poki keys a decision by its approval id alone, keeps an App Group mailbox for intents that run outside the app, lets Deny run without authentication, and drops the iOS 16 compatibility layer and the localized label set.
- [onehumanbeing/esp32-iphone-agent](https://github.com/onehumanbeing/esp32-iphone-agent/tree/cc966294b96b18da9b04931ec96cab7962461c7f) at commit `cc966294`, copyright 2026 Henry Yuan, under the [MIT license](third_party/LICENSE.esp32-iphone-agent): the update token bucket (`ios/IPhoneAgent/App/LiveActivity.swift`) and the system-counted countdown (`ios/AgentActivity/AgentActivityWidget.swift`).
- [leepokai/Codync](https://github.com/leepokai/Codync/tree/848070df40b788601bd0ae6c720fa77d823ab60e) at commit `848070d`, copyright 2026 Po Kai Lee, under the [Apache License 2.0](third_party/LICENSE.codync) with its [NOTICE](third_party/NOTICE.codync): the phase spring and row transition (`apps/ios/Kit/Sources/CodyncKit/Design/Motion.swift`, `ActivityCards.swift`), interpolated text and the expanded island's corner margins (`apps/ios/Widgets/CodyncWidgets.swift`). Poki changed these files: it ported the snippets into its own views.

The app and the Live Activity draw their Latin text in [Geist](https://github.com/vercel/geist-font) 1.3.1 (Regular, Medium, SemiBold, Bold and Black, from the `geist` npm package), copyright 2023 Vercel in collaboration with basement.studio, under the SIL Open Font License 1.1. The fonts and their complete license are in [native/ios-app/Shared/Fonts](native/ios-app/Shared/Fonts) and are bundled in both the app and its widget extension.

## iPhone app chat

The iPhone app's sessions list, chat, Poki details and model pages ([native/ios-app/Poki/Sessions](native/ios-app/Poki/Sessions), [native/ios-app/Poki/Chat](native/ios-app/Poki/Chat)) port code from five projects. Each file names its source in its header.

- [GetStream/swiftui-iMessage-clone](https://github.com/GetStream/swiftui-iMessage-clone/tree/df114b4) at commit `df114b4`, by Stefan Blos: the pinned conversation row and session row (`PinnedChannelsView.swift`, `iMessageChannelListItemView.swift`), the header with the picture and name that opens the details (`MessageListHeader.swift`, `MessageListHeaderModifier.swift`) and the message field with its send button (`ComposerInputView.swift`). The repository has no license file.
- [Mackarous/ConversationUI](https://github.com/Mackarous/ConversationUI/tree/e77c69e) at commit `e77c69e`, copyright 2024 Andrew Mackarous, under the [MIT license](third_party/LICENSE.conversationui): the message bubble (`Sources/ConversationUI/MessageBubble.swift`).
- [exyte/Chat](https://github.com/exyte/Chat/tree/f382a14) at commit `f382a14`, copyright 2019 exyte, under the [MIT license](third_party/LICENSE.exyte-chat): the plus button in front of the field (`Sources/ExyteChat/Views/InputView/InputView.swift`) and the waveform bars (`Sources/ExyteChat/Views/Recording/RecordWaveform.swift`).
- [gonzalezreal/swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui/tree/8371aeb) at commit `8371aeb`, copyright 2020 Guillermo Gonzalez, under the [MIT license](third_party/LICENSE.swift-markdown-ui): the table in Poki's answers, with its column layout, borders and row backgrounds ([native/ios-app/Poki/Chat/AnswerTable](native/ios-app/Poki/Chat/AnswerTable), from `Sources/MarkdownUI/Views/Blocks/Table*.swift`, `Theme/BlockStyle/Table*Style.swift` and `Views/Environment/Environment+Table.swift`), and the GitHub theme's table values (`Theme/Theme+GitHub.swift`).
- [lhuanyu/OllamaMessage](https://github.com/lhuanyu/OllamaMessage/tree/c857a02) at commit `c857a02`, copyright 2023 Huanyu Luo, under the [MIT license](third_party/LICENSE.ollamamessage): the model row and the provider list (`DialogueSettingsView.swift`, `OllamaModelSelectionView.swift`).

The plan bubble's motion (`PlanMotion.swift`) uses the spring, duration and order parameters of four [Motion+](https://motion.dev/plus) examples for React (notifications-list, copy-button, todo-list, typewriter-change-content), rewritten in SwiftUI. The typing pace is Poki's own. No Motion+ file is included.

## iPhone app conversations drawer

The conversations drawer in [native/ios-app/Poki/Sessions/ThreadsDrawer.swift](native/ios-app/Poki/Sessions/ThreadsDrawer.swift) follows `apps/mobile/src/features/servers/components/app-drawer-shell.tsx` in [nightly-labs/openbot](https://github.com/nightly-labs/openbot/tree/a74951cd3890f1793150ce40b9e0221c63e48f99) at commit `a74951c`, under the [PolyForm Noncommercial License 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0). Required Notice: Copyright 2026 Synthetify Labs spółka z ograniczoną odpowiedzialnością. Taken from it, rewritten from React Native in SwiftUI: the drawer under the page and the page that slides away to uncover it, one progress value from closed to open that the finger moves directly, the release that adds a sixth of a second of the finger's speed and opens past 0.45 or closes past 0.55, the spring that starts at the finger's speed, the page's corners that round within the first 15 % of the way, and the drawer that comes in from 24 points aside and from 55 % opacity. The page as a card with a hairline edge and a shadow follows `Sources/DrawerSideBar/SideBarNavigationView.swift` in [shubhamKachhiya/DrawerSideBar](https://github.com/shubhamKachhiya/DrawerSideBar) at commit `93370a0`, Copyright (c) 2026 shubhamKachhiya, under the MIT License. The width of the uncovered strip, the bounce and the stretch past open are Poki's own. The file names its sources in its header.

## iPhone app capsule field

The message field's app capsules ([native/ios-app/Poki/Capsule](native/ios-app/Poki/Capsule), ESP-377) adapt three files from [element-hq/element-x-ios](https://github.com/element-hq/element-x-ios/tree/21758530da454c65969c6ef159b9ca47b9394a7a) at commit `2175853`, copyright 2025 Element Creations Ltd. and 2023-2025 New Vector Ltd., under the GNU Affero General Public License v3.0 only, the license Poki itself uses: `ElementX/Sources/Other/Pills/PillTextAttachment.swift`, `PillTextAttachmentData.swift` and `PillView.swift`. Poki removed their room context and WysiwygComposer dependency, made the pill an app's icon and name, and draws it into the attachment's image. Each file names its source in its header. The app icons in `native/ios-app/Poki/AppIcons`, about 80 apps from Apple, the China store and the US store, are each app's App Store artwork, fetched through the iTunes Lookup API in November 2026, and are their makers' trademarks, used only to name each app. `native/ios-app/Poki/AppIcons/AppIcons.md` lists them with their dates and stores.

The home page's pill that stars Poki on GitHub uses the GitHub mark from [GitHub Octicons](https://github.com/primer/octicons) (`@primer/octicons` 19.15.0, `build/svg/mark-github-24.svg`), copyright 2025 GitHub Inc., under the [MIT license](third_party/LICENSE.octicons): the file is copied whole as `native/ios-app/Poki/AppIcons/github-mark.svg`, and `github.png` beside it draws it on a dark square. The mark is GitHub's trademark, used only to name GitHub.

## iPhone app settings rows

The settings rows in [native/ios-app/Poki/Settings/PokiSettingsKit.swift](native/ios-app/Poki/Settings/PokiSettingsKit.swift) (ESP-469) adapt [element-hq/compound-ios](https://github.com/element-hq/compound-ios/tree/a1db8e1b) at commit `a1db8e1b`, copyright 2023-2024 New Vector Ltd., under the GNU Affero General Public License v3.0 only: the icon on its own subtle ground beside the title and description, the 30 pt scaled icon that does not size the row, and the trailing value and chevron of `Sources/Compound/List/ListRowLabel.swift`, `ListRowDetails.swift` and `ListRowAccessory.swift`. The settings home's order, the profile on top and then groups of rows, follows `ElementX/Sources/Screens/Settings/SettingsScreen/View/SettingsScreen.swift` in [element-hq/element-x-ios](https://github.com/element-hq/element-x-ios) at commit `4447399a`, same licence. Poki draws the icons on a round ground in its own colours and keeps the rows in the system list. The file names its sources in its header.

## iPhone app suggestion rows

[native/ios-app/Poki/Chat/Marquee.swift](native/ios-app/Poki/Chat/Marquee.swift) takes two things from `MarqueeView.swift` in [nainamaharjan/MarqueeSwiftUI](https://github.com/nainamaharjan/MarqueeSwiftUI) (commit 0b877e64), MIT License, Copyright (c) 2024 nainamaharjan: the speed that eases toward its target by the time that passed since the last frame, and the content laid out several times with the position wrapping by one content's width. The drawing and the touch handling are a `UIScrollView` of our own.

## iPhone app home light

`PointMotion` in [native/ios-app/Poki/Chat/HomeBackdrop.swift](native/ios-app/Poki/Chat/HomeBackdrop.swift) is adapted from `PointAnimation` in `Sources/MeshingKit/AnimationPattern.swift` of [rryam/MeshingKit](https://github.com/rryam/MeshingKit/tree/1c519ac7369d055eef0c23fb5d4944b9ef910a3e) (commit 1c519ac7), MIT License, Copyright (c) 2024 Rudrank Riyam: a cosine offset per mesh point and axis, each at its own frequency, several of which add up on one point. Poki added a starting phase and scales the offset by how far the light drifts. The mesh, its colours and the timing are Poki's own.

## iPhone app talk bars and edge light

[native/ios-app/Poki/Chat/TalkBars.swift](native/ios-app/Poki/Chat/TalkBars.swift) is carried over from `Sources/LiveKitComponents/UI/Visualizer/BarAudioVisualizer.swift` in [livekit/components-swift](https://github.com/livekit/components-swift/tree/9f28db3ae5d2b51f3033ea725c952ddacb5657d0) (commit 9f28db3a), Apache License 2.0, Copyright 2025 LiveKit. The file keeps its license header and lists its changes: the agent's state is Poki's own type, with one state added; the bars' heights are made up while somebody speaks, since Poki does not link the LiveKit SDK and reads no audio levels; nothing moves with Reduce Motion. The complete license is in [third_party/LICENSE.livekit-components-swift](third_party/LICENSE.livekit-components-swift).

[native/ios-app/Poki/Chat/TalkEdgeGlow.swift](native/ios-app/Poki/Chat/TalkEdgeGlow.swift) is carried over from `IOS.swift` and `IOS_LowPowerMode.swift` in [jacobamobin/AppleIntelligenceGlowEffect](https://github.com/jacobamobin/AppleIntelligenceGlowEffect/tree/5f388f1c51322f62f2181693e125d955d9a45237) (commit 5f388f1c), MIT License, Copyright (c) 2025 Jacob Mobin. The file keeps the notice and lists its changes: Poki's blues for the colours, only the lower part of the edge shown, the lines' width and the light's strength set by what the talk is doing, and the view's own frame instead of the screen's. The notice is also in [third_party/LICENSE.AppleIntelligenceGlowEffect](third_party/LICENSE.AppleIntelligenceGlowEffect).

## iPhone app model loop

The chat's model loop (`native/ios-app/Poki/Chat/PiLoop.swift`) links two products of [xibbon/PiSwift](https://github.com/xibbon/PiSwift/tree/f8696524cf41ca0a7f42f5b230eafa443daececd) at commit `f869652`, a Swift port of Mario Zechner's pi-mono, copyright 2025 Mario Zechner, under the [MIT license](third_party/LICENSE.piswift): PiSwiftAgent (the agent loop) and PiSwiftAI (the model providers and the ChatGPT sign-in). They are a Swift package dependency, not copied files; PiSwift's own dependencies come with it through the package resolution: MacPaw/OpenAI and jamesrochabrun/SwiftAnthropic (MIT) and apple/swift-argument-parser (Apache-2.0).

The ChatGPT code sign-in in `ChatGPTLogin.swift` ports the device code flow of `@earendil-works/pi-ai` 1.5.0 (`dist/auth/oauth/openai-codex.js`), copyright Mario Zechner, MIT license, the same license text.

## External open-source tools

Setup and runtime invoke these separately installed tools. Their versions and build options are chosen by the installing environment.

| Repository | Use | License |
| --- | --- | --- |
| [Node.js](https://github.com/nodejs/node) | JavaScript runtime, Node.js 24 or newer | MIT and included third-party notices |
| [npm CLI](https://github.com/npm/cli) | Install locked JavaScript packages and run build scripts | Artistic-2.0 and included dependency notices |
| [Rust](https://github.com/rust-lang/rust), [Cargo](https://github.com/rust-lang/cargo) | Compile the native bridge and idevice tools | MIT OR Apache-2.0 and included third-party notices |
| [CPython](https://github.com/python/cpython) | Device discovery and the optional unlock script | PSF-2.0 and included third-party notices |
| [FFmpeg](https://github.com/FFmpeg/FFmpeg) | Encode and inspect recordings with `ffmpeg` and `ffprobe` | LGPL-2.1-or-later by default; GPL and other terms depend on the installed build. Run `ffmpeg -L` for that build's terms. |
| [Git](https://github.com/git/git) | Download and check the pinned idevice checkout during setup | GPL-2.0-only and included third-party notices |

## Distribution scope

This repository contains source code and the retained notices above. Setup downloads npm packages and builds idevice locally. Precompiled dependency bundles and the external tools are not committed here. A binary distribution must also retain the notices and satisfy the terms of the components actually included in that distribution. Poki's AGPL-3.0-only license does not replace any component's license.

The prebuilt macOS package includes the native bridge, OCR and simulator helpers, the unlock helper, and idevice tools. See [idevice release build notes](third_party/idevice-release.md) for the diagnostic-path replacement, reproduction commands, and dependency installation boundary. Rust dependency license texts shipped with the binary package are under `third_party/rust-licenses/`.

## GitHub CLI update check

[src/update-check.mjs](src/update-check.mjs) ports the complete release-check flow (`CheckForUpdate`, `getLatestReleaseInfo`, `getStateEntry`, and `setStateEntry`) from [GitHub CLI v2.83.0](https://github.com/cli/cli/blob/152d328db80d4d4d7318c7700b6644ee827618a7/internal/update/update.go), copyright 2019 GitHub Inc., under the [MIT license](third_party/LICENSE.github-cli). The port uses JavaScript and JSON instead of Go and YAML. Poki adds an anonymous short-timeout request, silent failed-attempt caching, release-note summaries, and cached notices for noninteractive MCP clients. It omits GitHub CLI's extension updates and terminal/CI restrictions.

## all-contributors thanks wall

[bin/thanks-wall.mjs](bin/thanks-wall.mjs) adapts the list layout and marker injection (`chunk`, `formatLine`, `generateContributorsList`, `injectListBetweenTags`, the avatar block template, and `formatAvatarUrl`) from [all-contributors/cli](https://github.com/all-contributors/cli/tree/ea23f04fd76498dd7c21717d715119d337e54012/src/generate), copyright 2016 Kent C. Dodds, 2019 Jake Bolam, 2020 Maximilian Berkmann, under the [MIT license](third_party/LICENSE.all-contributors-cli). Poki reads issue and pull request authors through the GitHub CLI instead of a `.all-contributorsrc` file, drops contribution badges and the table footer, and fails when a README is missing its markers.

## Poki Setup (desktop/)

The desktop app and its core crate ([desktop/](desktop/), AGPL-3.0-only) are written in Rust and TypeScript against these works:

- **GSA sign-in and anisette protocol.** [desktop/core/src/apple/gsa.rs](desktop/core/src/apple/gsa.rs), [srp.rs](desktop/core/src/apple/srp.rs) and [anisette.rs](desktop/core/src/apple/anisette.rs) follow Apple's GrandSlam flow (SRP-6a with Apple's `noUsernameInX` variant, the `spd` and `et` decryption, 2FA, the anisette v3 provisioning session) as implemented in [SideStore/apple-private-apis](https://github.com/SideStore/apple-private-apis) (icloud-auth, omnisette; MPL-2.0) and [Dadoum/Sideloader](https://github.com/Dadoum/Sideloader) (GPL-3.0-only). No source is copied; the request and response shapes are the same because Apple's servers define them.
- **Anisette client info override.** [desktop/core/src/apple/anisette.rs](desktop/core/src/apple/anisette.rs) sends the client info and user agent from AltStore pull request 1853 ([altstoreio/AltStore](https://github.com/altstoreio/AltStore), AGPL-3.0) in place of the anisette server's, and provisions a new identity when the client info changes, as that pull request does. The values are the ones [nab138/iloader](https://github.com/nab138/iloader) 2.4.1 uses (MIT).
- **Developer portal.** [desktop/core/src/apple/portal.rs](desktop/core/src/apple/portal.rs) uses the `developerservices2` QH65B2 actions and parameters as documented by Sideloader's `developersession.d` (GPL-3.0-only) and [SideStore/AltSign](https://github.com/SideStore/AltSign) (AGPL-3.0).
- **Entitlement rule.** [desktop/core/src/sign/entitlements.rs](desktop/core/src/sign/entitlements.rs) applies AltSign's rule for merging a profile's entitlements with the app's (AGPL-3.0).
- **Signing.** [apple-codesign](https://github.com/indygreg/apple-platform-rs) 0.29 (MPL-2.0) signs bundles; Apple's corecrypto and ldid are not used or shipped.
- **Device.** [jkcoxson/idevice](https://github.com/jkcoxson/idevice) 0.1.68 (MIT) for usbmuxd, lockdown, AMFI, misagent, installation_proxy, house_arrest, the image mounter, syslog and crash reports.
- **Apple root certificate.** `desktop/core/certs/AppleRootCA.der` is Apple Inc.'s public root certificate, used only to pin TLS to Apple's hosts.
- **Type.** Geist by Vercel, SIL Open Font License 1.1 ([desktop/app/public/fonts/LICENSE-Geist.txt](desktop/app/public/fonts/LICENSE-Geist.txt)).
- **Shell.** [Tauri 2](https://tauri.app) (MIT/Apache-2.0) with its opener, dialog, clipboard-manager and log plugins; window-vibrancy (MIT); React (MIT); Vite (MIT). Rust crate licences are listed by `cargo license` in `desktop/`.
