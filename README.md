# StageSolo

[中文说明](README.zh-CN.md)

With Stage Manager on several displays, clicking a thumbnail in one screen's strip switches **only that screen**.

macOS brings an app forward on every screen where it has windows. If Chrome has one window on your laptop and another on your external monitor, clicking Chrome in the laptop's strip can also swap the external monitor over to Chrome. StageSolo makes the click switch only the screen you clicked on, for any app.

**Without StageSolo**, clicking Chrome in the laptop's strip (left) also turns the external monitor (right) to Chrome:

![Without StageSolo: both screens switch to Chrome](docs/demo-without.gif)

**With StageSolo**, only the laptop switches:

![With StageSolo: only the laptop switches](docs/demo-with.gif)

StageSolo is a small menu bar app: one Swift file, no dependencies. It was vibe-coded with Claude Code.

## Requirements

- macOS 13 or later, Stage Manager on, two or more displays
- The Accessibility permission (see [Privacy](#privacy))

Tested only on macOS 26.6 on Apple silicon with three displays. Reports from other setups are welcome.

## Install

Needs the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/ubinaroy/StageSolo.git
cd StageSolo
make install
```

This builds `StageSolo.app`, copies it to `~/Applications` and starts it. When macOS asks, allow StageSolo in **System Settings → Privacy & Security → Accessibility**. The menu bar icon turns solid once StageSolo is active.

## Use

Click thumbnails as usual. Like Stage Manager, StageSolo acts as soon as you press. The menu bar icon has:

- **Pause / Resume**
- **Launch at Login**
- **About**, **Quit**

To add a window to the current group, hold ⇧ and click its thumbnail (a Stage Manager shortcut). StageSolo leaves every click made with ⇧, ⌥, ⌘ or ⌃ to Stage Manager.

## How it works

1. A mouse event tap looks at presses near the left and right edges of each screen.
2. Stage Manager draws each strip thumbnail as the app's real window scaled down, so the window list reports that window at thumbnail size. StageSolo uses this to find the window under the pointer. A press on the app icon under a thumbnail counts for the thumbnail the icon overlaps most. Windows grouped into one stage show up as thumbnails stacked on top of each other, and StageSolo treats them as one.
3. If that app, or an app grouped with it, also has windows on another screen, StageSolo takes over the press and brings forward just one window, the front one of the group: `_SLPSSetFrontProcessWithOptions` for that window only, synthesized make-key events and an Accessibility raise (the technique yabai uses). Stage Manager then switches only that window's screen and brings the rest of the group along.
4. Every other press passes through untouched, including presses on groups whose apps all live on one screen.

## Limitations

- Only presses on strip thumbnails are handled. ⌘Tab, the Dock and opening links still switch every screen.
- It relies on private macOS functions, so a macOS update can break it.
- Stage Manager rarely lets you add an app that has windows on another screen to a group: ⇧-click switches to it instead (seen on macOS 26.6, with or without StageSolo). Groups containing such an app are therefore barely tested.
- Stage Manager does not let you drag a thumbnail from the strip into a group, with or without StageSolo (on macOS 26 a press on a thumbnail switches at once). Use ⇧-click to add a window to the current group. Minimizing a window does not take it out of its group; drag it from the middle back to the strip.

## Privacy

StageSolo watches left mouse clicks only, never the keyboard. It makes no network connections and collects nothing. Each handled click is written to the macOS unified log: app name, window number and result.

## Troubleshooting

```bash
log show --last 10m --predicate 'subsystem == "io.github.ubinaroy.StageSolo"'
```

A line such as `Google Chrome window 72 on display 1: front=0 raise=0` means a click was handled and both calls succeeded. To watch every press StageSolo looks at, and why it passes one through, run `log stream --level info` with the same predicate.

## Rebuilding

`make install` builds and reinstalls. By default builds are ad-hoc signed, so macOS treats every new build as a new app: remove StageSolo from the Accessibility list and allow it again. To avoid this, create a code-signing certificate once in Keychain Access (**Certificate Assistant → Create a Certificate…**, name `StageSolo Dev`, identity type Self Signed Root, certificate type Code Signing). The Makefile signs with it when it exists, and macOS then keeps the permission across rebuilds.

## Uninstall

Turn off **Launch at Login**, quit StageSolo, delete `~/Applications/StageSolo.app` and remove StageSolo from the Accessibility list.

## Credits

The one-window focus technique comes from [yabai](https://github.com/koekeishiya/yabai). [AltTab](https://github.com/lwouis/alt-tab-macos) uses the same approach.

## License

[MIT](LICENSE)
