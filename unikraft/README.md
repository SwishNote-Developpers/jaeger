# Jaeger as a Unikraft unikernel

Packaging for running the Jaeger all-in-one binary as a unikernel, modelled on
[unikraft-cloud/examples/httpserver-go1.21](https://github.com/unikraft-cloud/examples/blob/main/httpserver-go1.21/Kraftfile).

Not part of the upstream Jaeger build. Nothing here is referenced by the
Makefile or CI.

## Status

Working on both targets.

* **Local (qemu), `Kraftfile`** — boots, serves, and answers queries, but only
  with `config-memory.yaml`; Badger cannot run here (see below). Verified end to
  end: a span posted to `:4318` comes back from
  `http://localhost:16686/api/v3/services`.
* **Unikraft Cloud, `cloud/Kraftfile`** — deployed to metro `sin` as instance
  `jaeger` on the persistent service `jaeger-otlp`, which publishes 443 to the
  OTLP/HTTP receiver and carries the `otlp.swishnote.com` domain. Badger lives on
  a 256MiB volume at `/data`. Verified: a span posted to 443 with the right SNI
  returns `200 {"partialSuccess":{}}`, and 50 spans survive both a restart and a
  full instance replacement — Badger reopens with `All 1 tables opened` and
  `Set nextTxnTs to 50`. The query port is deliberately not published, so
  read-back is only checked locally.

## Layout

    Kraftfile          local: spec v0.7, runtime base:latest, target qemu/x86_64
    rootfs/config.yaml minimal all-in-one config: OTLP in, Badger on /data, query
    rootfs/config-memory.yaml  local-only variant; memory storage instead of Badger
    rootfs/jaeger      the binary (built by build.sh, not checked in)
    rootfs/lib/        the dynamic loader, staged by build.sh
    rootfs/data/       mount point for the Badger volume
    cloud/Kraftfile    Unikraft Cloud: base-compat:latest, kraftcloud/x86_64
    cloud/Dockerfile   scratch image holding the staged rootfs
    cloud/rootfs/      hardlinks to ../rootfs (the Docker context cannot escape cloud/)
    build.sh           builds the binary and stages both rootfs trees
    buildkitd.sh       starts the rootless BuildKit daemon `unikraft build` needs
    DEPLOY.md          the runbook: prerequisites, deploy, verify, troubleshoot

## Build and run

    ./build.sh
    kraft run --rm -M 2048Mi -p 16686:16686 -p 4317:4317 -p 4318:4318 .

For Unikraft Cloud, and for verifying either target, see [DEPLOY.md](./DEPLOY.md).

## What the build has to get right

Four things, each found by a boot that failed:

1. **Static.** `scripts/makefiles/BuildBinaries.mk` already builds with
   `CGO_ENABLED=0`, so there is no libc to ship.
2. **Position-independent.** Unikraft's ELF loader rejects a non-PIE outright
   (`ELF executable is not position-independent!`), so `-buildmode=pie`.
3. **Ship the loader it asks for.** Go's `-buildmode=pie` links internally and
   emits a binary whose relocations the dynamic loader is expected to apply,
   naming that loader in `PT_INTERP` — on NixOS a `/nix/store` path that exists
   nowhere else. Deleting the header instead of satisfying it produces something
   that loads and then faults immediately: locally a `Unikraft Crash` at 1.1s, on
   Unikraft Cloud `killed by signal: 11/SIGSEGV` at 0.07s. `build.sh` therefore
   repoints `PT_INTERP` at `/lib/ld-linux-x86-64.so.2` and stages the host's own
   `ld.so` there. Because a `CGO_ENABLED=0` build has no `DT_NEEDED` entries, the
   bare loader is enough — it relocates and hands over, with nothing to resolve.

   The upstream example sidesteps this by building a genuine static PIE through
   the external linker (`-linkmode external -extldflags -static-pie`). That needs
   a C toolchain with static-pie support, which NixOS does not readily provide:
   its glibc ships no `rcrt1.o`, and neither `musl-gcc` nor `pkgsStatic.stdenv.cc`
   links one here.
4. **Do not trust a stale output.** `go build` skips rewriting an output binary
   whose embedded build ID already matches what it would produce, and patching
   `PT_INTERP` does not change the build ID. A patched binary left from a previous
   run is therefore kept as current, hiding a failed rebuild. `build.sh` removes
   the output first.

## Configuration notes

* **Badger needs a volume, and mmap.** The rootfs is read-only, so the database
  lives at `/data`, where a Unikraft Cloud volume is mounted. Badger mmaps its
  memtable, and the local target's initrd ramfs does not support mmap — it fails
  with `operation not supported` opening `/data/keys/00001.mem`. That is why the
  local target has its own memory-storage config. Retention is bounded by
  `ttl.spans` rather than by size, because Badger fails writes once the volume is
  full; lower it before anything else if the volume fills.
* **Bind 0.0.0.0.** Jaeger defaults to localhost, which is unreachable from
  outside the guest; `rootfs/config.yaml` sets every endpoint explicitly. Same
  reason `cmd/jaeger/Dockerfile` sets `JAEGER_LISTEN_HOST=0.0.0.0`.
* **OTLP/HTTP only.** The legacy jaeger/zipkin receivers, the Thrift UDP ports
  and the OTLP/gRPC listener on 4317 are all dropped. The client this serves
  selects `.with_http()` and its frontend proxies JSON to `/v1/traces`, so gRPC
  would be surface with no traffic behind it.
* **The service is persistent and owns the domain.** A service auto-created by
  `unikraft run` dies with its instance, and the next deploy invents a new name.
  `jaeger-otlp` is created explicitly, so the domain and its certificate survive
  redeploys. DNS points at the metro (`sin.unikraft.app`) rather than at any
  service, since the proxy routes on the request's domain.
* **UI.** The `jaeger-ui` submodule is uninitialised here, so the binary embeds
  the placeholder page and logs `ui assets not embedded in the binary`. Run
  `make build-ui` before `build.sh` for the real UI — it is embedded via
  `go:embed`, so it needs no rootfs entry either way.
* **Scale to zero, statefully.** The instance suspends after a minute idle and
  resumes on the next span, in under 100ms — the cold boot that created it took
  9.09s. `stateful=true` keeps its memory across the suspend, which Badger needs:
  it runs with `SyncWrites: false`, so a plain stop would drop whatever had not
  reached disk.
* **Memory sizing.** The default 64Mi is nowhere near enough; the ~80MB binary is
  itself loaded into guest memory. 2GiB is the working figure, and is also the
  per-instance ceiling on the current Unikraft Cloud quota.
* **Runtimes differ by target.** `base-compat` is published only for
  `kraftcloud/x86_64`; the local target uses `base`, the only runtime `kraft pkg
  pull` finds for `qemu/x86_64`.
