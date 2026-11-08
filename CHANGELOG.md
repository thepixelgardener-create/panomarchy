# Changelog

## 1.0.0

- First release: a wallpaper's `spans/<name>/left` and `right` images go to the screens left and right of the main screen; everything else behaves like Omarchy's own background service (Omarchy 4.0).
- `omarchy-shell background spans` and `spanState` report what each screen shows.
- A wallpaper or panel replaced at the same path is read again rather than served from Qt's image cache.
