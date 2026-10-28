# Presentation requirements and verification

Apple's current [Metal window guidance](https://developer.apple.com/documentation/metal/managing-your-game-window-for-metal-in-macos) specifies full-screen AppKit presentation on Apple Silicon with an opaque RGB CAMetalLayer. It recommends the normal `toggleFullScreen:` transition and leaving the system in control of screen placement. Drawable resolution need not equal the display's backing resolution; Core Animation can scale it while retaining direct-to-display eligibility. Exact pixel-size equality alone is therefore not a valid explanation for the observed Composited baseline.

The launcher and native synthetic probe use an opaque Metal canvas. The injected overlay draws into the game's existing drawable and creates no overlay window or layer. These are implementation properties; they do not establish the system's selected composition mode.

The latest local foreground observation reported **Composited both with and without the injected overlay**. No causal attribution to the overlay, resolution, color space or capture tooling has been established. Current locked-screen/offscreen GPU probes prove rendering and completion, not on-glass or direct display.

## Evidence to collect with an unlocked foreground session

1. Run the native probe fullscreen without overlay injection and confirm active/key/main window state and opaque RGB layer configuration.
2. Read the HUD's actual Layer Size and Composition indicator. Apple documents this indicator as showing **direct or composited** in [HUD metrics](https://developer.apple.com/documentation/xcode/understanding-metal-performance-hud-metrics). Record the observed mode rather than inferring it from fullscreen or Game Mode.
3. Repeat the same scene/runtime with injection, first hidden and then visible. Compare presentation mode separately from GPU completion, texture allocation and frame timing.
4. Repeat for each renderer/provider whose direct-display compatibility is claimed. Preserve the baseline and identify the runtime, display, window/layer state and observation method.

The [HUD logging documentation](https://developer.apple.com/documentation/xcode/monitoring-your-metal-apps-graphics-performance) describes frame numbers, process/Metal memory and timing in console statistics. Those documented CSV fields do not themselves supply a composition-mode proof. Performance reports can be saved through `MTL_HUD_REPORT_URL`; if a report lacks composition mode, a green timing report cannot close this requirement. See [performance reports](https://developer.apple.com/documentation/xcode/generating-performance-reports-with-metal-performance-hud).

Legacy [Quartz display capture](https://developer.apple.com/documentation/coregraphics/cgdisplaycapture(_:)) reserves a display against other applications. It is not used as a substitute for proof of Metal direct presentation, and ready does not change display configuration, suppress system security UI or attempt to bypass the locked session.
