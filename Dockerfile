# syntax=docker/dockerfile:1
#
# endpoint-exposer service worker image — built on the lean gRPC worker
# bridge. The bridge dials over gRPC and runs the bash entrypoint on each
# package-exec action; this image adds the cluster tooling the exposer's
# workflows need and bakes the service in.
FROM public.ecr.aws/nullplatform/scopes/worker-bridge:1.0.0

# Tooling the exposer workflows call (istio/gateway objects, template
# rendering): kubectl + gomplate. bash, jq, np, base64 and curl ship in
# the base.
RUN apk add --no-cache kubectl gomplate

# Bake the service in and point the bridge at its entrypoint.
COPY . /app/pkg
ENV NP_PACKAGE_NAME=endpoint-exposer \
    NP_SERVICE_PATH=/app/pkg \
    NP_SCOPE_ENTRYPOINT=/app/pkg/entrypoint/entrypoint
