# Prompteur

A teleprompter for macOS that lives in a thin black band right under the
camera, so you read your script while looking into the lens.

- The band floats above every window, a browser in full screen included.
- It **never takes the keyboard** from the app you are showing: you keep
  typing, scrolling and clicking in your browser while you read.
- Each sentence comes with a cue, in blue, for what to show on screen while
  you say it.
- It stays **out of your screenshots and screen recordings** by default, and
  one shortcut puts it in the picture when you want to show it.

It is a single Swift file with no dependencies, and it asks for no
permission: no Accessibility, no Screen Recording.

## Requirements

- macOS 13 or later
- The Swift compiler, which comes with Xcode or its Command Line Tools
  (`xcode-select --install`)

## Build

```sh
sh build.sh
open build/Prompteur.app
```

This builds `build/Prompteur.app` with the demo script from
[`examples/demo.md`](examples/demo.md) built in. To build in a script of your
own instead:

```sh
sh build.sh path/to/script.md
```

Prompteur has no Dock icon and no window of its own. It shows the band and a
small speech-bubble icon in the menu bar.

## Shortcuts

All of them work whichever app is in front, without stealing its focus.

| Shortcut | Action |
|---|---|
| **⌥** (Option alone, tapped) | Next sentence |
| **⌥←** | Previous sentence |
| **⌥↓** / **⌥↑** | Next / previous section |
| **⌥V** | Show or hide the band in screenshots and recordings |
| **⌥Q** | Quit |
| Click on the band | Next sentence (the left quarter goes back) |
| Right-click on the band | The menu |

Past the last sentence of a section, moving on opens the next section.

Option on its own only counts when it is tapped alone: holding it, or using it
with another key or a click (⌥←, typing a special character, an ⌥-click),
does not move the script.

## Screenshots and screen recordings

By default the band is excluded from capture, so a screen recording shows
your screen without the script on top of it. To show the band, for example in
a demo of the tool itself, press **⌥V** or tick **Visible in Screenshots and
Recordings** in the menu bar menu. The band says which way it went, and the
menu bar icon fills in while it is visible. The setting is remembered between
launches.

Hiding relies on macOS's window sharing setting (`NSWindow.sharingType`).
macOS screenshots honour it, and so do the recording apps it has been used
with, but it is up to each capture tool: check once with yours before you
rely on it.

## Scripts

A script is a Markdown file. Every heading opens a section, and every row of
a table under it is one sentence: what you say, then what you show.

```markdown
## Intro · home page

| Say | Show |
|---|---|
| Hi, I'm going to show you our new dashboard. | Open the home page |
| Everything starts from this one button. | Point at "New project" |
| ! Don't forget to mention the free plan. | Pricing page |
```

- `Title · subtitle` in a heading: the subtitle is shown next to the title.
- The header row of each table and anything outside tables (notes,
  paragraphs) are ignored.
- The second column is optional.
- A sentence starting with `!` is shown in yellow, for a line you must not
  miss.

### Loading a script

- **From the menu bar icon**: *Open Script…* picks a `.md` or `.json` file.
  Prompteur remembers it and opens it again at the next launch. *Reload
  Script* (⌘R while the menu is open) reads it again after you edit it, and
  *Use Built-in Script* goes back to the one built into the app.
- **Built into the app**: `sh build.sh path/to/script.md`.
- **From the command line**, for one launch:

  ```sh
  build/Prompteur.app/Contents/MacOS/Prompteur --script path/to/script.md
  ```

### JSON

If you generate scripts from another tool, Prompteur also reads JSON:

```json
[
  {
    "title": "Intro",
    "subtitle": "home page",
    "lines": [
      { "say": "Hi, I'm going to show you our new dashboard.", "show": "Open the home page" },
      { "say": "Don't forget to mention the free plan.", "show": "Pricing page", "highlight": true }
    ]
  }
]
```

Only `lines` and each line's `say` are required.

## Command-line options

| Option | Effect |
|---|---|
| `--script FILE` | Read this script for this launch |
| `--section N`, `--line N` | Start at this section and sentence (from 1) |
| `--visible` | Visible in screenshots and recordings for this launch |
| `--snapshot FILE.png` | Draw the band into an image and quit, to check a layout |
| `--log` | Print each sentence as it is shown (`section\|line\|text`) |

`build.sh` reads two environment variables: `OUT`, where to put the app, and
`BUNDLE_ID`, its identifier (`local.prompteur` by default), under which its
settings are kept.

## How it works

- The band is an `NSPanel` that can never become the key window, at the
  screen saver level, on every Space and beside full-screen apps.
- The arrow, Q and V shortcuts are global hot keys registered through Carbon,
  which needs no permission.
- Option alone cannot be registered as a hot key, and listening to the
  keyboard would need the Accessibility permission, so Prompteur reads the
  state of the modifier keys sixty times a second instead.
- The band sits below the notch, where a full-screen app's pixels begin.

## License

[MIT](LICENSE)
