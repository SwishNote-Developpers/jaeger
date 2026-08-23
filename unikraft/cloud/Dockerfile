# Rootfs for the Unikraft Cloud image.
#
# The binary is built outside this Dockerfile by ../build.sh, which hardlinks
# it into ./rootfs/ — building it here instead would mean shipping the Go
# toolchain and the jaeger-ui submodule into the build context for no gain.
#
# scratch is enough: the binary is CGO_ENABLED=0, so it has no DT_NEEDED and
# needs no libc. It does need the dynamic loader named by its PT_INTERP — Go's
# internal PIE linking leaves its relocations for ld.so to apply — so the loader
# is staged alongside it. See ../build-cloud.sh.
FROM scratch

COPY rootfs/jaeger /jaeger
COPY rootfs/config.yaml /config.yaml
COPY rootfs/lib/ld-linux-x86-64.so.2 /lib/ld-linux-x86-64.so.2
