<p align="center">
  <img src="docs/icon.png" width="96" alt="">
</p>

<h1 align="center">PrettyFolder</h1>

<p align="center">Put any picture on a folder icon on your Mac.</p>

<p align="center">
  <img src="docs/hero.gif" width="300" alt="The real app on a Mac desktop, a mountain lake at sunset. A picture of a smiling pink axolotl is dragged to a plain folder and dropped on the Set as Icon badge. Then one big folder wears everything in turn: headphones, fruit, a rocket, a tree frog, a robot that shrinks into a corner and grows past the edges, and oranges spinning to any angle.">
</p>

## Install

1. Download `PrettyFolder-<version>.zip` from the [latest release](https://github.com/NarekMynell/PrettyFolder/releases/latest), unzip it and move **PrettyFolder** to **Applications**.
2. Open it. PrettyFolder isn't notarized by Apple, so the first time macOS refuses to open it. Go to **System Settings › Privacy & Security**, scroll down and click **Open Anyway**. Or run this once in Terminal:

   ```sh
   xattr -dr com.apple.quarantine /Applications/PrettyFolder.app
   ```

3. In the window that opens, click **Turn On Finder Menu** and **Allow Accessibility**. PrettyFolder uses Accessibility only to see which folder is under the pointer.

PrettyFolder starts with your Mac and lives in the menu bar. Needs macOS 14 Sonoma or later.

## Give a folder a picture

<table>
<tr>
<td width="33%" valign="top"><img src="docs/drop.gif" width="100%" alt="A picture of a pink axolotl is dragged to a folder and dropped on the Set as Icon badge. The folder shows the axolotl."><br><b>Drop it</b><br>Drag a picture over a folder and drop it on <b>Set as Icon</b>. Dropping it on the folder itself works as always.</td>
<td width="33%" valign="top"><img src="docs/choose.gif" width="100%" alt="The pointer rests on a plain folder and buttons appear on it. The picture button opens a panel, a tree frog is picked, and the folder shows the frog."><br><b>Choose it</b><br>Point at a folder in Finder's icon view or on the Desktop. Buttons appear on top: the first one picks a picture.</td>
<td width="33%" valign="top"><img src="docs/remove.gif" width="100%" alt="The pointer rests on a folder with a leaf on it. The trash button takes the leaf off, and the plain folder is back."><br><b>Take it off</b><br>The trash button puts the standard folder back.</td>
</tr>
<tr>
<td valign="top"><img src="docs/open.gif" width="100%" alt="The third button on a folder opens the folder in PrettyFolder's window."><br><b>Open the window</b><br>The last button opens the folder in PrettyFolder's window, where everything below happens.</td>
<td valign="top"><img src="docs/menu.gif" width="100%" alt="A right-click on a folder opens Finder's menu. Folder Picture… opens PrettyFolder's window."><br><b>Or right-click</b><br>Finder's menu has one item from PrettyFolder, <b>Folder Picture…</b>, for one folder or several.</td>
<td valign="top"><img src="docs/clear.gif" width="100%" alt="A transparent rocket and a transparent logo are dropped on two folders. Only the rocket and the lightning bolt are left on them, the blue folder showing all around."><br><b>Logos and cut-outs</b><br>A transparent PNG or an SVG leaves the folder showing around it. SVGs stay sharp at every size.</td>
</tr>
</table>

## Put it just where you want

<table>
<tr>
<td width="33%" valign="top"><img src="docs/size.gif" width="100%" alt="Two fingers pinch the frame around a little robot until it is small, then the frame is dragged into the folder's corner."><br><b>Any size, anywhere</b><br>Pinch or scroll to change the size, and drag the frame anywhere on the folder.</td>
<td width="33%" valign="top"><img src="docs/shape.gif" width="100%" alt="The frame's handles are dragged, and its shape changes, sticking to the folder's lines."><br><b>Any shape</b><br>Drag the handles. Everything snaps to the folder's edges and middle. ⇧ keeps the proportions, ⌥ resizes around the middle, ⌘ turns snapping off.</td>
<td width="33%" valign="top"><img src="docs/zoom.gif" width="100%" alt="Two fingers pinch the frame around an aerial photo of a lagoon until it is four times the folder, then dragging the frame brings a palm island over the folder."><br><b>Zoom in</b><br>Make the frame up to eight times the folder, and drag it to choose the part that shows.</td>
</tr>
<tr>
<td valign="top"><img src="docs/cover.gif" width="100%" alt="Two fingers pinch the frame around a peony until the photo takes over the whole folder, tab and all."><br><b>The whole folder</b><br>Stretch the frame over the folder, and the picture covers it right up to its outline, in the folder's own light and shade.</td>
<td valign="top"><img src="docs/part.gif" width="100%" alt="The right mouse button slides a tall picture down inside its frame, to show the flamingo's head."><br><b>Choose the part</b><br>Drag with the right mouse button to move the picture inside its frame. Or hold Control, or double-click and drag.</td>
<td valign="top"><img src="docs/fit.gif" width="100%" alt="Fit shows the whole flamingo inside the frame, and Fill brings it back over the whole frame."><br><b>Fill or Fit</b><br><b>Fill</b> covers the whole frame. <b>Fit</b> shows the whole picture inside it.</td>
</tr>
<tr>
<td valign="top"><img src="docs/turn.gif" width="100%" alt="Dragging the dial under the folder turns a crooked sunset one way, then back until the horizon is straight."><br><b>Any angle</b><br>Drag the dial. It sticks to upright and to quarter turns; ⇧ turns in steps of 15°, and a double-click makes the picture upright.</td>
<td valign="top"><img src="docs/quarter.gif" width="100%" alt="The buttons beside the dial turn a sea turtle a quarter turn each way, then two fingers twist it to an angle."><br><b>Quarter turns and a twist</b><br>The buttons beside the dial turn a quarter turn, and so do ⌘L and ⌘R. Twist two fingers on the trackpad for any angle.</td>
<td valign="top"><img src="docs/keys.gif" width="100%" alt="Arrow keys move the frame, Command minus makes it smaller, and Command Z takes the last change back."><br><b>From the keyboard</b><br>Arrow keys nudge the frame, ⌥ and arrows nudge the picture, ⌘+ and ⌘− resize it, and ⌘Z undoes. <b>Done</b> closes the window.</td>
</tr>
</table>

## All your folders

<table>
<tr>
<td width="33%" valign="top"><img src="docs/several.gif" width="100%" alt="A picture is dropped on the window for three folders. All three get it, and a pinch changes all three."><br><b>Several at once</b><br>Select folders and right-click. Drop a picture on the window, and whatever you do there happens to all of them.</td>
<td width="33%" valign="top"><img src="docs/default.gif" width="100%" alt="The frame in the default look is made smaller and saved. A question asks about the folders using it, and all three folders change."><br><b>A default look</b><br><b>Default</b> is the look new pictures get. Saving it asks whether the folders using it should change too.</td>
<td width="33%" valign="top"><img src="docs/copies.gif" width="100%" alt="A folder is duplicated with the Option key. The copy has the same picture, and a pinch in the window changes the copy only."><br><b>Copies and moves</b><br>A copy keeps its picture and gets a look of its own. A folder moved or renamed stays known, on any disk.</td>
</tr>
<tr>
<td valign="top"><img src="docs/removeall.gif" width="100%" alt="The gear in the window opens the settings. Remove All Pictures asks first, then all three folders go back to plain."><br><b>Everything behind the gear</b><br>Open at login, the menu bar icon, the buttons on folders, <b>Redraw All Pictures</b> and <b>Remove All Pictures…</b>.</td>
<td colspan="2" valign="top"><img src="docs/depth.png" width="100%" alt="Eight folders covered completely by a photo: blood oranges and dragon fruit, a tree frog, the northern lights, oranges in their leaves, a sea turtle, a magenta peony, a pineapple and a beach from the air. Each keeps the folder's tab, light and shade."><br><b>Any picture macOS can open</b><br>JPEG, PNG, HEIC, WebP, GIF, TIFF, PSD, RAW, PDF, SVG and more.</td>
</tr>
</table>

## Uninstall

1. In PrettyFolder's window, click the gear, then **Remove All Pictures…** to get the standard folder icons back.
2. Click **Quit** and move PrettyFolder from Applications to the Trash.

## Build from source

Needs Xcode 26 or later.

```sh
git clone https://github.com/NarekMynell/PrettyFolder.git
cd PrettyFolder
make install
```

`make test` runs the tests, and `make readme-media` draws the pictures and animations in this README from the app's own views.

## License

[MIT](LICENSE)
