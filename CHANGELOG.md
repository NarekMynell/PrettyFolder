# Changelog

## 1.3.1

- Moving, resizing, pinching and turning a picture in the window are far smoother: a frame took up to 100 ms on the main thread, and now takes 5 to 25 ms.
- ⌘+, ⌘− and the arrow keys work as soon as the window opens, without clicking the folder first.
- Dragging a picture across an empty part of the Desktop no longer puts **Set as Icon** on a folder somewhere else.
- **Set as Icon** no longer fades when the pointer stops just beside it, no longer runs ahead of the pointer in list view, and no longer goes invisible when a new drag starts right after a drop.
- The buttons on a folder stay up, and work, when the folder is partly scrolled out of its window or Finder is busy, and come back right after the trash button without leaving the icon.
- Renaming a folder and making a new one of the old name no longer makes PrettyFolder forget the renamed one. Neither does a disk of the same name, two folders swapping names, or a folder whose permissions were changed.
- One ⌘Z never takes back two changes, and Undo no longer stays on with nothing to undo after closing the window. It keeps working after a folder is renamed in Finder, and no longer moves a folder to a new default look it was meant to be spared.
- Keys right after clicking the Fill or Fit already on are no longer lost.
- With several folders, the trash button or a dropped picture right after a change no longer gives an alert or leaves the new picture turned on some of them.
- A picture for several folders is no longer lost for the rest if the first one's picture changes while it is on its way.
- Folders out of reach when a new default look is saved get it once they can be reached.
- An icon shown over a folder while Finder loads its new one can no longer be left behind on the screen.
- Choosing Quit a second time while PrettyFolder is asking about the default look, or finishing a write, no longer quits on the spot.
- Folders inside an app can't be given a picture through a link to the app either.
- An SVG reached through a link stays sharp at every size.

## 1.3.0

- Turn the picture to any angle with the new dial below the folder: drag it sideways and the picture turns with it, a degree for every few points. It reads the angle as you go, sticks to upright and quarter turns, and ⇧ turns in steps of 15°. Scrolling on it or its arrow keys turn a degree at a time, and a double-click puts the picture upright. The buttons on either side of it turn a quarter turn left or right, and replace the rotate button.

## 1.2.0

- Turn the picture: twist two fingers on the trackpad, drag just outside a corner of its frame, click the new rotate button (⌥-click turns the other way), or press ⌘L or ⌘R. It sticks to upright and to quarter turns, and ⇧ turns it in steps of 15°. With **Fill** a turned picture still covers its whole frame; with **Fit** all of it stays inside.
- The frame can now be made up to eight times as big as the folder, to zoom into part of a picture: pinch, scroll or press ⌘+ well past the folder. A frame bigger than the folder always covers it, so moving it never leaves part of the folder bare. Pictures put on folders from now on are kept at twice the size, so they stay sharp zoomed in.
- Pinching or scrolling a frame that covers the folder zooms around the middle of the folder, so what you look at stays in view.
- The frame in the window is a thin line just outside the picture, with small handles, and shows only while the pointer is over the folder. While you move, resize or turn something, only a faint line is left, so nothing hides the picture's edges.
- A picture taken to the folder's edges now covers the folder right up to its outline at every icon size: no light rim of the folder around it, and no corners of the folder peeking out beside the picture's rounded ones. Folders that already have a picture are redrawn once after the update.
- Dragging the frame's edge up to the folder's top sticks to the folder's own edge instead of to a spot a hair below it, which left a sliver of the folder showing.

## 1.1.0

- One window for everything: the folder's picture, where it sits on the folder, the default look, and the few settings behind the gear. It replaces the Settings, folder look and welcome windows.
- Move and resize the picture's frame right on the folder: drag it to move it, its handles to resize it, and pinch or scroll to make it bigger or smaller, the picture with it. Drag with the right mouse button (or with Control, or double-click and drag) to move the picture inside the frame and pick the part that shows. Everything snaps to the folder's edges and middle; arrow keys nudge the frame and, with ⌥, the picture; ⌘+ and ⌘− make the frame bigger or smaller; ⇧ keeps the proportions, ⌥ resizes around the middle and ⌘ turns snapping off. The folder changes right away, and ⌘Z undoes.
- A picture made bigger than the folder is clipped to the folder's outline instead of covering the space around it.
- A picture across the back and the front of the folder takes on the folder's light and shade, so it shows the same depth as the folder.
- Pointing at a folder brings up buttons to choose a picture, remove it or open the window. They replace the button on the folder's tab.
- Drop a picture on the window to put it on the folder.
- Finder's right-click menu has a single item, **Folder Picture…**, which opens the window.
- Finder shows a folder's new picture or look right away, without flashing the plain folder in between. Before, it often kept showing the old picture.
- A new icon takes the old one's place in a single step. Before, the folder had no picture for a moment each time, and if Finder looked just then, after quick changes say, it could show a plain folder.
- Clicking in Finder right after a change, after **Done** say, no longer shows a plain folder while Finder is still loading the new picture.
- Changing a folder's picture no longer changes its modification date, so it doesn't jump around in windows sorted by date.
- VoiceOver can move and resize the picture's frame, and move the picture inside it.
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
