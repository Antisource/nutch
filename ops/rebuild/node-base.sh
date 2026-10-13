#!/usr/bin/env bash
# Base install of one node of the lab cluster: packages, host names, Hadoop 3.4.3 (checksum verified), its
# configuration, data folders, and shell settings. Every step can be repeated: it looks first and skips what is done.
# Run on the node, as the lab user (needs passwordless sudo):   node-base.sh master|worker
# Test hooks (environment): REBUILD_HOME, HOSTS_FILE, REBUILD_SKIP_APT=1, HADOOP_URL_BASE, HADOOP_VERSION.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
ROLE="${1:-}"; case "$ROLE" in master|worker) ;; *) die "usage: node-base.sh master|worker" ;; esac
VER="${HADOOP_VERSION:-3.4.3}"
URL_BASE="${HADOOP_URL_BASE:-https://archive.apache.org/dist/hadoop/common/hadoop-$VER}"
H="$HOME_DIR/hadoop"; DL="$HOME_DIR/downloads"
HOSTS="${HOSTS_FILE:-/etc/hosts}"
MASTER_VPC="${MASTER_VPC:-10.128.0.2}"; WORKER_VPC="${WORKER_VPC:-10.128.0.5}"
JAVA_PATH="${JAVA_HOME_PATH:-/usr/lib/jvm/java-11-openjdk-amd64}"

say "preflight ($ROLE)"
if [ -r /etc/os-release ]; then . /etc/os-release; case "${VERSION_ID:-}" in 22.04) ok "Ubuntu 22.04" ;; *) note "this was built on Ubuntu 22.04; found ${PRETTY_NAME:-unknown}" ;; esac; fi
[ "${REBUILD_SKIP_APT:-0}" = 1 ] || $SUDO true 2>/dev/null || die "passwordless sudo is needed (sudo -n true failed)"
free_kb=$(df -Pk "$HOME_DIR" | awk 'NR==2{print $4}')
[ "${free_kb:-0}" -ge 5000000 ] || die "less than 5 GB free in $HOME_DIR (the worker's default 10 GB disk is too small: create the VMs with a larger boot disk)"
ok "free space: $((free_kb / 1024)) MB"

say "packages"
if [ "${REBUILD_SKIP_APT:-0}" = 1 ]; then note "skipped (REBUILD_SKIP_APT=1)"; else
  PK="openjdk-11-jdk-headless ant git python3 zstd curl ca-certificates libcld2-0 wireguard-tools"
  [ "$ROLE" = master ] && PK="$PK maven"
  $SUDO apt-get update -qq > /dev/null 2>&1 || note "apt-get update reported a problem; continuing"
  $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $PK > "$STATE/apt.log" 2>&1 || { tail -5 "$STATE/apt.log"; die "apt-get install failed (log: $STATE/apt.log)"; }
  ok "installed: $PK"
fi
[ -d "$JAVA_PATH" ] || note "JAVA_HOME folder $JAVA_PATH is missing (the Hadoop settings name it)"

say "host names (the Google-internal addresses; the mesh stage moves them onto the mesh later)"
if grep -qE '[[:space:]]hadoop-master$' "$HOSTS" 2>/dev/null && grep -qE '[[:space:]]hadoop-worker$' "$HOSTS" 2>/dev/null; then
  ok "hadoop-master and hadoop-worker are already in $HOSTS"
else
  printf '%s hadoop-master\n%s hadoop-worker\n' "$MASTER_VPC" "$WORKER_VPC" | { [ -w "$HOSTS" ] && tee -a "$HOSTS" || $SUDO tee -a "$HOSTS"; } > /dev/null || die "could not write $HOSTS"
  ok "added $MASTER_VPC hadoop-master and $WORKER_VPC hadoop-worker"
fi

say "Hadoop $VER"
if [ -x "$H/bin/hadoop" ] && "$H/bin/hadoop" version 2>/dev/null | head -1 | grep -q "Hadoop $VER"; then
  ok "already installed in $H"
else
  mkdir -p "$DL" "$H" || die "cannot create $DL or $H"
  TAR="hadoop-$VER.tar.gz"
  if [ ! -s "$DL/$TAR" ]; then
    curl -fsSL -o "$DL/$TAR.part" "$URL_BASE/$TAR" && mv "$DL/$TAR.part" "$DL/$TAR" || die "download failed: $URL_BASE/$TAR"
  fi
  curl -fsSL -o "$DL/$TAR.sha512" "$URL_BASE/$TAR.sha512" || die "could not download the checksum file $URL_BASE/$TAR.sha512"
  want=$(grep -o -E '[0-9a-fA-F]{128}' "$DL/$TAR.sha512" | head -1 | tr 'A-F' 'a-f'); have=$(sha512sum "$DL/$TAR" | cut -d' ' -f1)
  [ -n "$want" ] && [ "$want" = "$have" ] || { rm -f "$DL/$TAR"; die "the SHA-512 of the Hadoop download does not match Apache's file (the download was removed; run again)"; }
  ok "SHA-512 matches Apache's file"
  tar -xzf "$DL/$TAR" --strip-components=1 -C "$H" || die "could not unpack the Hadoop tarball"
  "$H/bin/hadoop" version 2>/dev/null | head -1 | grep -q "Hadoop $VER" || die "unpacked, but 'hadoop version' does not say $VER"
  ok "installed in $H"
fi

say "Hadoop settings"
CONF="$H/etc/hadoop"
if python3 "$KIT_DIR/hadoop_conf.py" check "$KIT_DIR/conf" "$CONF" "$HOME_DIR" > "$STATE/conf-check.txt" 2>&1; then
  ok "the four files already match the specification"
elif [ -f "$CONF/core-site.xml" ] && grep -q "$H" "$CONF/core-site.xml" 2>/dev/null && [ "${REBUILD_FORCE_CONF:-0}" != 1 ]; then
  note "the settings differ from the specification; they are left alone (REBUILD_FORCE_CONF=1 rewrites them):"; sed 's/^/     /' "$STATE/conf-check.txt" | head -8
else
  [ ! -f "$CONF/core-site.xml" ] || cp -n "$CONF/core-site.xml" "$STATE/core-site.xml.before-rebuild" 2>/dev/null
  python3 "$KIT_DIR/hadoop_conf.py" render "$KIT_DIR/conf" "$CONF" "$HOME_DIR" || die "could not write the Hadoop settings"
  ok "written"
fi
grep -q "^export JAVA_HOME=$JAVA_PATH" "$CONF/hadoop-env.sh" 2>/dev/null || { echo "export JAVA_HOME=$JAVA_PATH" >> "$CONF/hadoop-env.sh"; ok "JAVA_HOME set in hadoop-env.sh"; }

say "data folders and shell settings"
mkdir -p "$HOME_DIR/hadoop-data/tmp" "$HOME_DIR/hadoop-data/namenode" "$HOME_DIR/hadoop-data/datanode" || die "cannot create the data folders"
RC="$HOME_DIR/.bashrc"
if ! grep -q '# >>> rebuild kit >>>' "$RC" 2>/dev/null; then
  { echo '# >>> rebuild kit >>>'; echo "export HADOOP_HOME=$H"; echo "export JAVA_HOME=$JAVA_PATH"; echo 'export PATH=$HADOOP_HOME/bin:$HADOOP_HOME/sbin:$PATH'; echo '# <<< rebuild kit <<<'; } >> "$RC"
  ok "added to $RC"
else ok "already in $RC"; fi
mark_done "base-$ROLE"
echo "BASE-DONE: $ROLE"
