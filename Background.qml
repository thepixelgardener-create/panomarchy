import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Item {
  id: root

  property var shell: null
  property bool suspended: false
  readonly property string home: Quickshell.env("HOME")
  readonly property string stateHome: home + "/.local/state"
  readonly property string currentBackgroundLink: stateHome + "/omarchy/current/background"
  readonly property string currentThemeBackgrounds: stateHome + "/omarchy/current/theme/backgrounds"

  property string currentBackground: ""
  property string displayedBackground: ""
  property string incomingBackground: ""
  property string oldBackground: ""
  // A theme switch names its next background before it has staged the rest of
  // the theme, so the incoming frame can decode while that work runs. A large
  // WebP takes ~130ms to decode at any sourceSize, which the reveal would
  // otherwise wait out after the transition arrives.
  property string preparedBackground: ""
  // The prepare and transition calls travel as separate IPC clients, so a
  // prepare can land after its transition. The path it names then must not be
  // decoded again.
  property string lastTransitionPath: ""
  // Native pixel size per wallpaper path, read from the file header before
  // the image loads. Decoding at screen size only saves memory for wallpapers
  // at least as large as the screen: with PreserveAspectCrop Qt scales the
  // decode up to cover sourceSize, so a smaller wallpaper would cost the
  // screen's worth of pixels instead of its own.
  property var nativeSizes: ({})
  property var sizeQueue: []
  property bool finishingTransition: false
  property int backgroundVersion: 0
  property int reloadVersion: 0
  property int revealStartedVersion: -1
  property int pendingThemeVersion: -1
  property string pendingColorsRaw: ""
  property string pendingShellRaw: ""
  property real revealProgress: 1
  readonly property bool ready: {
    if (isVideo(displayedBackground)) return true
    if (backgrounds.instances.length === 0) return false
    for (var panel of backgrounds.instances) {
      if (!panel.backgroundReady) return false
    }
    return true
  }

  function isVideo(path) {
    return Util.isVideoPath(path)
  }

  // Multimonitor backgrounds. Any wallpaper can have a left and a right panel
  // in a spans folder beside it, so that one scene runs across three
  // monitors, or each side screen shows a picture of its own:
  //
  //   <folder>/<name>.<ext>                   the wallpaper, on the main screen
  //   <folder>/spans/<name>/left.<ext>        the screen to its left
  //   <folder>/spans/<name>/right.<ext>       the screen to its right
  //   <folder>/spans/<name>/layout.json       optional: where the panels lie
  //                                           (or spans/layout.json for all)
  //
  // <folder> is a theme's backgrounds folder or a user's own, such as
  // ~/.config/omarchy/backgrounds/<theme>/. Omarchy lists only the files
  // directly in it, so the panels never show up as wallpapers themselves.
  //
  // Every screen has a role: "main" shows the wallpaper, "left" and "right"
  // show its panels, "wallpaper" shows the wallpaper itself as the built-in
  // background does. By default the main screen is the one with the most
  // physical pixels (the middle one on a tie) and the screens directly
  // beside it are left and right. The user's settings file can name every
  // role and move and scale the picture on any screen.
  //
  // With a layout, a panel is placed where it lies in the scene, measured
  // from the wallpaper on the main screen through the monitor positions
  // Hyprland reports, so the scene lines up across the bezels for any
  // arrangement. Without one, a panel fills its screen.
  //
  // A transition names a snapshot of its wallpaper rather than the wallpaper
  // itself, so each snapshot remembers the wallpaper it stands for.
  property var spanSources: ({})
  readonly property string transitionCache: home + "/.cache/omarchy/background-transitions/"

  // ~/.config/omarchy/multimonitor-background.json, read live:
  //   { "autoscale": true,
  //     "screens": { "<output>": { "role": "main|left|right|wallpaper",
  //                                "scale": 1.0, "x": 0, "y": 0 } } }
  // x and y move the picture on that screen, in logical pixels; scale zooms
  // it about the screen's centre. Every key is optional. Autoscale, on
  // unless set to false, sizes the panels so the scene is as large on
  // every screen as on the main one, by each monitor's physical size.
  readonly property string configPath: home + "/.config/omarchy/multimonitor-background.json"
  readonly property string pluginId: "thepixelgardener.multimonitor-background"
  property var config: ({ screens: {} })
  readonly property var roleNames: ["main", "left", "right", "wallpaper"]
  readonly property bool autoscale: config.autoscale !== false

  function loadConfig(text) {
    var parsed = {}
    text = String(text || "").trim()
    if (text) {
      try {
        parsed = JSON.parse(text)
      } catch (e) {
        // A half-typed edit keeps the settings that were working.
        console.warn("multimonitor-background: " + configPath + ": " + e)
        return
      }
    }
    if (!parsed || typeof parsed !== "object") parsed = {}
    if (!parsed.screens || typeof parsed.screens !== "object") parsed.screens = {}
    config = parsed
  }

  function screenConfig(name) {
    var entry = config.screens[name]
    return entry && typeof entry === "object" ? entry : {}
  }

  function configuredRole(name) {
    var role = String(screenConfig(name).role || "")
    return roleNames.indexOf(role) !== -1 ? role : ""
  }

  // Changes a setting at once, on screen. The file is written unless the
  // caller is mid-drag and persists when the gesture ends.
  function saveScreenSetting(name, key, value, deferWrite) {
    var values = {}
    values[key] = value
    saveScreenSettings(name, values, deferWrite)
  }

  // Several settings of one screen at once; undefined removes a setting.
  function saveScreenSettings(name, values, deferWrite) {
    var next = JSON.parse(JSON.stringify(config))
    var entry = next.screens[name] && typeof next.screens[name] === "object" ? next.screens[name] : {}
    for (var key in values) {
      if (values[key] === undefined) delete entry[key]
      else entry[key] = values[key]
    }
    if (Object.keys(entry).length) next.screens[name] = entry
    else delete next.screens[name]
    config = next
    if (!deferWrite) persistConfig()
  }

  function setAutoscale(enabled) {
    var next = JSON.parse(JSON.stringify(config))
    if (enabled) delete next.autoscale
    else next.autoscale = false
    config = next
    persistConfig()
  }

  // One screen's settings, or with no name every screen's and the scene's.
  function resetScreenSettings(name) {
    var next = JSON.parse(JSON.stringify(config))
    if (name) {
      delete next.screens[name]
    } else {
      next.screens = {}
      delete next.scene
    }
    config = next
    persistConfig()
  }

  // The whole scene's move and size: { "scene": { "x": 0, "y": 0, "scale": 1 } }.
  // It moves and sizes the wallpaper on the main screen, and every panel
  // placed by a layout follows it.
  function sceneConfig() {
    var scene = config.scene
    return scene && typeof scene === "object" ? scene : {}
  }

  function saveScene(values, deferWrite) {
    var next = JSON.parse(JSON.stringify(config))
    var scene = next.scene && typeof next.scene === "object" ? next.scene : {}
    for (var key in values) {
      if (values[key] === undefined) delete scene[key]
      else scene[key] = values[key]
    }
    if (Object.keys(scene).length) next.scene = scene
    else delete next.scene
    config = next
    if (!deferWrite) persistConfig()
  }

  function persistConfig() {
    configFile.setText(JSON.stringify(config, null, 2) + "\n")
  }

  // Millimetres per logical pixel, by output name, from the physical size
  // Hyprland reports for each monitor. Qt's own figure counts a rotated
  // monitor's millimetres the wrong way round, so Hyprland's is used.
  property var monitorMm: ({})

  function loadMonitors(text) {
    var monitors = []
    try {
      monitors = JSON.parse(String(text || "[]"))
    } catch (e) {
      return
    }
    var mm = ({})
    for (var i = 0; i < monitors.length; i++) {
      var m = monitors[i]
      var rotated = Number(m.transform) % 2 === 1
      var physicalWidth = Number(rotated ? m.physicalHeight : m.physicalWidth)
      var logicalWidth = Number(rotated ? m.height : m.width) / (Number(m.scale) || 1)
      if (physicalWidth > 0 && logicalWidth > 0) mm[m.name] = physicalWidth / logicalWidth
    }
    monitorMm = mm
  }

  function refreshMonitors() {
    monitorRefresh.restart()
  }

  function mmPerPixel(screen) {
    var mm = screen ? Number(monitorMm[screen.name]) : 0
    return mm > 0 ? mm : 0
  }

  // How much larger a screen must draw the scene than its logical pixels say,
  // so that it is as large on that screen as on the main one.
  function autoScaleFor(screen) {
    var main = mainScreen
    if (!autoscale || !main || !screen || screen.name === main.name) return 1
    var mainMm = mmPerPixel(main)
    var screenMm = mmPerPixel(screen)
    if (!(mainMm > 0 && screenMm > 0)) return 1
    var factor = mainMm / screenMm
    return factor > 0.25 && factor < 4 ? factor : 1
  }

  // The middle of the edge a screen shares with the main screen, in the
  // screen's own coordinates. Panels are scaled about it, so the scene keeps
  // meeting at that seam however much a panel grows or shrinks.
  function seamAnchor(screen) {
    var main = mainScreen
    if (!main || !screen) return { x: 0, y: 0 }
    var ax = Math.max(0, Math.min(screen.width, main.x + main.width / 2 - screen.x))
    var top = Math.max(screen.y, main.y)
    var bottom = Math.min(screen.y + screen.height, main.y + main.height)
    var ay = bottom > top ? (top + bottom) / 2 - screen.y
                          : Math.max(0, Math.min(screen.height, main.y + main.height / 2 - screen.y))
    return { x: ax, y: ay }
  }

  // The centre of the main screen, in global coordinates: the scene is sized
  // about it.
  function sceneAnchor() {
    var main = mainScreen
    return main ? { x: main.x + main.width / 2, y: main.y + main.height / 2 } : { x: 0, y: 0 }
  }

  // The point a screen's own size setting pivots on, in global coordinates:
  // the seam for a placed panel, the screen's centre for anything else.
  function screenAnchor(name) {
    for (var i = 0; i < Quickshell.screens.length; i++) {
      var screen = Quickshell.screens[i]
      if (screen.name !== name) continue
      var view = screenView(name)
      var local = view && view.aligned ? seamAnchor(screen) : { x: screen.width / 2, y: screen.height / 2 }
      return { x: screen.x + local.x, y: screen.y + local.y }
    }
    return { x: 0, y: 0 }
  }

  // What a screen shows now, for the editor.
  function screenView(name) {
    for (var panel of backgrounds.instances) {
      if (panel.modelData.name === name) return panel.baseView
    }
    return null
  }

  function openEditor() {
    if (root.shell && typeof root.shell.toggle === "function" && root.shell.toggle(pluginId, "{}")) return
    Util.execArgv(["omarchy-shell", "shell", "toggle", pluginId, "{}"])
  }

  // Each screen's role, by output name.
  readonly property var screenRoles: {
    var screens = []
    for (var i = 0; i < Quickshell.screens.length; i++) screens.push(Quickshell.screens[i])
    var roles = ({})
    if (screens.length === 0) return roles
    screens.sort(function(a, b) { return a.x - b.x || a.y - b.y })

    var main = -1
    for (var c = 0; c < screens.length && main < 0; c++) {
      if (configuredRole(screens[c].name) === "main") main = c
    }
    if (main < 0) {
      var middle = (screens.length - 1) / 2
      var most = -1
      for (var j = 0; j < screens.length; j++) {
        var s = screens[j]
        if (configuredRole(s.name)) continue
        var pixels = s.width * s.height * s.devicePixelRatio * s.devicePixelRatio
        if (pixels > most || (pixels === most && Math.abs(j - middle) < Math.abs(main - middle))) {
          most = pixels
          main = j
        }
      }
    }
    if (main < 0) main = 0
    roles[screens[main].name] = "main"

    var taken = ({ main: true })
    for (var k = 0; k < screens.length; k++) {
      if (k === main) continue
      var role = configuredRole(screens[k].name)
      if (role === "main") role = "wallpaper"
      if (role) {
        roles[screens[k].name] = role
        taken[role] = true
      }
    }
    // The screens directly beside the main one, unless the user said otherwise.
    if (!taken.left && main > 0 && !roles[screens[main - 1].name]) roles[screens[main - 1].name] = "left"
    if (!taken.right && main < screens.length - 1 && !roles[screens[main + 1].name]) roles[screens[main + 1].name] = "right"
    for (var r = 0; r < screens.length; r++) {
      if (!roles[screens[r].name]) roles[screens[r].name] = "wallpaper"
    }
    return roles
  }

  readonly property var mainScreen: {
    for (var i = 0; i < Quickshell.screens.length; i++) {
      if (screenRoles[Quickshell.screens[i].name] === "main") return Quickshell.screens[i]
    }
    return null
  }

  function spanSource(path) {
    return spanSources[path] || path
  }

  // Panel layouts, by wallpaper. A layout gives the wallpaper's size and each
  // panel's rectangle in the same units, relative to the wallpaper's top left:
  //   { "wallpaper": { "w": 1920, "h": 1080 },
  //     "left":  { "x": -1080, "y": -480, "w": 1080, "h": 1920 },
  //     "right": { "x": 1920,  "y": 70,   "w": 1920, "h": 1080 } }
  // undefined while it is being read, null when there is none.
  property var layouts: ({})
  property var layoutQueue: []

  function layoutKey(path) {
    var real = spanSource(path)
    if (!real || isVideo(real) || real.indexOf(transitionCache) === 0) return ""
    return real
  }

  function layoutFor(path) {
    var key = layoutKey(path)
    return key ? layouts[key] : null
  }

  function requestLayout(path) {
    var key = layoutKey(path)
    if (!key || layouts[key] !== undefined || layoutQueue.indexOf(key) !== -1) return
    layoutQueue = layoutQueue.concat([key])
    probeNextLayout()
  }

  function probeNextLayout() {
    if (layoutProbe.running || layoutQueue.length === 0) return
    var key = layoutQueue[0]
    var slash = key.lastIndexOf("/")
    var folder = key.substring(0, slash)
    var file = key.substring(slash + 1)
    var dot = file.lastIndexOf(".")
    var stem = dot > 0 ? file.substring(0, dot) : file
    layoutProbe.key = key
    layoutProbe.command = ["bash", "-c", 'cat -- "$1" 2>/dev/null || cat -- "$2" 2>/dev/null || true', "layout",
                           folder + "/spans/" + stem + "/layout.json", folder + "/spans/layout.json"]
    layoutProbe.running = true
  }

  function validRect(rect) {
    if (!rect || typeof rect !== "object") return null
    var x = Number(rect.x), y = Number(rect.y), w = Number(rect.w), h = Number(rect.h)
    if (!isFinite(x) || !isFinite(y) || !(w > 0) || !(h > 0)) return null
    return { x: x, y: y, w: w, h: h }
  }

  function validLayout(parsed) {
    if (!parsed || typeof parsed !== "object") return null
    var wall = parsed.wallpaper || {}
    var layout = {
      wallpaper: { w: Number(wall.w) > 0 ? Number(wall.w) : 1920, h: Number(wall.h) > 0 ? Number(wall.h) : 1080 },
      left: validRect(parsed.left),
      right: validRect(parsed.right)
    }
    return layout.left || layout.right ? layout : null
  }

  // The rectangle an image of the given native size covers on a w x h screen
  // when it is scaled to cover it, as Omarchy's wallpapers are.
  function coverRect(native, w, h) {
    var aspect = native && native.width > 0 && native.height > 0 ? native.width / native.height : w / h
    var rw = w, rh = h
    if (w / h > aspect) rh = w / aspect
    else rw = h * aspect
    return { x: (w - rw) / 2, y: (h - rh) / 2, w: rw, h: rh }
  }

  // A move and size setting as numbers: { scale, x, y }.
  function transformOf(settings) {
    var scale = Number(settings.scale)
    return { scale: scale > 0 ? scale : 1, x: Number(settings.x) || 0, y: Number(settings.y) || 0 }
  }

  // A rectangle sized about an anchor point and then moved.
  function transformed(rect, anchor, t) {
    return {
      x: anchor.x + (rect.x - anchor.x) * t.scale + t.x,
      y: anchor.y + (rect.y - anchor.y) * t.scale + t.y,
      w: rect.w * t.scale,
      h: rect.h * t.scale
    }
  }

  // Grows a rectangle about its centre until it covers the screen, so a
  // shift never shows an empty edge.
  function covering(rect, w, h) {
    var cx = rect.x + rect.w / 2
    var cy = rect.y + rect.h / 2
    var grow = Math.max(1, 2 * Math.max(cx, w - cx) / rect.w, 2 * Math.max(cy, h - cy) / rect.h)
    if (grow <= 1.0001) return rect
    return { x: cx - rect.w * grow / 2, y: cy - rect.h * grow / 2, w: rect.w * grow, h: rect.h * grow }
  }

  // The scene: the wallpaper's rectangle on the main screen, moved and sized
  // by the scene setting, in global logical pixels. The main screen's own
  // setting comes on top of it for that screen alone.
  function mainWallpaperRect(path) {
    var main = mainScreen
    var native = nativeSizes[path]
    if (!main || native === undefined) return null
    var cover = coverRect(native, main.width, main.height)
    return transformed({ x: main.x + cover.x, y: main.y + cover.y, w: cover.w, h: cover.h },
                       sceneAnchor(), transformOf(sceneConfig()))
  }

  // Where a panel lies on a screen, from its layout and the monitor layout.
  function placedPanel(path, layout, side, screen) {
    var panelRect = layout[side]
    var wall = mainWallpaperRect(path)
    if (!panelRect || !wall) return null
    var kx = wall.w / layout.wallpaper.w
    var ky = wall.h / layout.wallpaper.h
    return {
      x: wall.x + panelRect.x * kx - screen.x,
      y: wall.y + panelRect.y * ky - screen.y,
      w: panelRect.w * kx,
      h: panelRect.h * ky
    }
  }

  // The panel a wallpaper would have on one side, or "" for a video or a
  // transition snapshot that does not know its wallpaper yet.
  function spanPanelPath(path, side) {
    var real = spanSource(path)
    if (!real || isVideo(real) || (side !== "left" && side !== "right")) return ""
    if (real.indexOf(transitionCache) === 0) return ""
    var slash = real.lastIndexOf("/")
    var file = real.substring(slash + 1)
    var dot = file.lastIndexOf(".")
    if (slash < 0 || dot <= 0) return ""
    return real.substring(0, slash) + "/spans/" + file.substring(0, dot) + "/" + side + file.substring(dot)
  }

  // A panel that will not load falls back to the wallpaper.
  function spanPanelFailed(panelPath) {
    var known = Object.assign({}, nativeSizes)
    known[panelPath] = { width: 0, height: 0 }
    nativeSizes = known
  }

  function requestSizes(path) {
    requestNativeSize(path)
    requestNativeSize(spanPanelPath(path, "left"))
    requestNativeSize(spanPanelPath(path, "right"))
    requestLayout(path)
  }

  // A file replaced at the same path, as when a theme is updated or panels
  // are rebuilt, must not be served from Qt's image cache, which keys on the
  // URL. The URL therefore carries the file's modification time, read along
  // with its size.
  function fileStamp(path) {
    var native = nativeSizes[path]
    return native && native.stamp ? native.stamp : 0
  }

  function imageUrl(path) {
    var stamp = fileStamp(path)
    return Util.fileUrl(path) + (stamp ? "?v=" + stamp : "")
  }

  function refreshBackground() {
    if (!readlinkProc.running) readlinkProc.running = true
  }

  // The desktop must never be left without a wallpaper. A path that stops
  // loading, say one that ran through a theme since replaced, is resolved
  // again from the background link, which a theme switch always repoints.
  // Only a different path is taken, so a file that is there but unreadable
  // cannot loop. Resolving runs out of process, so a background chosen in the
  // meantime wins over what it finds; if that one fails too, it is resolved
  // in turn once the running lookup is done.
  property string failedBackground: ""
  property int recoverVersion: -1

  function recoverBackground(failedPath) {
    if (!failedPath || failedPath !== displayedBackground) return
    failedBackground = failedPath
    if (recoverProc.running) return
    recoverVersion = backgroundVersion
    recoverProc.running = true
  }

  function finishRecovery(path) {
    path = String(path || "").trim()
    var failedPath = failedBackground
    failedBackground = ""
    if (recoverVersion !== backgroundVersion) {
      recoverBackground(failedPath)
      return
    }
    if (!path || path === failedPath) return
    setBackground(path, true)
  }

  function setBackground(path, instant) {
    if (instant) reloadVersion += 1
    transitionBackground("", path, path, instant, instant)
  }

  function transitionBackground(fromPath, path, finalPath, instant, force) {
    path = String(path || "").trim()
    finalPath = String(finalPath || path).trim()
    fromPath = String(fromPath || "").trim()
    if (!path || (!force && finalPath === currentBackground)) return
    if (path !== preparedBackground) preparedBackground = ""
    preparedBackgroundTimer.stop()
    lastTransitionPath = path
    if (path !== finalPath) {
      var sources = Object.assign({}, spanSources)
      sources[path] = finalPath
      spanSources = sources
    }
    // The incoming frame gates the reveal, so its size is read first.
    requestSizes(path)
    requestSizes(fromPath || displayedBackground)
    requestSizes(finalPath)
    currentBackground = finalPath
    backgroundVersion += 1
    failedBackground = ""
    revealStartedVersion = -1

    // OWE draws a video background and fades the last still into it. That
    // still stays on screen until OWE has the first frame and suspends this
    // layer, so the desktop does not show an empty background meanwhile. A
    // running reveal finishes on its incoming still, which OWE fades from.
    if (!instant && !root.suspended && displayedBackground && isVideo(path) && !isVideo(displayedBackground)) return

    revealAnimation.stop()
    revealGraceTimer.stop()
    finishingTransition = false

    // Video frames are not fed through the image-only reveal stack. Switching
    // instantly also avoids decoding two full videos during a transition.
    if (instant || !displayedBackground || isVideo(path) || isVideo(displayedBackground)) {
      oldBackground = ""
      incomingBackground = ""
      preparedBackground = ""
      displayedBackground = finalPath
      revealProgress = 1
      return
    }

    oldBackground = fromPath || displayedBackground
    incomingBackground = path
    revealProgress = 0
  }

  function setPendingTheme(colorsB64, shellB64) {
    pendingColorsRaw = Util.decodeBase64(colorsB64)
    pendingShellRaw = Util.decodeBase64(shellB64)
    pendingThemeVersion = backgroundVersion
    pendingThemeFallbackTimer.restart()
  }

  function applyPendingTheme() {
    // Background polling can advance backgroundVersion while a theme switch is
    // pending; the latest theme payload should still apply.
    if (pendingThemeVersion < 0) return
    pendingThemeFallbackTimer.stop()
    Commons.Color.loadColors(pendingColorsRaw)
    // Commons.Color.loadShell also refreshes Style so the type scale flips with the
    // background reveal instead of waiting for a separate reload path.
    Commons.Color.loadShell(pendingShellRaw)
    Style.scheduleRefresh()
    pendingThemeVersion = -1
    pendingColorsRaw = ""
    pendingShellRaw = ""
  }

  function transitionBackgroundWithTheme(fromPath, path, finalPath, colorsB64, shellB64) {
    transitionBackground(fromPath, path, finalPath, false, true)
    setPendingTheme(colorsB64, shellB64)
    if (!incomingBackground || revealProgress >= 1) applyPendingTheme()
  }

  // Every screen slides together, so the reveal waits until each one has
  // decoded its incoming frame. A screen that cannot decode in time, or at
  // all, does not hold the others past a short grace; it joins the running
  // reveal once its frame is ready.
  function startReveal(panel) {
    if (!incomingBackground) return
    if (revealStartedVersion === backgroundVersion) {
      panel.maskReady = true
      return
    }
    for (var other of backgrounds.instances) {
      if (!other.incomingReady()) {
        revealGraceTimer.start()
        return
      }
    }
    beginReveal()
  }

  function beginReveal() {
    if (!incomingBackground || revealStartedVersion === backgroundVersion) return
    revealGraceTimer.stop()
    revealStartedVersion = backgroundVersion
    for (var panel of backgrounds.instances) {
      if (panel.incomingReady()) panel.maskReady = true
    }
    applyPendingTheme()
    revealAnimation.restart()
  }

  // The incoming frame stays over the base until the base has drawn the new
  // background on every screen. Ending it when the first screen is ready
  // left a larger screen, still decoding, black for a moment.
  function maybeFinishTransition() {
    if (!finishingTransition || !ready) return
    incomingBackground = ""
    oldBackground = ""
    preparedBackground = ""
    finishingTransition = false
    pruneNativeSizes()
  }

  onReadyChanged: maybeFinishTransition()

  function prepareBackground(path) {
    path = String(path || "").trim()
    // Only a still that is not already on screen is worth decoding ahead.
    if (!path || isVideo(path) || path === lastTransitionPath || path === displayedBackground) return
    requestSizes(path)
    preparedBackground = path
    preparedBackgroundTimer.restart()
  }

  function requestNativeSize(path) {
    if (!path || isVideo(path) || nativeSizes[path] !== undefined || sizeQueue.indexOf(path) !== -1) return
    sizeQueue = sizeQueue.concat([path])
    probeNextSize()
  }

  function probeNextSize() {
    if (sizeProbe.running || sizeQueue.length === 0) return
    sizeProbe.path = sizeQueue[0]
    sizeProbe.command = ["bash", "-c", 'magick identify -ping -format "%w %h" "$1" && stat -Lc " %Y" "$1"', "probe", sizeProbe.path]
    sizeProbe.running = true
  }

  // Each theme switch names fresh snapshot paths, so keep only the sizes of
  // the wallpapers still in play.
  function pruneNativeSizes() {
    var kept = {}
    var sources = {}
    var inPlay = [displayedBackground, incomingBackground, oldBackground, preparedBackground]
    var paths = []
    for (var i = 0; i < inPlay.length; i++) {
      if (!inPlay[i]) continue
      if (spanSources[inPlay[i]]) sources[inPlay[i]] = spanSources[inPlay[i]]
      paths.push(inPlay[i], spanPanelPath(inPlay[i], "left"), spanPanelPath(inPlay[i], "right"))
    }
    for (var j = 0; j < paths.length; j++) {
      if (paths[j] && nativeSizes[paths[j]] !== undefined) kept[paths[j]] = nativeSizes[paths[j]]
    }
    var keptLayouts = {}
    for (var k = 0; k < inPlay.length; k++) {
      var key = layoutKey(inPlay[k])
      if (key && layouts[key] !== undefined) keptLayouts[key] = layouts[key]
    }
    nativeSizes = kept
    layouts = keptLayouts
    spanSources = sources
  }

  function openSelector() {
    if (!bgSwitchProc.running) bgSwitchProc.running = true
  }

  function openThemeSwitcher() {
    var payload = JSON.stringify({ source: "themes" })

    // A cloned background may not summon the picker in-process, so it takes
    // the IPC route instead.
    if (!root.shell || !root.shell.summon("omarchy.image-picker", payload))
      Util.execArgv(["omarchy-shell", "shell", "summon", "omarchy.image-picker", payload])
  }

  // omarchy-theme-bg-set tells this service of the new background itself. A
  // refresh here would start an ordinary transition under an intro's cover.
  Process {
    id: bgSwitchProc
    command: ["bash", "-c", "background=$(omarchy-theme-bg-switcher); [[ -n $background ]] && omarchy-theme-bg-set \"$background\""]
  }

  Process {
    id: sizeProbe
    property string path: ""
    stdout: StdioCollector { id: sizeProbeOut }
    onExited: function(exitCode) {
      var parts = String(sizeProbeOut.text || "").trim().split(/\s+/)
      var width = exitCode === 0 ? parseInt(parts[0], 10) : 0
      var height = exitCode === 0 ? parseInt(parts[1], 10) : 0
      // Kept to nine digits so it fits the int version BackgroundMedia takes.
      var stamp = exitCode === 0 ? (parseInt(parts[2], 10) || 0) % 1000000000 : 0
      var known = Object.assign({}, root.nativeSizes)
      // An unreadable header records 0x0, which decodes at screen size.
      known[path] = { width: width > 0 ? width : 0, height: height > 0 ? height : 0, stamp: stamp }
      root.nativeSizes = known
      root.sizeQueue = root.sizeQueue.filter(function(queued) { return queued !== sizeProbe.path })
      root.probeNextSize()
    }
  }

  Process {
    id: layoutProbe
    property string key: ""
    stdout: StdioCollector { id: layoutProbeOut }
    onExited: function() {
      var parsed = null
      var text = String(layoutProbeOut.text || "").trim()
      if (text) {
        try {
          parsed = JSON.parse(text)
        } catch (e) {
          console.warn("multimonitor-background: layout for " + key + ": " + e)
        }
      }
      var known = Object.assign({}, root.layouts)
      known[key] = root.validLayout(parsed)
      root.layouts = known
      root.layoutQueue = root.layoutQueue.filter(function(queued) { return queued !== layoutProbe.key })
      root.probeNextLayout()
    }
  }

  Process {
    id: monitorProbe
    command: ["hyprctl", "monitors", "-j"]
    stdout: StdioCollector {
      onStreamFinished: root.loadMonitors(text)
    }
  }

  // Monitors come and go, and change size and scale; read their sizes again.
  Connections {
    target: Quickshell
    function onScreensChanged() { monitorRefresh.restart() }
  }

  Timer {
    id: repaintTimer
    interval: 300
    repeat: false
    onTriggered: root.suspended = false
  }

  Timer {
    id: monitorRefresh
    interval: 500
    repeat: false
    onTriggered: if (!monitorProbe.running) monitorProbe.running = true
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.loadConfig(text())
    onLoadFailed: root.loadConfig("")
  }

  Process {
    id: readlinkProc
    command: ["readlink", "-f", root.currentBackgroundLink]
    stdout: StdioCollector {
      onStreamFinished: root.setBackground(String(text || "").trim(), false)
    }
  }

  // The link's target when it exists, or else the theme's first background,
  // so a link left dangling still finds a wallpaper.
  Process {
    id: recoverProc
    command: [
      "bash", "-c",
      'target=$(readlink -f "$1"); if [[ -e $target ]]; then echo "$target"; else ' +
      'find "$2" -maxdepth 1 -type f \\( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.webp" \\) | sort | head -n 1; fi',
      "resolve", root.currentBackgroundLink, root.currentThemeBackgrounds
    ]
    stdout: StdioCollector {
      onStreamFinished: root.finishRecovery(text)
    }
  }

  ShellIpc {
    target: "background"

    function refresh(): void {
      root.refreshBackground()
    }

    function set(path: string): void {
      root.setBackground(path, false)
    }

    function setInstant(path: string): void {
      root.setBackground(path, true)
    }

    function setSuspended(value: string): void {
      root.suspended = value === "true"
    }

    function transition(fromPath: string, path: string): void {
      root.transitionBackground(fromPath, path, path, false, false)
    }

    function themeTransition(fromPath: string, path: string, finalPath: string, colorsB64: string, shellB64: string): void {
      root.transitionBackgroundWithTheme(fromPath, path, finalPath, colorsB64, shellB64)
    }

    function prepare(path: string): void {
      root.prepareBackground(path)
    }

    // omarchy-shell background spans: which file each screen shows, and how.
    function spans(): string {
      var lines = []
      for (var panel of backgrounds.instances) {
        var view = panel.baseView
        lines.push(panel.modelData.name + "\t" + panel.role + "\t" + (view ? view.file : "(waiting)")
                   + (view ? "\t" + view.how : ""))
      }
      return lines.join("\n")
    }

    // omarchy-shell background screens: every screen, its position and its settings.
    function screens(): string {
      var lines = ["settings: " + root.configPath + ", autoscale " + (root.autoscale ? "on" : "off")
                   + ", scene " + JSON.stringify(root.sceneConfig())]
      for (var i = 0; i < Quickshell.screens.length; i++) {
        var s = Quickshell.screens[i]
        var settings = root.screenConfig(s.name)
        var mm = root.mmPerPixel(s)
        lines.push(s.name + "\t" + root.screenRoles[s.name] + (root.configuredRole(s.name) ? " (set)" : " (auto)")
                   + "\t" + s.width + "x" + s.height + " at " + s.x + "," + s.y + " scale " + s.devicePixelRatio
                   + "\t" + (mm > 0 ? mm.toFixed(4) + " mm/px" : "size unknown")
                   + ", autoscale x" + root.autoScaleFor(s).toFixed(3)
                   + "\tsettings " + JSON.stringify(settings))
      }
      return lines.join("\n")
    }

    // omarchy-shell background setScene <x|y|scale> <value>: move or size the
    // whole scene; the value "auto" removes the setting.
    function setScene(key: string, value: string): string {
      if (["scale", "x", "y"].indexOf(key) === -1) return "unknown setting: " + key + " (scale, x or y)"
      var values = {}
      if (value === "auto" || value === "") {
        values[key] = undefined
      } else {
        var number = Number(value)
        if (!isFinite(number) || (key === "scale" && number <= 0)) return "not a number: " + value
        values[key] = number
      }
      root.saveScene(values, false)
      return "ok"
    }

    // omarchy-shell background setAutoscale <on|off>
    function setAutoscale(value: string): string {
      if (value !== "on" && value !== "off") return "use on or off"
      root.setAutoscale(value === "on")
      return "ok"
    }

    // omarchy-shell background repaint: hide every background window and
    // show it again with a fresh surface. A background layer has been seen
    // to stop showing its picture until the shell restarts; this brings it
    // back without the restart.
    function repaint(): string {
      root.suspended = true
      repaintTimer.restart()
      return "ok"
    }

    // omarchy-shell background editor: open or close the editor.
    function editor(): string {
      root.openEditor()
      return "ok"
    }

    // omarchy-shell background setScreen <output> <role|scale|x|y> <value>;
    // the value "auto" removes the setting.
    function setScreen(name: string, key: string, value: string): string {
      if (["role", "scale", "x", "y"].indexOf(key) === -1) return "unknown setting: " + key + " (role, scale, x or y)"
      var known = false
      for (var i = 0; i < Quickshell.screens.length; i++) known = known || Quickshell.screens[i].name === name
      if (!known) return "unknown screen: " + name + " (see omarchy-shell background screens)"
      if (value === "auto" || value === "") {
        root.saveScreenSetting(name, key, undefined)
        return "ok"
      }
      if (key === "role") {
        if (root.roleNames.indexOf(value) === -1) return "unknown role: " + value + " (main, left, right, wallpaper or auto)"
        root.saveScreenSetting(name, key, value)
        return "ok"
      }
      var number = Number(value)
      if (!isFinite(number) || (key === "scale" && number <= 0)) return "not a number: " + value
      root.saveScreenSetting(name, key, number)
      return "ok"
    }

    // omarchy-shell background resetScreens: back to automatic roles, no shifts.
    function resetScreens(): string {
      root.config = { screens: {} }
      configFile.setText(JSON.stringify(root.config, null, 2) + "\n")
      return "ok"
    }

    // omarchy-shell background spanState: the service's and every screen's state, for debugging.
    function spanState(): string {
      var lines = [
        "displayed=" + root.displayedBackground, "current=" + root.currentBackground,
        "incoming=" + root.incomingBackground, "old=" + root.oldBackground, "prepared=" + root.preparedBackground,
        "reveal=" + root.revealProgress + " finishing=" + root.finishingTransition + " ready=" + root.ready + " suspended=" + root.suspended,
        "sizes=" + JSON.stringify(root.nativeSizes), "layouts=" + JSON.stringify(root.layouts),
        "sources=" + JSON.stringify(root.spanSources), "config=" + JSON.stringify(root.config)
      ]
      for (var panel of backgrounds.instances) lines.push(panel.debugState())
      return lines.join("\n")
    }
  }

  // A prepared frame that no transition claims, say from a theme switch that
  // failed after naming it, must not hold its decoded texture indefinitely.
  Timer {
    id: preparedBackgroundTimer
    interval: 5000
    repeat: false
    onTriggered: root.preparedBackground = ""
  }

  Timer {
    id: revealGraceTimer
    interval: 250
    repeat: false
    onTriggered: root.beginReveal()
  }

  Timer {
    id: pendingThemeFallbackTimer
    interval: 300
    repeat: false
    onTriggered: root.applyPendingTheme()
  }

  NumberAnimation {
    id: revealAnimation
    target: root
    property: "revealProgress"
    from: 0
    to: 1
    duration: Style.duration(840)
    easing.type: Easing.OutCubic
    onFinished: {
      if (root.incomingBackground) {
        // After a video was chosen during the reveal, the incoming still
        // stays until OWE takes the background.
        root.displayedBackground = root.currentBackground && !root.isVideo(root.currentBackground)
          ? root.currentBackground : root.incomingBackground
        root.finishingTransition = true
      }
      root.revealProgress = 1
      // A base already holding the new background stays ready, so no
      // change of ready would end the transition.
      Qt.callLater(root.maybeFinishTransition)
    }
  }

  Component.onCompleted: {
    refreshBackground()
    monitorProbe.running = true
  }

  Variants {
    id: backgrounds
    model: Quickshell.screens

    PanelWindow {
      id: panel
      required property var modelData

      screen: modelData
      visible: !root.suspended
      anchors { top: true; bottom: true; left: true; right: true }

      color: "transparent"
      // Keep render updates enabled. The background layer has been observed to
      // lose its committed buffer while parked with updatesEnabled=false,
      // leaving a black desktop until omarchy-shell is restarted. A still
      // wallpaper costs nothing to keep enabled. OWE manages video layers.
      updatesEnabled: true

      property bool maskReady: false
      // main, left, right or wallpaper; see screenRoles.
      readonly property string role: root.screenRoles[modelData.name] || "main"

      // What this screen shows for a wallpaper: the file and where it lies on
      // the screen, in logical pixels. null until the sizes and layout it
      // depends on have been read, so nothing is ever decoded twice.
      function view(path) {
        if (!path || !sized) return null
        var file = path
        if (role === "left" || role === "right") {
          var panelPath = root.spanPanelPath(path, role)
          if (panelPath) {
            var panelSize = root.nativeSizes[panelPath]
            if (panelSize === undefined) return null
            if (panelSize.width > 0) file = panelPath
          }
        }
        var native = root.nativeSizes[file]
        if (native === undefined) return null
        // This screen's own move and size, on top of everything else.
        var own = root.transformOf(root.screenConfig(modelData.name))
        var center = { x: width / 2, y: height / 2 }
        var rect = null
        var how = "fill"
        var aligned = false
        if (role === "main" && file === path) {
          // The scene, then this screen's own setting about its centre.
          var scene = root.mainWallpaperRect(path)
          rect = root.transformed({ x: scene.x - modelData.x, y: scene.y - modelData.y, w: scene.w, h: scene.h }, center, own)
          how = "scene"
        } else if (file !== path) {
          var layout = root.layoutFor(path)
          if (layout === undefined) return null
          if (layout && layout[role]) {
            rect = root.placedPanel(path, layout, role, modelData)
            if (!rect && root.nativeSizes[path] === undefined) return null
            if (rect) {
              // Autoscale and this screen's own size both pivot on the seam.
              var seam = root.seamAnchor(modelData)
              var factor = root.autoScaleFor(modelData)
              rect = root.transformed(rect, seam, { scale: factor * own.scale, x: own.x, y: own.y })
              aligned = true
              how = "aligned" + (Math.abs(factor - 1) >= 0.001 ? " autoscale x" + factor.toFixed(3) : "")
            }
          }
        }
        if (!rect) rect = root.covering(root.transformed(root.coverRect(native, width, height), center, own), width, height)
        var covers = rect.x <= 0.5 && rect.y <= 0.5 && rect.x + rect.w >= width - 0.5 && rect.y + rect.h >= height - 0.5
        return { file: file, x: rect.x, y: rect.y, w: rect.w, h: rect.h, covers: covers, aligned: aligned,
                 how: how + " " + Math.round(rect.w) + "x" + Math.round(rect.h) + " at " + Math.round(rect.x) + "," + Math.round(rect.y)
                      + (covers ? "" : ", gaps filled") }
      }

      readonly property var baseView: view(root.displayedBackground)
      // While this screen shows a panel, the base already draws exactly what
      // is on screen, so it stands in for the old frame. The snapshot a
      // transition names is of the wallpaper, not of this screen's panel.
      readonly property bool oldOnBase: (role === "left" || role === "right") && !!baseView
        && baseView.file !== root.displayedBackground
      readonly property var oldView: oldOnBase || !root.oldBackground ? null : view(root.oldBackground)
      readonly property var incomingView: view(root.incomingBackground || root.preparedBackground)

      function debugState() {
        return modelData.name + " role=" + role + " oldOnBase=" + oldOnBase + " maskReady=" + maskReady
          + "\n  base " + (baseView ? baseView.file + " " + baseView.how : "(waiting)") + " decode=" + base.decodeSize
          + " ready=" + base.ready + " failed=" + base.failed + " readyFrames=" + readyFrames + " underlay=" + underlay.visible
          + "\n  old path=" + oldFrame.framePath + " status=" + oldFrame.status + " visible=" + oldFrame.visible
          + "\n  incoming path=" + incomingFrame.framePath + " status=" + incomingFrame.status + " layer=" + incomingLayer.visible
      }
      // A function, not a binding: onStatusChanged can run before a binding
      // on the same status has caught up.
      function incomingReady() {
        return root.incomingBackground !== "" && incomingFrame.status === Image.Ready
      }
      property int readyFrames: 0
      readonly property bool backgroundReady: base.ready && readyFrames >= 2

      FrameAnimation {
        running: base.ready && panel.readyFrames < 2
        onTriggered: panel.readyFrames += 1
      }

      // Decode the wallpaper at the size this screen can show, not the size
      // it was shipped at. With PreserveAspectCrop Qt takes sourceSize as the
      // area to cover, so this is the smallest decode that still fills the
      // screen. Stock wallpapers go up to 10456x3455 (144 MB as RGBA); a
      // 1080p laptop paid all of that for the 8 MB it can display, and paid
      // it up to three times over during a transition. The images wait for
      // the window's size and the wallpaper's native size so nothing is ever
      // decoded at native size first, and a wallpaper smaller than the screen
      // is decoded at its own size rather than scaled up to cover the screen.
      readonly property bool sized: width > 0 && height > 0

      // A view's image is decoded at the size it is drawn, in physical pixels,
      // rounded up to an eighth of the file's own size, so moving and
      // zooming the picture in the editor does not decode it again each time.
      function decodeSize(view) {
        if (!sized || !view) return Qt.size(0, 0)
        var native = root.nativeSizes[view.file]
        if (native === undefined) return Qt.size(0, 0)
        var w = Math.ceil(view.w * screen.devicePixelRatio)
        var h = Math.ceil(view.h * screen.devicePixelRatio)
        if (!(native.width > 0 && native.height > 0)) return Qt.size(w, h)
        var level = Math.min(1, Math.ceil(Math.max(w / native.width, h / native.height) * 8) / 8)
        return Qt.size(Math.round(native.width * level), Math.round(native.height * level))
      }

      function screenDecodeSize(view) {
        return decodeSize(view ? { file: view.file, w: width, h: height } : null)
      }

      function maybeStartReveal() {
        if (!incomingReady() || root.revealProgress >= 1 || maskReady) return
        Qt.callLater(function() {
          if (!incomingReady() || root.revealProgress >= 1 || maskReady) return
          root.startReveal(panel)
        })
      }

      WlrLayershell.namespace: "omarchy-background"
      WlrLayershell.layer: WlrLayer.Background
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore

      // OWE owns video backgrounds. This layer draws stills, and stays empty
      // behind a video so OWE's own layer shows through.
      // A placed panel that leaves part of its screen uncovered stands on a
      // blurred copy of itself filling the screen, never on black.
      BackgroundMedia {
        id: underlay
        anchors.fill: parent
        visible: !!panel.baseView && !panel.baseView.covers
        path: visible ? panel.baseView.file : ""
        version: root.reloadVersion + root.fileStamp(path)
        cached: true
        constrainDecode: true
        decodeSize: panel.screenDecodeSize(panel.baseView)
        layer.enabled: visible
        layer.effect: MultiEffect {
          blurEnabled: true
          blur: 1.0
          blurMax: 48
          brightness: -0.15
        }
      }

      BackgroundMedia {
        id: base
        x: panel.baseView ? panel.baseView.x : 0
        y: panel.baseView ? panel.baseView.y : 0
        width: panel.baseView ? panel.baseView.w : panel.width
        height: panel.baseView ? panel.baseView.h : panel.height
        path: panel.baseView ? panel.baseView.file : ""
        version: root.reloadVersion + root.fileStamp(path)
        cached: true
        constrainDecode: true
        decodeSize: panel.decodeSize(panel.baseView)
        onFailedChanged: {
          if (!failed) return
          if (path !== root.displayedBackground) root.spanPanelFailed(path)
          else root.recoverBackground(path)
        }
        onReadyChanged: panel.readyFrames = 0
      }

      Image {
        id: oldFrame
        x: panel.oldView ? panel.oldView.x : 0
        y: panel.oldView ? panel.oldView.y : 0
        width: panel.oldView ? panel.oldView.w : panel.width
        height: panel.oldView ? panel.oldView.h : panel.height
        readonly property string framePath: panel.oldView ? panel.oldView.file : ""
        readonly property size decode: panel.decodeSize(panel.oldView)
        source: decode.width > 0 ? root.imageUrl(framePath) : ""
        sourceSize.width: decode.width
        sourceSize.height: decode.height
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: false
        smooth: true
        mipmap: true
        visible: root.oldBackground !== "" && !panel.oldOnBase && root.revealProgress < 1
        onStatusChanged: panel.maybeStartReveal()
      }

      Item {
        id: incomingLayer
        anchors.fill: parent
        visible: root.incomingBackground !== "" && incomingFrame.status === Image.Ready && (root.revealProgress >= 1 || panel.maskReady)
        // The mask stays on until the base takes over: turning the layer off
        // as the reveal ends redraws the frame unmasked mid-transition.
        layer.enabled: root.incomingBackground !== "" && panel.maskReady
        layer.smooth: true
        layer.effect: MultiEffect {
          maskEnabled: true
          maskSource: revealMask
          maskThresholdMin: 0.5
          maskSpreadAtMin: 0.02
        }

        Image {
          id: incomingFrame
          x: panel.incomingView ? panel.incomingView.x : 0
          y: panel.incomingView ? panel.incomingView.y : 0
          width: panel.incomingView ? panel.incomingView.w : panel.width
          height: panel.incomingView ? panel.incomingView.h : panel.height
          // The same URL and size as a prepared frame keeps its decoded
          // image, so a transition to it can reveal at once.
          readonly property string framePath: panel.incomingView ? panel.incomingView.file : ""
          readonly property size decode: panel.decodeSize(panel.incomingView)
          source: decode.width > 0 ? root.imageUrl(framePath) : ""
          sourceSize.width: decode.width
          sourceSize.height: decode.height
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          cache: false
          smooth: true
          mipmap: true
          onStatusChanged: panel.maybeStartReveal()
        }
      }

      Item {
        id: revealMask
        anchors.fill: parent
        visible: false
        layer.enabled: true

        readonly property real slant: -0.18
        readonly property real centerTop: width / 2 - slant * height / 2
        readonly property real centerBottom: width / 2 + slant * height / 2
        readonly property real reach: width / 2 + Math.abs(slant) * height / 2 + 4
        readonly property real spread: reach * root.revealProgress

        Shape {
          anchors.fill: parent
          antialiasing: true
          preferredRendererType: Shape.CurveRenderer
          ShapePath {
            fillColor: "white"
            strokeColor: "transparent"
            startX: revealMask.centerTop - revealMask.spread; startY: 0
            PathLine { x: revealMask.centerTop + revealMask.spread; y: 0 }
            PathLine { x: revealMask.centerBottom + revealMask.spread; y: revealMask.height }
            PathLine { x: revealMask.centerBottom - revealMask.spread; y: revealMask.height }
            PathLine { x: revealMask.centerTop - revealMask.spread; y: 0 }
          }
        }
      }

      Connections {
        target: root
        function onIncomingBackgroundChanged() {
          panel.maskReady = false
          panel.maybeStartReveal()
        }
      }

      DesktopClicks { service: root }
    }
  }

  // OWE's video layer takes no clicks, and this service's own layer is hidden
  // under it while a video plays. A clear layer above the video and below
  // every window keeps the desktop's double-clicks working meanwhile.
  Variants {
    model: Quickshell.screens

    PanelWindow {
      required property var modelData

      screen: modelData
      visible: root.suspended
      color: "transparent"
      anchors { top: true; bottom: true; left: true; right: true }
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "omarchy-background"
      WlrLayershell.layer: WlrLayer.Bottom
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      DesktopClicks { service: root }
    }
  }

  // Inline components do not see this file's ids, so each one is handed the service.
  component DesktopClicks: MouseArea {
    required property var service
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    onDoubleClicked: function(mouse) {
      if (mouse.button === Qt.RightButton) service.openThemeSwitcher()
      else if (mouse.button === Qt.LeftButton) service.openSelector()
      mouse.accepted = true
    }
    // A middle click on the desktop opens the multimonitor editor.
    onClicked: function(mouse) {
      if (mouse.button === Qt.MiddleButton) service.openEditor()
    }
  }
}
