# DailyNote

A one-purpose iOS companion to Obsidian: launches straight into **today's daily
note** in your iCloud-synced vault — opening it if it exists, creating it from
your template if it doesn't. No vault indexing, no plugins, no animations.
Obsidian stays the source of truth; this app just reads and writes the same
markdown files.

- Vault: `Diary` (Obsidian iCloud container, picked once via the Files picker)
- Daily notes: `daily_notes/YYYY/MMMM/YYYY-MMM-DD-ddd.md` (e.g. `daily_notes/2026/July/2026-Jul-16-Thu.md`)
- Template: `daily_notes/0000.md`, `{{date:...}}` placeholders rendered exactly like Obsidian
- Zero entitlements, zero dependencies → works fully on a **free** Apple ID

## Install on your iPhone

1. On the iPhone: **Settings ▸ Privacy & Security ▸ Developer Mode** → on (reboots the phone). This only needs doing once.
2. Open `DailyNote.xcodeproj` in Xcode. Plug in the iPhone (first time: tap "Trust" on the phone).
3. Select the **DailyNote** scheme and your iPhone as the destination, press **Run** (⌘R). The scheme runs the **Release** build for full typing speed; switch the scheme's Run configuration back to Debug if you ever need breakpoints.
   - Signing is already set to your personal team (`4MDYDGTK35`). If Xcode complains, open the target's *Signing & Capabilities* tab and re-select your team.
4. First launch will be blocked: on the phone go to **Settings ▸ General ▸ VPN & Device Management**, trust your developer certificate, then launch again.
5. In the app, tap **Choose Vault Folder** → **Browse ▸ Obsidian ▸ Diary** → **Open**. That's the only setup; every future launch goes straight into today's note.

### Free vs paid Apple ID

- **Free**: the app's signature expires after **7 days** — it just stops launching. Plug the phone in and press Run in Xcode again (Window ▸ Devices ▸ "Connect via network" makes this cable-free). Your data and the vault grant survive re-signing.
- **Paid ($99/yr)**: signature lasts 1 year; no weekly ritual.

## Using it

- Launches with the keyboard up and the cursor at the end of the note (toggle in the gear menu) — type immediately.
- Markdown renders live in the editor (Obsidian-style): headings, **bold**, *italic*, ~~strikethrough~~, `code`, [[wikilinks]], links, #tags, lists/checkboxes, quotes, dimmed frontmatter. The underlying text is untouched — styling only.
- **Markup mode** (book toggle): renders the markdown in place — syntax concealed, aliases shown for `[[target|alias]]` links — while staying fully editable. The paragraph under the cursor reveals its raw markdown, like Obsidian's Live Preview. Concealment is display-only (null glyphs); the file bytes never change.
- **Instant open**: the last saved content of today's note is cached locally and shown the moment the app launches; the coordinated iCloud open reconciles in the background (your unsaved typing always wins; if both you and another device appended, the two are merged).
- **Reading mode**: the square book toggle renders the note like Obsidian's reading view — syntax hidden, real bullets/checkboxes, styled headings, tappable links, `[[target|alias]]` shows the alias. Read-only; toggle back to edit.
- **Smart lists**: Return continues `- ` / `* ` / `+ ` bullets, checkboxes (always unchecked), and numbered lists (auto-incremented); Return on an empty item removes the marker and exits the list. All auto-inserts go through the text-input system, so undo stays consistent.
- **Line timestamps**: the square clock toggle in the top bar stamps every new line with `-[HH:MM] ` as you press Return (24-hour). List continuation takes precedence on list lines; pastes are untouched. The setting persists across launches.
- **⤓ button** (bottom-right): jump to the end of the note for quick capture.
- Saves automatically ~1.5 s after you stop typing, and immediately when you leave the app.
- Edits made on other devices appear when you return to the app (as soon as iCloud has synced them). If both sides edited, the most recent save wins.
- Past midnight, returning to the app rolls over to the new day's note automatically.
- Gear menu: reload from disk, change vault folder.

## Behavior notes

- "Not found" vs "can't read" is handled strictly: offline with an undownloaded note shows an error + Retry — it will never overwrite a real note with a fresh template.
- If Obsidian created today's note but it hasn't synced down yet when DailyNote first opens, iCloud may briefly show a sync conflict for that one file; creation happens at most once per day and iCloud resolves it. In practice open Obsidian later and everything is merged by iCloud sync timing.
- If the template `daily_notes/0000.md` is unreadable, a built-in byte-identical copy is used and the top bar shows "built-in template".
- If saving fails (iCloud full etc.), a red "not saved" badge appears; the text is retried on your next keystroke/app switch and also stashed in app storage as a rescue copy.

## App Store submission

The `AppStore/` folder holds a complete review-ready package: listing metadata,
privacy policy text, reviewer test instructions, the 1024px icon, and a full
6.9-inch screenshot set. Start at `AppStore/SUBMISSION-CHECKLIST.md`.
Requires a paid Apple Developer membership.

## Development

Sources live in `DailyNote/` (filesystem-synchronized group — add a file to the
folder and Xcode picks it up). Pure-logic pieces (`MomentFormat`,
`VaultFileService`) are plain Foundation and can be tested from the Mac CLI:

```sh
swiftc -o /tmp/t DailyNote/MomentFormat.swift DailyNote/VaultFileService.swift <test-main.swift> && /tmp/t
```

Simulator build (note: keep derived data off iCloud-synced folders — building
with derived data inside `~/Documents` fails with a build-database disk I/O error):

```sh
xcodebuild -project DailyNote.xcodeproj -scheme DailyNote \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/dailynote-dd CODE_SIGNING_ALLOWED=NO build
```

Debug-only launch argument `--test-vault <path>` bypasses the folder picker and
uses a local folder as the vault (used for simulator smoke tests).
