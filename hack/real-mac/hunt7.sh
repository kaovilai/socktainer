#!/bin/zsh
# hunt7: multi-arch builds and runs (Rosetta amd64, QEMU s390x), a registry round trip on :5001
# (podman build --manifest -> manifest push --all -> rmi -> pull --platform -> run), docker build
# --platform, and docker buildx (default docker driver + docker-container driver), plus the versions
# of Apple container / podman / docker in use. Real podman + docker against socktainer on the default
# socket; PASS/FAIL lines go to ~/hunt7-results.txt (DONE marks the end).
# XFAIL lines are informative checks for paths socktainer may not support (s390x at runtime, buildx,
# docker push to a plain-http registry): they record the error text and are not counted as FAIL.
# INFO lines carry versions. Checks only touch resources labelled hunt=1 or named h7*/h7/*.
# buildx: the plugin is looked up under $H7_BUILDX_CONFIG/cli-plugins (default ~/.docker-buildx, see
# box-setup.sh), not ~/.docker, so hunt4's `docker build` stays on the classic builder.
export PATH=/usr/local/bin:/opt/podman/bin:$HOME/bin:$PATH
export DOCKER_HOST=unix://$HOME/.socktainer/container.sock
export CONTAINER_HOST=unix://$HOME/.socktainer/container.sock
P="perl $HOME/ptimeout.pl 120 podman --remote"
PB="perl $HOME/ptimeout.pl 1200 podman --remote"
D="perl $HOME/ptimeout.pl 120 docker"
DB="perl $HOME/ptimeout.pl 1200 docker"
BXCFG=${H7_BUILDX_CONFIG:-$HOME/.docker-buildx}
BX="perl $HOME/ptimeout.pl 1500 env DOCKER_CONFIG=$BXCFG docker buildx"
A=docker.io/library/alpine:latest
R=docker.io/library/registry:2
REG=localhost:5001
OUT=$HOME/hunt7-results.txt; : > $OUT
check() { local name=$1 want=$2; shift 2; local got; got=$(eval "$@" 2>&1); local rc=$?
  if [[ $got =~ $want ]]; then echo "PASS  $name" >> $OUT
  else local t=${got:0:400}; t=${t//$'\n'/ }; echo "FAIL  $name (rc=$rc) want=/$want/ got: $t" >> $OUT; fi; }
checkrc() { local name=$1 want=$2; shift 2; local got; got=$(eval "$@" 2>&1); local rc=$?
  if [[ $rc -eq 0 && $got =~ $want ]]; then echo "PASS  $name" >> $OUT
  else local t=${got:0:400}; t=${t//$'\n'/ }; echo "FAIL  $name (rc=$rc) want=/$want/ got: $t" >> $OUT; fi; }
# like checkrc, but a miss is recorded as XFAIL with the error text instead of FAIL
xcheck() { local name=$1 want=$2; shift 2; local got; got=$(eval "$@" 2>&1); local rc=$?
  if [[ $rc -eq 0 && $got =~ $want ]]; then echo "PASS  $name" >> $OUT
  else local t=${got:0:600}; t=${t//$'\n'/ }; echo "XFAIL $name (rc=$rc) want=/$want/ got: $t" >> $OUT; fi; }
info() { local name=$1; shift; local got; got=$(eval "$@" 2>&1); got=${got:0:300}; echo "INFO  $name: ${got//$'\n'/ | }" >> $OUT; }
section() { echo "== $1" >> $OUT; }
runlog() { local n=$1; shift; ${=P} run -d --name $n --label hunt=1 "$@" >/dev/null 2>&1 || { echo "RUNFAIL"; return; }; ${=P} wait $n >/dev/null 2>&1; ${=P} logs $n 2>&1; }
drunlog() { local n=$1; shift; ${=D} run -d --name $n --label hunt=1 "$@" >/dev/null 2>&1 || { echo "RUNFAIL"; return; }; ${=D} wait $n >/dev/null 2>&1; ${=D} logs $n 2>&1; }
# imgfile IMAGE PATH: print a file from an image's layers without running the image (podman save + python)
imgfile() { local t=$W/img.tar; rm -f $t
  ${=P} save -o $t "$1" >/dev/null 2>&1 || { echo SAVEFAIL; return; }
  python3 -I - $t "$2" <<'PY'
import sys, tarfile
outer = tarfile.open(sys.argv[1]); want = sys.argv[2].strip('/')
for m in outer.getmembers():
    if not m.isfile(): continue
    try: inner = tarfile.open(fileobj=outer.extractfile(m), mode='r:*')
    except tarfile.TarError: continue
    for n in inner.getmembers():
        if n.isfile() and n.name.lstrip('./') == want:
            sys.stdout.write(inner.extractfile(n).read().decode()); sys.exit(0)
print('NOTFOUND')
PY
}
h7images() { ${=P} images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -E '(^|/)h7/' | grep -v '<none>'; }
cleanup() {
  env DOCKER_CONFIG=$BXCFG docker buildx rm -f h7bx >/dev/null 2>&1
  ${=P} rm -f $(${=P} ps -aq --filter label=hunt=1 2>/dev/null) >/dev/null 2>&1
  ${=P} rm -f buildx_buildkit_h7bx0 >/dev/null 2>&1
  ${=P} manifest rm h7/ml:1 >/dev/null 2>&1
  ${=P} rmi -f $(h7images) $(${=P} images -q --filter label=h7ml=1 2>/dev/null) >/dev/null 2>&1; }

W=$HOME/h7ctx; rm -rf $W; mkdir -p $W
cat > $W/Dockerfile.arch <<'D'
FROM docker.io/library/alpine:latest
RUN uname -m > /arch.txt
CMD ["cat","/arch.txt"]
D
cat > $W/Dockerfile.ml <<'D'
FROM docker.io/library/alpine:latest
LABEL h7ml=1
RUN uname -m > /arch.txt
CMD ["cat","/arch.txt"]
D
cleanup
${=P} pull $A >/dev/null 2>&1; ${=P} pull $R >/dev/null 2>&1

section "versions"
check "container --version" "[0-9]+\\.[0-9]+\\.[0-9]+" "container --version"
info "container" "container --version"
info "container system status" "container system status 2>&1 | head -3"
info "macOS" "sw_vers -productVersion"
info "podman client" "podman --version"
info "podman server (socktainer)" "$P version --format '{{.Server.Version}} api {{.Server.APIVersion}}'"
info "docker" "$D version --format 'client {{.Client.Version}} server {{.Server.Version}} api {{.Server.APIVersion}}'"
info "docker compose" "docker compose version"
info "docker buildx" "env DOCKER_CONFIG=$BXCFG docker buildx version"
info "podman-compose" "podman-compose --version 2>&1 | tail -1"

section "podman --platform build + run"
checkrc "build linux/s390x (QEMU)" "." "setopt pipefail; cd $W && $PB build --platform linux/s390x -f Dockerfile.arch -t h7/s390x:1 . 2>&1 | tail -2"
check "s390x image Architecture" "^s390x" "$P image inspect h7/s390x:1 --format '{{.Architecture}}'"
check "s390x RUN saw s390x at build time" "^s390x" "imgfile h7/s390x:1 /arch.txt"
xcheck "run s390x: uname -m (QEMU at runtime)" "^s390x" "runlog h7s390a --platform linux/s390x h7/s390x:1 uname -m"
xcheck "run s390x: cat build-time arch" "^s390x" "runlog h7s390b --platform linux/s390x h7/s390x:1"
checkrc "build linux/amd64 (Rosetta)" "." "setopt pipefail; cd $W && $PB build --platform linux/amd64 -f Dockerfile.arch -t h7/amd64:1 . 2>&1 | tail -2"
check "amd64 image Architecture" "^amd64" "$P image inspect h7/amd64:1 --format '{{.Architecture}}'"
check "amd64 RUN saw x86_64 at build time" "^x86_64" "imgfile h7/amd64:1 /arch.txt"
check "run amd64: uname -m" "^x86_64" "runlog h7amd --platform linux/amd64 h7/amd64:1 uname -m"
check "run amd64 without --platform (image arch)" "^x86_64" "runlog h7amd2 h7/amd64:1 uname -m"

section "registry round trip ($REG)"
check "start registry :5001" "[0-9a-f]{64}" "$P run -d --name h7reg --label hunt=1 -p 5001:5000 $R"
for i in {1..30}; do [[ $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:5001/v2/) == 200 ]] && break; sleep 1; done
check "registry reachable" "^200$" "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:5001/v2/"
checkrc "build arm64+amd64 --manifest" "." "setopt pipefail; cd $W && $PB build --platform linux/arm64,linux/amd64 --manifest h7/ml:1 -f Dockerfile.ml . 2>&1 | tail -2"
check "local manifest has arm64+amd64" "arm64.*amd64|amd64.*arm64" "$P manifest inspect h7/ml:1 | tr -d ' \n'"
checkrc "manifest push --all" "." "setopt pipefail; $PB manifest push --tls-verify=false --all h7/ml:1 docker://$REG/h7/ml:1 2>&1 | tail -2"
check "registry index has arm64+amd64" "arm64.*amd64|amd64.*arm64" "curl -s -H 'Accept: application/vnd.oci.image.index.v1+json' -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' http://127.0.0.1:5001/v2/h7/ml/manifests/1 | tr -d ' \n'"
check "rm local list + members" "^$" "$P manifest rm h7/ml:1 >/dev/null 2>&1; $P rmi -f \$($P images -q --filter label=h7ml=1) >/dev/null 2>&1; $P images -q --filter label=h7ml=1"
checkrc "pull --platform linux/amd64 from registry" "." "setopt pipefail; $PB pull --tls-verify=false --platform linux/amd64 $REG/h7/ml:1 2>&1 | tail -1"
check "pulled amd64 Architecture" "^amd64" "$P image inspect $REG/h7/ml:1 --format '{{.Architecture}}'"
check "run pulled amd64: uname -m" "^x86_64" "runlog h7pa --platform linux/amd64 $REG/h7/ml:1 uname -m"
check "run pulled amd64: build-time arch" "^x86_64" "runlog h7pa2 --platform linux/amd64 $REG/h7/ml:1"
check "rmi pulled amd64" "^$" "$P rmi -f $REG/h7/ml:1 >/dev/null 2>&1; $P rmi -f \$($P images -q --filter label=h7ml=1) >/dev/null 2>&1; $P images -q --filter label=h7ml=1"
checkrc "pull --platform linux/arm64 from registry" "." "setopt pipefail; $PB pull --tls-verify=false --platform linux/arm64 $REG/h7/ml:1 2>&1 | tail -1"
check "pulled arm64 Architecture" "^arm64" "$P image inspect $REG/h7/ml:1 --format '{{.Architecture}}'"
check "run pulled arm64: uname -m" "^aarch64" "runlog h7pb $REG/h7/ml:1 uname -m"
check "run pulled arm64: build-time arch" "^aarch64" "runlog h7pb2 $REG/h7/ml:1"
${=P} rmi -f $REG/h7/ml:1 >/dev/null 2>&1
checkrc "docker pull --platform linux/amd64 from registry" "." "setopt pipefail; $DB pull --platform linux/amd64 $REG/h7/ml:1 2>&1 | tail -1"
check "docker run pulled amd64: uname -m" "^x86_64" "drunlog h7dpa --platform linux/amd64 $REG/h7/ml:1 uname -m"

section "docker build --platform"
check "docker build --platform linux/amd64" "Successfully built|naming to|writing image" "cd $W && $DB build --platform linux/amd64 -f Dockerfile.arch -t h7/dbamd:1 . 2>&1"
check "docker built amd64 Architecture" "^amd64" "$D image inspect h7/dbamd:1 --format '{{.Architecture}}'"
check "docker run amd64: uname -m" "^x86_64" "drunlog h7da --platform linux/amd64 h7/dbamd:1 uname -m"
check "docker run amd64: build-time arch" "^x86_64" "drunlog h7da2 --platform linux/amd64 h7/dbamd:1"
xcheck "docker push to plain-http $REG" "digest: sha256|Pushed|pushed" "$D tag h7/dbamd:1 $REG/h7/dbamd:1 && $DB push $REG/h7/dbamd:1 2>&1 | tail -3"

section "docker buildx"
if env DOCKER_CONFIG=$BXCFG docker buildx version >/dev/null 2>&1; then
  xcheck "buildx ls" "default" "$BX ls 2>&1"
  # default builder = docker driver: needs the daemon's BuildKit session/gRPC API
  xcheck "buildx build docker driver arm64+amd64 --push" "pushing manifest|exporting manifest list" "setopt pipefail; cd $W && $BX build --platform linux/arm64,linux/amd64 -f Dockerfile.arch -t $REG/h7/bx:1 --push . 2>&1 | tail -6"
  xcheck "buildx build docker driver amd64 --load" "naming to|writing image" "setopt pipefail; cd $W && $BX build --platform linux/amd64 -f Dockerfile.arch -t h7/bxd:1 --load . 2>&1 | tail -6"
  # docker-container driver: buildkitd runs in its own container, where localhost is not the host,
  # so it pushes to the registry container's IP; the host side reads back through localhost:5001.
  REGIP=$(docker inspect h7reg --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)
  info "registry container IP" "echo ${REGIP:-none}"
  printf '[registry."%s:5000"]\n  http = true\n  insecure = true\n' $REGIP > $W/buildkitd.toml
  xcheck "buildx create docker-container --bootstrap" "h7bx" "$BX create --name h7bx --driver docker-container --buildkitd-config $W/buildkitd.toml --bootstrap 2>&1 | tail -3"
  xcheck "buildx inspect h7bx platforms" "linux/amd64" "$BX inspect h7bx 2>&1"
  xcheck "buildx docker-container arm64+amd64 --push" "pushing manifest|exporting manifest list" "setopt pipefail; cd $W && $BX build --builder h7bx --platform linux/arm64,linux/amd64 -f Dockerfile.arch -t $REGIP:5000/h7/bx:2 --push . 2>&1 | tail -6"
  xcheck "registry bx index has arm64+amd64" "arm64.*amd64|amd64.*arm64" "curl -s -H 'Accept: application/vnd.oci.image.index.v1+json' -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' http://127.0.0.1:5001/v2/h7/bx/manifests/2 | tr -d ' \n'"
  xcheck "run buildx-pushed amd64: uname -m" "^x86_64" "$PB pull --tls-verify=false --platform linux/amd64 $REG/h7/bx:2 >/dev/null 2>&1; runlog h7bxa --platform linux/amd64 $REG/h7/bx:2"
  xcheck "buildx docker-container amd64 --load" "." "setopt pipefail; cd $W && $BX build --builder h7bx --platform linux/amd64 -f Dockerfile.arch -t h7/bxl:1 --load . 2>&1 | tail -3"
  xcheck "run buildx --load image: uname -m" "^x86_64" "drunlog h7bxl --platform linux/amd64 h7/bxl:1 uname -m"
  xcheck "buildx rm h7bx" "removed|^$" "$BX rm h7bx 2>&1"
else
  echo "XFAIL docker buildx (plugin missing under $BXCFG/cli-plugins; run box-setup.sh)" >> $OUT
fi

section "cleanup"
cleanup
check "no h7 containers left" "^$" "$P ps -aq --filter label=hunt=1"
check "no h7 images left" "^$" "h7images"
echo DONE >> $OUT
