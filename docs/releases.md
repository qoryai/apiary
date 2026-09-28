# Releases

How a release is cut and published.

A release is a tag on a branch named after it, `v0.1.0`, opened as one pull request. That
branch adds the release's section to `CHANGELOG.md`, `[X.Y.Z] - YYYY-MM-DD` with the day
the tag lands, with Added, Changed and Fixed as they apply and always **Migrations**, the
tables the release's migrations touch and whether one is long, and **Upgrading**, anything
the operator has to do or know; a fix that goes to `main` outside a release branch goes
under `[Unreleased]` until the next one. The same branch sets `version` in `mix.exs` to the
tag without the `v`: that is what `GET /health` and `bin/apiary version` report, and the
release workflow refuses a tag whose version `mix.exs` does not carry.

Pushing `vX.Y.Z` to the GitHub mirror runs `.github/workflows/release.yml`, which takes
the release body from the changelog, builds the image from the `Dockerfile` and publishes
it to `ghcr.io` under the version and `latest`. `scripts/changelog-section.sh 0.1.0` prints
the section the workflow would take, and fails when there is none, which is what stops a
tag from publishing without one. Check both before tagging:

```sh
scripts/changelog-section.sh X.Y.Z
grep 'version: "X.Y.Z"' mix.exs
```
