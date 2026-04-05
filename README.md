# hashcat-pdf-unlock

This project builds a container that combines:

- `pdf2hashcat` to extract PDF password hashes
- `hashcat` to crack the password
- `gpu-scatter-gather` to generate password candidates
- `qpdf` to inspect the PDF encryption and decrypt the file once the password is known

## How the tools work together

At a high level, the container does not try to "unlock" the PDF directly. It first converts the PDF's encryption data into a hash format that `hashcat` understands, then feeds candidate passwords into `hashcat` until one matches, and only then uses the recovered password to decrypt the original PDF.

### End-to-end flow

```text
Host machine
  |
  | docker compose run --rm pdf-unlock /data/input/example.pdf
  v
Container entrypoint: unlock-pdf
  |
  | 1. Read mounted PDF from /data/input
  |
  | 2. qpdf --show-encryption
  |    -> inspect PDF encryption revision
  |    -> choose hashcat mode such as 10400 / 10500 / 25400 / 10600 / 10700
  |
  | 3. pdf2hashcat.py example.pdf > /work/example.hash
  |    -> extract the PDF's password-verification data
  |    -> write a hashcat-compatible hash file
  |
  | 4. gpu-scatter-gather ... GSG_MASK ...
  |    -> generate candidate passwords on stdout
  |
  | 5. hashcat -m <mode> -a 0 /work/example.hash
  |    -> read candidates from stdin
  |    -> test each candidate against the extracted PDF hash
  |    -> store any hit in /work/hashcat.potfile
  |
  | 6. hashcat --show
  |    -> print the recovered password from the potfile
  |
  | 7. qpdf --password="<found>" --decrypt example.pdf /data/output/example.pdf
  |    -> write the unlocked PDF to the mounted output directory
  v
Host machine gets:
  - printed password in the terminal
  - unlocked PDF under output/
```

### What each tool is responsible for

- `pdf2hashcat` does not crack anything. It reads the encrypted PDF structure and converts the relevant encryption fields into the `$pdf$...` hash format that `hashcat` expects.
- `gpu-scatter-gather` does not know anything about PDFs. Its job is only to generate candidate passwords efficiently from a mask like `?1?1?1?1?1?1`.
- `hashcat` is the component that actually tests candidates against the extracted PDF hash and determines whether a candidate is correct.
- `qpdf` is used twice: first to inspect the PDF encryption so the wrapper can choose the correct `hashcat` mode, and later to decrypt the original PDF using the recovered password.

### Why the hashcat mode matters

`hashcat` needs to know which PDF encryption scheme it is attacking. Different PDF revisions map to different `hashcat` modes. The wrapper script calls `qpdf --show-encryption`, extracts the revision `R`, and maps it to a mode before cracking starts.

In practice the flow is:

- `R=2` -> `10400`
- `R=3` or `R=4` without AES -> `10500`
- `R=3` or `R=4` with AES -> `25400`
- `R=5` -> `10600`
- `R=6` -> `10700`

If this mapping is wrong, `hashcat` will test candidates against the wrong algorithm and never find the password even if the candidate generator is correct.

### Why gpu-scatter-gather is piped into hashcat

The wrapper uses a shell pipeline:

```text
gpu-scatter-gather ... | hashcat ...
```

That means candidate passwords are streamed directly into `hashcat` through standard input instead of being written out as a giant temporary wordlist first. Conceptually:

- `gpu-scatter-gather` produces `aaaaaa`, `aaaaab`, `aaaaac`, ...
- `hashcat` consumes each candidate immediately
- when a match is found, `hashcat` records it in the potfile

This keeps the container simple and avoids managing large intermediate files.

## Build

```bash
docker compose build
```

## Run with the default gpu-scatter-gather attack

Put an encrypted file under `input/`, then run:

```bash
docker compose run --rm pdf-unlock /data/input/example.pdf
```

By default this uses `gpu-scatter-gather` with the mask `?1?1?1?1?1?1` and `GSG_LOWERCASE=true`. The container prints the recovered password and writes the unlocked copy to `output/` while preserving the relative path under `input/`.

## Change the gpu-scatter-gather mask

Override the defaults at runtime:

```bash
docker compose run --rm \
  -e GSG_MASK='?1?1?1?1?1?1?1?1' \
  -e GSG_LOWERCASE=true \
  pdf-unlock /data/input/example.pdf
```

## Notes

- The only host mounts are `input/`, `output/`, and `work/`.
- `gpu-scatter-gather` is the only attack source wired into this container.
- `hashcat` mode is auto-detected from `qpdf --show-encryption`, but you can override it with `HASHCAT_MODE`.
- The default `gpu-scatter-gather` build uses `--no-default-features`, so it works without CUDA inside the image.
- If your Docker host is configured for GPU passthrough, uncomment `gpus: all` in `docker-compose.yml`.
