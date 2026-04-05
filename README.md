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

## Run with gpu-scatter-gather

Put an encrypted file under `input/`, then run:

```bash
docker compose run --rm \
  -e GSG_MASK='?1?1?1?1?1?1' \
  -e GSG_LOWERCASE=true \
  pdf-unlock /data/input/example.pdf
```

This generates 6 lowercase-letter candidates. The container prints the recovered password and writes the unlocked copy to `output/` while preserving the relative path under `input/`.

## Change the gpu-scatter-gather mask

Override the defaults at runtime:

```bash
docker compose run --rm \
  -e GSG_MASK='?1?1?1?1?1?1?1?1' \
  -e GSG_LOWERCASE=true \
  pdf-unlock /data/input/example.pdf
```

## How to use masks

`GSG_MASK` tells `gpu-scatter-gather` what kind of candidate passwords to generate.

### Basic idea

Each `?N` means:

- use charset `N` for this position

So:

- `?1?1?1?1?1?1` means 6 characters, all using charset 1
- `?1?2?1?2` means positions 1 and 3 use charset 1, while positions 2 and 4 use charset 2

This project's wrapper currently supports custom charsets `1` through `4`:

- `GSG_CHARSET1`
- `GSG_CHARSET2`
- `GSG_CHARSET3`
- `GSG_CHARSET4`

It also supports built-in charsets:

- `GSG_LOWERCASE=true` assigns lowercase letters to `charset 1`
- `GSG_UPPERCASE=true` assigns uppercase letters to `charset 1`
- `GSG_DIGITS=true` assigns digits to `charset 1`

In other words, the built-in switches in this wrapper all target `charset 1`.

### Important rule

If you set both a custom charset and a built-in charset for the same ID, the built-in one wins in the current wrapper logic. For example, if you set both `GSG_CHARSET1=abc123` and `GSG_LOWERCASE=true`, charset 1 will end up as lowercase only.

So when using `GSG_CHARSET1`, `GSG_CHARSET2`, `GSG_CHARSET3`, or `GSG_CHARSET4`, avoid setting conflicting built-in variables.

Also, the built-in charset switches conflict with each other in the current wrapper because they all target `charset 1`.

That means this is not valid if your intent is to combine them:

- `GSG_LOWERCASE=true`
- `GSG_UPPERCASE=true`
- `GSG_DIGITS=true`

In practice, the last one applied wins for `charset 1`, so they do not merge into one combined alphanumeric charset.

If you want lowercase + uppercase + digits together, define a custom charset explicitly instead of combining the built-in flags.

### Examples

6 lowercase letters:

```bash
docker compose run --rm \
  -e GSG_MASK='?1?1?1?1?1?1' \
  -e GSG_LOWERCASE=true \
  pdf-unlock /data/input/example.pdf
```

6 digits:

```bash
docker compose run --rm \
  -e GSG_MASK='?1?1?1?1?1?1' \
  -e GSG_DIGITS=true \
  pdf-unlock /data/input/example.pdf
```

4 lowercase letters followed by 2 digits:

```bash
docker compose run --rm \
  -e GSG_MASK='?1?1?1?1?2?2' \
  -e GSG_CHARSET1='abcdefghijklmnopqrstuvwxyz' \
  -e GSG_CHARSET2='0123456789' \
  pdf-unlock /data/input/example.pdf
```

6 lowercase alphanumeric characters:

```bash
docker compose run --rm \
  -e GSG_MASK='?1?1?1?1?1?1' \
  -e GSG_CHARSET1='abcdefghijklmnopqrstuvwxyz0123456789' \
  pdf-unlock /data/input/example.pdf
```

6 mixed-case alphanumeric characters:

```bash
docker compose run --rm \
  -e GSG_MASK='?1?1?1?1?1?1' \
  -e GSG_CHARSET1='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789' \
  pdf-unlock /data/input/example.pdf
```

What not to do for mixed-case alphanumeric:

```bash
docker compose run --rm \
  -e GSG_MASK='?1?1?1?1?1?1' \
  -e GSG_LOWERCASE=true \
  -e GSG_UPPERCASE=true \
  -e GSG_DIGITS=true \
  pdf-unlock /data/input/example.pdf
```

Alternate letter-digit pattern, such as `a1b2c3`:

```bash
docker compose run --rm \
  -e GSG_MASK='?1?2?1?2?1?2' \
  -e GSG_CHARSET1='abcdefghijklmnopqrstuvwxyz' \
  -e GSG_CHARSET2='0123456789' \
  pdf-unlock /data/input/example.pdf
```

### Mental model

Think of the mask as a template:

```text
?1?1?2?2
```

And think of the charsets as the allowed values for each placeholder:

```text
?1 = abcdefghijklmnopqrstuvwxyz
?2 = 0123456789
```

That template would generate candidates like:

```text
aa00
aa01
aa02
...
ab00
ab01
...
zz99
```

## Notes

- The only host mounts are `input/`, `output/`, and `work/`.
- `gpu-scatter-gather` is the only attack source wired into this container.
- `hashcat` mode is auto-detected from `qpdf --show-encryption`, but you can override it with `HASHCAT_MODE`.
- The default `gpu-scatter-gather` build uses `--no-default-features`, so it works without CUDA inside the image.
- If your Docker host is configured for GPU passthrough, uncomment `gpus: all` in `docker-compose.yml`.
