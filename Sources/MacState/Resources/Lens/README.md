# Lens optics in MacState

Retired from the application UI on 2026-10-07. Kept only for offline optical
comparison tests and license attribution. MacState now uses native AppKit
materials, with no screen capture or custom Metal lens instantiated by the UI.

Shader math adapted from `lens/lab/design-system/internal/renderer.js` in
https://github.com/ruiqichenbiec/design-systems
at commit `7a424c93b9be13cf835b91ea67495fec2ec0584e` (MIT, license alongside).

Retained: rounded signed-distance surface, finite-difference normals,
Snell refraction (IOR 1.45), dispersion, Fresnel rim and caustic.
Changed: Metal instead of WebGL2; the former experiment supplied desktop frames
via ScreenCaptureKit (the capture implementation has been removed); Gaussian blur via MPS; optical density
and refraction vary continuously; no rectangular shadow geometry.

The retained renderer is exercised with synthetic textures only. It does not
implement or request screen capture permission.
