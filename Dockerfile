# This file is based on these images:
#
#   - https://hub.docker.com/r/hexpm/elixir/tags - for the builder image
#     E.g.: docker.io/hexpm/elixir:1.20.4-erlang-29.1-debian-trixie-20260918-slim
#   - https://hub.docker.com/_/debian/tags?name=trixie-20260918-slim - for the runner image
#     E.g.: public.ecr.aws/docker/library/debian:trixie-20260918-slim, Amazon's public copy of it
#
# Find builder and runner images on Docker Hub or on Hex's Build Server (Bob).
# We recommend using Bob's Web UI to find recent tags:
#
#   - https://bob.hex.pm/docker?repo=hexpm/elixir&os=debian&sort=elixir_version,erlang_version,os_version
#
# We suggest using the same Debian version for both the builder and runner images.
#
# We suggest Debian/Ubuntu instead of Alpine to avoid production compatibility issues
# (such as DNS resolution failures, and dynamically linked NIFs/precompiled binaries).
#
# For finding packages in Debian, search on https://packages.debian.org/.

ARG ELIXIR_VERSION=1.20.4
ARG OTP_VERSION=29.1
ARG DEBIAN_VERSION=trixie-20260918-slim

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="public.ecr.aws/docker/library/debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

# install build dependencies
RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git curl ca-certificates \
  && rm -rf /var/lib/apt/lists/*

# prepare build dir
WORKDIR /app

# install hex + rebar
RUN mix local.hex --force \
  && mix local.rebar --force

# set build ENV
ENV MIX_ENV="prod"

# install mix dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV

# rustler_precompiled downloads mdex's NIF with Erlang's httpc, which fails on github.com's
# redirect: more than 10 KiB of headers, over its 10,240-byte limit. curl fetches the NIF instead.
ENV RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH=/var/cache/rustler_precompiled
RUN mkdir -p "$RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH" \
  && files="$(grep -oE "libmdex_native_nif-v[0-9.]+-nif-[0-9.]+-$(uname -m)-unknown-linux-gnu(--legacy_cpu)?\.so\.tar\.gz" \
    deps/mdex_native/checksum-Elixir.MDExNative.Native.exs)" \
  && for f in $files; do \
    v="${f#libmdex_native_nif-}"; \
    curl -fsSL --retry 3 -o "$RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH/$f" \
      "https://github.com/leandrocp/mdex_native/releases/download/${v%%-nif-*}/$f" || exit 1; \
  done

RUN mkdir config

# copy compile-time config files before we compile dependencies
# to ensure any relevant config change will trigger the dependencies
# to be re-compiled.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

# tailwind's installer also downloads the CLI with httpc and hits the same limit. curl places the
# CLI 4.3.0 of config/config.exs at the path `tailwind.install --if-missing` checks, and the build
# stops when the file's SHA-256 differs from the one pinned here for the CPU architecture.
RUN case "$(uname -m)" in \
    x86_64) target=linux-x64 sha=73f0e5459054e5cfaa8ab6f3b940f3fbe0f13cc7fd83bc24e7c655033c203400 ;; \
    aarch64) target=linux-arm64 sha=8f48dcb72be3b351c10563c5329b4638ba8516820dc3b3a1609625a166e87cbd ;; \
    *) echo "error: build on x86_64 or aarch64; found $(uname -m)" >&2; exit 1 ;; \
  esac \
  && mkdir -p _build \
  && curl -fsSL --retry 3 -o "_build/tailwind-$target-4.3.0" \
    "https://github.com/tailwindlabs/tailwindcss/releases/download/v4.3.0/tailwindcss-$target" \
  && echo "$sha  _build/tailwind-$target-4.3.0" | sha256sum -c - \
  && chmod 755 "_build/tailwind-$target-4.3.0"

RUN mix assets.setup

COPY priv priv

# The integrations commit the vendored descriptions come from (`Apiary.Kinds.Providers`).
COPY .integration-contract-ref ./

COPY lib lib

# Compile the release
RUN mix compile

COPY assets assets

# compile assets
RUN mix assets.deploy

# The documentation ships with the application: the guides and the module reference are
# built into priv/static/docs, which the release serves at /docs. `mix docs` is `mix
# docs.all`: one tree per set of features the documentation differs by, every one in the
# image, and each instance serves the one its QORY_FEATURES cover. After assets.deploy, so
# phx.digest does not fingerprint them.
COPY guides guides
COPY CHANGELOG.md ./
RUN mix docs

# Changes to config/runtime.exs don't require recompiling the code
COPY config/runtime.exs config/

COPY rel rel
RUN mix release

# start a new build stage so that the final image will only contain
# the compiled release and other runtime necessities
FROM ${RUNNER_IMAGE} AS final

# Debian's advisory DSA-6572-1 (2026-10-20) removes two root certificates after eMudhra
# intermediate certificates were compromised. The build stops on an older ca-certificates.
RUN apt-get update \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates \
  && rm -rf /var/lib/apt/lists/* \
  && { dpkg --compare-versions "$(dpkg-query -W -f='${Version}' ca-certificates)" ge 20250419+deb13u1 \
    || { echo "error: install ca-certificates 20250419+deb13u1 or later from trixie-security; found $(dpkg-query -W -f='${Version}' ca-certificates)" >&2; exit 1; }; }

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

# The certificate authorities of Amazon RDS, which Debian's store does not hold, for a
# DATABASE_URL with sslmode=verify-full&sslrootcert=/app/certs/rds-global-bundle.pem. The
# checksum pins the bundle: when Amazon changes it, the build stops until this line names
# the new one. The directory is made first, with the usual mode: a directory ADD makes
# takes the file's mode, 0644, which only root could enter.
RUN mkdir -p /app/certs
ADD --checksum=sha256:90a6f1a7978a1b1b096dca6c57511ca48d3b8cf052f8e704baf358f34ea2f21b --chmod=0644 \
  https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem /app/certs/rds-global-bundle.pem

# The keys generated at first start, in APIARY_KEYS_DIR. The directory belongs to nobody,
# so a new volume mounted on it takes that owner and the release can write to it.
RUN mkdir -p /var/lib/apiary/keys \
  && chown nobody /var/lib/apiary/keys
ENV APIARY_KEYS_DIR=/var/lib/apiary/keys

# The one-time codes of the adapters installed with Qory Apiary, in QORY_ENROLMENT_DIR
# (`Apiary.Adapters.Installed`). The directory belongs to nobody, mode 0755, so the release
# makes a folder in it per adapter where it is missing and writes each code there; each
# adapter mounts only its folder.
RUN mkdir -p /run/qory/enrolment \
  && chown nobody /run/qory/enrolment \
  && chmod 0755 /run/qory/enrolment
ENV QORY_ENROLMENT_DIR=/run/qory/enrolment

WORKDIR "/app"
RUN chown nobody /app

# set runner ENV
ENV MIX_ENV="prod"

# No erl_crash.dump: it holds every process's memory, the database password among it.
ENV ERL_CRASH_DUMP_BYTES=0

# Only copy the final release from the build stage
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/apiary ./

# The commit the image is built from, written into the release as the file REVISION, which
# the release reads at boot and GET /health reports as its revision. A file, so no setting
# can change it. A build without the argument writes none, and the revision is null.
ARG APIARY_REVISION
RUN if [ -n "$APIARY_REVISION" ]; then printf '%s\n' "$APIARY_REVISION" > /app/REVISION; fi

EXPOSE 4100

USER nobody

# If using an environment that doesn't automatically reap zombie processes, it is
# advised to add an init process such as tini via `apt-get install`
# above and adding an entrypoint. See https://github.com/krallin/tini for details
# ENTRYPOINT ["/tini", "--"]

CMD ["/app/bin/server"]
