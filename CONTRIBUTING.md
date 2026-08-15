# Contributing to DOKA

<p><a href="CONTRIBUTING.ru.md">Русская версия</a></p>

Thanks for taking an interest. This is a small project with a few firm conventions — most
of them exist because something broke once. Please read this before opening a pull request.

## Getting set up

```bash
git clone https://github.com/ippitenin/DOKA.git
cd DOKA/DOKA-app
swift build        # quick compile check
./run.sh           # release build, sign, install to ~/Applications, launch
```

`./build.sh` signs with a self-signed **“DOKA Dev”** certificate — see
[`scripts/make-dev-cert.md`](DOKA-app/scripts/make-dev-cert.md). Note that re-signing
resets macOS TCC permissions, so you will be re-granting microphone and accessibility
access fairly often while developing.

Architecture, invariants and the reasoning behind the odd-looking bits are documented in
[`CLAUDE.md`](CLAUDE.md). It is worth reading the section relevant to your change — many
“obvious improvements” have already been tried and reverted.

## Verification gates

There are no automated tests: the app is a single SPM executable target, and XCTest would
require splitting it into a `DOKACore` library plus a thin executable. That split is
deliberately postponed, so verification is manual and these four gates replace it:

1. `swift build` — must finish with **no warnings**.
2. `plutil -lint` on both `Localizable.strings` files (and both `InfoPlist.strings` if you
   touched them). `swift build` does **not** validate `.strings` syntax — a broken file
   compiles fine and fails at runtime.
3. `./build.sh` — the release build must sign successfully.
4. A manual smoke pass over whatever you touched. `CLAUDE.md` lists what to check per area.

**Gates 1 and 2 run automatically on every pull request** (`.github/workflows/build.yml`).
Run them locally before pushing to get the answer in seconds instead of minutes:

```bash
swift build
./scripts/check-localization.sh
```

`check-localization.sh` verifies that the Russian and English key sets match, that
placeholders (`%@`, `%ld`, …) agree between them, that every key used via `L(...)` exists,
and that no dead strings accumulate. If you add a key that is assembled dynamically, add
its prefix to `DYNAMIC_PREFIXES` in the script — otherwise it will be reported as dead.

Gates 3 and 4 stay manual: CI has no signing certificate and cannot click through the app.

Pure logic (`ReplacementEngine`, `TranscriptFormatter`, `LightMarkdown`, and friends) is
written to be testable and can be verified with a standalone harness that compiles the real
sources.

## Conventions

- **Code and comments are written in Russian.** Keep new code consistent with what is
  already there.
- **Every interface string goes through `L("key")`**, and the key must exist in *both*
  `Sources/DOKA/Resources/ru.lproj/Localizable.strings` and `en.lproj/`. No hardcoded
  user-facing text.
- **The design system is the source of truth.** Colours, radii, spacing and animations come
  from the `DS` tokens in `UI/DesignSystem/`; glass surfaces go through `glassSurface()`.
  Do not hardcode colours or magic numbers in new UI.
- **Do not move WhisperKit past the 0.18.x line.** In 1.x two executable products share a
  target and the universal build fails with “duplicate key found”. If you update the pin,
  verify a full `./build.sh` first, not just `swift build`.
- Commits follow conventional commits with a Russian description: `feat:`, `fix:`, `docs:`,
  `chore:`.

## Reporting bugs

Include your macOS version, your Mac’s chip (Apple Silicon or Intel), which recognition
service you were using, and what you expected to happen. If it involves a crash, Console
output helps.

**Never paste an API key into an issue.** Keys live in the Keychain precisely so they do not
end up in text.

## Contributor license grant

By submitting a pull request you agree that your contribution is licensed under GPL-3.0,
and you grant the project author (Ilya Pitenin) a non-exclusive, perpetual, worldwide,
royalty-free right to use, modify, sublicense and distribute your contribution, including
under a different license.

This keeps it possible to relicense the project or ship it through the Mac App Store
without collecting signatures from every past contributor. Your contribution remains
available under GPL-3.0 regardless — this grant adds a permission, it does not take one
away.
