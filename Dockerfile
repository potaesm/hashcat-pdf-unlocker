FROM rust:1.82-slim-bullseye AS gsg-builder

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    git \
    pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt

RUN git clone --depth 1 https://github.com/tehw0lf/gpu-scatter-gather.git

WORKDIR /opt/gpu-scatter-gather

RUN cargo build --release --no-default-features


FROM nvidia/cuda:11.8.0-devel-ubuntu20.04 AS hashcat-builder

ARG DEBIAN_FRONTEND=noninteractive
ARG HASHCAT_VERSION=7.1.2

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    ca-certificates \
    p7zip-full \
    wget \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt

RUN wget -O "hashcat-${HASHCAT_VERSION}.7z" "https://hashcat.net/files/hashcat-${HASHCAT_VERSION}.7z" \
    && 7z x "hashcat-${HASHCAT_VERSION}.7z" \
    && mv "hashcat-${HASHCAT_VERSION}" /opt/hashcat


FROM nvidia/cuda:11.8.0-devel-ubuntu20.04

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    ca-certificates \
    ocl-icd-libopencl1 \
    python3 \
    qpdf \
    && rm -rf /var/lib/apt/lists/*

COPY --from=hashcat-builder /opt/hashcat /opt/hashcat
COPY --from=gsg-builder /opt/gpu-scatter-gather/target/release/gpu-scatter-gather /usr/local/bin/gpu-scatter-gather
COPY vendor/pdf2hashcat.py /opt/pdf2hashcat/pdf2hashcat.py
COPY scripts/unlock-pdf.sh /usr/local/bin/unlock-pdf

RUN printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'cd /opt/hashcat' \
    'exec ./hashcat.bin "$@"' > /usr/local/bin/hashcat \
    && chmod +x /usr/local/bin/hashcat /usr/local/bin/unlock-pdf /opt/pdf2hashcat/pdf2hashcat.py

ENV INPUT_DIR=/data/input \
    OUTPUT_DIR=/data/output \
    WORK_DIR=/work \
    POTFILE_PATH=/work/hashcat.potfile \
    HASHCAT_PATH=/opt/hashcat

WORKDIR /data

ENTRYPOINT ["unlock-pdf"]
