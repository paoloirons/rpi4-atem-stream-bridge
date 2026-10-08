# Build the small Rust control service for the Raspberry Pi's ARM64 architecture.
FROM rust:1-bookworm AS builder
WORKDIR /src
COPY Cargo.toml ./
COPY src ./src
RUN cargo build --release

# FFplay renders the selected SRT feed in a fullscreen SDL window on each HDMI display.
FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg libsdl2-2.0-0 ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /src/target/release/rpi-srt-atem /usr/local/bin/rpi-srt-atem
ENV MEDIAMTX_API=http://mediamtx:9997 \
    RTSP_BASE=rtsp://mediamtx:8554 \
    DISPLAY=:0 \
    XAUTHORITY=/tmp/.Xauthority
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/rpi-srt-atem"]
