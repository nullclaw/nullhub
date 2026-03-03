# syntax=docker/dockerfile:1

# -- Stage 1: UI Build --------------------------------------------------------
FROM node:22-alpine AS ui-builder

WORKDIR /ui
COPY ui/package.json ui/package-lock.json ./
RUN npm ci
COPY ui/ ./
RUN npm run build

# -- Stage 2: Zig Build -------------------------------------------------------
FROM --platform=$BUILDPLATFORM alpine:3.23 AS builder

RUN apk add --no-cache zig musl-dev

WORKDIR /app
COPY build.zig build.zig.zon ./
COPY src/ src/

ARG TARGETARCH
RUN --mount=type=cache,target=/root/.cache/zig \
    --mount=type=cache,target=/app/.zig-cache \
    set -eu; \
    arch="${TARGETARCH:-}"; \
    if [ -z "${arch}" ]; then \
      case "$(uname -m)" in \
        x86_64) arch="amd64" ;; \
        aarch64|arm64) arch="arm64" ;; \
        *) echo "Unsupported host arch: $(uname -m)" >&2; exit 1 ;; \
      esac; \
    fi; \
    case "${arch}" in \
      amd64) zig_target="x86_64-linux-musl" ;; \
      arm64) zig_target="aarch64-linux-musl" ;; \
      *) echo "Unsupported TARGETARCH: ${arch}" >&2; exit 1 ;; \
    esac; \
    zig build -Dtarget="${zig_target}" -Doptimize=ReleaseSmall

# -- Stage 3: Runtime Base ----------------------------------------------------
FROM alpine:3.23 AS release-base

LABEL org.opencontainers.image.source=https://github.com/nullclaw/nullhub

RUN apk add --no-cache ca-certificates curl tzdata

RUN mkdir -p /opt/nullhub/ui /nullhub-data && chown -R 65534:65534 /nullhub-data

COPY --from=builder /app/zig-out/bin/nullhub /usr/local/bin/nullhub
COPY --from=ui-builder /ui/build /opt/nullhub/ui/build

ENV HOME=/nullhub-data
WORKDIR /opt/nullhub
EXPOSE 9800
ENTRYPOINT ["nullhub"]
CMD ["serve", "--host", "0.0.0.0", "--port", "9800"]

# Optional autonomous mode (explicit opt-in):
#   docker build --target release-root -t nullhub:root .
FROM release-base AS release-root
USER 0:0

# Safe default image (used when no --target is provided)
FROM release-base AS release
USER 65534:65534
