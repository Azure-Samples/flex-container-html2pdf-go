FROM golang:1.27.0-bookworm@sha256:ded31c68586d2e49e760acc2e65a884b23d032e9bbbed0ae0c55abd3fcaf4452 AS build

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN go test -count=1 ./...
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -mod=readonly -trimpath -ldflags="-s -w" -o /out/app .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go test -mod=readonly -c -o /out/pdf.test .

FROM debian:bookworm-slim@sha256:7ff6ba31527b9e336162fa061746c366c4b2032f4d2cff2078bea43f78efe3f8 AS runtime

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        chromium-headless-shell \
        chromium-sandbox \
        fontconfig \
        fonts-liberation \
        fonts-noto-color-emoji \
        fonts-noto-core \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --gid 10001 app \
    && useradd --uid 10001 --gid 10001 --create-home \
        --home-dir /home/app --shell /usr/sbin/nologin app \
    && mkdir -p /home/site/wwwroot /home/app/.cache /home/app/.config \
    && chown -R 10001:10001 /home/app /home/site/wwwroot

ENV CHROMIUM_PATH=/usr/bin/chromium-headless-shell \
    HOME=/home/app \
    XDG_CACHE_HOME=/home/app/.cache \
    XDG_CONFIG_HOME=/home/app/.config

WORKDIR /home/site/wwwroot

FROM runtime AS integration

COPY --from=build /out/pdf.test /tmp/pdf.test
RUN chmod 0555 /tmp/pdf.test
USER 10001:10001
ENTRYPOINT ["/tmp/pdf.test"]

FROM runtime AS final

COPY --from=build /out/app ./app
RUN chmod 0555 ./app
COPY host.json ./
USER 10001:10001
ENTRYPOINT ["/home/site/wwwroot/app"]
