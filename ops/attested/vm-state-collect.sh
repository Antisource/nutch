#!/usr/bin/env bash
# Collect the state of one VM into a folder and a tar file, to keep it when the machine is wiped.
# Read-only; no secrets: WireGuard private and preshared keys, and any line of a configuration file that mentions
# a password, secret, token or key, are removed (matched in lower case, so it works with mawk and gawk), and every removal is listed in redactions.txt.
# The job files themselves are NOT copied (they are 135 MB each); their sizes and fingerprints are listed.
# On the master (NODE=master) the HDFS home folder and the YARN history are copied with the plain client.
# Usage: vm-state-collect.sh NODE [OUTDIR]          NODE is a label: master or worker
# Test hooks: HADOOP_HOME (default ~/hadoop), VMSTATE_HOME (default $HOME).
H="${HADOOP_HOME:-$HOME/hadoop}"; HOMEDIR="${VMSTATE_HOME:-$HOME}"
NODE="${1:?usage: vm-state-collect.sh NODE [OUTDIR]}"; OUT="${2:-$HOMEDIR/vm-state-$NODE}"
SUDO=""; [ "$(id -u)" = 0 ] || SUDO="sudo -n"
[ ! -e "$OUT" ] || { echo "VM-STATE-STOP: $OUT already exists; move it away first" >&2; exit 1; }
mkdir -p "$OUT/hadoop-conf" "$OUT/seeds-and-conf" || exit 1
RED="$OUT/redactions.txt"; : > "$RED"
SENS='password|passwd|secret|token|private[ _-]?key|presharedkey|api[ _-]?key|credential'
# copy a text file, removing every line that mentions something sensitive, and list the removals
safecopy() {  # safecopy SRC DEST
  [ -r "$1" ] || return 0
  awk -v re="$SENS" -v f="$1" '{ if (tolower($0) ~ re) { printf "%s:%d\n", f, NR >> "'"$RED"'"; print "<line removed: it mentions something sensitive>" } else print }' "$1" > "$2"
}
safecat() {  # same, from a command's output on stdin
  awk -v re="$SENS" -v f="$1" '{ if (tolower($0) ~ re) { printf "%s:%d\n", f, NR >> "'"$RED"'"; print "<line removed: it mentions something sensitive>" } else print }'
}
{ echo "node label: $NODE"; echo "collected: $(date -u +%FT%TZ)"; echo "host: $(hostname)"; uname -a; grep -E '^(PRETTY_NAME|VERSION)=' /etc/os-release 2>/dev/null
  java -version 2>&1 | head -1; "$H/bin/hadoop" version 2>/dev/null | head -1; ant -version 2>&1 | head -1; python3 --version 2>&1; git --version 2>&1; wg --version 2>&1 | head -1; } > "$OUT/versions.txt" 2>&1
for f in "$H"/etc/hadoop/*; do [ -f "$f" ] && case "$f" in *.xml|*.sh|*.properties|*.cmd|*.policy|*.conf|*.txt) safecopy "$f" "$OUT/hadoop-conf/$(basename "$f")";; esac; done
safecopy /etc/hosts "$OUT/etc-hosts.txt"
{ ip -br addr 2>&1; echo; ip route 2>&1; } > "$OUT/network.txt"
mkdir -p "$OUT/wireguard"
for f in $($SUDO ls /etc/wireguard 2>/dev/null); do $SUDO cat "/etc/wireguard/$f" 2>/dev/null | safecat "/etc/wireguard/$f" > "$OUT/wireguard/$f.redacted"; done
$SUDO wg show 2>&1 | safecat "wg show" > "$OUT/wireguard/wg-show.txt"
{ $SUDO iptables-save 2>&1; echo "----- ip6tables"; $SUDO ip6tables-save 2>&1; } > "$OUT/firewall-iptables-save.txt"
$SUDO cat /root/iptables-before-mesh 2>/dev/null > "$OUT/firewall-before-mesh.txt"
{ systemctl list-unit-files --state=enabled --no-pager 2>&1 | head -80; echo "----- crontab"; crontab -l 2>&1; } > "$OUT/services.txt"
dpkg -l 2>/dev/null | awk 'NR>5{print $2, $3}' > "$OUT/packages.txt"
{ df -h 2>&1; echo; lsblk 2>&1; } > "$OUT/disks.txt"
{ ls -la "$HOMEDIR/hadoop-data" 2>&1; du -sh "$HOMEDIR"/hadoop-data/* 2>&1; for v in "$HOMEDIR"/hadoop-data/*/current/VERSION; do echo "--- $v"; cat "$v" 2>&1; done; } > "$OUT/hadoop-data-layout.txt"
ps -eo user,pid,etime,args 2>/dev/null | grep -E '[h]adoop|[y]arn|[j]ava' | cut -c1-220 > "$OUT/processes.txt"
grep -E '^\s*export\s+(HADOOP|JAVA|PATH|NUTCH|ANT|YARN|HDFS|MAPRED)' "$HOMEDIR/.bashrc" 2>/dev/null | safecat ".bashrc" > "$OUT/bashrc-exports.txt"
{ echo "--- the home folder"; ls -l --time-style=+%F "$HOMEDIR" 2>&1 | head -150; echo "--- fingerprints of the zips and archives in the home folder"; (cd "$HOMEDIR" && sha256sum *.zip *.tar.gz *.sha256 2>/dev/null); } > "$OUT/home-listing.txt"
{ echo "size bytes, date, path, sha256"; find "$HOMEDIR" -name '*.job' -size +50M 2>/dev/null | while read -r j; do echo "$(stat -c '%s %y' "$j" | cut -c1-30) $j $(sha256sum "$j" | cut -c1-64)"; done; } > "$OUT/job-files.txt"
{ for d in ccbot-work/nutch-cc m3-build clean-build; do p="$HOMEDIR/$d"; [ -d "$p/.git" ] && { echo "--- $d"; git -C "$p" log --oneline -1 2>&1 | cut -c1-110; echo "changes in the working tree: $(git -C "$p" status --short | wc -l)"; git -C "$p" status --short | head -8; }; done; } > "$OUT/build-clones.txt" 2>&1
for d in "$HOMEDIR/ccbot-work/nutch-cc"; do for f in "$d"/seeds/* "$d"/conf/nutch-site.xml; do [ -f "$f" ] && safecopy "$f" "$OUT/seeds-and-conf/$(basename "$f")"; done; done
if [ "$NODE" = master ] && [ -x "$H/bin/hdfs" ]; then
  P="-D fs.hdfs.impl=org.apache.hadoop.hdfs.DistributedFileSystem"; mkdir -p "$OUT/hdfs"
  "$H/bin/hdfs" dfs $P -ls -R / > "$OUT/hdfs/listing-plain.txt" 2>&1
  "$H/bin/hdfs" dfs $P -du -s -h /user /tmp > "$OUT/hdfs/sizes.txt" 2>&1
  "$H/bin/hdfs" dfs $P -get "/user/$(id -un)" "$OUT/hdfs/user-home" > "$OUT/hdfs/get-home.log" 2>&1
  "$H/bin/hdfs" dfs $P -get /tmp/hadoop-yarn/staging/history "$OUT/hdfs/yarn-history" > "$OUT/hdfs/get-history.log" 2>&1
  (cd "$OUT/hdfs" && find user-home yarn-history -type f 2>/dev/null | sort | xargs sha256sum > SHA256SUMS-of-hdfs-files.txt)
fi
n_red=$(grep -c . "$RED"); echo "redactions: $n_red (listed in redactions.txt)"
(cd "$OUT" && find . -type f ! -name SHA256SUMS | sort | xargs sha256sum > SHA256SUMS)
TAR="$OUT.tar.gz"; tar czf "$TAR" -C "$(dirname "$OUT")" "$(basename "$OUT")" && echo "archive: $TAR  $(stat -c %s "$TAR") bytes  sha256 $(sha256sum "$TAR" | cut -c1-16)"
echo "files: $(find "$OUT" -type f | wc -l)   hdfs files copied: $(find "$OUT/hdfs" -type f 2>/dev/null | wc -l)"
echo "VM-STATE-COLLECTED: $NODE"
