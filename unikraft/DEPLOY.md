# Deploying Jaeger to Unikraft Cloud

Runbook for the `cloud/` target. For the local qemu target see
[Running locally](#running-locally) at the end; for *why* the build looks the
way it does, see [README.md](./README.md).

Everything below was run against metro `sin` with the namespace
`okuyama-hiroyuki`. Substitute your own.

## Prerequisites

| Tool | Purpose | Check |
| --- | --- | --- |
| `unikraft` | Unikraft Cloud CLI | `unikraft quotas` prints your user and limits |
| `buildkitd`, `buildctl` | builds the erofs rootfs from `cloud/Dockerfile` | `./buildkitd.sh` |
| `runc` | BuildKit's OCI worker | `./buildkitd.sh` finds it in the nix store if it is not on PATH |
| `go`, `patchelf`, `readelf` | `build.sh` | — |

`unikraft quotas` also tells you what the instance has to fit inside. At the
time of writing: 16 instances, 1 vCPU each, 4.0GiB memory, 1.0GiB of volume
space.

## 1. Create the volume

Traces live in Badger on a persistent volume, so the volume has to exist before
the first deploy. Once created it outlives instances — skip this step on
redeploys.

    unikraft volumes create --name jaeger-data --size 256 --metro sin

`--size` is in MiB. Check what the metro has left first: `unikraft quotas` shows
both the per-metro volume budget and the per-volume ceiling.

## 2. Create the service

The service group owns the published ports and the domain, and a named one is
persistent: it survives `instances rm`, so the hostname the DNS points at stays
put across redeploys. A service auto-created by `unikraft run` does not — it is
deleted with its instance and the next deploy invents a new name, breaking any
CNAME aimed at it.

    unikraft services create --name jaeger-otlp --metro sin \
        --services 443:4318/http+tls \
        --domains otlp.swishnote.com

Only 443 is published, forwarding to the OTLP/HTTP receiver on 4318. There is no
4317: nothing sends OTLP/gRPC here, so the listener would be surface with no
traffic behind it.

Attaching a custom domain creates a certificate in `pending` state. It is issued
once the domain resolves to Unikraft Cloud — point a CNAME at the metro itself:

    otlp.swishnote.com.  CNAME  sin.unikraft.app.

The metro name is the target, not the service's own
`jaeger-otlp.sin.unikraft.app`. Both resolve to the same proxy
(`proxy.sin.unikraft.cloud`), because the proxy picks the service from the
domain in the request rather than from the name it was reached by — so the
metro-level name is the one that does not depend on the service at all.

`--services` and `--domains` **replace** rather than append. `unikraft services
edit <name> --services 443:4318/http+tls` drops every other port; pass the whole
set each time, and use `--dry-run` first to see the resulting list.

## 3. Start BuildKit

`unikraft build` refuses to build the rootfs without a Docker or BuildKit
daemon. `buildkitd.sh` starts a rootless one and is safe to re-run:

    ./buildkitd.sh
    export BUILDKIT_HOST=unix:///tmp/buildkit/buildkitd.sock

It prints the `export` line to copy. The daemon is not a service — it dies with
your session, so expect to run this again next time.

## 4. Build the binary

    ./build.sh

Writes `rootfs/jaeger` and `rootfs/lib/ld-linux-x86-64.so.2`, then hardlinks
both plus `rootfs/config.yaml` into `cloud/rootfs/`, which is what the Docker
build context can see. The script fails loudly if the binary comes out linked
against a shared library or without the expected `PT_INTERP` — both of which
produce a unikernel that loads and then immediately segfaults.

For the real UI rather than the placeholder page, initialise the submodule and
build the assets first; they are embedded into the binary by `go:embed`:

    git submodule update --init --recursive
    make build-ui
    ./build.sh

## 5. Build and push the image

    cd cloud
    unikraft build . --output okuyama-hiroyuki/jaeger:latest

**The namespace is not optional.** Passing a bare `jaeger:latest` resolves to
`unikraft.io/official/jaeger`, which rejects the push:

    401 Unauthorized
    unauthorized to access repository: official/jaeger, action: push

Confirm the image landed:

    unikraft images ls | grep jaeger

## 6. Deploy

    unikraft run \
        --metro sin \
        --image okuyama-hiroyuki/jaeger:latest \
        --name jaeger \
        -m 2048M \
        -v jaeger-data:/data \
        --service jaeger-otlp

Notes on the flags:

* `-v jaeger-data:/data` mounts the volume where `config.yaml` points Badger.
  Without it the instance still boots, but writes go to the read-only rootfs and
  storage initialisation fails.

* `-m` is lowercase, and the suffix is `M`/`G` — `-M` is not a flag and `2048Mi`
  is rejected as an invalid suffix.
* `--service jaeger-otlp` joins the service from step 2 instead of creating a
  throwaway one. Use `-p` only for a scratch deployment you do not intend to
  point DNS at.
* 2048M is the working figure. The ~80MB binary is loaded into guest memory and
  otelcol's Go heap sits on top; the default is far too small.
* `--metro` belongs to `run` only. `unikraft instances …` and `unikraft images
  …` do not accept it and will fail with `unknown flag --metro`.

The instance inherits the service's ports and domains, so the reachable host is
`otlp.swishnote.com` (once DNS is switched) and `jaeger-otlp.sin.unikraft.app`.

## 7. Verify

State first — `starting` means it has not finished booting, `stopped` means it
booted and exited:

    unikraft instances get jaeger

Then the logs. A healthy start ends with `Everything is ready. Begin running and
processing data.`:

    unikraft instances logs jaeger --tail 50

Then post a span.

While the certificate is still `pending` and DNS has not been switched, aim curl
at the metro's address but keep the service's own domain as the SNI, so the
proxy can route it — that checks the whole path before any DNS change:

    IP=$(dig +short sin.unikraft.app | tail -1)
    curl -k --resolve otlp.swishnote.com:443:$IP \
        https://otlp.swishnote.com/v1/traces ...

`-k` is only for the pending certificate. Once DNS is switched and the
certificate is issued, drop both flags and use the hostname directly:

    FQDN=otlp.swishnote.com
    NOW=$(date +%s)000000000

    curl -sS -w '\nHTTP %{http_code}\n' -X POST "https://$FQDN/v1/traces" \
        -H 'Content-Type: application/json' -d '{
      "resourceSpans": [{
        "resource": {"attributes": [
          {"key": "service.name", "value": {"stringValue": "smoketest"}}]},
        "scopeSpans": [{"spans": [{
          "traceId": "5b8efff798038103d269b633813fc60c",
          "spanId": "eee19b7ec3c1b174",
          "name": "hello-from-unikraft",
          "kind": 1,
          "startTimeUnixNano": "'$NOW'",
          "endTimeUnixNano": "'$NOW'"
        }]}]
      }]
    }'

`HTTP 200` with `{"partialSuccess":{}}` means the span was accepted — accepted
by the receiver, not yet written. The pipeline's `batch` processor holds spans
briefly, so a query issued immediately after the post can still come back empty.
Give it a second and retry before concluding anything is wrong.

Reading it back needs the query port, which the deployment above does not
publish. Either add `-p 443:16686/http+tls` and query
`https://$FQDN/api/v3/services`, or check the round trip locally — see
[Running locally](#running-locally).

## 8. Redeploy after a change

There is no in-place image swap. Rebuild, push, and replace the instance:

    ./build.sh
    cd cloud && unikraft build . --output okuyama-hiroyuki/jaeger:latest
    unikraft instances rm jaeger
    unikraft run --metro sin --image okuyama-hiroyuki/jaeger:latest \
        --name jaeger -m 2048M -v jaeger-data:/data --service jaeger-otlp

The service is persistent, so the domain, the certificate and the hostname all
survive; nothing in DNS has to change. Traces survive too: they live on the volume, not in the instance. Removing the
instance does not remove the volume.

## 9. Stop and clean up

    unikraft instances stop jaeger      # keep it, stop billing for runtime
    unikraft instances start jaeger     # bring it back
    unikraft instances rm jaeger        # delete the instance; the service stays
    unikraft services rm jaeger-otlp    # releases the domain and certificate
    unikraft images rm okuyama-hiroyuki/jaeger:latest
    unikraft volumes rm jaeger-data     # deletes the traces too

## Troubleshooting

Each of these was hit while getting the first deploy working.

**`Application exited with 0xb (killed by signal: 11/SIGSEGV)` at ~0.07s**

The binary's `PT_INTERP` does not point at a loader that exists in the rootfs.
Go's `-buildmode=pie` links internally and leaves the image's relocations for
the dynamic loader to apply, so removing or breaking that header yields a
binary that loads and then faults before reaching `main`. `build.sh` handles
this; if you build by hand, do not skip the `patchelf --set-interpreter` step or
the `ld-linux-x86-64.so.2` staged next to it.

**`buildkit not found; please start a docker or buildkit daemon`**

Step 3 was skipped, or `BUILDKIT_HOST` is not exported into the shell running
`unikraft build`.

**`buildkitd: rootless mode requires to be executed as the mapped root in a user namespace`**

`buildkitd --rootless` was started outside a user namespace. Use
`./buildkitd.sh`, which wraps it in `unshare`.

**`buildkitd: no worker found, rebuild the buildkit daemon?`**

No OCI runtime on PATH. `./buildkitd.sh` locates one in the nix store;
`nix-shell -p runc` also works.

**`401 unauthorized to access repository: official/jaeger`**

`--output` was given without a namespace. See step 5.

**`parsing arguments: unknown flag --metro`**

`--metro` is only valid on `unikraft run`. The `instances` and `images`
subcommands operate across metros.

**`--memory: invalid suffix: 'mi'`**

Use `-m 2048M`, not `-m 2048Mi`.

**`While opening memtable: /data/keys/00001.mem err: ... operation not supported`**

Badger mmaps its memtable and the filesystem under `/data` does not support it.
On Unikraft Cloud this means the volume was not mounted — check for
`-v jaeger-data:/data` and that `unikraft instances get jaeger` lists the volume.
On the local qemu target it is expected: the initrd's ramfs has no mmap, so use
`-- --config /config-memory.yaml`.

**Instance state goes `starting` → `stopped` with no application logs**

The guest crashed before Jaeger produced output. `unikraft instances logs`
shows the unikernel's own exit line; compare against the SIGSEGV case above.

## Running locally

The qemu target needs no cloud account and publishes the query port, so it is
the quicker way to check a change end to end:

    ./build.sh
    kraft run --rm -d -M 2048Mi \
        -p 16686:16686 -p 4317:4317 -p 4318:4318 -n jaeger-uk . \
        -- --config /config-memory.yaml
    kraft logs jaeger-uk

The `--config` override is required. The default `config.yaml` puts traces in
Badger, which mmaps its memtable; the initrd's ramfs does not support mmap, so
Badger fails to open with `operation not supported` on
`/data/keys/00001.mem`. `config-memory.yaml` uses the memory backend instead,
which is enough for smoke-testing a build.

Post a span to `http://localhost:4318/v1/traces` as in step 7, then read it
back:

    curl -sS http://localhost:16686/api/v3/services
    # {"services":["smoketest"]}

If that returns `{"services":[]}`, the batch processor has not flushed yet;
retry rather than treating it as a failure.

Note `kraft run` takes `-M 2048Mi` while `unikraft run` takes `-m 2048M`; the
two CLIs do not share flag syntax. Remove the instance with
`kraft rm jaeger-uk`.
