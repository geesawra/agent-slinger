# Build from the sidecar module root:
#   docker compose -f compose.yaml build
FROM golang:1.27 AS build

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build \
    -trimpath \
    -buildvcs=false \
    -ldflags='-s -w' \
    -o /out/agent-slinger-notify \
    ./cmd/agent-slinger-notify
RUN mkdir -m 0700 /out/state \
    && chown 65532:65532 /out/state

# Distroless static includes the system CA bundle used for verified HTTPS/WSS.
FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=build --chown=65532:65532 --chmod=0555 \
    /out/agent-slinger-notify /usr/local/bin/agent-slinger-notify
# Docker's named-volume copy-up preserves this owner and mode on first use.
COPY --from=build --chown=65532:65532 --chmod=0700 \
    /out/state /var/lib/agent-slinger-notify

USER 65532:65532
ENTRYPOINT ["/usr/local/bin/agent-slinger-notify"]
