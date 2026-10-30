# Real-Mac hunt (self-hosted runner)

`.github/workflows/real-mac.yaml` builds socktainer on a self-hosted Apple silicon Mac, starts it, and drives
real `podman` and `docker` clients against it:

| File | Purpose |
|---|---|
| `hunt3.sh` | podman builds (single arch, `--platform` arm64/amd64/s390x, `--manifest`), push/pull/`manifest push` against a `registry:2` on :5000 |
| `hunt7.sh` | build + run s390x (QEMU) and amd64 (Rosetta), registry round trip on :5001 (`manifest push --all` → `rmi` → `pull --platform` → run), `docker build --platform`, `docker buildx` (docker and docker-container drivers), tool versions |
| `ptimeout.pl` | hard timeout wrapper (macOS has no `timeout`; podman ignores `SIGALRM`) |
| `summarize.sh` | markdown PASS/FAIL table for the job summary; fails the job on any `FAIL` line or a missing `DONE` |

Each check writes a `PASS`, `FAIL`, `XFAIL` or `INFO` line to `~/hunt3-results.txt` / `~/hunt7-results.txt`.
`XFAIL` marks informative checks for paths socktainer may not support yet (s390x at runtime, buildx, docker
push to a plain-http registry); they record the client's error text and do not fail the job.
The scripts are vendored copies of the out-of-tree hunt suite; keep them in sync when that suite changes.

The workflow only runs in the `kaovilai/socktainer` fork, on `workflow_dispatch` or a nightly schedule.
**Never add `pull_request` or `pull_request_target` triggers**: a self-hosted runner would then execute
untrusted code on the Mac.

## Host prerequisites

macOS 26 on Apple silicon, logged in as the user that runs the runner, with:

- Xcode 26 (license accepted), Rosetta
- Apple container matching `Package.resolved` (`container system start --enable-kernel-install` done, `container system status` running)
- podman (pkg installer, `/opt/podman/bin`), docker CLI in `/usr/local/bin`, docker compose in `~/.docker/cli-plugins`
- docker buildx in `~/.docker-buildx/cli-plugins/docker-buildx` (a separate `DOCKER_CONFIG`, so `docker build` stays on the classic builder; `hunt7.sh` sets `DOCKER_CONFIG` itself)
- ports 5000 and 5001 free (the hunts publish `registry:2` there)

## Register the runner

Labels must include `socktainer` (the runner adds `self-hosted`, `macOS`, `ARM64` itself).
Registration tokens need admin on the fork and expire after an hour:

```sh
gh api -X POST repos/kaovilai/socktainer/actions/runners/registration-token --jq .token
```

Scaleway Apple silicon box (the platform downloads and configures the runner):

```sh
scw apple-silicon runner create zone=fr-par-3 \
  runner-configuration.name=socktainer-real-mac \
  runner-configuration.provider=github \
  runner-configuration.github-configuration.url=https://github.com/kaovilai/socktainer \
  runner-configuration.github-configuration.token=<registration-token> \
  runner-configuration.github-configuration.labels.0=socktainer
```

then apply it to the server (`scw apple-silicon server update <server-id> zone=fr-par-3 applied-runner-configurations.runner-configuration-ids.0=<runner-config-id>`).

Any other Mac, with the stock runner (on the box, as the user that owns the container system):

```sh
mkdir -p ~/actions-runner && cd ~/actions-runner
curl -fsSLO https://github.com/actions/runner/releases/download/v<version>/actions-runner-osx-arm64-<version>.tar.gz
tar -xzf actions-runner-osx-arm64-<version>.tar.gz
./config.sh --unattended --url https://github.com/kaovilai/socktainer --token <registration-token> \
  --name "$(hostname -s)" --labels socktainer
./svc.sh install && ./svc.sh start   # or ./run.sh in a tmux/screen session
```

The runner must run in the same user session as `container system start`, since socktainer talks to that
user's container API server and listens on `~/.socktainer/container.sock`.

## Run it

To test ref X, push it to a `real-mac/` branch on the fork; the run builds and tests the pushed commit:

```sh
git push origin X:refs/heads/real-mac/X
```

A push runs the workflow file from the pushed commit, so X must contain this workflow and `hack/real-mac/`.
For a ref that doesn't (e.g. `explore/full-parity`), put the `ci/real-mac-runner` commits on top first; they
only add new files, so the cherry-pick never conflicts:

```sh
git fetch origin
git checkout -B real-mac/X X
git cherry-pick origin/explore/full-parity..origin/ci/real-mac-runner
git push -f origin real-mac/X
```

Pushes to `ci/real-mac-runner` itself also run it. `workflow_dispatch` (`-f ref=<rev>`, harness from
`--ref`) and the nightly `schedule` (tests `explore/full-parity`) only start working once the workflow
is on the fork's default branch, which it deliberately is not.

Results (`hunt3-results.txt`, `hunt7-results.txt`, `socktainer.log`, tested SHA) are uploaded as the
`real-mac-results` artifact and summarized on the run page.

## Remove the runner

```sh
gh api -X POST repos/kaovilai/socktainer/actions/runners/remove-token --jq .token
cd ~/actions-runner && ./svc.sh stop && ./svc.sh uninstall && ./config.sh remove --token <remove-token>
```

On Scaleway: `scw apple-silicon runner delete <runner-config-id> zone=fr-par-3`.
