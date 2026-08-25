# The nested Docker daemon's config

`daemon.json` in this directory configures the `dockerd` that runs **inside** the devaloy container when the image is built with `WITH_DOCKER=true`. It has nothing to do with the Docker host's own daemon, which `scripts/host-resource-guard.sh` owns.

It gets its own copy line in `entrypoint.sh` rather than travelling with the rest of `config/`. The config sync copies into `/home/dev`, and `dockerd` reads `/etc/docker`.

JSON takes no comments, so the reasoning lives here.

## `bip` and `default-address-pools`

The two keys that are not optional. An unconfigured `dockerd` puts its bridge on `172.17.0.0/16` and allocates project networks from `172.17.0.0/12`. devaloy's own `eth0` sits on a bridge the outer host allocated, and both Docker's default and Dokploy's allocations come out of `172.16/12`. Measured on the scratch host during the Phase 0 spike, devaloy's `eth0` came up on `172.20.0.2/16`, which is inside the range an unpinned nested daemon would hand to a project network.

An overlap does not announce itself. It presents as a project stack whose containers cannot resolve each other, or as a box that stops answering, and the route table is the last place anyone looks.

Pinning into `10.x` removes the question. `10.201.0.1/16` is the nested `docker0`, and project networks come out of `10.202.0.0/16` in `/24` slices, which is 256 project networks. Change these only if the *outer* host uses `10.x`, and change both together.

## `log-opts`

`json-file` has no default size limit, so one chatty service writes until the volume is full. Ten megabytes across three files caps each container at 30 MB. A project that needs more history should ship its own `logging:` block in its own compose file.

## `builder.gc`

Build cache is the largest and cheapest waste on this box. Cheapest because a discarded layer costs a rebuild and never a pull, which is why this is the one thing devaloy reaps automatically. `defaultReservedSpace` is the current key name; `defaultKeepStorage` is the old one and is what most search results still show.

Images are **not** pruned automatically. `devaloy-prune` is the command for that, and the reasoning for keeping it manual is in the script's own header.
