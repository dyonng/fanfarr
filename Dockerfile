# Base images are pinned by digest-bearing date tags so a rebuild of an old
# commit produces the same image. The two must stay in step: a release built
# against one glibc will not run on another, so bump them together.
ARG ELIXIR_IMAGE=hexpm/elixir:1.19.6-erlang-27.3.4.16-debian-bookworm-20260824-slim
ARG RUNNER_IMAGE=debian:bookworm-20260824-slim

FROM ${ELIXIR_IMAGE} AS builder

# build-essential and git are needed to compile exqlite, which builds SQLite
# from bundled C sources rather than linking a system copy.
RUN apt-get update -y \
  && apt-get install -y --no-install-recommends build-essential git ca-certificates \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV="prod"

# Dependencies are copied and compiled before application source so that an
# ordinary code change does not invalidate the dependency layer.
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
COPY assets assets

# Digests and gzips static assets into priv/static.
RUN mix assets.deploy
RUN mix compile

# runtime.exs is read when the container starts, not now, so it is copied
# after compilation.
COPY config/runtime.exs config/
COPY rel rel
RUN mix release

FROM ${RUNNER_IMAGE} AS runner

# ffmpeg/ffprobe: codec inspection and transcoding themes that clients cannot
#   play -- Apple TV, for instance, cannot play Opus.
# gosu: drops from root to the requested PUID/PGID in the entrypoint.
# libstdc++6/libgcc-s1: runtime libraries for the compiled exqlite NIF.
RUN apt-get update -y \
  && apt-get install -y --no-install-recommends \
     ca-certificates locales libstdc++6 libgcc-s1 openssl ffmpeg gosu curl \
  && rm -rf /var/lib/apt/lists/*

# yt-dlp ships a self-contained binary, so it is installed directly rather than
# through Python. YouTube breaks yt-dlp often enough that its version wants to
# move independently of ours: override YTDLP_VERSION at build time, or mount a
# newer binary over /usr/local/bin/yt-dlp, without rebuilding the app.
ARG YTDLP_VERSION=latest
RUN set -eux; \
  if [ "$YTDLP_VERSION" = "latest" ]; then \
    url="https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_linux"; \
  else \
    url="https://github.com/yt-dlp/yt-dlp/releases/download/${YTDLP_VERSION}/yt-dlp_linux"; \
  fi; \
  curl -fsSL -o /usr/local/bin/yt-dlp "$url"; \
  chmod +x /usr/local/bin/yt-dlp; \
  /usr/local/bin/yt-dlp --version

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app

# The release runs as this user unless PUID/PGID say otherwise. Both ids are
# rewritten at startup by the entrypoint, which is why the account exists here
# with placeholder values rather than being created at runtime.
RUN groupadd -g 1000 fanfarr && useradd -u 1000 -g fanfarr -d /app -s /bin/bash fanfarr

COPY --from=builder --chown=fanfarr:fanfarr /app/_build/prod/rel/fanfarr ./
COPY --chown=root:root docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# All mutable state -- database, generated secret, caches -- lives here.
VOLUME ["/config"]

ENV PORT=7373 \
    FANFARR_CONFIG_DIR=/config \
    PHX_SERVER=true

EXPOSE 7373

# Shallow on purpose: this reports whether the app is up and can reach its
# database. Plex or YouTube being unreachable is a dashboard concern, not a
# reason for Docker to restart the container.
HEALTHCHECK --interval=30s --timeout=5s --start-period=45s --retries=3 \
  CMD curl -fsS "http://localhost:${PORT}/health" || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["bin/server"]
