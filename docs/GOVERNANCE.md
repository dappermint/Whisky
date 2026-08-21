# Governance & continuity

This fork exists because the original [whisky-app/whisky](https://github.com/whisky-app/whisky) was
archived in April 2025 when its maintainer stepped away. It's worth being honest about the fact that
this project carries the same structural risk.

> **Scope.** This document covers the `preview` branch and the Whisky Preview app released from it,
> maintained by [@dappermint](https://github.com/dappermint). `main` tracks
> [frankea/Whisky](https://github.com/frankea/Whisky), which has its own maintainer and its own
> governance; see that repository for how @frankea runs it. Where the two differ, the notes below say so.

## Who maintains this

Whisky Preview is maintained by **one person**, [@dappermint](https://github.com/dappermint), who holds
final authority over the `preview` branch, its releases, and its signing identity. Upstream,
[@frankea](https://github.com/frankea) maintains `frankea/Whisky`, where @dappermint holds a **project
member (triage)** role since August 2026: issue triage, labels, and pull request review, with no commit
access and no release capability. There is no team and no company on either side. "Active community
fork" describes the development pace and the openness to contributions; it does not imply a staffed
organization.

This is a deliberate choice, not an oversight. Maintaining a Wine wrapper well is mostly steady,
low-drama work, and a small project moves faster without coordination overhead. But it means the
**bus factor for releases is one**, and you should weigh that before depending on this fork for
anything critical.

## Trust is granted in stages

Roles here expand with track record:

1. **Contributor**: pull requests, reviewed and merged by the maintainer.
2. **Project member (triage)**: issue triage, labels, and pull request review. No commit access.
3. **Co-maintainer (commit)**: direct commit and merge rights. Considered only after a sustained
   record at the previous stage, and only alongside branch protection requiring review on `main`.

Regardless of stage, **release signing stays with the maintainer**. For Preview that means the
self-signed certificate described in [`ReleaseWorkflow.md`](ReleaseWorkflow.md#signing): there is no
Apple Developer ID, so builds are not notarized, and there is no Sparkle update key because Preview
ships no in-app updater. Nothing reaches users through the release channel without the maintainer
building and signing it.

## What that means for you

- **Releases depend on one person's availability.** If @dappermint is unavailable for a stretch,
  expect no new Preview releases until they're back. Existing installs keep working.
- **Bug triage is best-effort.** See [`SUPPORT.md`](SUPPORT.md) for what to realistically expect.
- **Most of the runtime is consumed, not owned.** Whisky bundles DXVK/D3DMetal/DXMT binaries from
  upstream projects (see [`DEPENDENCIES.md`](DEPENDENCIES.md)); if those stall, Whisky's runtime
  currency is affected. The Wine build is the exception on `preview`, which builds its own from
  [dappermint/winecx-gptk](https://github.com/dappermint/winecx-gptk) because the GPTK route needs
  it. That adds to what one maintainer carries.

## If you want to reduce that risk

The most useful thing a contributor could do is **become a second maintainer**. If you have macOS +
Swift + Wine-packaging experience and want to share the load (or be a backstop), open an issue or reach
out. This path is real: it is how the current project member role came to be (see issue #194), and it
follows the staged model above.

## Maintainer continuity (operational)

So that a lapse doesn't silently break things, the maintainer keeps these minimums:

- **Off-machine backup** of the signing material. For Preview that is `identity.p12`, the self-signed
  certificate: losing it changes the app's designated requirement, which resets every user's TCC
  consent. [`ReleaseWorkflow.md`](ReleaseWorkflow.md#credential-continuity-backup--recovery) covers the
  export, encryption, and restore test.
- The full release procedure is documented in [`ReleaseWorkflow.md`](ReleaseWorkflow.md) so it is
  reproducible rather than living only in one person's head.

There is intentionally **no shared key escrow** today: the project member role does not carry release
responsibilities, so there is still nobody to escrow to. That is the honest state of things; it will
change if the project gains a co-maintainer with release duties.
