FROM rust:1.82-slim-bookworm AS gsg-builder

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    git \
    pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt

RUN git clone --depth 1 https://github.com/tehw0lf/gpu-scatter-gather.git \
    && git clone --depth 1 https://github.com/sighook/pdf2hashcat.git

WORKDIR /opt/gpu-scatter-gather

RUN cargo build --release --no-default-features


FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    ca-certificates \
    hashcat \
    ocl-icd-libopencl1 \
    pocl-opencl-icd \
    python3 \
    qpdf \
    && rm -rf /var/lib/apt/lists/*

COPY --from=gsg-builder /opt/gpu-scatter-gather/target/release/gpu-scatter-gather /usr/local/bin/gpu-scatter-gather
COPY --from=gsg-builder /opt/pdf2hashcat/pdf2hashcat.py /opt/pdf2hashcat/pdf2hashcat.py
COPY scripts/unlock-pdf.sh /usr/local/bin/unlock-pdf

RUN chmod +x /usr/local/bin/unlock-pdf /opt/pdf2hashcat/pdf2hashcat.py

ENV INPUT_DIR=/data/input \
    OUTPUT_DIR=/data/output \
    WORK_DIR=/work \
    POTFILE_PATH=/work/hashcat.potfile

WORKDIR /data

ENTRYPOINT ["unlock-pdf"]
