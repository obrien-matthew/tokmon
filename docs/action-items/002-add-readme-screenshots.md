# Add the README screenshots

The README references two images that need to be saved into the repo:

- `docs/images/menu.png` — the menu bar widget + expanded menu screenshot
- `docs/images/settings.png` — the Settings window screenshot

## Steps

1. Save the two screenshots (the ones shared in chat on 2026-07-21) to
   the paths above. If they were taken to the clipboard, retake with
   Cmd-Shift-4 (saves to Desktop) and move them:

   ```sh
   mkdir -p docs/images
   mv ~/Desktop/menu-screenshot.png docs/images/menu.png
   mv ~/Desktop/settings-screenshot.png docs/images/settings.png
   ```

2. Commit and push:

   ```sh
   git add docs/images && git commit -m "README screenshots" && git push
   ```

Until this is done, the README's screenshot section renders as broken
images — do this before (or right after) making the repo public.
