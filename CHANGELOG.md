# Changelog

## 1.0.0

- First release: a wallpaper's `spans/<name>/left` and `right` images go to the screens left and right of the main screen; everything else behaves like Omarchy's own background service (Omarchy 4.0).
- Screen roles (`main`, `left`, `right`, `wallpaper`) are chosen automatically or set per screen, and each screen's picture can be moved and scaled, in `~/.config/omarchy/multimonitor-background.json` or with `omarchy-shell background setScreen`. The file applies as soon as it is saved.
- An optional `layout.json` places the panels by the monitor layout Hyprland reports, so a scene lines up across the bezels for any arrangement; a gap a panel leaves is filled with a blurred copy of it.
- `omarchy-shell background screens`, `spans` and `spanState` report what each screen does.
- A wallpaper or panel replaced at the same path is read again rather than served from Qt's image cache.
