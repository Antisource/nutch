#!/usr/bin/env bash
# Milestone 4, baby step 4.6.1: the wrapper's classes on Hadoop's own classpath.
#
# Hadoop puts every jar of share/hadoop/common/lib on the classpath of its commands, its daemons and
# the task containers it starts. A jar placed there is therefore loaded by all of them, without any
# setting, and nothing uses it until a setting names its classes (baby step 4.6.2). This script builds
# that jar from the wrapper's classes inside a job file (so they are byte for byte the classes that
# ran), installs it on one node, compares it with a job file class by class, and tests that the
# wrapper loads from the library folder with no job file on the classpath.
#
# Usage:
#   wrapper-jar.sh build JOBFILE OUTJAR        build attested-hdfs.jar from the classes in JOBFILE (deterministic)
#   wrapper-jar.sh install JAR [JOBFILE]       copy JAR into Hadoop's common/lib on this node; with JOBFILE, refuse
#                                              unless its classes are identical to the job file's
#   wrapper-jar.sh verify [JOBFILE]            what is installed here, on the classpath, and (with JOBFILE) identical
#   wrapper-jar.sh selftest                    the wrapper loads from the library folder (reads HDFS only: ls /)
#   wrapper-jar.sh remove                      delete the installed jar (undo)
# Settings (environment): HADOOP_HOME (default ~/hadoop); ATTESTED_FORCE=1 to replace a different jar.
set -uo pipefail
H="${HADOOP_HOME:-$HOME/hadoop}"
LIBDIR="$H/share/hadoop/common/lib"
JAR="$LIBDIR/attested-hdfs.jar"
die() { echo "WRAPPER-JAR-STOP: $*" >&2; exit 1; }
fp() { sha256sum "$1" | cut -c1-64; }

# classes_same JAR JOBFILE: prints SAME or the differences; exit code 0 only for SAME
classes_same() {
  python3 - "$1" "$2" <<'PY'
import sys, zipfile
jar, job = zipfile.ZipFile(sys.argv[1]), zipfile.ZipFile(sys.argv[2])
P = "org/apache/nutch/attested/"
a = {n: jar.read(n) for n in jar.namelist() if n.startswith(P) and n.endswith(".class")}
b = {n: job.read(n) for n in job.namelist() if n.startswith(P) and n.endswith(".class")}
bad = [("only in the jar", n) for n in sorted(set(a) - set(b))] + [("only in the job file", n) for n in sorted(set(b) - set(a))] \
    + [("different bytes", n) for n in sorted(set(a) & set(b)) if a[n] != b[n]]
if bad or not a:
    for why, n in bad: print("  %s: %s" % (why, n))
    print("CLASSES-DIFFER" if a else "CLASSES-DIFFER (the jar holds no wrapper class)"); sys.exit(1)
print("CLASSES-SAME (%d classes identical to the job file)" % len(a))
PY
}

case "${1:-}" in
build)
  job="${2:?usage: $0 build JOBFILE OUTJAR}"; out="${3:?usage: $0 build JOBFILE OUTJAR}"
  [ -f "$job" ] || die "no job file at $job"
  [ ! -e "$out" ] || die "$out already exists; remove it or choose another name"
  python3 - "$job" "$out" <<'PY' || die "could not build the jar"
import sys, zipfile
job, out = sys.argv[1], sys.argv[2]
src = zipfile.ZipFile(job)
names = sorted(n for n in src.namelist() if n.startswith("org/apache/nutch/attested/") and n.endswith(".class"))
if not names: sys.exit("no wrapper classes under org/apache/nutch/attested/ in " + job)
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    def put(name, data):
        zi = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0)); zi.compress_type = zipfile.ZIP_DEFLATED
        zi.external_attr = 0o644 << 16; z.writestr(zi, data)
    put("META-INF/MANIFEST.MF", "Manifest-Version: 1.0\r\nCreated-By: attested wrapper-jar.sh (step 4.6.1)\r\n\r\n")
    for n in names: put(n, src.read(n))
print("%d classes written" % len(names))
PY
  echo "built $out: sha256 $(fp "$out")"
  classes_same "$out" "$job" || die "the new jar does not match the job file"
  ;;
install)
  jar="${2:?usage: $0 install JAR [JOBFILE]}"; job="${3:-}"
  [ -f "$jar" ] || die "no jar at $jar"
  [ -d "$LIBDIR" ] || die "no library folder $LIBDIR (is HADOOP_HOME right?)"
  if [ -n "$job" ]; then [ -f "$job" ] || die "no job file at $job"; classes_same "$jar" "$job" || die "the jar's classes differ from the job file's"; fi
  if [ -f "$JAR" ] && ! cmp -s "$jar" "$JAR"; then
    [ "${ATTESTED_FORCE:-}" = 1 ] || die "a different attested-hdfs.jar is already installed here (sha256 $(fp "$JAR" | cut -c1-16)); set ATTESTED_FORCE=1 to replace it"
  fi
  cp "$jar" "$JAR.new" && chmod 644 "$JAR.new" && mv -f "$JAR.new" "$JAR" || die "could not install into $LIBDIR"
  echo "installed $JAR: sha256 $(fp "$JAR")"
  n="$("$H/bin/hadoop" classpath --glob 2>/dev/null | tr ':' '\n' | grep -c 'common/lib/attested-hdfs.jar')"
  [ "$n" = 1 ] && echo "on Hadoop's classpath: yes" || die "the jar is installed but not on Hadoop's classpath ($n entries)"
  echo "WRAPPER-JAR-INSTALLED"
  ;;
verify)
  job="${2:-}"
  if [ ! -f "$JAR" ]; then echo "not installed: $JAR"; exit 1; fi
  echo "installed: $JAR"; echo "sha256: $(fp "$JAR")"; ls -l "$JAR" | awk '{print "size:", $5, "bytes"}'
  n="$("$H/bin/hadoop" classpath --glob 2>/dev/null | tr ':' '\n' | grep -c 'common/lib/attested-hdfs.jar')"; echo "entries on Hadoop's classpath: $n"
  if [ -n "$job" ]; then classes_same "$JAR" "$job" || exit 1; fi
  ;;
selftest)
  [ -f "$JAR" ] || die "the jar is not installed here"
  dir="$(mktemp -d /tmp/attested-jar-selftest.XXXXXX)" || die "no temporary folder"
  "$H/bin/hdfs" dfs -D fs.hdfs.impl=org.apache.nutch.attested.AttestedHdfsFileSystem \
      -D fs.AbstractFileSystem.hdfs.impl=org.apache.nutch.attested.AttestedHdfs \
      -D attested.audit.dir="$dir/audit" -D attested.records.dir="$dir/records" -ls / > "$dir/out.txt" 2>&1
  if cat "$dir"/audit/*.tsv 2>/dev/null | grep -F "INIT" | grep -qF "wrapper=org.apache.nutch.attested.AttestedHdfsFileSystem"; then
    echo "JAR-LOADS-FROM-LIB-OK: a plain 'hdfs dfs -ls /' with the wrapper switched on loaded it from $LIBDIR (no job file on the classpath)"
    rm -rf "$dir"
  else
    echo "JAR-SELFTEST-FAILED: see $dir/out.txt" >&2; exit 1
  fi
  ;;
remove)
  [ -f "$JAR" ] || die "nothing to remove: $JAR does not exist"
  rm -f "$JAR" && echo "removed $JAR"
  ;;
*)
  echo "usage: $0 build JOBFILE OUTJAR | install JAR [JOBFILE] | verify [JOBFILE] | selftest | remove" >&2; exit 2
  ;;
esac
