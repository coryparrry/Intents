# Foundation Evals demo

One uninterrupted recording accelerated to 16 seconds, followed by a four-second animation of the existing app logo. Bright user-supplied background. Fixed window size and position. No audio, captions, artificial camera movement, or cuts between app pages. 1920 × 1080 at 60 fps.

The September 6 replacement recording shows the cases, scoring setup, model and feature settings, an evaluation, and its results and trace. The entire 62.493333-second recording is preserved as one continuous take, accelerated to 16 seconds (about 3.906× speed).

## Preview and export

Run `npm install`, then `npm run dev`. The current session uses an ignored symlink to an existing local Remotion installation; install normally when moving this project elsewhere.

`npm run render` renders the background and logo animation with Remotion, places the uninterrupted recording over that background, and appends the closing animation. The result is `out/foundation-evals-demo-20s.mp4`. This avoids thousands of temporary frame files. FFmpeg and Python 3 are required for export.

## Assets

The `public/` source media and `out/` exports are local-only and ignored by Git. Restore the source media listed below before previewing or rendering from a fresh clone. Published repository images live in `.github/assets/`.

- `public/user-recording.mov`: the supplied original recording. `public/user-take-16s.mp4` is the cropped, scaled and accelerated silent take used in the composition.
- `public/background.png`: user-provided `ChatGPT Image Jun 8, 2026 at 02_48_28 PM (6).png` from the UIshot backgrounds folder.
- `public/app-logo.png`: existing app logo from the repository's AppIcon asset.
- `public/user-last-frame.png`: final frame of the recording, used to transition into the logo ending.

No newly generated imagery or online photograph is used in the final composition. Earlier drafts and unused assets may remain in the project folder.

## Final verification

The final MP4 is exactly 20.000 seconds, 1200 frames, 1920 × 1080 at 60 fps, with a single video stream and no audio stream. Full decoding and black-frame detection passed. The last app frame and first logo frame were inspected in the browser to verify the handoff.
