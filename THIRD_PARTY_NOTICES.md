# Third-party notices

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

## screen_brightness compatibility package

- Location: `third_party/screen_brightness_no_windows/`
- Upstream interface: <https://github.com/aaassseee/screen_brightness>
- Copyright: Copyright (c) 2021 Jack Liu
- License: MIT

The local package preserves the public `screen_brightness` interface while
omitting Windows plugin registration. Its license text is included beside the
package.
