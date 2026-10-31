# Third-party notices

## AnimeJaNai Windows runtime

- mpv fork and build sources: <https://github.com/the-database/mpv/tree/19c0fcf895>
  and <https://github.com/the-database/mpv-winbuild>.
- 7-Zip 26.02 standalone console: <https://www.7-zip.org/>; its complete license
  is installed under `data/licenses/animejanai/` together with source notices.
- AJI v0.11.1: <https://github.com/the-database/animejanai-inference/tree/v0.11.1>.
- Unmodified AnimeJaNai ONNX models by the-database are downloaded separately,
  under CC BY-NC-SA 4.0 (including its noncommercial restriction):
  <https://github.com/the-database/mpv-AnimeJaNai/tree/6361f4fe059d22984f9074860a4a227489a5d464>.
- NVIDIA TensorRT/CUDA and Microsoft ONNX Runtime/DirectML retain their own
  licenses, which are preserved with the downloaded runtime.

The application's GPLv3 license does not replace the models' or inference
runtimes' licenses. Fixed component versions and installation layout are
maintained with the pinned media-kit fork and the Dart runtime installer.

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

- Packages: `media_kit_video` and `media_kit_libs_windows_video`, resolved through
  pinned pub Git dependencies
- Fork: <https://github.com/AniBakaBaka/media-kit>
- Upstream: <https://github.com/media-kit/media-kit>
- License: MIT

The fork retains the upstream history and carries AniBaka's Windows renderer
and native GPU backend under `media_kit_video/windows/anibaka/`. The backend
retains AniBaka's GPLv3 license and video2dlssnr's MIT notices. The Windows
libraries package owns the pinned AnimeJaNai libmpv bundle and extraction tool.
AniBaka opts in through CMake without copying plugin sources into this repository.
The package licenses are also installed in the Windows application's
`data/licenses/` directory.

## Optional RIFE interpolation model

- Runtime download: `component-rife.7z` from mpv-AnimeJaNai 3.7.0, verified
  by pinned SHA-256; the unmodified `rife_v4.14.onnx` and
  `rife_v4.14_lite.onnx` models are installed for the full and fast modes.
- Distribution: <https://github.com/the-database/mpv-AnimeJaNai/releases/tag/3.7.0>
- RIFE upstream: <https://github.com/hzwer/ECCV2022-RIFE>
- Copyright: Megvii Inc.; license: MIT. The full license is installed beside
  the model as `RIFE_LICENSE.txt`.

## screen_brightness compatibility package

- Package: `screen_brightness`, resolved through pub Git dependencies
- Fork: <https://github.com/AniBakaBaka/screen_brightness>
- Upstream interface: <https://github.com/aaassseee/screen_brightness>
- Copyright: Copyright (c) 2021 Jack Liu
- License: MIT

The fork preserves the upstream Dart API while omitting the Windows dependency
and plugin registration. Its license text is included in the package. Both
forks are pinned to commits in `pubspec.yaml` and `pubspec.lock`.
