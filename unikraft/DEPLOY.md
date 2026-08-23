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

## 1. Start BuildKit

`unikraft build` refuses to build the rootfs without a Docker or BuildKit
daemon. `buildkitd.sh` starts a rootless one and is safe to re-run:

    ./buildkitd.sh
    export BUILDKIT_HOST=unix:///tmp/buildkit/buildkitd.sock

It prints the `export` line to copy. The daemon is not a service — it dies with
your session, so expect to run this again next time.

## 2. Build the binary

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

## 3. Build and push the image

    cd cloud
    unikraft build . --output okuyama-hiroyuki/jaeger:latest

**The namespace is not optional.** Passing a bare `jaeger:latest` resolves to
`unikraft.io/official/jaeger`, which rejects the push:

    401 Unauthorized
    unauthorized to access repository: official/jaeger, action: push

Confirm the image landed:

    unikraft images ls | grep jaeger

## 4. Deploy

    unikraft run \
        --metro sin \
        --image okuyama-hiroyuki/jaeger:latest \
        --name jaeger \
        -m 2048M \
        -p 4317:4317/tls \
        -p 4318:4318/tls

Notes on the flags:

* `-m` is lowercase, and the suffix is `M`/`G` — `-M` is not a flag and `2048Mi`
  is rejected as an invalid suffix.
* `-p <public>:<guest>/<handler>`. `tls` terminates TLS and forwards the plain
  stream, which is what OTLP gRPC and OTLP/HTTP both want. Use
  `-p 443:16686/http+tls` if you also want the query API and UI published.
* 2048M is the working figure. The ~80MB binary is loaded into guest memory and
  otelcol's Go heap sits on top; the default is far too small.
* `--metro` belongs to `run` only. `unikraft instances …` and `unikraft images
  …` do not accept it and will fail with `unknown flag --metro`.

The command prints the instance UUID and the generated FQDN, e.g.
`spring-butterfly-4c7lnt57.sin.unikraft.app`.

## 5. Verify

State first — `starting` means it has not finished booting, `stopped` means it
booted and exited:

    unikraft instances get jaeger

Then the logs. A healthy start ends with `Everything is ready. Begin running and
processing data.`:

    unikraft instances logs jaeger --tail 50

Then post a span. Replace the FQDN with the one from step 4:

    FQDN=spring-butterfly-4c7lnt57.sin.unikraft.app
    NOW=$(date +%s)000000000

    curl -sS -w '\nHTTP %{http_code}\n' -X POST "https://$FQDN:4318/v1/traces" \
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

## 6. Redeploy after a change

There is no in-place image swap. Rebuild, push, and replace the instance:

    ./build.sh
    cd cloud && unikraft build . --output okuyama-hiroyuki/jaeger:latest
    unikraft instances rm jaeger
    unikraft run --metro sin --image okuyama-hiroyuki/jaeger:latest \
        --name jaeger -m 2048M -p 4317:4317/tls -p 4318:4318/tls

The FQDN is generated per service and **changes on every redeploy**. Anything
pointing at the old name has to be updated.

Storage is in-memory, so every redeploy starts with an empty trace store.

## 7. Stop and clean up

    unikraft instances stop jaeger      # keep it, stop billing for runtime
    unikraft instances start jaeger     # bring it back
    unikraft instances rm jaeger        # delete instance and its service
    unikraft images rm okuyama-hiroyuki/jaeger:latest

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

Step 1 was skipped, or `BUILDKIT_HOST` is not exported into the shell running
`unikraft build`.

**`buildkitd: rootless mode requires to be executed as the mapped root in a user namespace`**

`buildkitd --rootless` was started outside a user namespace. Use
`./buildkitd.sh`, which wraps it in `unshare`.

**`buildkitd: no worker found, rebuild the buildkit daemon?`**

No OCI runtime on PATH. `./buildkitd.sh` locates one in the nix store;
`nix-shell -p runc` also works.

**`401 unauthorized to access repository: official/jaeger`**

`--output` was given without a namespace. See step 3.

**`parsing arguments: unknown flag --metro`**

`--metro` is only valid on `unikraft run`. The `instances` and `images`
subcommands operate across metros.

**`--memory: invalid suffix: 'mi'`**

Use `-m 2048M`, not `-m 2048Mi`.

**Instance state goes `starting` → `stopped` with no application logs**

The guest crashed before Jaeger produced output. `unikraft instances logs`
shows the unikernel's own exit line; compare against the SIGSEGV case above.

## Running locally

The qemu target needs no cloud account and publishes the query port, so it is
the quicker way to check a change end to end:

    ./build.sh
    kraft run --rm -d -M 2048Mi \
        -p 16686:16686 -p 4317:4317 -p 4318:4318 -n jaeger-uk .
    kraft logs jaeger-uk

Post a span to `http://localhost:4318/v1/traces` as in step 5, then read it
back:

    curl -sS http://localhost:16686/api/v3/services
    # {"services":["smoketest"]}

If that returns `{"services":[]}`, the batch processor has not flushed yet;
retry rather than treating it as a failure.

Note `kraft run` takes `-M 2048Mi` while `unikraft run` takes `-m 2048M`; the
two CLIs do not share flag syntax. Remove the instance with
`kraft rm jaeger-uk`.
