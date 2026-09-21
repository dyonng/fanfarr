# Base images are pinned by digest-bearing date tags so a rebuild of an old
# commit produces the same image. The two must stay in step: a release built
# against one glibc will not run on another, so bump them together.
ARG ELIXIR_IMAGE=hexpm/elixir:1.19.6-erlang-27.3.4.16-debian-bookworm-20260824-slim
ARG RUNNER_IMAGE=debian:bookworm-20260824-slim

# Declared before the first FROM, so it reaches the ffmpeg stage below; a build
# argument is only global if it is written above every stage.
ARG FFMPEG_VERSION=9.0.2

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

# The commit this image is built from, baked in at compile time so a running
# container cannot misreport itself and the release needs no build-related env
# at runtime. Declared here rather than at the top of the file so it only
# invalidates the compile layers, not the dependency cache.
ARG BUILD_REF=""
ENV BUILD_REF=$BUILD_REF

# Strict, and BEFORE assets.deploy: that alias compiles too, and a second
# compile afterwards is a no-op that would catch nothing. A warning here is a
# module that will not exist at runtime -- Req was once exactly that -- so it
# has to fail the build rather than ship.
RUN mix compile --warnings-as-errors

# Digests and gzips static assets into priv/static.
RUN mix assets.deploy

# runtime.exs is read when the container starts, not now, so it is copied
# after compilation.
COPY config/runtime.exs config/
COPY rel rel
RUN mix release

# ffmpeg is built here rather than installed from Debian, because Debian's
# package is 492 MB across 233 dependencies -- libllvm15 (115 MB), Mesa (25 MB),
# flite speech synthesis (28 MB), Intel's Media SDK (27 MB), the Z3 solver
# (23 MB), librsvg, libcodec2, x265 -- and this app can reach none of it. It
# calls ffmpeg for four things and nothing else: EBU R128 loudness, a trim with
# fades, decoding to PCM for the waveform, and the mp3 transcode yt-dlp asks
# for. The configure line is that list, plus what reading an mp3, an m4a or a
# webm needs.
#
# The version is pinned so a rebuild is reproducible. A component left out here
# fails at runtime rather than at build time, so the suite's cutter, normaliser
# and waveform tests are what hold this line honest: between them they make
# every call the app makes.
#
# The network protocols are kept deliberately. The app itself only ever hands
# ffmpeg a local file, but yt-dlp is the least predictable part of this stack
# and delegates to ffmpeg when it feels like it; two megabytes buys immunity to
# that changing under us.
# The network protocols are kept deliberately. The app itself only ever hands
# ffmpeg a local file, but yt-dlp is the least predictable part of this stack
# and delegates to ffmpeg when it feels like it; two megabytes buys immunity to
# that changing under us.
#
# The mov family of muxers is here for a subtler reason, and it is the one that
# bit: yt-dlp passes `-movflags +faststart` on an mp3, an option belonging to a
# muxer it is not using, and ffmpeg only tolerates that when the muxer that
# defines the option is compiled in. Leaving mov out made every download fail
# at the post-processing step with "Option not found" -- found by running the
# real yt-dlp against the real image rather than by reading the configure line.
FROM ${RUNNER_IMAGE} AS ffmpeg

# Re-declared, which is how a global build argument crosses into a stage.
ARG FFMPEG_VERSION

RUN apt-get update -y \
  && apt-get install -y --no-install-recommends \
     build-essential pkg-config nasm libmp3lame-dev libssl-dev \
     ca-certificates curl xz-utils \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src

RUN set -eux; \
  curl -fsSL -o ffmpeg.tar.xz "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"; \
  tar -xJf ffmpeg.tar.xz; \
  mv "ffmpeg-${FFMPEG_VERSION}" ffmpeg

WORKDIR /usr/src/ffmpeg

RUN set -eux; \
  ./configure \
    --prefix=/opt/ffmpeg \
    --disable-everything \
    --disable-autodetect \
    --disable-doc \
    --disable-debug \
    --disable-programs \
    --enable-ffmpeg \
    --enable-ffprobe \
    --enable-small \
    --enable-libmp3lame \
    --enable-openssl \
    --enable-protocol=file,pipe,http,https,tcp,tls \
    --enable-demuxer=mp3,mov,matroska,ogg,wav,flac,hls \
    --enable-muxer=mp3,wav,pcm_s16le,mov,mp4,m4a,null \
    --enable-parser=aac,flac,mp3,opus,vorbis \
    --enable-decoder=aac,flac,mp3,mp3float,opus,vorbis,pcm_s16le \
    --enable-encoder=libmp3lame,pcm_s16le \
    --enable-filter=afade,aformat,anull,anullsink,aresample,asetpts,astats,atrim,ebur128,loudnorm,volume; \
  make -j"$(nproc)"; \
  make install

FROM ${RUNNER_IMAGE} AS runner

# gosu: drops from root to the requested PUID/PGID in the entrypoint.
# libstdc++6/libgcc-s1: runtime libraries for the compiled exqlite NIF.
# libmp3lame0: the one library the ffmpeg build above links against rather
#   than compiling in.
# tzdata: the zone database TZ is resolved against. debian:*-slim does not
#   ship it, and glibc answers a TZ it cannot resolve by using UTC and saying
#   nothing -- so without this, TZ=America/Toronto in the compose file is a
#   silent four-hour error on every timestamp in the dashboard. Fanfarr logs
#   the zone it resolved at boot so that failure is visible if it ever recurs.
RUN apt-get update -y \
  && apt-get install -y --no-install-recommends \
     ca-certificates libmp3lame0 libstdc++6 libgcc-s1 openssl gosu curl tzdata \
  && rm -rf /var/lib/apt/lists/*

# The two binaries built above, and the licence they carry: this is an LGPL
# ffmpeg now, so its notice ships with it -- which is also why the usual
# "/usr/share/doc cleanup" is not done here, unlike most images this size.
COPY --from=ffmpeg /opt/ffmpeg/bin/ffmpeg /usr/local/bin/ffmpeg
COPY --from=ffmpeg /opt/ffmpeg/bin/ffprobe /usr/local/bin/ffprobe
COPY --from=ffmpeg /usr/src/ffmpeg/LICENSE.md /usr/share/doc/ffmpeg/LICENSE.md
COPY --from=ffmpeg /usr/src/ffmpeg/COPYING.LGPLv2.1 /usr/share/doc/ffmpeg/COPYING.LGPLv2.1

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

# C.UTF-8 rather than a generated en_US.UTF-8. The locales package is 15.8 MB
# of data for languages this app never renders, and glibc has shipped C.UTF-8
# built in since 2.35. Elixir needs *a* UTF-8 locale -- the latin1 warning it
# once emitted was the absence of one, not the absence of this particular one.
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8

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
# The Host header is deliberately not localhost. Phoenix's generated force_ssl
# config excludes localhost specifically, so a healthcheck using it would keep
# passing while every real request was redirected away -- which is exactly how
# that bug reached a running container unnoticed. Checking under an ordinary
# host name exercises the same path a browser does.
HEALTHCHECK --interval=30s --timeout=5s --start-period=45s --retries=3 \
  CMD curl -fsS -H "Host: fanfarr.healthcheck" "http://127.0.0.1:${PORT}/health" || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["bin/server"]
