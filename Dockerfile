# Build a static zedis-server and ship it in an empty image.
FROM debian:bookworm-slim AS build
ARG ZIG_VERSION=0.17.0
ARG ZIG_ARCH=x86_64
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz" \
    | tar -xJ -C /opt \
    && ln -s "/opt/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig
WORKDIR /src
COPY build.zig build.zig.zon LICENSE README.md ./
COPY src ./src
COPY tests ./tests
COPY bench ./bench
# -Dcpu=baseline keeps the binary portable across hosts.
RUN zig build -Doptimize=ReleaseSafe -Dcpu=baseline --prefix /out \
    && mkdir -p /out/data

FROM scratch
COPY --from=build /out/bin/zedis-server /zedis-server
COPY --from=build /out/bin/zedis-cli /zedis-cli
COPY --from=build /out/data /data
# zedis-server reads $PORT itself, so no shell is needed in the image.
ENV PORT=6379
EXPOSE 6379
VOLUME /data
ENTRYPOINT ["/zedis-server", "--bind", "0.0.0.0", "--dir", "/data", "--appendonly", "yes"]
