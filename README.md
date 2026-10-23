# Foresite Mind (Mac app)

A small native Mac app around the live Foresite Mind dashboard, which stays a page on claude.ai (so its connectors and live data keep working). This repo holds the app's source and builds it; the app updates itself from this repo's releases.

What the app adds to the page:

- **Menu-bar status**: the icon turns coral with a count while Claude is running tasks; the menu lists them and your open actions. The Dock icon's right-click menu is the same menu.
- **Mac notifications** when a task finishes, fails or goes quiet, when an agent is added, and when an update is out.
- **⌥M** shows or hides the Mind from anywhere (in wallpaper mode it lifts the Mind above your windows and drops it back).
- **⌥⇧A quick add**: type a line, press Enter, and it joins the Action List queue.
- **Wallpaper Mode** (⌥⇧W from anywhere): the Mind sits behind every window, below the menu bar, on the main display, a chosen display, or all displays.
- **Ambient Mode**: after 2–30 idle minutes the Mind fades in full screen; any movement fades it out.
- **Siri & Shortcuts** through `foresitemind://` links: `say`, `show`, `hide`, `toggle`, `add`, `add?text=…`, `wallpaper/on|off|toggle`, `ambient`, `reload`.
- **Self-update**: checks this repo's latest release on launch and every six hours; "Update to x.y…" downloads it, swaps the app in Applications and relaunches, with no Gatekeeper prompt because the app did the download.
- claude.ai's own bar across the top of the page is hidden in wallpaper and ambient modes (optional in the window).

## Install
1. Download `Foresite-Mind.zip` from the latest release, unzip, drag **Foresite Mind** into Applications.
2. First launch only: open it, choose **Done** on the warning, then System Settings › Privacy & Security › **Open Anyway**. The app isn't notarised by Apple yet; updates installed by the app itself don't ask again.
3. Sign in to claude.ai in the window. The sign-in is kept.
4. Menu-bar icon (or the Dock icon's right-click menu) › **Open at Login**.

## Build
`bash build.sh` on any Mac with the Xcode command line tools; output in `dist/`. Pushes to `main` build on GitHub and publish a release tagged `v<version>.<build>` from `Info.plist`; bump `CFBundleVersion` for every release.
