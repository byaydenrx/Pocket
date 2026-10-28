# Changelog

All notable changes to Pocket are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/). Pocket started from Vorssaint 3.4.2;
its history is in UPSTREAM-CHANGELOG.md.

## [1.0.1] - 2026-10-28

### Summary
A leaner, tidier Pocket: fewer, better features, native Liquid Glass everywhere and a cleaner Settings window.

### Added
- Keep Awake and a timer as dropdowns in Quick Toggles; right-click the menu bar icon to keep awake with no time limit.
- Storage tab inside Clean & Optimize, Run All for upkeep tasks, and App Updates as its own panel tab.
- Wi-Fi details and ping in the Network tab and Monitor settings.
- Every keyboard shortcut can be removed.

### Changed
- All glass is the system's own Liquid Glass and follows your Liquid Glass setting.
- The volume mixer looks like FineTune's.
- Settings are regrouped: Pocket, Menu Bar, Windows & Dock, Mac, Maintenance and About.
- Downloads lives in the menu panel; aria2 runs only while you use it.
- The cleaner reports the space it actually freed, apart from what went to the Trash.

### Removed
- Many upstream tools that overlapped or were rarely used: window layouts, clipboard history, snippets, screenshots and recording, command bar, radial menu, Dynamic Island, mouse remapping, the uninstaller and more.

### Fixed
- The menu panel no longer stays open after you click away.
- Only one shelf opens at a time.
- Shortcuts that apps use (like ⌘C) can no longer be taken over.
- Rebuilding the Open With menu and Homebrew cleanup work on macOS 27.
- Dock previews no longer cover the Now Playing card on Music.

## [1.0.0] - 2026-10-28

### Summary
The first Pocket: one menu bar app for your Mac's everyday tools, every feature built in and idle until you switch it on.

### Added
- Menu Bar Timer with typed times, recent timers, alarm tones and a Pomodoro mode.
- Downloads: aria2 downloads, torrents and magnets right in the menu panel.
- Dock Now Playing: hover Music in the Dock for a card with controls; ⌘-drag to pin it.
- Reminders in the menu panel and, optionally, in the menu bar with a due count.
- Storage Analyzer: drives, folders and largest files, with Move to Trash.
- Clean & Optimize: the cleaner plus upkeep tasks (DNS, Quick Look, Open With, fonts, memory, Spotlight, Homebrew).
- Task Manager: your busiest apps with one-click quit; system processes are never listed.
- Menu Bar Manager: hide menu bar icons behind an arrow, with an always-hidden section.
- Window Pin keeps a live copy of any window on top; Focus mode dims everything else.
- Menu Bar Calendar with a month view, events and world clocks.
- Network Tools: addresses, Wi-Fi details, ping and a speed test.
- Screen Ruler and a pixel color picker.
- Display: resolutions with HiDPI, refresh rate, brightness, main display and mirroring.
- Shelf file tools that match the file type: images, video, audio and PDF.
- Any Settings page can be pinned to the menu panel as a tab; tabs and quick toggles can be renamed.
- More quick toggles: Sleep Now, Dock Auto-Hide, Clear Clipboard and Restart Finder.
- One Liquid Glass look everywhere, Clear or Tinted, with a darkness slider.
- Signed self-updates from GitHub releases.

### Changed
- Quit on close can be instant, with a delay slider.
- The keep-awake icon dims instead of changing color.
- Settings from Vorssaint are imported on first launch.
