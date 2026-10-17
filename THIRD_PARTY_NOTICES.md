# Third-party notices

## ech_http native TLS transport

- Package: `ech_http`, resolved through a pinned pub Git dependency
- Fork: <https://github.com/AniBakaBaka/ech_http>
- Upstream: <https://github.com/ech-research/ech_http>
- License: MIT; full text in `assets/licenses/ech_http/LICENSE`
- Native dependencies: libcurl, BoringSSL, zlib, Mozilla CA bundle, and Android
  libc++; their notices are in `assets/licenses/ech_http/THIRD_PARTY_NOTICES.md`.

The dependency SDKs are downloaded at build time from pinned, SHA-256 verified
archives. The full license notices above are included in the Flutter asset
bundle; the build hook bundles the native runtime.

This file records third-party source and assets included directly in this
repository. Packages resolved through Flutter or Dart package management retain
their own license files in their respective distributions.

## Anime4K shaders

- Location: `assets/anime4k/`
- Upstream: <https://github.com/bloc97/Anime4K>
- Copyright: Copyright (c) 2019-2021 bloc97
- License: MIT, except `Anime4K_AutoDownscalePre_x2.glsl` and
  `Anime4K_AutoDownscalePre_x4.glsl`, which are distributed under the
  Unlicense/public-domain dedication.

Each shader keeps its upstream copyright and complete license notice in the
source file.

## Eva Icons

- Location: navigation SVG files under `assets/`
- Files: `compass.svg`, `compass-outline.svg`, `message-circle.svg`,
  `message-circle-outline.svg`, `smiling-face.svg`, and
  `smiling-face-outline.svg`
- Upstream: <https://github.com/akveo/eva-icons>
- Copyright: Copyright (c) 2018 Akveo
- License: MIT

The complete license is included at `assets/eva-icons-LICENSE.txt` and is
packaged with the application.

## media_kit_video Windows bridge

- Package: `media_kit_video`, resolved through pub Git dependencies
- Fork: <https://github.com/AniBakaBaka/media-kit>
- Upstream: <https://github.com/media-kit/media-kit>
- License: MIT

The fork retains the upstream history and carries AniBaka's Windows renderer
under `media_kit_video/windows/anibaka/`. AniBaka opts into that renderer and
provides its native GPU backend. The package's license is also installed in
the Windows application's `data/licenses/media_kit_video_windows/` directory.

## screen_brightness compatibility package

- Package: `screen_brightness`, resolved through pub Git dependencies
- Fork: <https://github.com/AniBakaBaka/screen_brightness>
- Upstream interface: <https://github.com/aaassseee/screen_brightness>
- Copyright: Copyright (c) 2021 Jack Liu
- License: MIT

The fork preserves the upstream Dart API while omitting the Windows dependency
and plugin registration. Its license text is included in the package. Both
forks are pinned to commits in `pubspec.yaml` and `pubspec.lock`.
