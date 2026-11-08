# Real Chromium scrolling regression

These are viewport PNGs saved through Chrome Guest mode's built-in Capture screenshot command on 2026-11-07 from https://getbootstrap.com/docs/5.3/examples/cheatsheet/ (Bootstrap 5.3.8). They include a sticky header, a fixed right sidebar, a floating theme button, and sparse typography on white. They contain no user screenshots, browser profile data, or signed-in content.

The body moves upward by exactly 138 physical pixels per step between viewport-0.png, viewport-1.png, and viewport-2.png. Full-resolution comparison of the large typography confirms identical body pixels at this offset. During the associated live app test, the previous matcher preferred a large, empty white overlap and duplicated page content. Resting browser PNGs alone did not reproduce that transient failure; they guard real-page alignment, while a separate sparse-page regression exercises small rendering differences and false empty overlaps.

Bootstrap is MIT licensed; see BOOTSTRAP-LICENSE.txt. These fixtures are test resources and are not included in the Still application bundle.
