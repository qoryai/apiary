# This file is based on these images:
#
#   - https://hub.docker.com/r/hexpm/elixir/tags - for the builder image
#     E.g.: docker.io/hexpm/elixir:1.20.4-erlang-29.1-debian-trixie-20260918-slim
#   - https://hub.docker.com/_/debian/tags?name=trixie-20260918-slim - for the runner image
#     E.g.: docker.io/debian:trixie-20260918-slim
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
ARG RUNNER_IMAGE="docker.io/debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

# install build dependencies
RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git \
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
RUN mkdir config

# copy compile-time config files before we compile dependencies
# to ensure any relevant config change will trigger the dependencies
# to be re-compiled.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

RUN mix assets.setup

COPY priv priv

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

RUN apt-get update \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates \
  && rm -rf /var/lib/apt/lists/*

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
ADD --checksum=sha256:fe45bbebf92ad3e27a583bbb2ddd1553c521ed4d49af5514dc0a40372ea5395c --chmod=0644 \
  https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem /app/certs/rds-global-bundle.pem

# The keys generated at first start, in APIARY_KEYS_DIR. The directory belongs to nobody,
# so a new volume mounted on it takes that owner and the release can write to it.
RUN mkdir -p /var/lib/apiary/keys \
  && chown nobody /var/lib/apiary/keys
ENV APIARY_KEYS_DIR=/var/lib/apiary/keys

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
