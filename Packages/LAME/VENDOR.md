# Vendored: LAME 3.100 (libmp3lame)

MP3 encoder used for the "Download MP3" export. iOS has no system MP3
encoder; LAME is the standard one.

- Upstream: LAME 3.100 (`lame_3.100.orig.tar.gz`, Debian source archive,
  fetched 2026-10-03; identical to the SourceForge 3.100 release).
- License: **LGPL-2.0-or-later** (see `COPYING` in the upstream tarball).
  The app is AGPL-3.0-or-later; LGPL components linked into an AGPL work
  keep their license, credited in `NOTICE`.
- Only `libmp3lame/` is vendored (the encoder library). Not vendored:
  `frontend/` (CLI), `mpglib/` (decoder), `Dshow/`, `ACM/`, `i386/` and
  `vector/` (x86 NASM/SIMD; iOS is ARM — all call sites are guarded by
  `HAVE_XMMINTRIN_H`, left undefined).

## Layout (`Sources/CLAME/`)

- The 20 `libmp3lame/*.c` encoder sources + their internal headers.
- `vector/lame_intrin.h` (declarations only; implementations are x86-only).
- `interface.h` (from `mpglib/`; needed by the preprocessor in
  `mpglib_interface.c`, which compiles to an empty unit without
  `HAVE_MPGLIB` — the app encodes only, never decodes).
- `config.h`: minimal replacement for the autoconf-generated `config.h`.
  Only the `HAVE_*` macros the sources test plus the `ieee754_*` typedefs
  from `config.h.in`. Enabled via `-DHAVE_CONFIG_H` in `Package.swift`.
- `include/lame.h`: the public header (Swift `import CLAME`).
- `lame.h` (target root): byte-identical duplicate so the quoted
  `#include "lame.h"` in the C sources resolves without relying on
  SwiftPM's include-path behavior.

## Swift API surface

`import CLAME` exposes the `lame_*` C API. The app's `MP3Encoder` (in
`Sources/App/`) uses: `lame_init`, `lame_set_in_samplerate`,
`lame_set_num_channels`, `lame_set_brate`, `lame_set_quality`,
`lame_init_params`, `lame_encode_buffer_interleaved`,
`lame_encode_flush`, `lame_close`.
