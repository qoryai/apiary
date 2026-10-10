# Releases

How a release is cut and published. There are no release branches.

Changes go under `[Unreleased]` in `CHANGELOG.md`. A release is one pull request to `main`
that turns `[Unreleased]` into the release's section. Its heading is
`## [X.Y.Z] - YYYY-MM-DD`, dated the day the tag lands: `scripts/changelog-section.sh` finds
the section by a line that starts `## [X.Y.Z] `. The section has Added, Changed and Fixed
as they apply, and always **Migrations**, the tables the release's migrations touch and
whether one is long, and **Upgrading**, anything the operator has to do or know. The same
pull request puts back an empty `## [Unreleased]` above the new section, for the changes
after it. It also sets `version` in `mix.exs` to the version without the `v`: that is what
`GET /health` and `bin/apiary version` report. Once it is merged, the tag `vX.Y.Z` goes on
the commit the merge leaves at the head of `main`, and that tag is the release. The release
workflow refuses a tag whose version `mix.exs` does not carry.

Pushing `vX.Y.Z` to the GitHub mirror runs `.github/workflows/release.yml`, which takes
the release body from the changelog, builds the image from the `Dockerfile` for
`linux/amd64` and `linux/arm64`, and publishes it as `ghcr.io/qoryai/apiary`, tagged
`X.Y.Z`, `X.Y` and `latest`. It publishes the GitHub release with three files attached:
`compose.yaml`; `env.example`, a copy of `.env.example` that names `X.Y.Z` in
`APIARY_VERSION`; and `apiary.yaml`, the AWS template `deploy/aws/apiary.yaml` with the
version written in. `deploy/aws/stack-policy.json` is not attached: the template job
uploads it to the S3 bucket beside the template, and only when the repository variables
`AWS_TEMPLATE_BUCKET` and `AWS_TEMPLATE_ROLE_ARN` are set. Without them, nothing goes to
S3. `scripts/changelog-section.sh 0.1.0` prints the section the workflow would take, and
fails when there is none, which is what stops a tag from publishing without one. Check
both before tagging:

```sh
scripts/changelog-section.sh X.Y.Z
grep 'version: "X.Y.Z"' mix.exs
```

Before a release, `.github/workflows/prerelease.yml` publishes pre-release images. It runs
only by hand: from the Actions tab, for the branch it is run on or the ref it is given,
once the workflow is on the default branch; or by pushing a commit to the branch
`prerelease`, which it then builds. That branch is not a release branch: a push to it runs
this workflow alone and publishes only a pre-release image. The workflow never runs on a
push to any other branch or on a schedule. It builds the image as `release.yml` does and
pushes it to `ghcr.io/qoryai/apiary-prerelease` alone, as `sha-` and the commit's first
seven characters, and as `next` when the ref is `next`. That package stays private: GHCR
sets visibility per package, so pre-release tags never sit beside a release's. Its old
`sha-` tags are deleted by hand. A test stack names one under Test image, in the AWS
template's For testing only group, with a download key whose account can read the package.
