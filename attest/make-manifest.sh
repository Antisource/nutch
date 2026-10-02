#!/usr/bin/env bash
# Write a plain-text manifest describing one node of the crawl cluster.
#
# Usage: attest/make-manifest.sh <master|worker> <output-file>
#
# Environment (all optional):
#   WORK_DIR    folder holding nutch-cc, crawler-commons, language-detection-cld2
#               (default: $HOME/ccbot-work), master only
#   HADOOP_DIR  Hadoop install folder (default: $HOME/hadoop)
#   FORK        the Nutch fork checkout (default: $WORK_DIR/nutch-cc), master only
#   SEED_FILE   seed list used for the run (default: $WORK_DIR/seeds/seed.txt)
#   WARC_OUT    folder holding the run's SHA256SUMS.txt (default: $WORK_DIR/warc-out)
#
# The manifest is only text written by this script. Binding it to a TDX quote
# (attest/quote.sh) proves which Trust Domain vouched for its fingerprint,
# not that every line in it is true.
set -euo pipefail

ROLE="${1:-}"
OUT="${2:-}"
case "$ROLE" in
  master|worker) ;;
  *) echo "usage: $0 <master|worker> <output-file>" >&2; exit 1 ;;
esac
[ -n "$OUT" ] || { echo "usage: $0 <master|worker> <output-file>" >&2; exit 1; }

WORK_DIR="${WORK_DIR:-$HOME/ccbot-work}"
HADOOP_DIR="${HADOOP_DIR:-$HOME/hadoop}"
FORK="${FORK:-$WORK_DIR/nutch-cc}"
SEED_FILE="${SEED_FILE:-$WORK_DIR/seeds/seed.txt}"
WARC_OUT="${WARC_OUT:-$WORK_DIR/warc-out}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

{
  echo "# training-custody crawl manifest"
  echo "node: $(hostname)"
  echo "role: hadoop-$ROLE"
  echo "date_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "kernel: $(uname -r)"
  echo "hadoop: $(hadoop version | head -1)"
  echo "java: $(java -version 2>&1 | head -1)"
  echo "libcld2: $(dpkg -s libcld2-0 | grep '^Version')"
  echo "scripts_repo_commit: $(git -C "$REPO_DIR" rev-parse HEAD)"
  echo "scripts_repo_uncommitted_files: $(git -C "$REPO_DIR" status --short | wc -l)"
  echo "--- sha256 of the scripts used"
  sha256sum "$REPO_DIR"/attest/*.sh "$REPO_DIR"/ops/*.sh
  if [ "$ROLE" = master ]; then
    echo "fork_commit: $(git -C "$FORK" rev-parse HEAD)"
    echo "fork_branch: $(git -C "$FORK" branch --show-current)"
    echo "fork_uncommitted_files: $(git -C "$FORK" status --short | wc -l)"
    echo "crawler_commons_commit: $(git -C "$WORK_DIR/crawler-commons" rev-parse HEAD)"
    echo "cld2_commit: $(git -C "$WORK_DIR/language-detection-cld2" rev-parse HEAD)"
  fi
  echo "--- sha256 of hadoop configuration"
  sha256sum "$HADOOP_DIR"/etc/hadoop/{core,hdfs,yarn,mapred}-site.xml
  if [ "$ROLE" = master ]; then
    echo "--- sha256 of inputs"
    sha256sum "$FORK/conf/nutch-site.xml" "$SEED_FILE" \
      "$FORK/conf/effective_tld_names.dat" "$FORK"/runtime/deploy/apache-nutch-*.job
    if [ -f "$WARC_OUT/SHA256SUMS.txt" ]; then
      echo "--- sha256 of outputs (from $WARC_OUT/SHA256SUMS.txt)"
      cat "$WARC_OUT/SHA256SUMS.txt"
    fi
  fi
} > "$OUT"

echo "manifest written: $OUT"