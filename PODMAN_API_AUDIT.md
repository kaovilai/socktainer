# Podman CLI (remote socket) API coverage audit

Scope: what the `podman` CLI needs from a remote unix socket (`CONTAINER_HOST` set,
no podman machine involved — that layer is entirely client-side VM provisioning
and never touches the wire once a socket connection exists). Paths verified
against `github.com/podman-container-tools/podman` `pkg/api/server/register_*.go`
(canonical route registration) where fetched; the rest match the long-stable
libpod API v4/v5 convention (`/libpod/<resource>/...`).

## What "✅" means here

A ✅ means the route is registered **and** a real `podman` 6.1.4 client (`CONTAINER_HOST` set,
`podman --remote`) completed the command against a running socktainer with real data present — an
empty store is not enough, since most decode failures only show once a list has an entry. The
libpod API reuses Docker-compat's semantics but not its wire shapes (prune and delete answer
report arrays, `wait` a bare integer, lists drop Docker's envelopes, create takes podman's whole
`SpecGenerator`, and some parameters are renamed), so each route runs the Docker-compat handler and
translates the request and response in `Routes/Libpod/LibpodAdapter.swift` / `LibpodSchema.swift`.
Routes that only wrap a Docker-compat route which is itself unimplemented say so in their row.

Verified on macOS 26.6.2 with Apple Container 1.6.0 (matching this build) and `podman` 6.1.4:
about 230 `podman` commands (including attached `podman run`/`start -a`) across handshake, images, volumes, networks, containers (lifecycle,
exec, logs, stats, cp, filters, formats, error mapping, ~40 `run` flags), `build` (single and
multi-platform, Rosetta and QEMU builders), push to a local registry, manifest lists, top, pause,
healthcheck run, commit, diff, export, save/load, events filters and replay, pods, and
podman-compose 1.6.0 (with and without `--in-pod`); the Docker CLI (with Compose v2.39.4) was run
through the same features.

Limits that Docker-compat shares (libpod mirrors Docker-compat's support, it does not go beyond it):

- `rename` works on any container that is not running; renaming a running one is a 409, since Apple
  Container cannot change the id of a running container.
- `top` runs `ps` inside the container (there is no host-side view of the VM's processes), so the
  image must provide `ps` (busybox or procps); one without it (distroless, debian-slim) is a 500 that
  says so.
- `pause`/`unpause` stop every process with SIGSTOP and resume it with SIGCONT (Apple Container has
  no freezer or pause primitive). Paused state is persisted (`socktainer-paused.json`) and survives a
  daemon restart; entries for containers stopped or restarted while the daemon was down are dropped
  at startup. An image without a shell gets only PID 1 stopped. `exec` into a paused container is a
  409, as on Docker and podman.
- `commit` writes the base image's layers plus one layer holding the container's changes (whiteouts
  for deletions), like moby. It falls back to a single squashed layer for a never-started container
  or when the base image's layers are no longer stored. The container is not paused while it is
  read; its guest page cache is flushed first, as for `export`.
- `diff` compares the container's `rootfs.ext4` with the image snapshot it was cloned from;
  `/etc/hosts`, `/etc/hostname` and `/etc/resolv.conf` are hidden as Docker's init layer hides them.
- `events --since`/`--until` replay a ring of recent events (last 1000 by default,
  `SOCKTAINER_EVENTS_HISTORY`, 0 disables), persisted to `socktainer-events.jsonl` (capped at twice
  the history limit), so it survives a daemon restart.
- `save` without `--platform` exports only the platforms whose content is in the local store.
- `manifest annotate` sets architecture, OS, variant and annotations (instance and `--index`);
  `--os-version`, `--os-features` and `--features` are a 400, since the image store cannot encode them.
- A default named volume is an ext4 disk image, which only one running container can safely mount:
  starting a second container that mounts it while another running container has it is a 409
  (`volume "X" is in use by running container Y; ext4-backed volumes can't be shared`). Compose
  files that mount one default volume in two services now get that error instead of two diverging
  copies. To share, create the volume with local-driver bind options
  (`--opt type=none --opt o=bind --opt device=/host/dir`, also Compose `driver_opts`): it is the host
  directory over virtiofs, any number of running containers can mount it, it is reported as a
  volume and cannot be removed while in use. Unlike a default volume it gets no copy-up of image
  content. Directory-backed default volumes are not viable: virtiofs ignores `chown` and rejects
  `chmod` on the share root.
- `podman cp` out of a container to a host path under `/tmp` fails inside the podman client on macOS
  (`/tmp` is a symlink to `/private/tmp`); copying to a real directory works.

Currently registered in this repo: `Sources/socktainer/configure.swift`
("Podman libpod routes" section) + `Sources/socktainer/Routes/Libpod/*.swift`.

## Ping / handshake (critical path — CLI probes this before anything else)

| Path | Method | Implemented |
|---|---|---|
| `/libpod/_ping` | GET, HEAD | ✅ `LibpodPingRoute` |
| `/libpod/version` | GET | ✅ `LibpodVersionRoute` |
| `/libpod/info` | GET | ✅ `LibpodInfoRoute` |

## Containers

| Command | Method + Path | Implemented |
|---|---|---|
| `podman ps` / `ps -a` | GET `/libpod/containers/json` | ✅ |
| `podman create` | POST `/libpod/containers/create` | ✅ |
| `podman start` | POST `/libpod/containers/{id}/start` | ✅ |
| `podman stop` | POST `/libpod/containers/{id}/stop` | ✅ |
| `podman kill` | POST `/libpod/containers/{id}/kill` | ✅ |
| `podman restart` | POST `/libpod/containers/{id}/restart` | ✅ |
| `podman rm` | DELETE `/libpod/containers/{id}` | ✅ |
| `podman inspect` (container) | GET `/libpod/containers/{id}/json` | ✅ |
| `podman logs` | GET `/libpod/containers/{id}/logs` | ✅ |
| `podman top` | GET `/libpod/containers/{id}/top` | ✅ (psgo descriptors mapped onto `ps -o`; `%CPU` computed as psgo does; plain `ps` arguments passed through) |
| `podman rename` | POST `/libpod/containers/{id}/rename` | ✅ (any container that is not running, as Docker-compat) |
| `podman wait` | POST `/libpod/containers/{id}/wait` | ✅ (several `condition`s are ORed; `stopped`/`exited`/`removing`, plus `running`, `created`/`configured`, `paused`, `healthy`/`unhealthy`, `stopping`, `unknown` answering -1 as podman does; a container seen running and then found stopped counts as `stopping`; `interval` honoured) |
| `podman attach` | POST `/libpod/containers/{id}/attach` | ✅ (stdin reaches a running container started with `-i`; detach keys honoured, default ctrl-p,ctrl-q) |
| `podman exec` (create+start) | POST `/libpod/containers/{id}/exec`, `/libpod/exec/{id}/start`, GET `/libpod/exec/{id}/json`, POST `/libpod/exec/{id}/remove` | ✅ (`exec -t` keeps the session's terminal setting, like podman, whatever the start body says; a paused container is a 409, `container state improper`) |
| terminal resize (`run -it`, `attach`, `exec -it`) | POST `/libpod/containers/{id}/resize`, `/libpod/exec/{id}/resize` | ✅ (a resize before start is applied once the process starts) |
| `podman stats` | GET `/libpod/containers/stats` (batch, what the CLI calls) and `/libpod/containers/{name}/stats` | ✅ |
| `podman pause` | POST `/libpod/containers/{name}/pause` | ✅ (SIGSTOP to every process; inspect/ps report paused; survives daemon restart) |
| `podman unpause` | POST `/libpod/containers/{name}/unpause` | ✅ |
| `podman container prune` | POST `/libpod/containers/prune` | ✅ |
| `podman update` | POST `/libpod/containers/{name}/update` | ✅ |
| `podman commit` | POST `/libpod/commit` | ✅ (base layers + one change layer; `changes`, including the `CMD=` shorthand; streamed or not) |
| `podman export` | GET `/libpod/containers/{name}/export` | ✅ (a running container's guest is flushed first) |
| `podman diff` (container) | GET `/libpod/containers/{name}/changes` | ✅ (moby `ChangesDirs` semantics; `diffType=all\|container\|image` honoured, `all` falls back to the image for an image name, a bad value is 400) |
| `podman healthcheck run` | GET `/libpod/containers/{name}/healthcheck` (libpod-only) | ✅ (one run of the configured check through the scheduled probe; updates `State.Health`; 409 without a healthcheck or when not running) |
| `podman cp` | GET/HEAD/PUT `/libpod/containers/{name}/archive` | ✅ |

## Images

| Command | Method + Path | Implemented |
|---|---|---|
| `podman images` | GET `/libpod/images/json` | ✅ |
| `podman pull` | POST `/libpod/images/pull` | ✅ |
| `podman rmi` | DELETE `/libpod/images/remove?images=…` (batch) and `/libpod/images/{name}` | ✅ |
| `podman inspect` (image) | GET `/libpod/images/{name}/json` | ✅ |
| `podman tag` | POST `/libpod/images/{name}/tag` | ✅ |
| `podman build` | POST `/libpod/build` | ✅ |
| `podman push` | POST `/libpod/images/{name}/push` | ✅ |
| `podman search` | GET `/libpod/images/search` | ✅ |
| `podman history` | GET `/libpod/images/{name}/history` | ✅ |
| `podman image prune` | POST `/libpod/images/prune` (confirmed in podman source) | ✅ |
| `podman save` | GET `/libpod/images/{name}/get` (single) or `/libpod/images/export?references=...` (multi) | ✅ (platforms whose content is local) |
| `podman load` | POST `/libpod/local/images/load` (confirmed in podman source — note: NOT `/libpod/images/load`) | ✅ |
| `podman untag` | POST `/libpod/images/{name}/untag` | ✅ |
| `podman image diff` | GET `/libpod/images/{name}/changes`; the CLI calls `/libpod/containers/{name}/changes?difftype=image` | ✅ (top layer against the layers below it: whiteout = D, path present below = C, else A; with `parent`, both images' full filesystems are compared) |
| `podman import` | POST `/libpod/images/import` (confirmed in podman source: query params are `reference`/`message`/`changes`/`url`, not Docker's `repo`/`tag`/`fromSrc`) | ✅ (translates libpod's `reference` query param into Docker's `repo`/`tag`/`fromSrc=-` shape, then delegates; `url`-based remote import still rejected, same limitation as the Docker-side route) |

## Volumes

| Command | Method + Path | Implemented |
|---|---|---|
| `podman volume ls` | GET `/libpod/volumes/json` | ✅ |
| `podman volume create` | POST `/libpod/volumes/create` | ✅ |
| `podman volume rm` | DELETE `/libpod/volumes/{name}` | ✅ |
| `podman volume inspect` | GET `/libpod/volumes/{name}/json` | ✅ |
| `podman volume prune` | POST `/libpod/volumes/prune` | ✅ |

## Networks

| Command | Method + Path | Implemented |
|---|---|---|
| `podman network ls` | GET `/libpod/networks/json` | ✅ |
| `podman network create` | POST `/libpod/networks/create` | ✅ |
| `podman network rm` | DELETE `/libpod/networks/{name}` | ✅ |
| `podman network inspect` | GET `/libpod/networks/{name}/json` | ✅ |
| `podman network prune` | POST `/libpod/networks/prune` | ✅ |
| `podman network connect` | POST `/libpod/networks/{name}/connect` | ✅ (no-op parity response, same as Docker-side route) |
| `podman network disconnect` | POST `/libpod/networks/{name}/disconnect` | ✅ (no-op parity response, same as Docker-side route) |

## System

| Command | Method + Path | Implemented |
|---|---|---|
| `podman system df` | GET `/libpod/system/df` | ✅ |
| `podman events` | GET `/libpod/events` | ✅ (`filters` with podman's semantics, `since`/`until` replay recent history, `stream=false`; Docker actions renamed to podman's: `died`, `remove`, `exec_died`, `health_status`, ...; network connect/disconnect name the container) |
| `podman login` (auth check) | POST `/libpod/auth` | ✅ |

## Manifest lists (multi-arch)

Real podman's actual multi-arch **build** workflow (confirmed against
[podman-container-tools/podman#27211](https://github.com/podman-container-tools/podman/issues/27211)):
invoked bare (no `--manifest` flag), `podman build --platform a,b,c -t foo .`
only builds a **single** architecture regardless of how many comma-separated
`--platform` values are passed — the client never asks the server for a
multi-arch result unless `--manifest <name>` is given. The only real
multi-arch path for the `build` command specifically is `--platform a,b
--manifest name`; `podman manifest create`/`add` are a separate, always-multi-
arch-capable path that doesn't go through `build` at all. A Docker-compat
client hitting `/build?platform=a,b,c` directly is a separate case: that
endpoint does assemble a multi-platform manifest list from a comma-separated
`platform` value, matching Docker's own API contract rather than podman's.

Implemented as a `ClientManifestService` modeling a manifest list as an
ordinary tagged reference whose descriptor points at an OCI image index blob
— no separate bookkeeping layer; "the current members of `name`" is always
just "decode whatever index `name` currently points at." Built on two
existing Apple Containerization framework primitives this codebase's own
`load`/`import` code already relies on: a second `ImageStore(path:)` instance
over the daemon's own Application Support directory, and `ContentStore.ingest`
to write new index blobs (via `ContentWriter.write`, which computes the
correct SHA256 filename — `completeIngestSession` trusts the filename
verbatim with no hashing of its own, so getting this right matters).

`resolvedPushPlatform`'s single-available-platform narrowing (used by
ordinary image push) would silently defeat an explicit "push the whole list"
request, so manifest-list push goes through a dedicated `pushManifestList`
that always pushes `platform: nil` instead. Pushing to a different
destination reference needs a re-tag first, since the framework's push always
pushes to the same reference it resolves from (`retagForPush`).

Known limitation: `ImageStore`'s reference table (`state.json`) is a plain
load-entire-map → overwrite-entire-map with no file lock, shared with the
separate `container-apiserver` process — the real contention is cross-process,
which no in-process lock added here would fix. This is the same risk profile
the existing `load`/`import` code already accepts; ingest and create are kept
back-to-back to narrow, not close, the window.

| Command | Method + Path | Implemented |
|---|---|---|
| `podman manifest create` | POST `/libpod/manifests/{name}` | ✅ |
| `podman manifest inspect` | GET `/libpod/manifests/{name}/json` | ✅ |
| `podman manifest exists` | GET `/libpod/manifests/{name}/exists` | ✅ |
| `podman manifest add` | PUT `/libpod/manifests/{name}` (`operation: "update"`) | ✅ |
| `podman manifest remove` | PUT `/libpod/manifests/{name}` (`operation: "remove"`) | ✅ |
| `podman manifest rm` | DELETE `/libpod/manifests/{name}` | ✅ |
| `podman manifest annotate` | PUT `/libpod/manifests/{name}` (`operation: "annotate"`) | ✅ (arch/os/variant/annotations, `--index`; `--os-version`/`--os-features`/`--features` are a 400) |
| `podman manifest push` | POST `/libpod/manifests/{name}/registry/{destination}` (v4+) and legacy POST `/libpod/manifests/{name}/push?destination=` | ✅ (both forms) |
| `podman build --manifest <name>` | server-side: build all requested platforms and register the result under a named, addressable manifest list | ✅ |

## Pods

Apple Container has no pod primitive and runs every container in its own VM, so a pod here is a
named group of containers (label `io.socktainer.pod`, store `socktainer-pods.json` in the
Application Support directory) on a per-pod network `pod-<name>`, where members reach each other by
name. Members share no network, IPC, UTS or PID namespace (no `localhost` between them) and there is
no infra container; pod-level published ports (`pod create -p`) are a 400 — publish on the member
containers instead.

| Command | Method + Path | Implemented |
|---|---|---|
| `podman pod create` | POST `/libpod/pods/create` | ✅ |
| `podman pod exists` / `inspect` | GET `/libpod/pods/{name}/exists`, `/libpod/pods/{name}/json` | ✅ |
| `podman pod ps` | GET `/libpod/pods/json` (filters `id`/`name`/`label`/`status`/`network`) | ✅ |
| `podman pod start` / `stop` / `restart` / `kill` | POST `/libpod/pods/{name}/start|stop|restart|kill` | ✅ |
| `podman pod rm` / `prune` | DELETE `/libpod/pods/{name}`, POST `/libpod/pods/prune` | ✅ |
| `podman run --pod`, `podman ps --pod` | container create joins the pod; list/inspect report `Pod`/`PodName` | ✅ |
| `podman pod top` | GET `/libpod/pods/{name}/top` | ✅ (PIDs are each member's own; only format descriptors are accepted, `-ef` is "unknown descriptor" as on podman) |
| `podman pod stats` | GET `/libpod/pods/stats` (`-a`, `--format json`, no names) | ✅ |
| `podman pod pause` / `unpause` | POST `/libpod/pods/{name}/pause|unpause` | ✅ |
| `podman pod logs -c <member>` | container logs endpoint | ✅ (the remote client requires `-c`) |
| `podman pod clone` | | ➖ the remote client never sends a request (pkg/domain/infra/tunnel/pods.go returns nil) |

podman-compose 1.6.0 in-pod `up -d`/`ps`/`down` works.

## Not applicable / intentionally out of scope

- `podman generate kube`, `podman play kube` — skip unless a future need
  surfaces.
- `podman machine *` — client-side only, never reaches the socket. Confirmed
  out of scope per the ask.
- `podman unshare`, `podman system connection *`, `podman completion` — purely
  client-side (namespace tricks / connection-list bookkeeping / shell
  completions), never hit the socket at all.
- checkpoint/restore — niche, CRIU-based, not applicable to the Apple
  Container VM backend.
- `podman secret *` — Swarm-style secret store; low value without a broader
  secrets/Swarm story, and no evidence it's used against a non-Swarm-mode
  daemon.

## Minor / low-priority gaps

- `{resource}/exists` endpoints: `/libpod/containers/{name}/exists`,
  `/libpod/images/{name}/exists`, `/libpod/volumes/{name}/exists`,
  `/libpod/networks/{name}/exists` all return 204 (exists) or 404 (not found).
- `podman generate systemd` — out of scope (systemd unit generation is a
  Linux-host concept, not meaningful under Apple Container).

## Top gaps worth implementing next (priority order)

1. Sharing a *default* (ext4) named volume between running containers — blocked
   on Apple Container mounting each volume as a disk image per VM; refused with
   a 409 today, shareable only via bind-option volumes.
2. `podman pod clone` — needs client-side support in podman's remote tunnel
   before the server can do anything.
