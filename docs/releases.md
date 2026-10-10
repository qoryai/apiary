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

Before a release, `.github/workflows/prerelease.yml` publishes pre-release images. It runs
only by hand: from the Actions tab, for the branch it is run on or the ref it is given,
once the workflow is on the default branch; or by pushing a commit to the branch
`prerelease`, which it then builds. It never runs on a push to any other branch or on a
schedule. It builds the image as `release.yml` does and pushes it to
`ghcr.io/qoryai/apiary-prerelease` alone, as `sha-` and the commit's first seven characters,
and as `next` when the ref is `next`. That package stays private: GHCR sets visibility per
package, so pre-release tags never sit beside a release's. Its old `sha-` tags are deleted
by hand. A test stack names one under Test image, in the AWS template's For testing only
group, with a download key whose account can read the package.
