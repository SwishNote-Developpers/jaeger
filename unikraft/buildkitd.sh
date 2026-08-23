#!/usr/bin/env bash
# Start the rootless BuildKit daemon that `unikraft build` needs, and print the
# BUILDKIT_HOST to use. Idempotent: if something is already listening on the
# socket, it just prints the address.
#
# `unikraft build` looks for Docker or BuildKit and will not build the erofs
# rootfs without one. Plain `buildkitd --rootless` refuses to start outside a
# user namespace and wants RootlessKit, which is not packaged here — `unshare`
# creates the namespace directly instead. BuildKit also needs an OCI runtime on
# PATH; NixOS has runc in the store but not in the profile.
set -euo pipefail

sock=${BUILDKIT_SOCK:-/tmp/buildkit/buildkitd.sock}
root=${BUILDKIT_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/jaeger-unikraft-buildkit}
log=${BUILDKIT_LOG:-${TMPDIR:-/tmp}/jaeger-unikraft-buildkitd.log}

if [ -S "$sock" ] && command -v buildctl >/dev/null 2>&1 && \
   buildctl --addr "unix://$sock" debug workers >/dev/null 2>&1; then
    echo "buildkitd already listening on $sock"
    echo "export BUILDKIT_HOST=unix://$sock"
    exit 0
fi
if [ -S "$sock" ]; then
    echo "socket $sock already exists; assuming a daemon owns it" >&2
    echo "export BUILDKIT_HOST=unix://$sock"
    exit 0
fi

runc="$(command -v runc || true)"
if [ -z "$runc" ]; then
    runc="$(ls /nix/store/*runc-*/bin/runc 2>/dev/null | head -1 || true)"
fi
[ -n "$runc" ] || { echo "error: no runc found; try nix-shell -p runc" >&2; exit 1; }

mkdir -p "$(dirname "$sock")" "$root"

# --oci-worker-snapshotter native: overlayfs needs privileges we do not have.
# --oci-worker-no-process-sandbox: required when the daemon is already confined
#   to a user namespace it did not create itself.
nohup env PATH="$(dirname "$runc"):$PATH" \
    unshare --user --map-root-user --mount --pid --fork \
    buildkitd \
        --rootless \
        --addr "unix://$sock" \
        --oci-worker-snapshotter native \
        --oci-worker-no-process-sandbox \
        --root "$root" \
    > "$log" 2>&1 &

for _ in $(seq 1 40); do
    [ -S "$sock" ] && break
    sleep 0.25
done
[ -S "$sock" ] || { echo "error: buildkitd did not come up; see $log" >&2; exit 1; }

echo "buildkitd started (log: $log)"
echo "export BUILDKIT_HOST=unix://$sock"
