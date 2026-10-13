#!/usr/bin/env bash
# Build the crawler job from git, build the wrapper's library jar from it, install it, and switch the node to the wrapped
# configuration. The kit's folder must hold ops/attested (the scripts it calls).   node-wrapper.sh ACTION [ARGS]
#   deps              master: build crawler-commons and language-detection-cld2 at the commits of the lab cluster
#   build             master: clone the crawler (REF, default the branch feat/tee-hadoop-cluster) and run 'ant runtime'
#   jar               master: build ~/attested-hdfs.jar from the job file, and install it here
#   install-jar JAR   any node: install a jar that was built on the master
#   mode              any node: prepare the PLAIN and WRAPPED settings and switch this node to WRAPPED (restarts its daemons)
# Settings (environment): REF, NUTCH_REPO, CC_COMMIT, CLD2_COMMIT.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
ATT="$KIT_DIR/../attested"; hadoop_env
ACT="${1:-}"
NUTCH_REPO="${NUTCH_REPO:-https://github.com/Antisource/nutch.git}"; REF="${REF:-feat/tee-hadoop-cluster}"
CC_REPO=https://github.com/crawler-commons/crawler-commons.git; CC_COMMIT="${CC_COMMIT:-13118882ddfe}"
CLD2_REPO=https://github.com/commoncrawl/language-detection-cld2.git; CLD2_COMMIT="${CLD2_COMMIT:-38efccdc1ec1}"
W="$HOME_DIR/ccbot-work"; SRC="$HOME_DIR/nutch-build"
job() { cat "$STATE/job.path" 2>/dev/null || echo "$SRC/runtime/deploy/apache-nutch-1.22.job"; }
case "$ACT" in
deps)
  mkdir -p "$W"
  for spec in "crawler-commons:$CC_REPO:$CC_COMMIT" "language-detection-cld2:$CLD2_REPO:$CLD2_COMMIT"; do
    IFS=: read -r name u1 u2 commit <<< "$spec"; url="$u1:$u2"
    [ -d "$W/$name/.git" ] || git clone -q "$url" "$W/$name" || die "could not clone $url"
    git -C "$W/$name" checkout -q "$commit" || die "$name has no commit $commit"
    say "building $name at $(git -C "$W/$name" rev-parse --short=12 HEAD)"
    (cd "$W/$name" && mvn -q -B install -DskipTests > "$STATE/mvn-$name.log" 2>&1) || { tail -8 "$STATE/mvn-$name.log"; die "mvn install failed for $name"; }
    ok "$name installed in ~/.m2"
  done; mark_done deps ;;
build)
  is_done deps || die "run 'deps' first"
  [ -d "$SRC/.git" ] || git clone -q "$NUTCH_REPO" "$SRC" || die "could not clone $NUTCH_REPO"
  git -C "$SRC" fetch -q origin && git -C "$SRC" checkout -q "$REF" && { git -C "$SRC" merge -q --ff-only "origin/$REF" 2>/dev/null || true; } || die "cannot check out $REF"
  say "building the job at $(git -C "$SRC" rev-parse --short=9 HEAD)"
  (cd "$SRC" && ant runtime > "$STATE/ant.log" 2>&1); tail -2 "$STATE/ant.log" | cut -c1-80
  grep -q "BUILD SUCCESSFUL" "$STATE/ant.log" || die "ant runtime failed (log: $STATE/ant.log)"
  echo "$SRC/runtime/deploy/apache-nutch-1.22.job" > "$STATE/job.path"
  echo "JOB: $(sha256sum "$(job)" | cut -c1-16)  $(job)"; mark_done build ;;
jar)
  [ -f "$(job)" ] || die "no job file; run 'build' first"
  bash "$ATT/wrapper-jar.sh" build "$(job)" "$HOME_DIR/attested-hdfs.jar" || die "building the jar failed"
  ATTESTED_FORCE=1 bash "$ATT/wrapper-jar.sh" install "$HOME_DIR/attested-hdfs.jar" "$(job)" || die "installing the jar failed" ;;
install-jar)
  JAR="${2:-}"; [ -f "$JAR" ] || die "usage: node-wrapper.sh install-jar JAR"
  ATTESTED_FORCE=1 bash "$ATT/wrapper-jar.sh" install "$JAR" || die "installing the jar failed" ;;
mode)
  bash "$ATT/cluster-mode.sh" prepare || die "cluster-mode prepare failed"
  bash "$ATT/cluster-mode.sh" wrapped --restart || die "switching to the wrapped configuration failed (the script put the old file back)" ;;
*) die "unknown action '$ACT'" ;;
esac
