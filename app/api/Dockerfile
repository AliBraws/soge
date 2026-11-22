# syntax=docker/dockerfile:1
# Multi-arch (linux/amd64 + linux/arm64) WITHOUT QEMU: Go cross-compiles on the
# build platform, the runtime stage has no RUN step.
FROM --platform=$BUILDPLATFORM golang:1.27-alpine AS build
ARG TARGETOS TARGETARCH
WORKDIR /src
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download && go mod verify
COPY . .
RUN --mount=type=cache,target=/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -buildvcs=false -ldflags="-s -w" -o /out/soge .

# RDS CA bundle for sslmode=verify-full (TLS 1.3 to Aurora).
FROM --platform=$BUILDPLATFORM alpine:3.24 AS certs
ADD https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem /rds-global-bundle.pem

# distroless/static (Debian 13): no shell, no package manager, non-root (65532).
FROM gcr.io/distroless/static-debian13:nonroot
COPY --from=certs --chmod=0444 /rds-global-bundle.pem /etc/ssl/certs/rds-global-bundle.pem
COPY --from=build /out/soge /soge
USER 65532:65532
EXPOSE 8443
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 CMD ["/soge", "healthcheck"]
ENTRYPOINT ["/soge"]
CMD ["serve"]
