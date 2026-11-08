# Changelog

## 1.0.0

- First release: a wallpaper's `spans/<name>/left` and `right` images go to the screens left and right of the main screen; everything else behaves like Omarchy's own background service (Omarchy 4.0).
- Screen roles (`main`, `left`, `right`, `wallpaper`) are chosen automatically or set per screen, and each screen's picture can be moved and scaled, in `~/.config/omarchy/panomarchy.json` or with `omarchy-shell background setScreen`. The file applies as soon as it is saved.
- An optional `layout.json` places the panels by the monitor layout Hyprland reports, so a scene lines up across the bezels for any arrangement; a gap a panel leaves is filled with a blurred copy of it.
- An editor, opened from the bar icon, a middle click on the desktop or `omarchy-shell shell toggle thepixelgardener.panomarchy`, shows the monitors as Hyprland places them with their pictures live. It adjusts either the whole scene or one screen: drag to move, drag a corner handle to resize with the opposite corner held, scroll to zoom about the pointer.
- The whole scene has its own move and size (`scene` in the settings, `setScene`), which the side screens follow; a screen's own size pivots on the seam it shares with the main screen.
- A bar icon, three screens sharing one horizon, opens the editor.
- Autoscale, on by default, sizes the panels by each monitor's physical size from Hyprland, so a scene is as large on every screen as on the main one.
- `omarchy-shell background screens`, `spans` and `spanState` report what each screen does; `setAutoscale on|off` switches autoscaling.
- A wallpaper or panel replaced at the same path is read again rather than served from Qt's image cache.
