FROM golang:1.22 AS builder

WORKDIR /src

COPY go.mod ./
COPY cmd ./cmd
COPY internal ./internal

ARG APP_VERSION=dev
ARG GIT_SHA=local
ARG BUILD_TIME=unknown

RUN CGO_ENABLED=0 GOOS=linux go build \
	-ldflags="-s -w" \
	-o /out/release-api ./cmd/release-api

FROM gcr.io/distroless/static-debian12

WORKDIR /app

COPY --from=builder /out/release-api /app/release-api

ARG APP_VERSION=dev
ARG GIT_SHA=local
ARG BUILD_TIME=unknown

ENV APP_NAME=release-api \
	APP_ENV=dev \
	APP_PORT=8080 \
	LOG_LEVEL=info \
	FEATURE_CACHE_WARM=true \
	APP_VERSION=${APP_VERSION} \
	GIT_SHA=${GIT_SHA} \
	BUILD_TIME=${BUILD_TIME}

EXPOSE 8080

ENTRYPOINT ["/app/release-api"]
