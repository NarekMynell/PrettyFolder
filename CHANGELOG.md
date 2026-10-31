# Changelog

## 1.1.0

- One window for everything: the folder's picture, where it sits on the folder, the default look, and the few settings behind the gear. It replaces the Settings, folder look and welcome windows.
- Move and resize the picture right on the folder. It snaps to the folder's edges and middle; arrow keys nudge it, ⇧ keeps its proportions, ⌥ resizes around the middle and ⌘ turns snapping off. The folder changes right away, and ⌘Z undoes.
- A picture made bigger than the folder is clipped to the folder's outline instead of covering the space around it.
- Pointing at a folder brings up buttons to choose a picture, remove it or open the window. They replace the button on the folder's tab.
- Drop a picture on the window to put it on the folder.
- Finder's right-click menu has a single item, **Folder Picture…**, which opens the window.

## 1.0.1

- Fixed a crash when a picture dragged out of Photos, Safari or Mail was dropped on the **Set as Icon** badge.
- Folders on a disk that isn't connected, or moved to another disk, keep their picture and look. Folders that stay missing are forgotten after 90 days.
- If the folder list can't be read, it is set aside instead of being replaced, and no stored picture is deleted.
- When another app asks PrettyFolder to remove pictures, it asks you first.
- The badge no longer loses a drop when the pointer moves away right after letting go, or while it fades out.
- The tab button reacts to a click, so pressing on a folder's tab to drag the folder no longer opens the picker.
- The drop badge and tab button turn on even when macOS is slow to report the Accessibility permission.

## 1.0.0

First release.
