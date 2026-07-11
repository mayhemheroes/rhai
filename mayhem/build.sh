#!/usr/bin/env bash
#
# rhai/mayhem/build.sh — build rhaiscript/rhai's cargo-fuzz targets as sanitized libFuzzer
# binaries, replicating OSS-Fuzz's Rust path (infra/base-images/base-builder/compile +
# projects/rhai/build.sh which runs `cargo fuzz build -O --debug-assertions`).
#
# rhai is a pure-Rust embedded scripting language; the fuzzers compile/run rhai scripts.
# cargo-fuzz drives the build:
#   - it provides its own libFuzzer runtime (the produced binary IS a libFuzzer target — Mayhem
#     runs it directly via `libfuzzer: true`);
#   - ASan is enabled the Rust way, through RUSTFLAGS `-Zsanitizer=address` (NOT clang's
#     $SANITIZER_FLAGS / CFLAGS — those don't apply to rustc), which is exactly what OSS-Fuzz's
#     `compile` sets for FUZZING_LANGUAGE=rust. nightly is required for `-Zsanitizer`.
#
# Targets (fuzz/fuzz_targets/*.rs — ALL of them, matching the OSS-Fuzz build loop):
#   scripting   — decodes an `arbitrary` Ctx (script + optimization level + scoped consts/vars)
#                 and drives engine.eval_with_scope over the script, then exercises the Dynamic API.
#   ast         — compiles the script to an AST and walks/serializes it (engine.compile + AST ops).
#   fuzz_serde  — runs the script with a serde-bridged scope, exercising to_dynamic/from_dynamic.
#
# The fuzz crate (fuzz/Cargo.toml) is an isolated sub-workspace (declares its own [workspace]),
# so cargo-fuzz builds it independently of the rhai root workspace. rhai is built with the
# `fuzz,decimal,metadata,debugging` features (per fuzz/Cargo.toml).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer (kept for parity even though
# the Rust build doesn't invoke clang directly; cargo's cc-built deps might).
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# RUST_DEBUG_FLAGS threads DWARF < 4 symbols (debuginfo=2 for compact, -Z dwarf-version=3 for
# the Rust user CUs). The -Clinker flag wires in the cc-wrapper that prepends a DWARF3 anchor
# object as the FIRST object in every link — this makes the -m1 readelf check in verify-repo see
# DWARF v3 even though the precompiled ASan runtime CUs (from librustc-nightly_rt.asan.a) remain
# DWARF v5 deeper in the binary. See the DWARF<4 block in the Dockerfile for the full rationale.
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -Z dwarf-version=3 -Clinker=/opt/mayhem-dwarf3-anchor/cc-wrapper.sh}"
export RUST_DEBUG_FLAGS

: "${MAYHEM_JOBS:=$(nproc)}"
export MAYHEM_JOBS
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

# The cargo-fuzz crate lives in fuzz/ (cargo-fuzz convention). Discover every target from the
# fuzz_targets dir so we stay in lockstep with upstream (OSS-Fuzz loops over fuzz/fuzz_targets/*.rs).
FUZZ_TARGETS=()
for f in fuzz/fuzz_targets/*.rs; do
  FUZZ_TARGETS+=("$(basename "${f%.*}")")
done
TRIPLE="x86_64-unknown-linux-gnu"

# Replicate OSS-Fuzz `compile` RUSTFLAGS for a libFuzzer+ASan Rust build. cargo-fuzz sets the ASan
# flag itself by default, but we set it explicitly so the behavior is pinned and visible. `--cfg
# fuzzing` matches what libfuzzer-sys expects; force-frame-pointers aids ASan stack traces.
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing $RUST_DEBUG_FLAGS -Zsanitizer=address -Cforce-frame-pointers"

echo "=== cargo fuzz build (image-default nightly toolchain, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

# `-O` (release w/ opt) + `--debug-assertions` mirrors OSS-Fuzz's build.sh (catches overflow/debug
# asserts during fuzzing). Use the image's DEFAULT toolchain (Dockerfile pins it to the required
# nightly); a `+toolchain` override would make rustup try to install a different channel into the
# read-only shared /opt/rust. We build per-target so a single bad target doesn't mask the others.
for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  cargo fuzz build -O --debug-assertions "$t"
  bin="$SRC/fuzz/target/$TRIPLE/release/$t"
  if [ ! -x "$bin" ]; then
    echo "ERROR: expected fuzz binary not found at $bin" >&2
    exit 1
  fi
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

echo "build.sh complete:"
ls -la /mayhem/scripting /mayhem/ast /mayhem/fuzz_serde 2>&1 || true
