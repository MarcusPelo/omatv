# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

OmaTV is a single-plugin repository: an Omarchy/Quickshell bar-widget plugin (`marcuspelo.omatv`) that searches TMDB for Movies, TV shows and People, shows the connected account's Favorites/Watchlist, and keeps a local viewing history. There is no build system, package manager, or test suite — the entire plugin is one QML file plus a manifest.

## Architecture

- **`Panel.qml`** (~3500 lines) is the whole plugin: bar chip, popup panel, state, and all networking. This single-file layout (as opposed to Omarchy's split `BarWidget.qml`/`Panel.qml`/`Model.js` convention) is a deliberate choice, not a shortcut — keep new features in this file unless it grows large enough to genuinely need splitting.
- **`manifest.json`** declares the plugin id (`marcuspelo.omatv`), entry point (`Panel.qml`), and the one user-facing setting (`language`).
- The file is organized into two passes of the same section names — first properties/state, then the functions/logic/UI that use them — marked by `// ---- <section>` comments: `credentials`, `account`, `navigation`, `search`, `movie`, `tv`, `person`, `formatting`, `networking`, `auth flow`, `account lists`, `toggles`, `history`, `selection`, `components`, `io`, `bar chip`, `panel`.
- **Networking**: all HTTP calls go through `curl` via `Quickshell.Io.Process`, never `XMLHttpRequest`. `startRequest(proc, path, extraQuery, method, body)` (in the `networking` section) builds every request as a `curl -K -` config file written to the process's **stdin** — this is how secrets (API key, session id) and POST bodies stay out of argv/URLs and out of `ps`/`/proc/<pid>/cmdline`. Never add a new call that passes a secret via a URL or command-line argument.
- **`Process.stdinEnabled`** must be declared `false` and set to `true` imperatively immediately before `.running = true`, then reset to `false` in `onStarted` right after `write()`. A declarative `stdinEnabled: true` never delivers EOF to the child process, so it hangs forever — this has caused a real, hard-to-diagnose bug (a session file that silently failed to be created). Every new `Process` that writes to stdin must follow this exact pattern.
- **TMDB error contract**: the only reliable failure signal across every endpoint (search, detail, auth, account, favorite, watchlist) is `data.success === false`. Do not treat the presence of `status_message` alone as an error — successful write endpoints (`POST /favorite`, `POST /watchlist`) return `{"status_code":1,"status_message":"Success."}` with no `success` field at all. Always route parsed responses through the existing `tmdbError(data)` helper.
- **Caching**: in-memory session caches (`movieCache`, `tvCache`, `personCache`, `knownForSeedCache`) key by id and avoid refetching within a session. Favorites/Watchlist are different: they are cached to disk at `~/.cache/omatv/account.json` and **only refreshed manually** (the Refresh button or the `r` shortcut) to stay clear of TMDB's rate limit — never add polling or auto-refresh for account lists. Heart/bookmark toggles on a Movie/TV screen are the one exception: each click sends a single request and patches the cached list in place, rolling back on failure.
- **Keyboard model**: the panel opens with `PanelKeyCatcher` focused (not the search field), so single-letter shortcuts work immediately; `/` moves focus into the search field. `PanelKeyCatcher` reserves `h`/`j`/`k`/`l`/`x` for list movement/delete before `onTextKey` ever fires, so shortcuts cannot use those letters (history is bound to `v`, not `h`, for this reason). `Escape` inside the search field only returns focus to the key catcher (`Keys.onEscapePressed` on the `TextField`); the actual back/close navigation lives solely in `PanelKeyCatcher.onCloseRequested`. Any screen change hands focus back to the key catcher via `onViewChanged`, so a stuck-focused search field can never silently disable every shortcut.
- **Selection/navigation**: `selectedIndex` + `activeList` (computed per `view`) drive `j`/`k`/arrow movement and `Enter`-to-open; `pushView`/`popView` maintain `navStack` so `Escape` walks back screen by screen. `onActiveListChanged` resets `selectedIndex` to `0` whenever the underlying list changes.
- **Secrets on disk**: `API_KEY`/`LANGUAGE` live in `~/.config/omatv/.env` (parsed by a `FileView`, re-chmod'd to `0600` on every load) — never inside the plugin repo directory. The TMDB session (`session_id`, `account_id`, `username`) lives in `~/.config/omatv/session.json`, written atomically at `0600` (via a temp file + `umask 077` + `mv`, never chmod'd after the fact — that window was a real, since-fixed vulnerability). Both paths are gitignored and must never be committed.

## Development loop

```bash
PLUGIN_DIR="$HOME/.config/omarchy/plugins/marcuspelo.omatv"

omarchy plugin validate "$PLUGIN_DIR"
qmllint -I /usr/share/omarchy/shell "$PLUGIN_DIR"/*.qml

omarchy plugin enable marcuspelo.omatv
omarchy-shell shell rescanPlugins     # picks up most edits
omarchy restart shell                  # use this instead if a logic-only edit doesn't visibly take effect

omarchy-shell marcuspelo.omatv open    # open the panel via IPC (real keyboard focus, unlike `shell summon ... '{}'`)
```

There is no automated test suite. Verify changes with `omarchy plugin validate` + `qmllint` (must both pass clean), then a live check: open the panel via the command above, drive it with `wtype` (keyboard-only; there is no `xdotool`/`ydotool` in this environment) or ask the user to click, and screenshot with `omarchy capture screenshot fullscreen save` + `magick <file> -crop WxH+X+Y` (get the widget's geometry first via `omarchy-shell shell debugBarGeometry`) to inspect the result.

When a live check needs the panel to land on a specific screen (e.g. a Person page) without keyboard/mouse simulation, a temporary code change (e.g. overriding a default in `onOpenedChanged`) is safer than blind `wtype` — always mark it `// TEMP-DEBUG`, `grep -n "TEMP-DEBUG"` before finishing, and remove it before committing.

## Security notes specific to this plugin

- Every new network call must go through `startRequest`'s stdin-config pattern (see Architecture above) — no exceptions for "just one query param."
- Any new file that persists a credential must be created at `0600` atomically (temp file + `umask 077` + `mv`), not written then `chmod`'d.
- `.env` and `session.json` must stay outside the plugin repo directory (`~/.config/omatv/`, not `~/.config/omarchy/plugins/marcuspelo.omatv/`) and stay in `.gitignore`.

## Git

- Remote: `git@github.com:MarcusPelo/omatv.git` (SSH — HTTPS push fails here, no credential helper), branch `main`.
- This plugin is listed on the Omarchy plugin marketplace (`HANCORE-linux/omarchy-plugin-marketplace`, submission issue #540 — #464 was closed and resubmitted 2026-08-17). Marketplace security-baseline validation is pinned to an exact commit SHA — after pushing a fix that a maintainer needs to re-verify, edit the submission issue body (not a comment) to re-trigger `validate-submission.yml`.
- Before submitting or updating the listing, run HANCORE's pinned `security-scan.md` pre-submission checklist and attach the results to the submission (see the `reference_security_scan_checklist` memory).
