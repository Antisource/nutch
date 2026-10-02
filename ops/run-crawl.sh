#!/usr/bin/env bash
# Run the Common Crawl Nutch fork on the Hadoop cluster, capped at 10 fetch attempts.
#
# Cap: --size-fetchlist 4 selects at most 4 URLs per round, and round 1 can only
# fetch the 2 seed URLs, so 3 rounds fetch at most 2 + 4 + 4 = 10 URLs.
#
# Usage (from the repo root, after "ant runtime"):
#   ops/run-crawl.sh <hdfs-seed-dir> <hdfs-crawl-dir>
set -euo pipefail

SEEDS="${1:?usage: $0 <hdfs-seed-dir> <hdfs-crawl-dir>}"
CRAWL_DIR="${2:?usage: $0 <hdfs-seed-dir> <hdfs-crawl-dir>}"
ROUNDS=3

exec runtime/deploy/bin/crawl \
  -s "$SEEDS" \
  --num-fetchers 1 \
  --num-tasks 1 \
  --size-fetchlist 4 \
  --num-threads 2 \
  --time-limit-fetch 10 \
  -D mapreduce.map.memory.mb=2048 \
  -D mapreduce.map.java.opts=-Xmx1536m \
  -D mapreduce.reduce.memory.mb=2048 \
  -D mapreduce.reduce.java.opts=-Xmx1536m \
  "$CRAWL_DIR" "$ROUNDS"