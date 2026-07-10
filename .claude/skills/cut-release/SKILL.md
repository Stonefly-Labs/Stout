---
name: cut-release
description: SemVer release procedure for the Stout package — runs the full gate (swift test, swift format lint --strict, an API-breakage diff), bumps BOTH the package version AND the `stout:<version>` sdkVersion string, updates the changelog, creates and pushes the tag via the protected-main PR flow, and verifies CI. Use this when asked to "cut a release", "tag a version", "publish X.Y.Z", "do a SemVer bump", "ship a new version", or "release Stout", or when deciding whether a change is major/minor/patch. It does NOT itself run git commands on your behalf unless you execute the listed steps.
---
# Cut a Release (SemVer)

Release procedure for `Stonefly-Labs/Stout`. Under the prime directive, a release
is a quality gate, not a formality: nothing tagged unless tests, lint, and the
API-breakage check are green, and the version numbers are internally consistent.
`main` is **protected** — everything goes through a PR (0 approvals required; you
may self-merge once CI is green).

## 0. Decide the version (SemVer)

Pre-release (0.y.z): breaking changes bump the minor, everything else the patch.
Post-1.0:

| Change | Bump |
|---|---|
| Breaking public API change (removed/renamed symbol, changed signature, changed documented behavior) | **major** |
| New public API, backward compatible | **minor** |
| Bug fix / internal-only change / docs | **patch** |

The API-breakage diff in step 2 is what tells you if a "minor" is secretly a major.

## 1. Gate — tests + lint (must both pass)

```sh
swift build
swift test
swift format lint --strict --recursive Sources Tests   # 2-space indent; zero output = pass
```

Do not proceed on any failure. (CI enforces the same two required checks:
**Build & Test** and **Lint (swift-format)**.)

## 2. API-breakage diff

Detect unintended public-API changes so the SemVer bump is correct:

```sh
# Snapshot the current public API and diff against the last release tag.
swift package diagnose-api-breaking-changes <last-release-tag>
```

- If it reports breaking changes and you intended a minor/patch → either restore
  compatibility or escalate the bump to major (post-1.0) / minor (0.y).
- If clean, the intended bump stands.
(If `diagnose-api-breaking-changes` is unavailable in the toolchain, fall back to
generating and diffing a symbol dump, e.g. `swift api-digester -dump-sdk`, or a
manual review of the public surface in `Sources/*/`.)

## 3. Bump the version in BOTH places

A release changes two things that MUST match — a mismatch means telemetry is
mislabeled in the field:

1. **Package version** — the source of truth for the git tag (Swift packages are
   versioned by tag; also update any `let version`/version constant if the package
   carries one, and any docs referencing the current version).
2. **The `stout:<version>` sdkVersion string** — the value written to the Part A
   tag `ai.internal.sdkVersion` on every Breeze envelope (see `breeze-schema` §2
   and design §6). Find it (e.g. `grep -rn 'stout:' Sources`) and bump it to the
   same `X.Y.Z`.

Verify they agree before tagging.

## 4. Changelog

Update `CHANGELOG.md` (Keep a Changelog style): move Unreleased items under a new
`## [X.Y.Z] - <YYYY-MM-DD>` heading, grouped Added / Changed / Fixed / Security.
Call out any breaking changes and any security-relevant fixes explicitly.

## 5. PR the release prep

`main` is protected, so the version bump + changelog land via PR:

```sh
git switch -c release/vX.Y.Z
git add -A
git commit -m "Release vX.Y.Z"   # end with the Co-Authored-By trailer (see CLAUDE.md)
git push -u origin release/vX.Y.Z
gh pr create --fill
```

Wait for **Build & Test** + **Lint** to go green (branch must be up to date with
`main`), then merge (self-merge allowed). Linear history — no force-push.

## 6. Tag and push

Tag the merge commit on `main` (annotated), matching the package version exactly:

```sh
git switch main && git pull --ff-only
git tag -a vX.Y.Z -m "Stout vX.Y.Z"
git push origin vX.Y.Z
```

Then optionally cut a GitHub release:

```sh
gh release create vX.Y.Z --title "Stout vX.Y.Z" --notes-from-tag
```

## 7. Verify CI

Confirm the tag's checks are green:

```sh
gh run list --branch vX.Y.Z
gh run watch <run-id>
```

CI currently runs on a **self-hosted, macOS-only** runner (decision D6). **Linux
coverage is a known gap** — for a release, at minimum sanity-check that the change
does not rely on macOS-only Foundation/NIO behavior, since Stout is a server-side
(Linux-first) library.

## Checklist

- [ ] `swift test` green
- [ ] `swift format lint --strict` clean
- [ ] API-breakage diff reviewed; SemVer bump matches reality
- [ ] Package version bumped
- [ ] `stout:<version>` sdkVersion string bumped to match
- [ ] CHANGELOG updated (incl. Security/Breaking notes)
- [ ] Release PR merged (CI green)
- [ ] Annotated tag `vX.Y.Z` pushed
- [ ] Tag CI green
