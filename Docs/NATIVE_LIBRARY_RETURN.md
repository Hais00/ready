<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Native session return and library restoration

The producer/keeper exit barrier remains the authority for session completion.
Overlay closure still waits for that existing barrier; these changes do not
guess that the game has exited or restore the library before it is reaped.

During gameplay, decoded artwork, card tiles, chrome previews and owned canvas
graphics are released. Catalog/name models and the artwork disk index remain.
No thumbnail snapshot is kept in RAM for return.

After confirmed exit, visible cards get priority indexed disk reads. The canvas
recreates its chrome and sparse card layers immediately, using a return-only CPU
chrome surface while Metal shader/pipeline construction runs in the background.
That construction previously ran synchronously on Main. The renderer builder is
generic and device-only; generation/cancellation guards prevent a result from
reattaching after another game starts. A profile switch can use the same generic
pipeline without stranding the CPU fallback or carrying old profile images.

Unrelated Steam metadata/artwork maintenance resumes after the visible card
stamps commit, rather than immediately after decoding. This prevents full-catalog
warming from taking precedence over the first returned library frame. Genuinely
missing disk assets remain honest placeholders rather than blocking on network.

Own hidden-window tests hold shader compilation behind a gate while verifying
real disk-loaded cards, layers and controller geometry. They also verify late
build cancellation and a profile switch during compilation. These tests establish
ordering and owned resource state, not commercial-game frame pacing or display
scan-out latency. See the [current native checkpoint](../Validation/hosted-native-interaction-checkpoint.json).
