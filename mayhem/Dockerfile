# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile (SMALL form) — builds ON TOP of the org C/C++ base image
# (ghcr.io/mayhemheroes/base). The base provides debian + clang/llvm + libFuzzer + the
# identities + the build-contract ENV. rhai is a RUST crate (an embedded scripting language),
# and the base ships NO Rust toolchain, so this image installs rustup (nightly) + cargo-fuzz as
# root into a SHARED location (/opt/rust) usable by the non-root `mayhem` user, then runs
# build.sh + test.sh.
#
# Build (from the repo root):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] \
#       -t rhai-commit:test .

FROM ghcr.io/mayhemheroes/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); never bake it as ENV — an empty value
# breaks clang. build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH

# Sanitizer override: the base exports SANITIZER_FLAGS (ASan+UBSan, halting) as the default,
# but cargo-fuzz drives Rust instrumentation via RUSTFLAGS (-Zsanitizer=address), NOT $SANITIZER_FLAGS.
# Declared here for parity; build.sh wires ASan into RUSTFLAGS the cargo-fuzz way.
ARG SANITIZER_FLAGS
ARG MAYHEM_JOBS=

# Pin the nightly toolchain (cargo-fuzz needs nightly for `-Z` flags / -Zsanitizer=address).
# Mirrors OSS-Fuzz's base-builder-rust which pins a dated nightly.
ARG RUST_TOOLCHAIN=nightly-2025-09-05
ARG CARGO_FUZZ_VERSION=0.12.0

# Shared Rust install: CARGO_HOME/RUSTUP_HOME under /opt/rust, world-readable, so the non-root
# `mayhem` user can invoke cargo/rustc/cargo-fuzz without owning the toolchain.
ENV RUSTUP_HOME=/opt/rust/rustup \
    CARGO_HOME=/opt/rust/cargo \
    PATH=/opt/rust/cargo/bin:$PATH

USER root
RUN set -eux; \
    mkdir -p "$RUSTUP_HOME" "$CARGO_HOME"; \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --no-modify-path --profile minimal --default-toolchain "$RUST_TOOLCHAIN"; \
    rustup component add rust-src --toolchain "$RUST_TOOLCHAIN"; \
    cargo install cargo-fuzz --version "$CARGO_FUZZ_VERSION" --locked; \
    # The non-root `mayhem` user runs `cargo fuzz build`, which WRITES into CARGO_HOME (registry
    # cache, git checkouts). Toolchain dirs stay read-only; the cargo home must be group/other
    # writable so the build can populate the registry. (Build image, not a hardened runtime.)
    chmod -R a+rX /opt/rust; \
    chmod -R a+rwX "$CARGO_HOME/registry" "$CARGO_HOME/git" 2>/dev/null || true; \
    mkdir -p "$CARGO_HOME/registry" "$CARGO_HOME/git" && chmod -R a+rwX "$CARGO_HOME/registry" "$CARGO_HOME/git"; \
    rustc --version; cargo --version; cargo fuzz --version
USER root

# DWARF<4 gate workaround for Rust/cargo-fuzz (§6.2 item 10).
# Problem: cargo-fuzz links the Rust nightly ASan runtime archive
# (librustc-nightly_rt.asan.a) via --whole-archive, and that archive's
# objects (compiled by clang 21+ with DWARF v5) land FIRST in .debug_info
# before any user/std CUs. The -Z dwarf-version=3 RUSTFLAG only controls
# rustc's own CUs — it cannot retroactively lower the precompiled runtime.
# Solution (the Go-canary trick, adapted for Rust): compile a tiny stub with
# clang -gdwarf-3 and inject it as the FIRST object in every link via a
# cc-wrapper linker script (-Clinker=...). The wrapper prepends anchor.o to
# the linker command; since .debug_info CUs appear in linker-argument order,
# anchor.o's DWARF3 CU becomes offset 0 — the one verify-repo's -m1 reads.
RUN set -eux; \
    mkdir -p /opt/mayhem-dwarf3-anchor; \
    printf 'void __mayhem_dwarf3_anchor(void) __attribute__((visibility("hidden"),used));\nvoid __mayhem_dwarf3_anchor(void) {}\n' \
      > /opt/mayhem-dwarf3-anchor/anchor.c; \
    clang -g -gdwarf-3 -c /opt/mayhem-dwarf3-anchor/anchor.c \
      -o /opt/mayhem-dwarf3-anchor/anchor.o; \
    printf '#!/bin/bash\nexec cc /opt/mayhem-dwarf3-anchor/anchor.o "$@"\n' \
      > /opt/mayhem-dwarf3-anchor/cc-wrapper.sh; \
    chmod +x /opt/mayhem-dwarf3-anchor/cc-wrapper.sh; \
    chmod a+rX /opt/mayhem-dwarf3-anchor /opt/mayhem-dwarf3-anchor/anchor.o \
               /opt/mayhem-dwarf3-anchor/cc-wrapper.sh; \
    echo "DWARF3 anchor ready: $(readelf --debug-dump=info /opt/mayhem-dwarf3-anchor/anchor.o | grep -m1 Version:)"

USER mayhem

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl. .git history)
# is copied to /mayhem as `mayhem`; build.sh builds in place.
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

# Run rhai's real test suite at build time; a failing suite fails the image build.
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
