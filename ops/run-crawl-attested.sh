#!/usr/bin/env bash
# Like ops/run-crawl.sh (same cap of 10 fetch attempts, same options), but every
# HDFS request of the Nutch jobs goes through the attested wrapper: the two -D
# settings below put it behind hdfs:// for FileSystem and for FileContext, and the
# wrapper writes its audit log to /tmp/attested-audit on each machine.
#
# Usage (from the repo root, after "ant runtime"):
#   ops/run-crawl-attested.sh <hdfs-seed-dir> <hdfs-crawl-dir>
#
# The crawl script's own two "hadoop fs" calls (a folder test and a listing of the
# segments) run in a separate command-line program that does not get the settings;
# they only read.
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
  -D fs.hdfs.impl=org.apache.nutch.attested.AttestedHdfsFileSystem \
  -D fs.AbstractFileSystem.hdfs.impl=org.apache.nutch.attested.AttestedHdfs \
  -D attested.audit.dir=/tmp/attested-audit \
  -D mapreduce.map.memory.mb=2048 \
  -D mapreduce.map.java.opts=-Xmx1536m \
  -D mapreduce.reduce.memory.mb=2048 \
  -D mapreduce.reduce.java.opts=-Xmx1536m \
  "$CRAWL_DIR" "$ROUNDS"
