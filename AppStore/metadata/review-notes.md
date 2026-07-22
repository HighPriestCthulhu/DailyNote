# Notes for App Review

DailyNote opens or creates "today's daily note" — a markdown file — inside a
folder the user picks. It is a fast companion for people who keep daily notes
in iCloud Drive (e.g. with the Obsidian app), but it works with any folder.

## How to test without any other app

1. Open Apple's **Files** app → On My iPhone → create a folder named `Diary`,
   and inside it a folder named `daily_notes`. (The app validates that the
   picked folder contains `daily_notes`.)
2. Launch DailyNote → tap **Choose Vault Folder** → navigate to and open the
   `Diary` folder you just created.
3. The app creates today's note (e.g. `daily_notes/2026/July/2026-Jul-21-Tue.md`)
   from a built-in template and opens it in the editor, keyboard up. Type to
   edit; the file autosaves.
4. Top-bar controls, left to right:
   - **Book toggle** — markup mode: renders the markdown in place (syntax
     hidden, headings/bold/links styled) while staying editable; the line
     under the cursor shows its raw markdown.
   - **Clock toggle** — line timestamps: each Return starts the new line with
     the current time, `-[HH:MM]`.
   - **Gear menu** — cursor preference, reload, change folder.
5. Markdown demo: type things like `## Heading`, `**bold**`, `- item`
   (press Return to see list continuation), `- [ ] task`.

## Privacy / permissions

- No network calls, no analytics, no accounts, no data collection.
- File access is only through the user-picked folder (security-scoped
  bookmark via `UIDocumentPickerViewController` / `fileImporter`).
- No special entitlements or background modes.

## Notes

- The app is deliberately minimal and animation-free; instant launch into
  today's note is the entire product.
- "Obsidian" is mentioned only descriptively (interoperability with markdown
  vaults); the app does not use Obsidian code or trademarks in UI/branding.
