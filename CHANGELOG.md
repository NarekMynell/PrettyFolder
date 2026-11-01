# Changelog

## 1.1.0

- One window for everything: the folder's picture, where it sits on the folder, the default look, and the few settings behind the gear. It replaces the Settings, folder look and welcome windows.
- Move and resize the picture's frame right on the folder: drag it to move it, and its handles to resize it. Double-click and drag to move the picture inside the frame, and pinch or scroll to zoom it, to pick the part that shows. Everything snaps to the folder's edges and middle, and the zoom to where the picture just fills or fits the frame; arrow keys nudge the frame and, with ⌥, the picture; ⌘+ and ⌘− zoom; ⇧ keeps the proportions, ⌥ resizes around the middle and ⌘ turns snapping off. The folder changes right away, and ⌘Z undoes.
- A picture made bigger than the folder is clipped to the folder's outline instead of covering the space around it.
- A picture across the back and the front of the folder takes on the folder's light and shade, so it shows the same depth as the folder.
- Pointing at a folder brings up buttons to choose a picture, remove it or open the window. They replace the button on the folder's tab.
- Drop a picture on the window to put it on the folder.
- Finder's right-click menu has a single item, **Folder Picture…**, which opens the window.
- Finder shows a folder's new picture or look right away, without flashing the plain folder in between. Before, it often kept showing the old picture.
- A new icon takes the old one's place in a single step. Before, the folder had no picture for a moment each time, and if Finder looked just then, after quick changes say, it could show a plain folder.
- Clicking in Finder right after a change, after **Done** say, no longer shows a plain folder while Finder is still loading the new picture.
- Changing a folder's picture no longer changes its modification date, so it doesn't jump around in windows sorted by date.
- VoiceOver can move and resize the picture's frame, and move and zoom the picture inside it.
- **Remove All Pictures** keeps the folders it can't reach right now, on a disk that isn't connected for example, and tells you which, so they can be done later. Before, it forgot them with their pictures still on.
- Folders inside apps and other packages are left alone, like the packages themselves.
- A folder list that couldn't be read keeps only the stored pictures it mentions, so the others are cleaned up as usual.
- Other apps can only open PrettyFolder's window for folders. They can no longer ask it to choose or remove pictures.
- Quitting waits for the last change to be written.
- Turning on the Finder menu from a copy that macOS runs from Downloads or a disk image asks you to move PrettyFolder to Applications first.

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
