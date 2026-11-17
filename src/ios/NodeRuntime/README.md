# Bundled Node.js runtime


Official signed Alpine Linux 3.21/aarch64 packages. These Linux ELF files run only inside the existing iSH guest, not as iOS native libraries.


Runtime: Node.js 22.23.5-r0; npm 10.9.1-r0. Full dependency closure is included.


`install.sh` verifies SHA-256, Alpine signatures, architecture and branch; uses only a local repository with `--no-network`; confirms node/npm/npx and actual JS execution. It never bypasses signatures or runs user plugins.


No rootfs reset is performed. Package dependencies may be forward-updated; unsupported downgrade/removal plans are rejected. Installation errors are not a guarantee of automatic rollback.


AOJIT recorded build remains 22.23.2-r0. The bundled Node build is newer, so full AOJIT hit coverage is not claimed. This does not provide a Cordis/DeepSeek Harness host or arbitrary native npm addon support.


## Provenance and licenses


Packages are redistributed unchanged with their Alpine signatures. Full package metadata, immutable packaging commits and upstream source homepages are in manifest.json. Before distributing binaries, retain all upstream notices and provide corresponding source for copyleft components as their licenses require. Source retrieval script records checksums; the runtime bundle is not a relicense of those projects.


| Package | Version | License | Immutable packaging source |
|---|---|---|---|

| ada-libs | 2.9.2-r1 | ( Apache-2.0 OR MIT ) AND MPL-2.0 | https://gitlab.alpinelinux.org/alpine/aports/-/tree/a6328ea36a87303e794b2b934cbadbb2757dc1b2/main/ada |

| brotli-libs | 1.1.1-r0 | MIT | https://gitlab.alpinelinux.org/alpine/aports/-/tree/2e2e1c66200dbbb50a717171d1df57829ff4c264/main/brotli |

| busybox | 1.37.0-r14 | GPL-2.0-only | https://gitlab.alpinelinux.org/alpine/aports/-/tree/284d827a2793963e6dcf88324bd1eb81adff579c/main/busybox |

| busybox-binsh | 1.37.0-r14 | GPL-2.0-only | https://gitlab.alpinelinux.org/alpine/aports/-/tree/284d827a2793963e6dcf88324bd1eb81adff579c/main/busybox |

| c-ares | 1.34.9-r0 | MIT | https://gitlab.alpinelinux.org/alpine/aports/-/tree/dbc05e4ef8f0c86d93ce3d4933d28ab5d39241f4/main/c-ares |

| ca-certificates | 20261020-r0 | MPL-2.0 AND MIT | https://gitlab.alpinelinux.org/alpine/aports/-/tree/660f223b42ca35e7d2a76ce568e15c847b92d33d/main/ca-certificates |

| icu-data-en | 74.2-r1 | ICU | https://gitlab.alpinelinux.org/alpine/aports/-/tree/1544fc8aa5994c812b43101c6808b955239503fe/main/icu |

| icu-libs | 74.2-r1 | ICU | https://gitlab.alpinelinux.org/alpine/aports/-/tree/1544fc8aa5994c812b43101c6808b955239503fe/main/icu |

| libcrypto3 | 3.3.7-r2 | Apache-2.0 | https://gitlab.alpinelinux.org/alpine/aports/-/tree/a254386dfe34f70a05bdb8b2a3d7a5b20b6f076e/main/openssl |

| libgcc | 14.2.0-r4 | GPL-2.0-or-later AND LGPL-2.1-or-later | https://gitlab.alpinelinux.org/alpine/aports/-/tree/1a03a2a9c9e77f1a07d48b6f6805e72c8c63c03f/main/gcc |

| libssl3 | 3.3.7-r2 | Apache-2.0 | https://gitlab.alpinelinux.org/alpine/aports/-/tree/a254386dfe34f70a05bdb8b2a3d7a5b20b6f076e/main/openssl |

| libstdc++ | 14.2.0-r4 | GPL-2.0-or-later AND LGPL-2.1-or-later | https://gitlab.alpinelinux.org/alpine/aports/-/tree/1a03a2a9c9e77f1a07d48b6f6805e72c8c63c03f/main/gcc |

| musl | 1.2.5-r12 | MIT | https://gitlab.alpinelinux.org/alpine/aports/-/tree/5245849e14d213abe18d589b4b80d65793327940/main/musl |

| nghttp2-libs | 1.69.0-r0 | MIT | https://gitlab.alpinelinux.org/alpine/aports/-/tree/f5865f848b702c52c657060adbe80706265984ec/main/nghttp2 |

| nodejs | 22.23.5-r0 | MIT | https://gitlab.alpinelinux.org/alpine/aports/-/tree/ebf0d5231d2d4c893b5f3b7710a0ce3bfe7ef509/main/nodejs |

| npm | 10.9.1-r0 | Artistic-2.0 | https://gitlab.alpinelinux.org/alpine/aports/-/tree/6eae051666671f2d152bc51d5404cb39fd5b728c/community/npm |

| simdjson | 3.10.1-r0 | Apache-2.0 | https://gitlab.alpinelinux.org/alpine/aports/-/tree/4870e167116b803d074ed670b3d034dc647d202c/main/simdjson |

| simdutf | 5.6.3-r0 | Apache-2.0 OR MIT | https://gitlab.alpinelinux.org/alpine/aports/-/tree/6b3723803c6f6955c86efaa065d09bad0939523f/main/simdutf |

| sqlite-libs | 3.48.0-r4 | blessing | https://gitlab.alpinelinux.org/alpine/aports/-/tree/ee0eac4d746e3a414cacb3186b3577ccc4342c07/main/sqlite |

| ssl_client | 1.37.0-r14 | GPL-2.0-only | https://gitlab.alpinelinux.org/alpine/aports/-/tree/284d827a2793963e6dcf88324bd1eb81adff579c/main/busybox |

| zlib | 1.4-r0 | Zlib | https://gitlab.alpinelinux.org/alpine/aports/-/tree/d3332621d44c2c4cf52e52217b16674db190212c/main/zlib |

| zstd-libs | 1.5.6-r2 | BSD-3-Clause OR GPL-2.0-or-later | https://gitlab.alpinelinux.org/alpine/aports/-/tree/5c2ddf18f193dafdd25ae7391d96c7e30766eecd/main/zstd |
