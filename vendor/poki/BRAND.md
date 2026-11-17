# Poki brand and design assets

Poki's source code is open source under the [AGPL-3.0-only license](LICENSE). That includes the code that draws the app's screens.

Poki's character and artwork are not covered by the AGPL. The only permissions for them are the ones in this file. This file explains what they are, what you can do with them without asking, and what a fork has to change.

Copyright (c) 2026 Joseph Zhou (周瑟夫). All rights reserved, to the extent the law protects these works.

## The Poki bear

The Poki bear is the character at the center of Poki, and the main thing this file protects. It covers the bear as a character, not only the files below: its design, its face and expressions, its poses, its 3D model, its renders and animations, and any other image of the bear, including new versions made from it.

| What | Where |
| --- | --- |
| Illustrations, poses and expressions | The `.png` files in [`native/ios-app/Poki/Bear/`](native/ios-app/Poki/Bear) and its `Model/` folder, the `.png` files in [`native/ios-app/Poki/ActivityBears/`](native/ios-app/Poki/ActivityBears), and [`native/ios-app/Poki/Chat/PokiFace.png`](native/ios-app/Poki/Chat/PokiFace.png) |
| 3D model | [`native/ios-app/Poki/Bear/Model/PokiBear.usdz`](native/ios-app/Poki/Bear/Model/PokiBear.usdz) |
| Artwork, animations and videos of the bear on the Poki website and in Poki's release posts | Outside this repository |

## Other brand assets

| What | Where |
| --- | --- |
| The Poki app icon, light and dark | [`docs/images/poki-app-icon.png`](docs/images/poki-app-icon.png) |
| The earlier Poki icon | [`docs/images/poki-icon.png`](docs/images/poki-icon.png) |
| Promotional images and animations | [`docs/images/poki-home.gif`](docs/images/poki-home.gif), [`docs/images/roadmap.png`](docs/images/roadmap.png), [`docs/images/roadmap.zh-CN.png`](docs/images/roadmap.zh-CN.png) |

In this file, "brand assets" means the Poki bear and everything in the two tables above.

## Not brand assets

This file does not claim anything that belongs to someone else, and it does not restrict the code.

- **Source code.** All code in this repository, including the user interface code and the code and animation data next to the bear's pictures (`.swift`, `.json`), stays under the AGPL-3.0-only license, or under the license of the project it came from.
- **Third-party material.** Other apps' icons (`native/ios-app/Poki/AppIcons/`, `native/ios-app/Poki/ProxyIcons/`), AI provider logos (`native/ios-app/Poki/ProviderIcons/`), the Geist fonts, contributors' profile pictures in `docs/images/acknowledgments.png`, and the code and designs listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) belong to their owners and keep their own terms.
- **Earlier copies.** This notice applies from the commit that adds it. It does not change the terms of copies published before that commit.

## What you can do without asking

- Build and run Poki from this repository, with the brand assets unchanged, for yourself or for your team.
- Fork this repository to work on it and send pull requests back.
- Share unchanged copies of this repository or of official Poki releases.
- Use screenshots, screen recordings and the app icon, unchanged, to write about, review, teach or link to Poki: articles, videos, tutorials, talks and social posts.
- Say truthfully that your project is "based on Poki" or "a fork of Poki".

## What needs written permission

- Using the Poki bear, the app icon or other brand assets in your own app, website, product, marketing or merchandise.
- Making or publishing new versions of the Poki bear: redrawings, traced or edited images, new poses or expressions, other 3D models, animations, stickers, or a character that copies the bear's look closely enough to be taken for it.
- Using the name Poki, the bear or the icon in a way that suggests your product is Poki, or is made or endorsed by the Poki project.

## If you publish a fork

The AGPL lets you copy, change and share Poki's code. It does not give you the brand assets, and it does not let you present your version as Poki. Before you publish a changed version, or a build of one:

1. Replace the Poki bear, the app icon and the other brand assets with your own artwork.
2. Give it a name other than Poki, and app and bundle identifiers of your own.
3. Keep the copyright and license notices that the AGPL requires.

## Asking for permission

Open an issue titled "Brand asset request" and say what you want to use and where. A permission is valid only if it is given in writing.
