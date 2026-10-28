# Adding a feature to Pocket

1. Add a case to `AppFeature` in `Core/FeatureCatalog.swift`, then run `Tools/typecheck.sh`. The compiler lists every exhaustive switch that needs the new case (group, symbol, enable keys, permissions, energy profile, aliases, hub title and description, Settings destination, `SettingsPage`).
2. Put the code in `Modules/<Name>/`: a service with `syncWithPreferences()` that starts and stops everything, plus a `<Name>Settings` view.
3. Wire it up in `FeatureRuntime`, `SettingsPageContent` (in `SettingsView.swift`) and `SettingsDirectory`. For a panel tab, add a `PanelSectionID` case.


## Glass and names

- Use `HUDBackdrop` for floating panels and `.panelGlassSurface()` for popovers, and call `PocketGlassChrome.clearSystemMaterial(of:)` after showing a popover, so the new surface matches the rest.
- Let users rename what you show: `PocketNames.title(id, fallback)` plus `PocketNames.promptRename`.
- A panel tab is a `PanelSectionID` case; any Settings page can also be pinned as a tab with no code (`PanelCustomTabs`).

## Keep it light

A feature that is off must cost nothing: start timers, taps, observers and processes in `syncWithPreferences()` only when the feature's switch is on, and sample only while the view that shows the data is on screen.

## See every page

`Pocket --snapshot <folder>` renders each menu panel tab and Settings page to PNGs (layout only; offscreen rendering cannot draw Liquid Glass) plus `structure.txt` with the sidebar and tab order. Quit the running Pocket first.
