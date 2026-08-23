#!/usr/bin/env bash
# Build the Jaeger binary in the shape Unikraft's ELF loader accepts, and stage
# it for both the local qemu target (Kraftfile) and Unikraft Cloud
# (cloud/Kraftfile). See README.md for why each step is here.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
out="$here/rootfs/jaeger"
interp=/lib/ld-linux-x86-64.so.2

cd "$repo"

# go build skips rewriting an output whose embedded build ID already matches, and
# patching PT_INTERP does not change the build ID — so a binary left from a
# previous run would be silently kept as current. Start clean.
rm -f "$out"

CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -trimpath \
    -buildmode=pie \
    -ldflags "-s -w" \
    -o "$out" \
    ./cmd/jaeger

# Unikraft's ELF loader rejects a non-PIE outright, and Go's -buildmode=pie uses
# internal linking, which leaves the image's relocations for the dynamic loader
# to apply. So the loader has to be there: PT_INTERP names a path inside the
# rootfs, and the loader is staged at it. A CGO_ENABLED=0 build has no DT_NEEDED
# entries, so ld.so has nothing to resolve — it only relocates and hands over.
patchelf --set-interpreter "$interp" "$out"

# The loader the build host's own PIEs use, which is self-contained.
host_interp="$(readelf -l "$(command -v env)" | sed -n 's/.*interpreter: \(.*\)\]/\1/p')"
[ -n "$host_interp" ] || { echo "error: could not determine the host's ELF interpreter" >&2; exit 1; }
mkdir -p "$here/rootfs/lib"
install -m 0755 "$host_interp" "$here/rootfs/lib/ld-linux-x86-64.so.2"

if readelf -d "$out" 2>/dev/null | grep -qi needed; then
    echo "error: $out links against a shared library; the bare loader is not enough" >&2
    readelf -d "$out" | grep -i needed >&2
    exit 1
fi
readelf -l "$out" | grep -q "$interp" || { echo "error: PT_INTERP was not set to $interp" >&2; exit 1; }

# The Docker build context cannot reach outside cloud/, so stage the rootfs there
# as hardlinks rather than copies — the binary is ~80MB.
mkdir -p "$here/cloud/rootfs/lib"
ln -f "$here/rootfs/jaeger"                    "$here/cloud/rootfs/jaeger"
ln -f "$here/rootfs/config.yaml"               "$here/cloud/rootfs/config.yaml"
ln -f "$here/rootfs/lib/ld-linux-x86-64.so.2"  "$here/cloud/rootfs/lib/ld-linux-x86-64.so.2"

printf 'built %s (%s bytes), interpreter %s staged from %s\n' \
    "$out" "$(stat -c %s "$out")" "$interp" "$host_interp"
