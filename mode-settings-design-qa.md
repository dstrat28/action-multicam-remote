# Design QA

## Source visual truth

- `/Users/ds/Downloads/IMG_0792.PNG` — Video capture fields.
- `/Users/ds/Downloads/IMG_0793.PNG` — Photo capture fields.
- `/Users/ds/Downloads/IMG_0794.PNG` — Slow Motion capture fields.
- `/Users/ds/Downloads/IMG_0795.PNG` — Timelapse capture fields.
- `/Users/ds/Downloads/IMG_0796.PNG` — Hyperlapse capture fields.
- `/Users/ds/Downloads/IMG_0797.PNG` — SuperNight capture fields.
- All references are 1206 × 2622 px.

## Implementation evidence

- Full main-list Video state: `/private/tmp/action-cam-remote-mode-summary-main.png` (1206 × 2622 px).
- Full main-list mixed Photo/Video state: `/private/tmp/action-cam-remote-mode-summary-photo.png` (1206 × 2622 px).
- Side-by-side source/implementation comparison: `/private/tmp/mode-settings-comparison.png` (2412 × 2622 px).
- Runtime: iPhone 17 Pro simulator, iOS 26.5, connected-camera debug fixture.
- Focused region: each connected camera card's mode picker, capture-setting summary, and action button.

## Comparison

- Camera Info now always presents a `Camera Mode` field, while the mode picker remains on the main camera card.
- Video and SuperNight summarize resolution, frame rate, and one broadly readable lens/framing value.
- Photo summarizes resolution/size, aspect ratio, and at most one active burst/timer behavior.
- Slow Motion summarizes resolution, frame rate, and playback multiplier.
- Timelapse summarizes resolution, interval, and duration with plain-language labels.
- Hyperlapse summarizes resolution, rate, and duration with plain-language labels.
- Technical values such as stabilization `Off` and `RS+` remain available in the labeled Camera Info rows but are omitted from the glanceable card.
- The reserved DJI FOV numeric value is no longer exposed as a meaningful setting.
- Typography, spacing, colors, thumbnails, selection controls, and record/capture button styling remain consistent with the existing dashboard.
- Two-line capture summaries fit the existing card width without clipping the action button; the longest tested GoPro Video summary wraps cleanly.

## Verification history

1. Initial simulator launch reused persisted disconnected cameras and could not prove the connected-card layout.
2. Added a debug-only connected-camera launch fixture and corrected its launch-argument routing.
3. Rebuilt, relaunched, and visually inspected connected Video cards.
4. Switched the Action 6 fixture to Photo through the runtime mode picker and verified the card changed to `Photo`, `Medium · 16:9`, and `Capture`.
5. Compared the supplied Action 6 Photo source and the implemented main-list state side by side at the same native screenshot scale.
6. Exercised Slow Motion, Timelapse, and Hyperlapse in the runtime picker and asserted their rendered summaries through the simulator accessibility tree.

Final result: passed
