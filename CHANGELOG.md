# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- Game Settings on a library card resolves the game's program before deciding
  anything, scanning the bottle on demand when needed. It used to fall through
  to selecting the bottle whenever the bottle had not been opened that
  session, silently; the genuine fallback now says why it went there.

### Added
- Library cards are yours to arrange: rename a game, mark it a favourite, or
  hide it. Favourites sort first, hidden cards sit behind Show Hidden, and a
  rename follows the game rather than the file it happens to be.
- Game Settings in a card's right-click menu opens the game's own settings,
  the same form the bottle's Programs tab shows. A Steam game finds the
  executable that speaks for it; when nothing single does, the bottle opens
  instead.
- Games launch from Spotlight. Every visible library entry is indexed by name,
  and picking one starts it through the same whisky:// launching the url
  scheme uses. Renames and hides keep the index current.
- Why These Settings, on every program's settings page: the launch plan's
  notes and each environment variable the next launch will carry, labeled
  with the layer that set it and the reason that layer recorded.
- A crash while Whisky is in the background lands in Notification Center, and
  clicking it opens the diagnosis. Audio device alerts go there too when a
  game is frontmost, with a Settings toggle to turn them off entirely.
- Cmd-N creates a bottle again, and macOS Game Mode can engage for fullscreen
  games now that Whisky declares it.

### Changed
- Every way of starting a program goes through one launch door, so launcher
  fixes, the game database profile and your own overrides apply whether the
  click came from the library, a pin, the bottle's run panel, a file drop or
  the cli. Known games get their recommended profile on direct runs too, not
  only through Steam.
- The audio driver and latency preset actually reach the Wine registry,
  synced at launch when they changed. They were settings-file decoration
  before.
- Troubleshooting fixes do what their cards say. The four fixes that had no
  implementation are real or gone, winetricks installs run from the card and
  only confirm once the verb lands, the audio buffer fix speaks the app's own
  presets, and a flow referencing an unimplemented fix fails validation
  instead of shipping a dead Apply button.
- The troubleshooting wizard is translated. Every other language saw
  hardcoded English in the one surface built for someone whose game is
  broken.
- Audio troubleshooting opens the guided wizard directly in its audio flow
  instead of a separate wizard running a duplicate engine.
- The bottle's Configuration screen leads with graphics, audio and
  performance; the Wine plumbing follows, collapsed by default.
- An empty library teaches adding a game: an Add a Game button opens the same
  flow a Finder drop lands in, and the copy says drops work anywhere on the
  window.
- Whisky no longer claims system-wide ownership of .bat and .msi files. It
  stays the app for .exe.

### Fixed
- A pinned executable that lives inside a Steam game's install folder merges
  into the Steam card instead of showing the game twice; matching is by
  location, not by name, so "Game" can never claim "Game II".
- Crashes are classified when the session ends rather than seconds after
  launch, and the classifier reads the head of long logs, where loader errors
  actually appear.
- Settings that did nothing were wired or removed: the shader cache toggle
  controls the cache DXVK actually reads, a dxvk.conf in the bottle is picked
  up at launch, and the invented network tuning variables and the Sequoia
  compatibility toggle are gone, since the real fixes ship unconditionally.
- Recommended graphics backend uses the same DXMT gate as the picker, so it
  can no longer choose a backend the installed runtime cannot deliver.
- Diagnosis remediation cards have a working Apply everywhere they appear,
  and a fix that cannot be performed is recorded as failed rather than
  applied.

### Removed
- The standalone audio troubleshooting engine and wizard, folded into the
  guided troubleshooting wizard.
- The unimplemented install-dependency fix and the unreferenced flow fragment
  that carried it.
- A release script that assumed signing credentials the project does not
  have; releases ship through CI.

### Added
- Ways to launch without opening the window. Right-clicking Whisky in the Dock
  lists the pinned games. `whisky://launch?pin=Name` and
  `whisky://launch?steam=12345` start a game from Shortcuts, Raycast or a
  stream deck, with `&bottle=Name` to pick when two bottles match. Dropping an
  installer or exe from Finder anywhere on the window opens the run flow.

### Changed
- Whisky tells macOS it is a games app, so the Apps window and the App Store
  category file it under Games rather than Utilities.

### Fixed
- The crash banner's View Diagnosis button opens the diagnosis it announced
  instead of only dismissing the banner. The launcher section's View
  Diagnostics and the missing-dependency Install button had the same problem,
  posting notifications nothing observed; both now do what they say, and
  Troubleshoot finds the right bottle instead of asking every time.

### Removed
- ClickOnce support. Games do not arrive as `.appref-ms` deployments, so the
  detection pass, the badge, the context menu and the .NET auto-recommendation
  are gone. A prefix containing ClickOnce artifacts still scans cleanly.
- The Sparkle updater. It was linked and delegated but never constructed, with
  no feed to check. Updates ship through the Homebrew cask.

### Fixed
- A new bottle is usable the moment it finishes. The spinner beside its name kept
  running after creation had completed and only a relaunch cleared it.
- Library recency reflects launches started in Whisky rather than reading Steam's
  manifest dates, which carried over playtime from other machines or external sessions.
- Steam games still read "Never run" in 2026.8.8. Recording launches only fills
  in from the build that started doing it, so everything already installed had
  nothing to show. Steam has been writing a last-played time into each game's
  manifest all along, including for sessions started inside the client, so that
  is where the time comes from now and the history you already have shows up.
- A focused library card drew two rings, a rounded one following the card and a
  squarer one outside it.

### Fixed
- Steam games in the library always read "Never run", and the Steam entry took
  the credit for every launch. A Steam game starts by running the client with
  `-applaunch`, so the run log belonged to the client rather than to the game.
  Launches are recorded per game now, which also means "most recently played
  first" sorts the way it says it does.
- Refresh rebuilds the library. It reloaded only when the set of bottles changed,
  so a game installed in Steam or a program pinned in a bottle stayed invisible
  until the app was restarted, while the button spun as though something had
  happened.
- Starting something from the library shows that it is starting. A card carries a
  spinner from the click and a badge while the game is running, rather than
  twenty silent seconds while Wine brings a window up.
- Card text in light mode. The backdrop faded towards transparent, so the corner
  holding the name composited against the window and left white text on something
  close to white.
- The same Steam game installed in two bottles appeared as two cards sharing one
  identity, which had them swapping artwork.
- The warning badge on a bottle in the sidebar is a button. It means the prefix
  still has a wineserver running, and it now stops it instead of only saying so.

### Added
- The library sorts by recency, name or bottle, and a card has a menu: run it,
  stop it, show it in Finder, remove the pin. Cards take keyboard focus and start
  on return, so the play button is not mouse-only.
- Storefront clients are labelled as launchers and sit below the games, named for
  what they are rather than for their executable, so the Steam client stops
  appearing as `steam`.

### Changed
- The sidebar's search field is gone. The library has one, and two fields side by
  side searching different things is a choice nobody should have to make to find
  a game.
- Cards are narrower and the window is wider at its minimum, so two columns fit
  at the smallest size the window can take.
- Pins in the bottle screen start on a single click, the same as a library card.
- Scrolling the library no longer re-reads Steam's manifests or re-decodes every
  banner, both of which happened on each pass.

### Added
- The app opens onto a library rather than a sidebar of bottle names. Everything
  worth launching is there, most recently played first: programs you pinned, and
  Steam games parsed out of the bottle. Steam games show the banner Steam already
  cached inside the prefix, so the art arrives with nothing fetched, and anything
  without art gets a card coloured from the icon in its own executable. A bottle
  is one click away under Bottles, and is named on a card only when you have more
  than one.
- British English. Thirteen strings differ, and macOS picks it up from Language &
  Region without anything to set in the app.

### Fixed
- The audio settings showed their own key names, so the driver picker read
  `config.audio.driver.auto` instead of Automatic. Every string in the audio
  feature had translations for 22 languages and no English source value. 63 keys,
  plus 37 more across the console and program overrides that were never in the
  catalogue at all.
- Play Test Tone now plays a tone. The executable it runs has never been included
  in a build, so the button ran, emitted nothing, and then asked whether you heard
  it. The tone is also 600ms with fades now rather than a 100ms click, since a
  click is what a broken audio path sounds like.

### Changed
- The bottle action bar reads as one control group, with Run as the only
  prominent button rather than four that look equally important.

### Added
- Discord now sees what a bottle is running. Two switches per bottle, both off
  by default: Whisky can publish the program it launched as your activity, and
  games that publish their own rich presence can reach the Discord client
  through a relay for the named pipe they expect. Neither writes anything into
  a prefix, and the presence half needs a Discord application id supplied at
  build time.
- MetalFX can be enabled at all now. It is reachable only through the DLSS API,
  which means a game calling `NVSDK_NGX_D3D12_*` in `nvngx.dll`, and the
  payload's copy of that bridge was the one file deployment skipped, so
  `D3DM_ENABLE_METALFX` had nothing to hook in any bottle. It is on by default
  under D3DMetal, and only engages for a game that asks for DLSS with DLSS
  switched on in the game's own settings.
- Metal 4 command encoding for D3DMetal, on by default. D3DMetal checks the OS
  version before it reads the variable and only takes that path for D3D12
  devices, so it is inert rather than harmful on older systems and D3D11 games.

### Fixed
- DLL overrides now actually reach the prefix. The `.reg` file was written
  without a byte order mark, which is the only thing Wine uses to recognise a
  Unicode `.reg`, so the import matched no header and did nothing while exiting
  successfully, and it was applied with `regedit`, which has no silent switch.

### Changed
- In sync with upstream Whisky 3.6.1, so the bottle location checks, the
  resumable runtime downloads and the launcher DXVK resolution match what
  upstream ships. Preview's own capability probe, which reports the first thing
  a location cannot do that a prefix needs, is kept on top of it.

### Added
- Video in games that ask D3D12 to convert their decoded frames now plays
  correctly under D3DMetal. D3DMetal exposes no video device at all, so a
  game that decodes video itself and asks D3D12 to convert NV12 to RGB was
  getting nothing back and falling into a fallback path no Windows machine
  runs: S.T.A.L.K.E.R. Call of Pripyat Enhanced Edition drew its intro and
  menu backgrounds at half resolution with the colour flattened to an olive
  cast. Deploying the GPTK payload now also installs the video processor the
  runtime ships, and installs that already have the payload pick it up at
  launch without reimporting.

## [3.6.1] - 2026-08-13 (App)

### Changed
- With D3DMetal installed, the Recommended graphics backend now resolves
  launchers to DXVK, since their Chromium-based clients cannot render on
  D3DMetal, while the games they start still resolve to D3DMetal. Bottles
  without D3DMetal installed behave exactly as before (#188).
- Interrupted runtime downloads now resume where they left off and retry
  transient failures automatically instead of restarting the full archive
  from zero. Partial downloads survive quitting the app, the Retry button
  continues rather than starts over, and a completed archive left behind by
  an interrupted setup is verified and reused. The SHA-256 integrity check
  before install is unchanged (#174).
- Pressing Play on a Steam game no longer creates settings files for every
  executable near the game's install folder: only the program that actually
  launches is materialized, so Play is snappier for games that ship many
  helper executables and bottles stop accumulating unused settings plists
  (#181).
- Waiting for a cold Steam client no longer spawns a Wine tasklist process
  every two seconds: a host-side process check answers the common
  nothing-running-yet case, so cold starts stop competing with the client
  they are waiting for (#189).

### Added
- Creating a bottle on an external or network volume now checks the location
  up front, while the creation sheet is still open: if macOS is withholding
  Files and Folders access, the sheet says so and offers a direct route to
  the privacy settings instead of failing later with a cryptic prefix error.
  The default location is checked on submit too, and creation stays disabled
  until the location is usable (#190, #191).
- Community translations from Crowdin for the new interrupted-setup message,
  covering all 22 supported languages (#195).

### Fixed
- The external-volume checks above now actually engage on disk images and
  other removable volumes that macOS cannot place on a bus: those volumes
  answer nil rather than false to the internal-volume query, so both the
  consent check and the capacity fallback had classified them as internal
  and never ran (#193).
- Bottles on non-APFS removable drives are no longer refused as "full" when
  the drive has plenty of space: the capacity check now falls back to the
  standard figure on external volumes, where the purgeable-space service
  behind the preferred figure has no backing and reports zero (#192).
- DLL overrides now reach Wine through the prefix registry instead of the
  WINEDLLOVERRIDES environment variable: the bottle's set goes to the prefix
  default and the launched program's resolved set to its own AppDefaults
  entry (helper processes like steamwebhelper.exe included). A launcher's
  graphics backend no longer silently becomes every game's backend, and
  per-program backend overrides now take effect instead of being masked by
  the inherited variable (#184, #185).
- The DLL Overrides section now lists the managed overrides of the graphics
  backend actually in effect: a DXMT bottle shows the four entries it applies
  at launch instead of none, and a stale legacy DXVK flag no longer credits a
  D3DMetal bottle with overrides that are never applied (#186).
- Program override settings now resolve Recommended before reporting: the
  DXVK sub-controls appear for a program that resolves to DXVK, and the
  inherited summary names the backend that actually runs instead of reading
  "Recommended" (#187).
- A bottle no longer shows up twice in the bottle list and `whisky list`
  when the registry holds the same path in two URL forms (with and without
  a trailing slash). The registry now compares canonical paths everywhere
  entries are added, and a registry already carrying duplicates is healed
  on first load (#183).
- `whisky run` now passes options it doesn't recognize through to the
  program, so `whisky run MyBottle app.exe --disable-gpu` works without a
  bare `--` separator. A program option that shares a name with one of
  run's own options still goes after `--`, which the help text now
  explains (#183).
- The command line tool now uses consistent exit codes: 64 with a usage
  block only for malformed invocations, and 1 with a plain error on stderr
  for well-formed commands that fail (no such bottle, game not found). The
  convention is documented in `whisky --help`, and `run` and `launch` still
  pass through the launched program's own exit code (#182).
- Steam game routes are now forgotten when their bottle is deleted instead
  of lingering in the routing store; removing a bottle from the list while
  keeping its files preserves the routes so a re-imported bottle picks them
  back up (#180).
- Output from very short-lived Wine processes is no longer occasionally
  lost: a race between the pipe reader and the termination drain could
  finish the process stream before the final chunk was delivered, dropping
  it from logs and the in-app output view. This was also the cause of the
  long-standing intermittent CI failure in the process stream tests.

## [3.6.0] - 2026-08-04 (App)

### Added
- Settings gains a Game Porting Toolkit section: point it at your own
  download of Apple's evaluation environment (the disk image or a mounted
  volume) and the D3DMetal payload is validated and imported. Imported
  payloads are stored safely across engine updates and deploy automatically
  once an engine capable of running them is installed; the section states
  plainly whether the current engine can (#164).
- Bottles with Steam installed now show a games library: installed games are
  listed with their state (running, downloading, update stalled), and Play
  brings the client up quietly, starts the game, and applies its community
  configuration for that launch only instead of rewriting bottle settings.
  Per-program settings you have tuned yourself still win over the community
  profile (#161).
- The command line tool gains `whisky games` (list a bottle's installed
  Steam games) and `whisky launch <appid>` (launch one), both with `--json`
  output. Launches route through the same pipeline as the app's Play
  button, remember which bottle an App ID last launched from, and need no
  `--bottle` flag for games installed in one place (#169).
- Whisky is now fully translated in all 22 supported languages: Arabic,
  Chinese (Simplified and Traditional), Czech, Danish, Dutch, Finnish,
  French, German, Italian, Japanese, Korean, Polish, Portuguese (Brazil
  and Portugal), Romanian, Russian, Spanish, Swedish, Turkish, Ukrainian,
  and Vietnamese. Translations are managed on Crowdin, where corrections
  and improvements from native speakers are welcome (#177).

### Changed
- Program shortcuts now launch through the live pipeline instead of baking
  the environment in when the shortcut is created: a shortcut made today
  picks up tomorrow's graphics, GameDB, and override changes. Existing
  shortcuts keep working; recreate a shortcut to adopt the new behavior
  (#169).

### Fixed
- The sidebar's running-status check no longer writes a log file per probe:
  at one probe per minute per visible bottle, the old path accumulated
  ~1440 stray log files per idle bottle per day and rescanned the whole log
  folder each time, all on the main thread. The probe now asks wineserver
  directly, with no logging side effects (#153).
- A failed bottle move no longer corrupts the bottle's state. Previously the
  pin and blocklist paths were rewritten (and saved) to point at the new
  location before the move was attempted, and the bottle stayed marked busy
  until the app restarted; both are now rolled back when the move fails
  (#154).
- Bottle actions no longer re-enable mid-operation: a bottle that is
  exporting, duplicating, or moving keeps its busy state even when the
  bottle list reloads (previously any registry reload, such as creating a
  bottle or re-importing an orphan, dropped the guard and let conflicting
  actions run against files still being copied) (#155).
- Games installed in a Steam library are no longer mistaken for the Steam
  client: executables under `steamapps/common` stop inheriting the client's
  compatibility profile and get their own launcher detection instead (a
  Rockstar title bought on Steam now detects the Rockstar launcher).
  Launches from the program list and pins also run launcher detection now,
  matching every other launch path (#160).
- Two programs sharing a filename (the classic `Launch.exe` case) no longer
  share one settings file. Settings are now keyed by the program's location
  inside the bottle, existing settings migrate automatically, and the old
  files are kept so downgrading loses nothing (#162).

## [3.5.2] - 2026-07-30 (App)

### Added
- Bottles on disk that aren't in the library — created by an older version,
  left behind by a reset registry, or restored from a backup of the Bottles
  folder — are now detected at startup and offered for one-click re-import
  (Closes #145).

### Changed
- Engine archive extraction is now staged: the archive is unpacked and its
  symlinks audited in a temporary directory, and only content that passes
  every safety check is moved into place. A rejected archive leaves the
  existing installation completely untouched (Closes #147).

### Fixed
- The backend picker no longer offers D3DMetal when the installed engine
  doesn't include it, and bottles already configured for D3DMetal show a
  warning explaining the WineD3D fallback instead of games failing silently
  at launch (Closes #146).
- The "Recommended" graphics backend now resolves to one the installed
  runtime actually provides: DXMT when the runtime bundles it, otherwise
  DXVK, and D3DMetal only when its payload is present. Previously it always
  chose D3DMetal, which the runtime doesn't ship, so fresh bottles silently
  fell back to wined3d and DirectX 11 games failed to launch out of the box
  (Fixes #141).
- First-run engine setup no longer fails with "Archive contains unsafe path"
  on systems whose language formats dates day-first (e.g. UK or French
  locales). The archive safety check parsed tar's localized listing and
  wrongly rejected every entry; the listing now runs with a pinned locale so
  it reads the same everywhere (Fixes #139).
- An unreadable bottle registry no longer silently wipes the bottle list. On
  startup the corrupt file is moved aside (an alert says where) and, when the
  file is in the older paths-only fallback format, the bottle paths are
  recovered instead of being overwritten with an empty list (Refs #61).
- Bottle creation now fails loudly when the new bottle can't be saved to the
  registry: the save is verified on disk and the existing failure alert (with
  copyable diagnostics) fires. Previously the error case existed but was never
  raised, so the bottle silently vanished on the next launch (Refs #61).
- Creating a bottle while the Wine runtime (WhiskyWine) isn't installed now
  shows a clear "runtime missing" error with a Run Setup button instead of a
  low-level file-not-found failure (Refs #61).
- The Winetricks button now shows an error when the bundled winetricks
  resources can't be found, instead of silently doing nothing (Refs #134).

## [3.5.1] - 2026-07-24 (App)

### Fixed
- Installing bottle dependencies (VC++, .NET, DirectX, fonts) and the Winetricks
  verb browser now work out of the box. `winetricks` was expected inside the
  downloaded Wine runtime but was never shipped there, so dependency installs
  failed with a missing-file error and the verb list showed empty. `winetricks`
  (and its verb catalog) are now bundled in the app itself, so they work on a
  clean install with no extra setup (Closes #134).

## [3.5.0] - 2026-06-14 (App)

### Added
- Bottle configuration options now carry inline descriptions explaining what
  they do. The Wine section (Windows version, build, enhanced sync, DPI, Retina
  mode) and the DXVK section (DXVK, async, HUD) previously had no explanation;
  each now shows a one-line caption so you can make an informed choice without
  hunting through docs (Closes whisky-app/whisky#807).
- Optional menu-bar extra (**Settings → General → "Show Whisky in the menu
  bar"**, off by default). When enabled, a menu-bar item lets you launch a
  bottle's pinned programs, reopen Whisky, or quit without the main window
  focused — and Whisky keeps running after the window is closed, so it stays
  reachable from the menu bar and running Wine processes aren't terminated.
  When disabled, behaviour is unchanged (Closes whisky-app/whisky#571).

### Changed
- Scanning a bottle for installed programs now runs off the main thread —
  walking the `Program Files` trees and parsing each executable's metadata no
  longer blocks the UI, so opening or switching to a bottle with many installed
  programs no longer hitches. The programs list shows a progress indicator while
  the scan runs (Closes whisky-app/whisky#574).
- Update checks are now gentler: a scheduled background check that finds a new
  version no longer interrupts you with a focus-stealing dialog. Instead a Dock
  badge appears and the "Check for Updates" menu item reads "Install Update…",
  so you can apply it when ready. User-initiated checks and the install itself
  are unchanged (Closes whisky-app/whisky#765).

## [3.4.0] - 2026-06-13 (App)

### Added
- DXMT (Direct3D 11 → Metal) as a selectable per-bottle and per-program
  graphics backend, marked Experimental. Deployed per-bottle like DXVK
  (native DLLs in the prefix), so selecting it for one bottle never affects
  others. Requires the matching Wine runtime that bundles the DXMT backend
  (shipped alongside this release); the backend card explains how to update
  when it's unavailable. D3DMetal remains the recommended default.

### Fixed
- Per-program graphics overrides now reliably win over the bottle's
  setting: the override UI's legacy DXVK flag could silently re-enable or
  disable the wrong translation layer when an explicit backend was chosen
  for a program.
- Installing or updating the Wine runtime no longer erases the rest of
  Whisky's Application Support folder. Previously the installer wiped the
  whole folder instead of just the runtime, destroying unrelated app state —
  including the telemetry queue and anonymous ID, which is why a completed
  install could go missing from the opt-in funnel.
- A launch error for a Windows program opened from Finder is no longer
  silently swallowed — it now surfaces as an error notification instead of
  only being logged while the dialog closes.

### Changed
- Wine runtime updated to Libraries v3.1.1, which ships DXMT 0.80 as the
  native per-bottle backend (see Added). Wine 11.0 and DXVK 1.10.3 are
  unchanged from the previous runtime.

## [3.3.0] - 2026-06-11 (App)

### Added
- Optional, **opt-in** anonymous usage telemetry. A checkbox during first-run
  setup (off by default, changeable anytime in Settings → Privacy) enables five
  anonymous events covering the first-run funnel — runtime install
  started/succeeded/failed (with a coarse reason), first bottle created, first
  program launch attempted — so install failures in the field become visible.
  The first-program-launch event now fires from both the programs list and a
  program's detail view, so no real launch path is missed. Nothing is sent
  without explicit consent; no person profile is created, and no personal data,
  paths, or raw error text is ever included. The full event list, the SDK context
  that accompanies it, and the IP/GeoIP handling are documented in the README and
  SECURITY.md.

### Fixed
- The first-run telemetry opt-in is now always reachable: when the Wine runtime
  is missing, setup no longer skips straight past the welcome screen (the only
  place the consent checkbox lives) before you can make a choice.
- Bottle and per-program settings are now written atomically, so a crash
  mid-save can no longer leave a truncated settings file that wipes the
  configuration.
- Every persisted settings choice — graphics backend, performance and resolution
  presets, Windows version, launcher mode/type/locale and spoofed GPU vendor,
  audio driver/latency/output mode, clipboard and process-cleanup policies, and
  the per-program equivalents — now tolerates an unknown value written by a newer
  Whisky. A single unrecognized choice falls back to its default (per-program
  overrides fall back to inheriting the bottle's choice) instead of failing to
  load the entire bottle's settings.
- An unreadable settings file is no longer silently overwritten. When a bottle's
  `Metadata.plist` or a program's settings plist can't be decoded (corruption or
  an unexpected file version), the original is moved aside to a
  `.corrupt-<timestamp>` sibling before defaults are written, so the unreadable
  data is preserved for recovery rather than destroyed.
- Closed several crash vectors when opening a Windows executable with crafted or
  corrupt headers during icon extraction (also reached by the Finder thumbnail
  extension): overflow traps in resource-offset math, unbounded recursion on
  circular or pathologically deep resource directories, and header reads
  straddling the end of a truncated file. Resource offsets are now resolved with
  overflow-checked math, the directory walk is depth-capped, and short reads are
  rejected instead of loading past the buffer.
- Hardened icon and thumbnail extraction against crafted executables that could
  previously hang the parser or render garbage: resource directory entry counts
  are clamped to the file size, the whole resource walk shares a total-entry
  budget so fan-out can't amplify, and icon bitmap dimensions and palette lengths
  are validated before reading pixels. An executable with no usable icon now
  falls back to a generic system icon instead of showing a blank tile.
- The "Failed to Export Diagnostics Report" alert is now localizable instead of
  English-only, matching the rest of the launcher diagnostics UI.

## [3.2.0] - 2026-06-10 (App)

### Added
- The Wine runtime download is now verified against a published SHA-256 before
  installation. A corrupted or truncated download is caught and rejected with a
  clear error and a retry, instead of unpacking a broken runtime. Runtime
  metadata that predates the published checksum still installs unchanged.

### Fixed
- Bottle creation now validates the chosen location before doing any work: if
  the folder isn't writable or the disk is nearly full, you get a clear,
  actionable error up front instead of the bottle silently disappearing after a
  cryptic Wine failure. Builds on the bottle-creation diagnostics added for
  issue #61.
- Runtime installation failures now surface their cause. `install(from:)`
  propagates the underlying error (missing tarball, disk full, archive
  extraction failure) instead of swallowing it, so the setup screen shows the
  specific reason and the diagnostics report captures it.
- A half-installed Wine runtime is no longer mistaken for a working one. The
  install check now requires the `wine64` binary on disk, not just the version
  file, so a partial extraction or removal prompts a clean re-install instead of
  leaving every bottle to fail with cryptic Wine errors.
- Bottle-creation error messages are now localizable instead of English-only,
  so non-English users see translated text when creation fails.

### Documentation
- Landing page (`frankea.github.io/Whisky`) now shows app screenshots, adds an
  honest "Graphics backends" section (D3DMetal default, why DXVK is pinned at
  1.10.3 by design, and the Wine-wide anti-cheat limitation), and bumps the
  advertised version to 3.1.0.
- Replaced the dead "Game Support wiki" links (the wiki page bounced to the repo
  root) across the README, landing page, and issue templates with the bundled
  Game Configurations database.

## [3.1.0] - 2026-06-08 (App)

### Added
- **File → Migrate from the Original Whisky** discovers bottles created by the
  archived original app (`com.isaacmarovitz.Whisky`) and imports them in one
  step, with checkboxes to choose which. Bottles are referenced in place —
  nothing is moved or copied — so the import is non-destructive and the original
  app keeps working, replacing the previous manual export/import dance.
- Bottle creation now copies host fonts (Arial Unicode, Arial, Tahoma) into
  `drive_c/windows/Fonts` so Unity titles render fallback glyphs instead of
  empty boxes (Closes whisky-app/whisky#1050).
- File pickers for "Run" and "Pin Program" now accept `.msix`, `.appx`,
  `.appref-ms`, and `.url` files in addition to `.exe`/`.msi`/`.bat`. Steam
  desktop shortcuts (`.url`) launch correctly via Wine's `start` handler
  (Closes whisky-app/whisky#756, whisky-app/whisky#815, whisky-app/whisky#826).
- Winetricks verb browser is searchable: filter the verb table by name or
  description (Closes whisky-app/whisky#763).
- Wine inherits the host timezone (`TZ`) so games keying off date/time render
  correctly instead of treating the bottle as UTC
  (Closes whisky-app/whisky#1001).
- PE icon extraction returns a generic Windows-executable system icon when
  parsing fails, so program tiles and pins never render blank
  (Closes whisky-app/whisky#687).
- Display sleep / screen saver is now suppressed via an `IOPMAssertion` for
  as long as any Wine process is registered. Controllers don't generate user
  activity events on macOS, so without this, gaming with only a controller
  would still trigger the screen saver
  (Closes whisky-app/whisky#547).
- Bundled GameDB ships 29 new per-game entries with curated configs that
  GAME-02/GAME-03 surface as one-click recommendations:
  - Diablo IV, Skyrim Special Edition, Warhammer 40,000: Space Marine
    (Closes whisky-app/whisky#813, whisky-app/whisky#1125, whisky-app/whisky#1246).
  - AVX-off recipes for Granblue Fantasy: Relink, Turtle WoW
    (Closes whisky-app/whisky#508, whisky-app/whisky#805).
  - DXVK + runtime recipes for Age of Empires II DE, Bannerlord II,
    Warframe, Thunderstore Mod Manager, Animal Well, Supermarket Together,
    Talos Principle 2, Street Fighter 6, PS Plus PC App, Fields of Mistria,
    Horizon Forbidden West, Injustice 2, Monster Hunter Wilds, Trackmania
    2020, Trackmania Nations Forever, Team Fortress 2, Potion Craft,
    TMNT: Shredder's Revenge, Assetto Corsa, Futureport 82
    (Closes whisky-app/whisky#314, whisky-app/whisky#524, whisky-app/whisky#548,
    whisky-app/whisky#594, whisky-app/whisky#647, whisky-app/whisky#679,
    whisky-app/whisky#699, whisky-app/whisky#757, whisky-app/whisky#769,
    whisky-app/whisky#782, whisky-app/whisky#845, whisky-app/whisky#867,
    whisky-app/whisky#880, whisky-app/whisky#891, whisky-app/whisky#982,
    whisky-app/whisky#1026, whisky-app/whisky#1037, whisky-app/whisky#1105,
    whisky-app/whisky#1192, whisky-app/whisky#1236, whisky-app/whisky#1281,
    whisky-app/whisky#1350).
  - D3DMetal-preferred recipe for Among Us (DXVK shadow glitch)
    (Closes whisky-app/whisky#1123).
  - "Broken/unplayable" entries for Cities: Skylines II and Metal Gear Solid
    Master Collection Vol. 1 with diagnostic notes
    (Closes whisky-app/whisky#1032, whisky-app/whisky#1268).
  - Classic-DDraw recipe (wineD3D + WinXP) for Zuma Deluxe
    (Closes whisky-app/whisky#484).
- Input config gains "Map Command Key to Windows Ctrl" toggle (under
  Controller Compatibility Mode). Writes
  `HKCU\Software\Wine\Mac Driver\{Left,Right}CommandIsCtrl` so common
  Cmd+A/C/V/S keystrokes register inside Wine apps as Ctrl+A/C/V/S
  (Closes whisky-app/whisky#1060).
- Setup/Welcome view's "Uninstall" button now offers two options: remove the
  WhiskyWine runtime only (preserves bottles for later reinstall) or remove
  everything (runtime + default bottles directory + BottleData registry).
  Bottles at custom paths outside the default directory are preserved
  (Closes whisky-app/whisky#411).
- The bundled DXVK version is now tracked alongside the runtime version. The
  WhiskyWine version record carries an optional `dxvkVersion`, and the setup
  diagnostics report gained a `[VERSION]` section listing the installed runtime
  and DXVK versions to speed up triage of runtime-mismatch issues. The field is
  backward-compatible: runtime plists without it still load.

### Changed
- Diagnostic reports (WhiskyWine setup and Wine prefix) now link to this fork's issue tracker
  (`frankea/Whisky`) instead of the archived upstream, so reports reach a maintained repo. Internal
  Logger subsystems and notification names also moved off the archived `com.isaacmarovitz.Whisky`
  namespace onto `com.franke.Whisky`.
- Bundled GameDB grows by 4 more entries from the third-pass retriage:
  DJMAX RESPECT V (Korean fonts + DXVK), They Are Billions (vcrun + DXVK),
  SpellForce 3 (corefonts + d3dcompiler), Fallout 4 (Sequoia compat + xact)
  (Closes whisky-app/whisky#748, whisky-app/whisky#890,
  whisky-app/whisky#980, whisky-app/whisky#1312).
- Bundled GameDB gains 20 more entries from the fourth-pass retriage —
  full coverage of the long tail of mainstream titles in the upstream
  backlog: Jusant, Ready or Not, Persona 3 Reload, Binding of Isaac,
  Trackmania Turbo, It Takes Two, Tales of Berseria, Cobalt Core,
  Psychonauts 2, Assassin's Creed Odyssey, killer7, Train Sim World 5,
  Black Mesa, Far Cry 4, Severed Steel, Halo: Master Chief Collection,
  Mortal Kombat Komplete Edition, YS X: Nordics, Slime Rancher 2,
  Monster Hunter: World (Iceborne) (Closes whisky-app/whisky#279,
  whisky-app/whisky#631, whisky-app/whisky#694, whisky-app/whisky#727,
  whisky-app/whisky#829, whisky-app/whisky#1025, whisky-app/whisky#1108,
  whisky-app/whisky#1119, whisky-app/whisky#1124, whisky-app/whisky#1137,
  whisky-app/whisky#1157, whisky-app/whisky#1160, whisky-app/whisky#1162,
  whisky-app/whisky#1180, whisky-app/whisky#1190, whisky-app/whisky#1208,
  whisky-app/whisky#1214, whisky-app/whisky#1235, whisky-app/whisky#1258,
  whisky-app/whisky#1320). The bundled DB now covers 79 titles.
- Diagnostic system-info reports use sysctl-based hardware detection
  (`hw.optional.arm64`) instead of the `#if arch(arm64)` compile-time
  macro, so a universal binary running its x86_64 slice through Rosetta
  no longer misreports the host as Intel
  (Closes whisky-app/whisky#1097).
- Installed-programs list filters out known launcher helpers and crash
  reporters (steamerrorreporter, steamservice, steamwebhelper, GameOverlayUI,
  vc_redist, UEPrereqSetup, the CrossOver HTML engine helper, etc.) so the
  visible list stays clean by default while leaving the user blocklist for
  app-specific filtering
  (Closes whisky-app/whisky#432, whisky-app/whisky#1215).
- WhiskyWine download survives transient Wi-Fi/Ethernet/VPN disconnects via
  `waitsForConnectivity` and bounded request/resource timeouts so a stalled
  download surfaces an error instead of hanging forever
  (Closes whisky-app/whisky#293, whisky-app/whisky#995, whisky-app/whisky#1020, whisky-app/whisky#1070).

### Fixed
- Wine no longer pegs a CPU core when a running process goes quiet. After a
  process closed its stdout/stderr but kept running, the pipe's readability
  handler fired continuously on the permanently-readable EOF condition. The
  handler now removes itself on EOF (the final bytes are still drained when the
  process exits), so an idle Wine process no longer spins
  (Closes whisky-app/whisky#917, whisky-app/whisky#1010).
- Moving a bottle no longer wipes its pinned-program list. The `move()` loop
  was shadowing the bottle's `url` with `pin.url`, causing
  `updateParentBottle` to compare a pin path against itself instead of the
  bottle root. Pin paths are now correctly rewritten to point at the new
  bottle location (Closes whisky-app/whisky#830).
- Right-click "Add to blocklist" no longer creates duplicate entries. The
  context-menu actions dedupe against the existing blocklist before
  appending, both for single-row and multi-selection cases
  (Closes whisky-app/whisky#431).
- DXVK installation no longer stops short when the bundle directory contains a
  non-DLL file. The copy loop returned on the first non-`.dll` entry (e.g. a
  stray `.DS_Store`), which could leave some DXVK DLLs uninstalled; it now skips
  non-DLL entries and continues.
- Pinning start-menu programs no longer stops at the first already-pinned entry.
  The pin loop returned early once it found a program already in the pin list,
  leaving every subsequent start-menu program unpinned; it now skips that entry
  and continues processing the rest.

### Documentation
- Added project governance and support docs: `docs/GOVERNANCE.md` (honest single-maintainer
  continuity stance), `docs/SUPPORT.md` (where to file and what to expect), and
  `docs/DEPENDENCIES.md` (pinned Wine/DXVK/D3DMetal/DXMT runtime components and their sources).
- Documented the reproducible runtime-assembly procedure in `docs/ReleaseWorkflow.md` (previously
  marked "out of scope") and added a weekly `RuntimeTrack` workflow that flags when a bundled runtime
  component falls behind upstream. The bug-report template now asks reporters to confirm they're on
  this fork rather than the archived original.
- `SECURITY.md` now documents how Wine/DXVK runtime vulnerabilities are handled — pinned versions are
  tracked against upstream, and a critical bundled-component CVE triggers an out-of-band runtime rebuild
  and release. Added `FUNDING.md` describing the volunteer, single-maintainer sustainability model.
- Removed the inherited CrossOver affiliate links (`ad=1010`) from the README and funding config; this
  fork has no affiliate or revenue-sharing arrangement, and those links credited the original project.

## [3.0.1] - 2026-05-01 (App)

### Fixed
- WhiskyWine install hung at "Installing WhiskyWine — Almost there" because
  `Tar.validateArchivePaths` waited for the `tar -tvzf` process to exit before
  reading its stdout pipe. With the 313 MB Wine Libraries archive the verbose
  listing easily exceeds the pipe buffer, so tar blocked writing while Whisky
  waited for it to finish — a classic pipe deadlock. The pipe is now drained
  before `waitUntilExit`.

## [3.0.0] - 2026-05-01 (App)

First app release of the active community fork of [whisky-app/whisky](https://github.com/whisky-app/whisky)
(archived April 2025). Resolves all 54 v1.0 milestone requirements covering 10 categories of
upstream issues (#40, #41, #42, #43, #44, #45, #47, #48, #49, #50). Bumps the macOS minimum
to 15 (Sequoia).

### Added
- Guided troubleshooting wizard with step-by-step diagnostic flows for 8 issue categories (Issue #50)
- Terminal application selection: choose between Terminal, iTerm2, or Warp (Refs #47, upstream #911)
- Duplicate bottle feature for cloning bottles without export/import (Refs #47, upstream #822)
- App Nap management: disable macOS process throttling for better game performance (Refs #47, upstream #1297)
- Controller & Input Compatibility settings for game controller detection issues (Issue #42)
- Toast notifications showing launch success/failure feedback (Refs #49)
- Archive progress indicator with toast notifications for bottle export (Refs #49, upstream #827)
- Icon caching for faster program list loading (Refs #49, upstream #941)
- Improved UX for unavailable bottles with warning icon and quick remove button (Refs #49, upstream #1039)
- Retry button for failed config values (Build Version, Retina Mode, DPI) (Refs #49, upstream #967)
- Comprehensive Launcher Compatibility System including detection, diagnostics, and configuration
- Stability diagnostics export for crash/freeze reports (Refs #40)
- WhiskyWine download/install diagnostics with copy-to-clipboard workflow (Issue #63)
- SwiftFormat integration for automated code formatting
- DocC documentation for WhiskyKit public API
- Code coverage reporting and badges
- GitHub Pages and Releases infrastructure
- WhiskyKit test infrastructure and initial test suite
- Dependabot configuration for dependency updates

### Changed
- Refactored shared program launch logic into reusable `LaunchResult` and `launchWithUserMode()` (Issue #68)
- Refactored `BottleSettings` and `Wine` modules into smaller, focused components
- Replaced `print()` statements with `os.log` Logger for better debugging
- Consolidated CI workflows for improved efficiency
- Implemented proper thread safety by removing `@unchecked Sendable` usage
- Raised minimum deployment target from macOS 14 (Sonoma) to macOS 15 (Sequoia)
- AVX toggle and Sequoia compatibility mode are now always visible (no longer gated by OS version)

### Fixed
- Fixed Terminal launch (shift-click) producing malformed commands due to double-escaping (Issue #71)
- Fixed localization fallback showing raw keys to non-English users (Refs #49)
- Fixed WhiskyCmd `run` command not launching programs (now uses Wine directly) (Refs #49, upstream #1088, #1140)
- Corrected Dependabot Swift configuration
- Capped Wine process logs and pruned old logs to prevent excessive disk usage (Issue #46)
- Surface bottle creation failures with diagnostic information (Issue #61)
- Fixed winetricks dependency installs failing when %AppData% is empty (Issue #64)
- Fixed hardcoded "crossover" username in user profile path detection
- Added Wine prefix validation before running winetricks with repair option

### Security
- Process environment logging now records keys only (not values) to avoid persisting secrets in logs

### Removed
- Unmaintained CLI dependencies (SwiftyTextTable, Progress.swift)
- Removed `#available(macOS 15, *)` availability checks as macOS 15 is now the minimum

### Documentation
- Added comprehensive Launcher Troubleshooting and Steam Compatibility guides
- Removed obsolete Markdown files from the root and `docs/` directory
- Updated `README.md` and `CONTRIBUTING.md` to reflect current project state
- Consolidated documentation into the `docs/` directory

## [3.0.0] - 2026-01-18 (Wine Libraries)

### Changed
- Upgraded Wine from 7.7 to 11.0 (Gcenx stable build) for improved application compatibility
- Updated DXVK to macOS-compatible v1.10.3

### Fixed
- Steam "steamwebhelper is not responding" error caused by stubbed WSALookupServiceBegin (Issue #72)
- Improved networking stack for better launcher compatibility

## [2.5.0] - 2026-01-10

### Added
- Initial release of Whisky Wine binaries for this fork
- Wine/GPTK libraries packaged as `Libraries.tar.gz`
- GitHub Pages hosting for version metadata
- Sparkle appcast support for automatic updates
- Release workflow documentation

### Changed
- Fork setup with new distribution infrastructure
- Updated GitHub Pages URLs for the frankea fork

### Documentation
- Added `RELEASE_WORKFLOW.md` for publishing releases
- Added `DOCUMENTATION_AUDIT.md` for tracking documentation status
- Updated `README.md` with fork-specific information

---

## Categories Guide

When adding entries to this changelog, use the following categories:

- **Added** - New features
- **Changed** - Changes in existing functionality
- **Deprecated** - Soon-to-be removed features
- **Removed** - Now removed features
- **Fixed** - Bug fixes
- **Security** - Vulnerability fixes
- **Documentation** - Documentation-only changes

[Unreleased]: https://github.com/frankea/Whisky/compare/v3.0.0...HEAD
[3.0.0]: https://github.com/frankea/Whisky/releases/tag/v3.0.0
[2.5.0]: https://github.com/frankea/Whisky/releases/tag/v2.5.0
