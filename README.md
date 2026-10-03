<p align="center"><img src="docs/icon.png" width="128" alt="Foldera icon"></p>

<h1 align="center">Foldera</h1>

<p align="center">
A small file manager for the Mac that works like Windows Explorer.<br>
Native Swift and AppKit, no dependencies, about 2.3 MB.
</p>

> [!WARNING]
> **Experimental beta (0.2) — not sufficiently tested. Download and use at your own risk.**
>
> Foldera works with real files: it copies, moves, renames, replaces and
> deletes them, including permanent deletion. Bugs in these operations can
> damage files or cause irreversible data loss. It has not been tested
> enough to be considered safe for important or irreplaceable data.
>
> I use Foldera myself because I need its features together in one place.
> My own use covers only a small part of the situations other people may
> encounter. This is experimental software, and you are responsible for
> deciding whether to download and use it.
>
> Keep verified backups (for example, Time Machine), try it on copies of
> files first, and never rely on Undo as your only protection. Please
> report problems in [Issues](https://github.com/vladimirperovic/Foldera/issues).

![Details view with the Markdown preview](docs/details.png)

If you came to the Mac from Windows and miss Explorer, this is for you:
the address bar, the navigation pane, the Details list with Enter, F2 and
Backspace, tabs in the title bar, Cut and Paste, a Size column in KB. It
also has things Explorer never had: a picture viewer in the manner of
FastStone, zip/RAR/7z archives you walk into like folders, a disk usage
map, folder sync in the manner of FreeFileSync, and Markdown files shown
(and edited) in the details pane.

| | |
|---|---|
| ![Large icons with the size slider](docs/pictures.png) | ![Disk usage](docs/disk-usage.png) |

## Install

1. Download `Foldera-0.2.0-beta.dmg` from
   [Releases](https://github.com/vladimirperovic/Foldera/releases), open it,
   and drag **Foldera** onto **Applications**.
2. Open it. The beta is not notarized by Apple yet, so macOS refuses the
   first time: go to **System Settings › Privacy & Security**, scroll down,
   and click **Open Anyway** next to Foldera. Or, in Terminal:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Foldera.app
   ```

Needs macOS 14 (Sonoma) or later on an Apple silicon Mac. To build it
yourself, see [Building](#building).

## Layout

- **Address bar**: `This Mac › Macintosh HD › Users › you`. Click a part to
  go there. Click a `›` for a menu of the folders inside. Click the empty
  area (or ⌘L, F4, ⌥D) to type a path, including `\\server\share`; Tab
  completes folder names. A long path folds its start into `«`.
- **Command bar**: New ▾, Cut, Copy, Paste, Rename, Share, Delete, Sort ▾,
  View ▾, ⋯, and **Details** at the far right for the details pane.
- **Navigation pane**, in two sections:
  - **Quick access**: pinned folders and files, marked with a pin.
    Right-click → *Add to Quick access*, or drop a folder into the section.
    Drag to reorder.
  - **Locations**, as in Finder:
    - iCloud Drive and the drives cloud apps add (SeaDrive, OneDrive, Google
      Drive, Dropbox…);
    - home and This Mac with its drives;
    - AirDrop and Network (the file servers nearby);
    - Trash (drop files on it; right-click → Empty Trash).
  - Every folder unfolds into a tree.
- **Layouts**: **Details** (⌘1), **Large icons** with thumbnails (⌘2) and
  **Columns** (⌘3, as in Finder).
  - Details shows Name, Date modified, Type and Size (in KB, as Windows
    does), with folders first. A **Status** column appears for iCloud Drive
    items.
  - **Sort ▾** also offers Date created, Date accessed, File extension and
    Tags, as Windows does. Sorting by one of them adds its column;
    right-click the column headers to show or hide those columns.
  - Finder tags show as coloured dots after the name.
- **Details pane** (⇧⌘P or ⌥P, Alt+P in Windows) on the right:
  - a Quick Look preview of the selected file;
  - its type, size, dates, tags and iCloud state;
  - picture dimensions and camera, PDF page count, running time, and where
    a download came from;
  - for a folder, how many items it holds.
- **Status bar**: item count, selection and its size, and the layout switch.
- **Search** (top right): searches the folder and everything below it as
  you type. `*.pdf` works.
  - **Search options** (the button beside the box, ⌥⌘F): kind (pictures,
    videos, music, documents, archives, apps, folders), size, and date
    modified (today, this week…).
  - With an option set and the box empty, it lists everything that
    matches.
- **Tabs**, Windows 11 style, in the title bar:
  - each about 220 points (4–5 cm on a MacBook), with the + right after the
    last one; as more tabs open they shrink to icons, then scroll horizontally,
    keeping + visible. Compact tabs close with ⌘W, middle-click or their menu;
  - ⌘T opens one, ⌘W closes one (⇧⌘W closes the window), ⌃Tab switches;
  - middle-click a folder to open it in a background tab, and middle-click
    a tab to close it;
  - drag tabs to reorder them; right-click a tab for Duplicate, Move to New
    Window, and Close Others.

- **One pane or two**: the switch at the right of the command bar (▭ ◫,
  or ⌥⌘1 / ⌥⌘2) puts a second pane beside the tab on screen, as Total
  Commander has it. Each pane has its own tabs and folder tree; the second
  opens where it was last left. The pane at work has a
  coloured line along its top; click a pane or press Tab to change.
  - The **Sync** icon in the command bar and **Sync › Sync Folders…**
    (⌥⌘S) open a separate sync window with the two displayed folders.
    Each side lists its relative paths, sizes and dates, with planned actions
    between them. Browsing stays available while the Sync window is open.
  - **Copy to other pane** (⌥F5; F5 still refreshes) and **Move to other
    pane** (F6), also in the right-click menu.
  - **Swap panes** (⌘U), **Same folder in other pane**, **Compare panes**
    (selects, on each side, what the other lacks or has an older copy of)
    and **Sync panes…** (the two folders in Sync Folders), in the View menu.

When the window gets narrow, the file list gives way first, then the
details pane, then the navigation pane. Each keeps a usable width, and each
gets back the width you dragged it to once there is room again.

## Keys

| Windows habit | Here |
|---|---|
| Enter opens · Backspace goes back | same |
| Type the start of a name to select it, then Enter to open | same, in Details, Large icons and Columns |
| Jump to a folder or tab / search commands | ⌘P Quick Open · ⌥⌘P commands |
| Alt+← → ↑ | ⌥← ⌥→ ⌥↑ |
| F2 rename · F5 refresh · F3 search · F4 / Alt+D address | same |
| Delete → Recycle Bin · Shift+Delete → gone | fn+Delete → Trash · ⇧fn+Delete → gone (asks first) |
| Ctrl+Z / Ctrl+Y undo, redo | ⌘Z / ⇧⌘Z |
| Ctrl+X / C / V · Ctrl+Shift+C copy as path | ⌘X / C / V · ⇧⌘C |
| Ctrl+Shift+N new folder · Alt+Enter properties | ⇧⌘N · ⌥↩ (or ⌘I) |
| Alt+P preview pane | ⌥P or ⇧⌘P |
| — | Space: Quick Look · ⇧⌘. hidden files · ⌘K connect to server |
| Total Commander: Num+ / Num− / Num* | select by pattern (also ⌥⌘A) / deselect / invert |
| Total Commander: Ctrl+B · Ctrl+M · Tab | ⌃B files in all subfolders · ⌃M rename many (or F2 with several selected) · Tab other pane |

**Quick Open** (⌘P, Go menu) searches pinned folders, the last 50 successfully
visited folders, open tabs across all windows, and Foldera's commands. Type part
of a name, use ↑/↓, and press Enter to open the folder, switch tabs, or run the
command. Escape closes it. Choose **Folders & Tabs** or **Commands** to narrow
the results; ⌥⌘P starts with commands. Serbian search words such as `skriveni`,
`sinhronizacija`, and `kopiraj tekst` work too. Unavailable commands are dimmed.

**Copy text from image** appears when you right-click one image, including in
Foldera's picture viewer, and in the Edit menu. Text recognition runs locally
using macOS Vision, with a Cancel button. It copies recognized text to the
clipboard; an unreadable image or one without text leaves the clipboard alone.
For animated or multi-frame images it reads the first frame.

## Disk usage and folder sizes

- **Disk usage** (⌘4, View ▾, or right-click a folder → *Analyze disk usage*)
  draws the folder as a treemap, after tobi's
  [disktree](https://github.com/tobi/disktree):
  - every folder is a box sized by what it takes on disk, with the folders
    inside it drawn inside;
  - files are coloured by kind; small files are summed per folder;
  - click to select (the details pane and the status bar show its size and
    share), double-click to go in, right-click for the usual menu.
  - Moving something to the Trash takes it out of the picture right away.
  - F5 measures again.
- **Folder sizes** (View ▾): the Size column shows what each folder holds,
  measured in the background. Windows doesn't do this.
- Measuring runs in the background and is remembered for the session, so
  walking into a folder already measured is instant.
- **Picture size**: the slider at the bottom left. All the way left is the
  list (Details); move it right and the folder turns into pictures at once,
  bigger the further you go (48–256 points), keeping what you were looking
  at in sight. ⌘+ / ⌘− and ⌘ (or ⌃) with the scroll wheel do the same.

## Copying, moving, undo

- **Paste into the same folder** makes `name - Copy`.
- **Name clashes** ask Replace / Keep both / Skip / Stop. A replaced item
  goes to the Trash.
- **Folders with the same name are merged**, as in Windows. Clashing files
  inside are asked about one by one, or all at once.
- **Large copies** show a progress window with Cancel. A cancelled copy
  leaves no half-copied file behind, and a move deletes the original only
  once every byte has arrived. On APFS a copy is a clone and takes no
  space.
- **Dragging**: onto the same drive moves; onto another drive copies; ⌥
  always copies. Cut items show faded.
- **⌘Z undoes** copies, moves, renames, new items, zips and trips to the
  Trash, newest first. ⇧⌘Z redoes them. The history is shared by all
  windows and the viewer.

## Sync folders

The **Sync** toolbar icon, **Sync › Sync Folders…** (⌥⌘S), and
**File › Sync Folders…** open a separate window to keep two folders in step, as
[FreeFileSync](https://freefilesync.org) does. Right-click a folder →
*Sync with…*, or two selected folders → *Sync these folders…*, to start
from those. The clock button at the top right brings back pairs synced
before, with their settings. Choose or drop each folder at the top.
**Compare** and **Synchronize** sit above the folder paths; the dropdown
beside Synchronize chooses **Mirror**, **Update** or **Two way**.
The centre arrow reverses Mirror and Update without swapping the folders.
The table keeps both sides and their actions aligned while scrolling.

**Profiles and schedules**

- **Save Profile…** gives the current folder pair and settings a name. Pick
  it in the top-left dropdown or **Sync › Saved Profiles** to open it again.
  **Save Changes** updates the selected profile; choose *Current folders
  (unsaved)* to save another. The dropdown also offers rename and delete.
- **Schedule…** runs a saved profile every hour, daily at a chosen local time,
  or weekly on a chosen day. Save changed settings before editing a schedule.
  Choose **Off** to stop it. A paused schedule can be resumed by saving its
  schedule again, or by resolving the issue with a successful manual sync.
- Schedules use a user LaunchAgent and run even when Foldera is closed,
  while the user is logged in. The scheduler checks once a minute. After
  sleep or login it runs overdue profiles once, without replaying a backlog.
  Unavailable folders produce a history entry and are retried at the next
  scheduled time. Conflicts, unreadable items, large replacements/deletions,
  and permanent removals pause the schedule for manual review. Manual and
  scheduled runs cannot overlap.
- The preview filters show **Copy**, **Replace**, **Delete**, **Conflicts**
  or **Skipped** rows. They change the view only: Synchronize still uses the
  entire plan. The displayed count makes this explicit.
- **History…**, also under **Sync › Sync History…**, shows the 200 most recent
  manual and scheduled runs. Select a run for its folders, settings, times,
  copied/deleted items and errors. **Open Sync** opens those settings for
  review; **Refresh** picks up new background runs.
  A manual run that leaves unresolved conflicts is marked **Needs review**,
  with the conflict count and the actions that finished.

Profiles and full history are stored in
`~/Library/Application Support/Foldera/SyncLibrary`.
The background service is `com.vladimirperovic.foldera.sync`, registered
only when a schedule is enabled. No schedule is enabled by default.

- **Two way** (⇄): what changed on either side is copied to the other,
  deletions included. Foldera remembers what both sides held when they were
  last the same, which is how it tells a file deleted on one side from a
  file new on the other.
  - The first time there is nothing to remember: nothing is deleted, and
    of two different files the newer one wins.
  - A file changed on both sides is a conflict and stays as it is until you
    choose.
- **Mirror** (→|): the right folder becomes an exact copy of the left.
  Whatever is only on the right is deleted.
- **Update** (→): new and newer files go from the left to the right.
  Nothing is deleted, and a newer file on the right is kept.

**Compare** (Enter, ⌘R) lists what would happen; nothing changes until
**Synchronize**.
- **Exclude** names that should never sync, with `;` between them:
  `node_modules; *.tmp; .git`. A name matches whole, ignoring case; `*` and
  `?` are wildcards. What is excluded is left alone on both sides, and a
  folder holding any of it is never deleted or replaced as a whole. Each
  pair remembers its own list.
- Right-click rows to change them: copy either way, delete, or don't sync.
  Double-click one to see it in Foldera.
- A folder on one side only is a single row, with what it holds.
- Files are the same when size and date modified agree (to two seconds, as
  FAT drives keep dates), or, with *Compare content*, when every byte does.
  That reads every file of the same size on both sides, which takes a while
  for big folders.
- A symbolic link is the same as another when it points to the same place,
  whichever comparison; a link and a file are never the same.
  Two way remembers the link's destination, so changing it is detected even
  when the size and date stay the same. Older history without that destination
  shows a conflict until the two links are compared equal again.
- By date and size, a file edited without its size or date changing looks
  unchanged, as in FreeFileSync. *Compare content* remembers what the files
  held (a SHA-256 of each), so Two way sees such an edit too. Where it has
  nothing remembered by content yet, it shows a conflict rather than guess.

Replaced and deleted files go to the Trash, and ⌘Z undoes the whole sync.
Network drives often have no Trash; *Delete files permanently* syncs them,
asks first, and can't be undone.

What keeps it careful:
- Nothing inside a folder that couldn't be read is deleted or replaced, and
  a folder that can't be read at all stops the compare.
- Nothing is changed unless it is still as Compare found it: the same file
  on the disk, not touched since (its size, its date, and the time anything
  about it changed, which can't be set back). A folder to be deleted or
  replaced whole is read again first, to the bottom. A file to be deleted
  must still be missing on the other side. A replacement is looked at once
  more right before the old file goes.
- Nothing is read or written through a folder that has become a symbolic
  link since Compare, and a sync stops if another drive or folder now
  stands where one of the two was.
- A replacement is copied in beside the old file first, so a failed copy
  leaves the old one as it was.
- A sync that would delete everything on one side, however little, or
  replace and delete more than half of its files (and at least 10), asks
  first. An empty or unmounted drive looks like everything deleted.
- Names are compared ignoring case unless both drives tell case apart.
- `.DS_Store`, `._` files and a drive's own folders (`.Trashes`,
  `.Spotlight-V100`…) are never synced, also inside a folder copied whole.
  Symbolic links are copied as links.
- Quitting while a sync, copy or archive is still going asks first, stops
  it and lets it clean up. If stopping takes more than 30 seconds, quitting
  is cancelled so the unfinished work can finish safely.

The checks shrink the time in which another program's change could slip
through to the moment between the last look and the change itself, but
can't close it: don't sync folders that other programs are busy writing to.

What Two way remembers is kept in `~/Library/Application Support/Foldera/Sync`,
one file per pair, a few dozen bytes per item. Detection of moved files
is not supported yet.

## Archives: zip, RAR, 7z, tar

- **Open an archive like a folder** (Enter or double-click), as Windows does
  with a zip. It works for zip, RAR (4 and 5), 7z, tar, tar.gz, tar.bz2,
  tar.xz, cab and lzh.
  - Inside, you can browse, preview, Quick Look, open files, and copy or
    drag them out.
  - It is read-only: nothing can be added, renamed or deleted inside.
  - **Extract all** sits at the right of the command bar.
- **Extract All / Extract To…** from the right-click menu, for all of those
  formats.
  - Progress and Cancel, like copying.
  - An archive holding one folder does not unpack into `name/name`.
  - Entries containing `..` path components are left out. Leading `/`
    characters are removed from absolute paths, so those entries stay
    inside the target folder too. Extraction cannot write through a
    symbolic link to a location outside it.
- **Compress to ▸ ZIP / 7z / TAR.GZ**. Zips are plain, without `__MACOSX`,
  so they open cleanly on Windows.
- **Passwords**: a password-protected zip asks for its password. macOS's
  archive library can't decrypt encrypted RAR or 7z archives, and says so.
  Multi-part RARs (`.part1.rar`) and `.tar.zst` are not supported.

The archive support is the libarchive that macOS ships (the one behind
`/usr/bin/tar`), called directly. An opened archive is unpacked once into
`~/Library/Caches/Foldera/Archives`, which is emptied when Foldera
starts and quits.

## Tools from Total Commander

- **Select by pattern** (Num+, ⌥⌘A, Edit menu): `*.mp3`, `IMG_2026*`, or
  several at once, `*.jpg; *.png`. Num− takes matching names out of the
  selection, Num* inverts it.
- **Files in all subfolders** (⌃B, View menu): every file of the folder and
  the folders inside it in one list, with the folder each is in, as Total
  Commander's branch view. Esc goes back.
- **Rename many** (⌃M, or F2 with several selected): a pattern made of text
  and `[N]` name, `[E]` extension, `[C]` counter (start, step, digits),
  `[D]` date modified and `[P]` folder; find and replace (or a regular
  expression); lowercase, UPPERCASE or Title Case. Every new name shows
  before anything is renamed, and nothing is renamed while one would
  clash. Names can be swapped. ⌘Z undoes all of it.
- **Checksum** (right-click): copy the SHA-256, write a `.sha256` file in
  the format `shasum -a 256 -c` checks, or verify the files a `.sha256`
  file lists.
- **Compare files**: two selected files (or one in each pane), byte by
  byte; it says where they first differ.
- **Drives** in This Mac show a bar of how full they are, red past 90%.
- **Each folder remembers its layout** (Details, Large icons, Columns), as
  in Windows; a folder never set opens in the layout on screen.

## More

- **AirDrop** and **Share**, from the right-click menu.
- **Tags**: the right-click menu lists Finder's tags. Choosing one adds it,
  or removes it if every selected item already has it.
- **iCloud Drive**:
  - the Status column shows each item's state: cloud-only, downloaded,
    downloading or uploading;
  - *Download Now* keeps a copy on this Mac;
  - *Remove Download* frees the space and leaves the file in iCloud (Windows'
    "Free up space").
- **Connect to Server** (⌘K): `smb://nas.local/Photos`, a bare IP address or
  `\\server\share`. macOS asks for the password, and the share opens here.

## Markdown

Select a `.md` file and the details pane shows it rendered, GitHub-style:
tables, task lists, code and pictures. **Edit** switches to the text right
there; **Done** or ⌘S saves. The window button (or right-click → *Edit
Markdown*) opens an editor with the text and the rendered page side by
side, updated as you type.

HTML in a Markdown file is shown as text, never run, and scripts are off
in the view. The view can't read files on its own: Foldera hands it only the
pictures in the file's folder and up to two folders above it
(`../images/x.png` works; a picture elsewhere on the disk stays blank).

## Picture viewer

Enter or a double-click on a picture opens the viewer, with the folder's
other pictures one key away. It handles JPEG, PNG, WebP, HEIC, AVIF, JPEG XL,
GIF, TIFF, BMP, ICO, TGA, PSD, SVG and camera RAW (CR2, CR3, NEF, ARW,
DNG…). macOS decodes all of them itself.

| | |
|---|---|
| → ← · Space · wheel | next / previous |
| click | fit ↔ actual size at that spot; drag to pan |
| + − · 0 · 1 · pinch · ⌘/⌥ + wheel | zoom · fit · 100% |
| F or Enter · double-click | full screen |
| R · L | rotate (view only) |
| I | EXIF panel (camera, lens, exposure, GPS…) |
| S | slideshow |
| Delete | to the Trash (⌘Z brings it back), then the next picture |
| E | open in the default app (Preview, Photoshop…) |
| Esc | leave full screen / close |

The viewer decodes pictures at screen resolution and keeps the one before
and after ready. It loads the full resolution only when you zoom past the
screen's resolution.

Turn the viewer off under View › Open Pictures in Foldera's Viewer.
Foldera also appears under **Open With** for pictures in Finder.

## Open folders in Foldera instead of Finder

Foldera › *Open Folders in Foldera…* makes it the default for folders
opened from other apps, the Dock and `open .`. It also becomes the target
of "Show in Finder" in most apps. *Open Folders in Finder Again* undoes
this. Finder keeps running for the desktop.

## Building

Needs macOS 14 or later and the Swift 6 toolchain (the Command Line Tools
are enough).

```bash
./build.sh            # build/Foldera.app, ad-hoc signed for this Mac
./build.sh install    # …and copy it to /Applications
./build.sh dmg        # …and build/Foldera-0.2.0-beta.dmg, the disk image to hand out
./test.sh             # the tests (swift test, with a workaround for the CLT)
```

The regression tests use temporary files. Setting `FOLDERA_TEST_VOLUME`
to a mounted, disposable, case-sensitive volume also exercises case-sensitive
rename collisions and move/Undo/Redo across volumes. Passing these tests does
not replace testing with real workloads, network shares and other macOS versions.

If Finder automation is unavailable, `FOLDERA_DMG_LAYOUT=0 ./build.sh dmg`
creates the same installer without arranging its Finder window.

Protected folders (Desktop, Documents, Downloads) ask for permission the
first time. Every new build gets a new ad-hoc signature, so macOS asks
again after each rebuild. Full Disk Access for Foldera stops the prompts.

`Foldera --snapshot <folder|thismac|image> out.png [--icons|--columns|--usage] [--pane]
[--light|--dark] [--size WxH] [--tabs count] [--search text] [--select name] [--press keys]
[--iconsize points] [--act newfolder|cut|properties|quickopen|commands] [--query text]
[--press-delay seconds] [--wait seconds] [--capture properties|viewer|sheet]
[--two-panes other-folder]
[--right-tabs count]
[--sync other-folder [--mode twoWay|mirror|update] [--sync-left] [--sync-empty]]
[--sync-library folder] [--sync-profile UUID] [--sync-filter all|copies|replacements|deletions|conflicts|skipped]`
renders a window to a PNG. It is used during development to check the
interface without clicking (the screenshots above were made this way, of a
made-up folder). It leaves your settings as they were.

## License and credits

[MIT](LICENSE). The F on the icon is Cormorant Garamond by Christian
Thalmann (SIL Open Font License). Inspired by
[Search](https://github.com/driceroland/Search) by driceroland; the disk
usage map follows tobi's [disktree](https://github.com/tobi/disktree).
