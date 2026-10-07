# syntax=docker/dockerfile:1
#
# endpoint-exposer service worker image — built on the lean gRPC worker
# bridge. The bridge dials over gRPC and runs the bash entrypoint on each
# package-exec action; this image adds the cluster tooling the exposer's
# workflows need and bakes the service in.
FROM public.ecr.aws/nullplatform/scopes/worker-bridge:2.0.1

# Tooling the exposer workflows call (istio/gateway objects, template
# rendering): kubectl + gomplate + yq (HTTPRoute YAML manipulation in
# scripts/istio/build_httproute). bash, jq, np, base64 and curl
# ship in the base.
RUN apk add --no-cache kubectl gomplate yq-go

# Bake the service in and point the bridge at its entrypoint.
# Bake the service in. --chown so the files belong to the uid this image runs
# as: `np` chmods the action script in place at runtime, and a root-owned tree
# would be read-only for the non-root user.
COPY --chown=10001:10001 . /app/pkg
ENV NP_PACKAGE_NAME=endpoint-exposer \
    NP_SERVICE_PATH=/app/pkg \
    NP_SCOPE_ENTRYPOINT=/app/pkg/entrypoint/entrypoint

# Hand HOME to the runtime user. The RUN steps above ran as root with HOME
# already set to /home/app by the base, so tools invoked at build time left
# root-owned config and cache dirs there (tofu: ~/.terraform.d, az: ~/.azure)
# that the non-root user could not write to at runtime.
RUN chown -R 10001:10001 /home/app

# Drop root for the runtime. Everything above installs as root, as usual; the
# base (worker-bridge 2.0.0+) ships the app user, np on PATH and a writable
# HOME, and leaves the switch to each image. Numeric on purpose: k8s
# admission with runAsNonRoot resolves USER to a numeric id to prove it
# isn't root, and a name doesn't satisfy that check.
USER 10001:10001
