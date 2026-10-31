# Satu image: build PWA (Vue) → tanam ke binary Go → jalankan di alpine.

FROM node:22-alpine AS web
WORKDIR /src/web
COPY web/package.json web/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY web/ ./
RUN mkdir -p ../server/internal/webui/dist && npm run build

FROM golang:1.24-alpine AS server
WORKDIR /src/server
COPY server/go.mod server/go.sum ./
RUN go mod download
COPY server/ ./
COPY --from=web /src/server/internal/webui/dist ./internal/webui/dist
ARG VERSION=dev
RUN CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o /out/aitodo ./cmd/server

FROM alpine:3.20
RUN apk add --no-cache ca-certificates tzdata && adduser -D -H -u 1000 app && mkdir /data && chown app:app /data
COPY --from=server /out/aitodo /usr/local/bin/aitodo
ENV DATA_DIR=/data ADDR=0.0.0.0:8080
USER app
VOLUME ["/data"]
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s CMD wget -qO- http://127.0.0.1:8080/api/health || exit 1
ENTRYPOINT ["aitodo"]
