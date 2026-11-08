# Multimonitor Background

A background for [Omarchy](https://omarchy.org) on more than one monitor. Omarchy shows the same wallpaper on every screen; with this plugin a wallpaper can bring a left and a right panel, so one scene runs across three screens, past the bezels, or each side screen shows a picture of its own. Which screen shows what, and where the picture sits on each, follows your monitor layout and your settings.

![A black hole's accretion disk running across a portrait screen, a 16:9 main screen and a third screen](preview.webp)

*The black hole from the [Gargantuan](https://github.com/thepixelgardener-create/omarchy-gargantuan-theme) theme across three screens.*

Wallpapers without panels, video wallpapers, transitions, intros and the background switcher all work as before: the plugin is Omarchy's own background service with these additions.

## Install

```bash
omarchy plugin add https://github.com/thepixelgardener-create/omarchy-multimonitor-background.git --enable
omarchy restart shell
```

Enabling it switches Omarchy's built-in background off; the restart makes sure the shell runs the plugin's code fresh. `--enable` also asks where the bar icon goes; to add or move it later:

```bash
omarchy bar put thepixelgardener.multimonitor-background --after omarchy.clock
```

To go back to the built-in background:

```bash
omarchy plugin disable thepixelgardener.multimonitor-background
omarchy plugin enable omarchy.background
```

## Screens and roles

Every screen has a role:

| Role | Shows |
|---|---|
| `main` | the wallpaper |
| `left` | the wallpaper's left panel |
| `right` | the wallpaper's right panel |
| `wallpaper` | the wallpaper itself, as without the plugin |

By default the **main** screen is the one with the most physical pixels (on a tie, the one nearest the middle), the screens directly to its left and right are **left** and **right**, and any other screen shows the wallpaper. A screen whose panel is missing shows the wallpaper too. Change any of it in the editor below.

## The editor

Click the plugin's icon in the bar (three screens sharing one horizon), middle-click the desktop, or run

```bash
omarchy-shell shell toggle thepixelgardener.multimonitor-background
```

The editor draws your monitors where Hyprland puts them, each with the picture it shows now, and the desktop behind follows every change as you make it. At the top right you choose what to adjust:

- **Whole scene**: the picture across all screens at once. The side screens follow the main one, so this is how you place the scene where you want it.
- **One screen**: the picture on a single monitor, for when autoscale does not quite match it. Its size pivots on the edge it shares with the main screen, so the scene stays attached at the bezel while you make it larger or smaller.

What you adjust has an orange box around it. Then:

- **Drag** anywhere to move it.
- **Drag a corner** of the box to resize it; the opposite corner stays where it is.
- **Scroll** to zoom about the pointer; **double-click** to reset.
- In One screen mode, **click** a screen to pick it; **Shows** sets its role.
- Keys: **arrows** nudge by 1 px (10 with Shift), **+** and **−** zoom, **Tab** picks the next screen, **S** goes back to the whole scene, **0** resets, **Esc** closes.
- **Autoscale** switches autoscaling for all screens; **Reset all** clears every setting.

To open it from the keyboard, add a binding to `~/.config/hypr/bindings.lua`, for example:

```lua
o.bind("SUPER + CTRL + B", "Multimonitor background", "omarchy-shell shell toggle thepixelgardener.multimonitor-background")
```

## Autoscale

Monitors of different sizes show the same number of logical pixels at different physical sizes: on a 32-inch 4K at scale 2 a pixel is 0.36 mm, on a 24-inch 1080p screen 0.28 mm, so a scene running across them would shrink by a quarter at the bezel. Autoscale reads each monitor's physical size from Hyprland and enlarges or shrinks the panels so the scene is as large on every screen as on the main one, keeping it aligned at the middle of each shared edge. It is on by default; switch it in the editor or with

```bash
omarchy-shell background setAutoscale off
```

A monitor that reports no physical size is left as it is.

## Settings

Everything the editor does can also be done from a terminal:

```bash
omarchy-shell background screens                    # every screen, its role, size and settings
omarchy-shell background setScene x 120             # move the whole scene 120 px right
omarchy-shell background setScene scale 1.1         # and make it 10 % larger
omarchy-shell background setScreen HDMI-A-1 role main
omarchy-shell background setScreen DP-3 y -12       # move one screen's picture 12 px up
omarchy-shell background setScreen DP-3 scale 1.05  # make it 5 % larger, about its seam
omarchy-shell background setScreen DP-3 y auto      # remove one setting
omarchy-shell background resetScreens               # back to automatic, no moves
```

`x` and `y` are in logical pixels. The scene is sized about the main screen's centre. A screen's own `scale` comes on top of autoscale and pivots on the seam it shares with the main screen, or on its centre if it shows a picture of its own. A picture that only fills its screen is enlarged as needed, so a move never shows an empty edge; elsewhere a gap shows a blurred copy of the picture.

The settings live in `~/.config/omarchy/multimonitor-background.json` and apply as soon as the file is saved, so you can also edit it by hand:

```json
{
  "autoscale": true,
  "scene": { "x": 120, "y": 0, "scale": 1.1 },
  "screens": {
    "HDMI-A-1": { "role": "main" },
    "DP-5": { "role": "left" },
    "DP-3": { "role": "right", "y": -12, "scale": 1.05 }
  }
}
```

Output names are the ones `hyprctl monitors` and `omarchy-shell background screens` show.

## Adding panels to a wallpaper

Put the panels in a `spans` folder beside the wallpaper, in a folder named after it, with the wallpaper's file extension:

```
backgrounds/
├── 01-gargantuan.webp            the wallpaper, on the main screen
└── spans/
    ├── layout.json               optional: where the panels lie in the scene
    └── 01-gargantuan/
        ├── left.webp             the screen left of the main screen
        ├── right.webp            the screen right of it
        └── layout.json           optional, for this wallpaper only
```

That works for a theme's own `backgrounds/` folder and for your own wallpapers in `~/.config/omarchy/backgrounds/<theme>/`. Omarchy only lists the files directly in those folders, so the panels never turn up as wallpapers of their own. A wallpaper may have only one of the two panels.

**Without a layout**, a panel simply fills its screen: right for a different picture per screen.

**With a layout**, the panels are placed where they lie in one scene, measured from the wallpaper on the main screen through the monitor positions Hyprland reports, so the scene lines up across the bezels whatever the arrangement. The layout gives the wallpaper's size and each panel's rectangle, in the same units, relative to the wallpaper's top-left corner:

```json
{
  "wallpaper": { "w": 1920, "h": 1080 },
  "left":  { "x": -1080, "y": -480, "w": 1080, "h": 1920 },
  "right": { "x": 1920,  "y": 70,   "w": 1920, "h": 1080 }
}
```

This one, from Gargantuan, says the left panel is a portrait 1080 × 1920 whose right edge meets the wallpaper's left edge, starting 480 units above its top, and the right panel a 1920 × 1080 starting 70 units lower than the wallpaper. Where a screen reaches past its panel, the gap shows a blurred copy of the panel rather than black. The units only need to agree with each other; the wallpaper's own pixels work as well as anything.

## Troubleshooting

```bash
omarchy-shell background spans       # the file each screen shows and where it sits
omarchy-shell background spanState   # the full state of the service and every screen
```

If a screen stays black or shows the wrong picture, `omarchy restart shell` puts it right; please open an issue with the `spanState` output.

## Limits

- The panels are found by name, so a wallpaper and its panels must share the file extension.
- Hyprland does not know how wide your bezels are or how the monitors stand on the desk; autoscale evens out pixel sizes, and the editor's drag and zoom do the rest.
- The plugin is a copy of the background service from Omarchy 4.0. When Omarchy changes its own background service, the copy does not follow; if anything about wallpapers misbehaves after an Omarchy update, switch back to the built-in with the two commands above.
- The lock screen still shows the wallpaper on every screen; it is drawn by Omarchy's lock, not by the background service.

## License

MIT. The plugin is a modified copy of Omarchy's background service, which is MIT-licensed as well; [LICENSE](LICENSE) carries both notices. The preview image is from the Gargantuan theme.
