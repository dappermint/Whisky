<div align="center">

  # Whisky Preview 🥃
  *Wine but a bit stronger*

  ![](https://img.shields.io/github/actions/workflow/status/dappermint/Whisky/CI.yml?branch=preview&style=for-the-badge&label=CI)
  [![](https://img.shields.io/github/downloads/dappermint/Whisky/total?style=for-the-badge&logo=github&label=Downloads)](https://github.com/dappermint/Whisky/releases)
  [![](https://img.shields.io/github/issues/dappermint/Whisky?style=for-the-badge)](https://github.com/dappermint/Whisky/issues)
  [![Documentation](https://img.shields.io/badge/Documentation-DocC-blue?style=for-the-badge)](https://dappermint.github.io/Whisky/documentation/whiskykit/)
</div>

> **This is the `preview` branch.** It carries Steam, DLL override and D3DMetal work that
> hasn't landed upstream yet, and ships as a separate app (`Whisky Preview.app`,
> `com.dappermint.WhiskyPreview`) that installs beside a normal Whisky rather than replacing
> it. `main` tracks [frankea/Whisky](https://github.com/frankea/Whisky) and is where upstream
> contributions are prepared — it is never released from.
>
> Lineage: [whisky-app/whisky](https://github.com/whisky-app/whisky) (archived April 9, 2025)
> → [frankea/Whisky](https://github.com/frankea/Whisky) → this fork. Not affiliated with the
> original project or getwhisky.app. Report problems with *this* build here, not upstream.

## Install

```sh
brew tap dappermint/tap
brew trust --cask dappermint/tap/whisky-preview
brew install --cask whisky-preview
```

The `brew trust` step is required: Homebrew refuses to load a cask from a third-party tap
until you trust it, because a cask can run code on install. This one does — see below.

Builds are ad-hoc signed and not notarized, so Gatekeeper blocks a plain double-click of the
DMG with no way to approve it. The cask clears the quarantine flag in a `postflight` block,
which is why it is the supported path. There is no in-app updater; upgrade with
`brew upgrade --cask whisky-preview`.

On first launch the bottle list is empty, since this app has its own bundle identifier.
**File → Import Bottles from Another Whisky…** adopts bottles from frankea's build or from the
archived original. They are referenced in place, never copied or moved, so the other build
keeps working.

## Overview

Whisky provides a clean and easy-to-use graphical wrapper for Wine built in native SwiftUI. You can make and manage bottles, install and run Windows apps and games, and unlock the full potential of your Mac with no technical knowledge required.

<img width="650" alt="Whisky in action" src="./images/demo.gif">

<img width="650" alt="Config" src="./images/config-screenshot.png">

*Familiar UI that integrates seamlessly with macOS*

<div align="right">
  <img width="650" alt="New Bottle" src="./images/new-bottle-screenshot.png">

  *One-click bottle creation and management*
</div>

<img width="650" alt="debug" src="./images/debug-screenshot.png">

*Debug and profile with ease*

---

## Key Features

- **Wine 11.14** - GPTK-capable build that executes Apple's D3DMetal payload, with GStreamer and FFmpeg
- **DXMT & DXVK Graphics** - DirectX 11 through native Metal translation (DXMT) out of the box, with DXVK over MoltenVK as the universal fallback
- **Launcher Compatibility** - Built-in support for Steam, Epic, EA App, Rockstar, Battle.net, and more
- **Controller Support** - SDL environment variable controls for gamepad detection and mapping issues
- **Stability Diagnostics** - One-click diagnostic reports for troubleshooting crashes and freezes
- **Native SwiftUI** - Beautiful, familiar macOS interface

## System Requirements

- **CPU**: Apple Silicon (M-series chips)
- **OS**: macOS Tahoe 26.0 or later

## Installation

See [Install](#install) at the top. In short: tap, trust, `brew install --cask whisky-preview`.

### Bringing bottles over

This app has its own bundle identifier, so it does not see another Whisky's bottles
automatically. **File → Import Bottles from Another Whisky…** scans both known containers:

- `~/Library/Containers/com.franke.Whisky/` — frankea's fork
- `~/Library/Containers/com.isaacmarovitz.Whisky/` — the archived original

Pick the bottles you want. They are referenced **in place** — nothing is moved or copied — so
whichever build owns them keeps working. A bottle registered by both is offered once. The
**Bottle → Export** / **File → Import Bottle** route still works if you'd rather move bottles by
hand or onto another Mac; with no bottles worth keeping, skip the import and let this app create
a fresh one.

## Uninstalling

`brew uninstall --cask whisky-preview` removes the app but leaves the Wine runtime, your bottles
and app data behind — by design, so reinstalling doesn't re-download the runtime or lose bottles.

> ⚠️ **Back up your bottles first if you want to keep them.** The container below holds every
> bottle in the default location. Bottles you created in a custom folder live wherever you put
> them — check **Bottle → Reveal in Finder** before deleting anything.

To remove everything, including bottles:

```sh
brew uninstall --zap --cask whisky-preview
```

The `zap` moves these to the Trash rather than deleting them outright:

```
~/Library/Containers/com.dappermint.WhiskyPreview          # bottles + bottle list
~/Library/Application Support/com.dappermint.WhiskyPreview # the Wine runtime
~/Library/Caches/com.dappermint.WhiskyPreview
~/Library/HTTPStorages/com.dappermint.WhiskyPreview
~/Library/Preferences/com.dappermint.WhiskyPreview.plist
~/Library/Saved Application State/com.dappermint.WhiskyPreview.savedState
```

Bottles imported from another Whisky live in *that* build's container and are left untouched.
So are bottles in a custom location — delete those folders yourself if you want them gone.

## Telemetry (disabled in this build)

**Whisky Preview sends nothing, ever.** Upstream ships an opt-in analytics token;
this fork ships an empty one, so the code path is inert even if you tick the
consent box. Reporting into someone else's analytics project would be wrong, and
this fork has no project of its own.

The rest of this section describes the mechanism as it exists upstream, for
anyone reading the shared code. It does not run here.

When enabled and given a token, Whisky sends five events covering the first-run
funnel:

| Event | Properties |
| --- | --- |
| `runtime_install_started` | — |
| `runtime_install_succeeded` | — |
| `runtime_install_failed` | `reason`: one of `download_failed`, `verify_failed`, `tarball_missing`, `extract_failed`, `runtime_incomplete` |
| `first_bottle_created` | — |
| `first_program_launch_attempted` | — |

`runtime_install_started` is sent once per setup attempt; the `_succeeded` /
`_failed` events are sent per install attempt (so retries are counted). The two
`first_…` events are sent at most once per install.

No personal data, file names, paths, raw error text, or identifiers tied to you
are ever sent. Events carry a random per-install anonymous ID (reset if you opt
out). Every event Whisky can send is the list above, and all of it is declared in
one file, [`Whisky/Utils/Telemetry.swift`](Whisky/Utils/Telemetry.swift), with
every automatic-capture feature of the analytics SDK disabled and no person
profile ever created (`identify()` is never called). Each event also carries the
SDK's standard context — app and macOS version, hardware model, locale, and more;
see [SECURITY.md](SECURITY.md) for the full list. Like any HTTPS request,
PostHog's ingestion sees the connecting IP (GeoIP enrichment is disabled); none
of this is tied to your identity.

## Documentation

- **[Support](docs/SUPPORT.md)** - Where to file bugs and what to expect from a single-maintainer fork
- **[Governance & continuity](docs/GOVERNANCE.md)** - Who maintains this and the honest bus-factor situation
- **[Runtime dependencies](docs/DEPENDENCIES.md)** - The bundled Wine/DXVK/D3DMetal/DXMT versions and their upstream sources

WhiskyKit, the core framework powering Whisky, has comprehensive API documentation:

- **[WhiskyKit API Documentation](https://frankea.github.io/Whisky/documentation/whiskykit/)** - Full API reference with usage examples
- **[Getting Started Guide](https://frankea.github.io/Whisky/documentation/whiskykit/gettingstarted)** - Learn how to integrate WhiskyKit
- **[Architecture Overview](https://frankea.github.io/Whisky/documentation/whiskykit/architecture)** - Understand how WhiskyKit components work together

### Troubleshooting

- **[Launcher Troubleshooting](docs/LauncherTroubleshooting.md)** - Fix issues with Steam, Epic, Battle.net, etc.
- **[Steam Compatibility Guide](docs/SteamCompatibility.md)** - Detailed guide for Steam on Whisky
- **[Stability Troubleshooting](docs/StabilityTroubleshooting.md)** - Diagnose crashes, freezes, reboots, and kernel panics
- **Controller Issues** - Enable "Controller Compatibility Mode" in Bottle Config → Controller & Input
- **[Game Configurations](https://github.com/frankea/Whisky/blob/main/WhiskyKit/Sources/WhiskyKit/GameDatabase/Resources/GameDB.json)** - 80+ curated per-game compatibility configs, also browsable in-app under Game Configurations

### Upstream issue audit

Per-issue accounting of how this fork addresses the open issues from the
archived upstream repo. Read [docs/AUDIT.md](docs/AUDIT.md) for the
methodology — including how to read the `addressed-direct` vs
`addressed-categorical` distinction and what `unverified` GameDB entries
actually mean.

### Test coverage

The Coverage badge above is scoped to the **`whiskykit` flag** — line
coverage of the framework that holds the bottle, Wine, GameDB, and
PE-parser logic, measured by `swift test --enable-code-coverage` per
[`.github/workflows/CI.yml`](.github/workflows/CI.yml). The blended
project-wide number on the [Codecov dashboard](https://codecov.io/gh/frankea/Whisky)
reads much lower because it averages in the SwiftUI app target, which
only receives best-effort UI-test coverage. Read the badge as
"WhiskyKit unit-test coverage," not full-app coverage.

WhiskyUITests gives behavioural coverage of the SwiftUI surface (toolbar,
create-bottle sheet, fixture-dependent flows). CI now runs them with
`-enableCodeCoverage YES` and uploads the resulting app-target coverage to
Codecov under a separate `whiskyapp` flag (best-effort — the upload never gates
CI). Because UI tests exercise far less of the app than the unit tests do of
WhiskyKit, expect the app-target number to read lower than the WhiskyKit badge
above.

---

## Credits & Acknowledgments

Whisky is possible thanks to the magic of several projects:

- [msync](https://github.com/marzent/wine-msync) by marzent
- [DXVK-macOS](https://github.com/Gcenx/DXVK-macOS) by Gcenx and doitsujin
- [DXMT](https://github.com/3Shain/dxmt) by 3Shain
- [MoltenVK](https://github.com/KhronosGroup/MoltenVK) by KhronosGroup
- [Sparkle](https://github.com/sparkle-project/Sparkle) by sparkle-project
- [SemanticVersion](https://github.com/SwiftPackageIndex/SemanticVersion) by SwiftPackageIndex
- [swift-argument-parser](https://github.com/apple/swift-argument-parser) by Apple
- [CrossOver](https://www.codeweavers.com/crossover) by CodeWeavers and WineHQ
- D3DMetal by Apple

Special thanks to Gcenx, ohaiibuzzle, Nat Brown, and [Isaac Marovitz](https://github.com/IsaacMarovitz) (original author) for their support and contributions!

---

<table>
  <tr>
    <td>
        <picture>
          <source media="(prefers-color-scheme: dark)" srcset="./images/cw-dark.png">
          <img src="./images/cw-light.png" width="500">
        </picture>
    </td>
    <td>
        Whisky doesn't exist without CrossOver. If you want a fully-supported commercial Wine experience on macOS, check out <a href="https://www.codeweavers.com/crossover">CrossOver</a> from CodeWeavers. (This fork has no affiliate arrangement and receives nothing from CrossOver sales.)
    </td>
  </tr>
</table>
