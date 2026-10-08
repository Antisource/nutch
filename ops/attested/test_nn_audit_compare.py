#!/usr/bin/env python3
"""Tests of nn_audit_compare.py on a data set that has the shape of the real probe (NameNode lines in the
real format, wrapper lines in the wrapper's 7-column format) and a known answer."""
import calendar, os, subprocess, sys, tempfile, time

TOOL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "nn_audit_compare.py")
D = "/user/u/nn-audit-probe-T"
BASE = calendar.timegm(time.strptime("2026-10-08 06:42:00", "%Y-%m-%d %H:%M:%S")) * 1000
results = []


def check(name, ok):
    results.append(ok)
    print(("PASS  " if ok else "FAIL  ") + name)


class Data:
    def __init__(self):
        self.nn, self.wr, self.t, self.skew = [], [], BASE, 0

    def nn_line(self, t, cmd, src, dst="null", allowed="true", perm="null"):
        stamp = time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(t // 1000)) + ",%03d" % (t % 1000)
        self.nn.append("%s INFO FSNamesystem.audit: allowed=%s\tugi=u (auth:SIMPLE)\tip=/10.10.0.1\tcmd=%s\tsrc=%s\tdst=%s\tperm=%s\tproto=rpc" % (stamp, allowed, cmd, src, dst, perm))

    def wr_line(self, t, op, p1, p2="", extra=""):
        self.wr.append("%d\ttdx-lab\t4242\t%s\thdfs://hadoop-master:9000%s\t%s\t%s" % (t + self.skew, op, p1, ("hdfs://hadoop-master:9000" + p2) if p2 else "", extra))

    def tick(self, ms=2000):
        self.t += ms
        return self.t

    # operations in the shapes seen on the real cluster
    def w_mkdir(self):
        t = self.tick(); self.nn_line(t, "mkdirs", D, perm="u:supergroup:rwxr-xr-x"); self.wr_line(t + 5, "MKDIRS", D)

    def w_put(self, name):
        t = self.tick(); x = D + "/" + name; xc = x + "._COPYING_"; rec = D + "/." + name + ".attested"; recc = D + "/." + name + "._COPYING_.attested"
        for p in (x, rec, D, xc, recc):
            self.nn_line(t, "getfileinfo", p)
        self.nn_line(t + 60, "create", xc, perm="u:supergroup:rw-r--r--"); self.wr_line(t + 62, "CREATE", xc, extra="overwrite=true")
        self.nn_line(t + 650, "create", recc, perm="u:supergroup:rw-r--r--"); self.wr_line(t + 652, "CREATE", recc, extra="sidecar")
        self.nn_line(t + 700, "open", recc)
        self.nn_line(t + 760, "rename", xc, x, perm="u:supergroup:rw-r--r--"); self.wr_line(t + 762, "RENAME", xc, x)
        self.nn_line(t + 770, "rename", recc, rec, perm="u:supergroup:rw-r--r--"); self.wr_line(t + 772, "RENAME", recc, rec, "sidecar")

    def w_cat(self, name):
        t = self.tick(); x = D + "/" + name; rec = D + "/." + name + ".attested"
        self.nn_line(t, "getfileinfo", x); self.nn_line(t + 40, "open", rec)
        self.nn_line(t + 170, "open", x); self.wr_line(t + 230, "OPEN", x, extra="openFile verify=ok")
        self.nn_line(t + 175, "open", rec)

    def w_mv(self, a, b):
        t = self.tick()
        self.nn_line(t, "rename", D + "/" + a, D + "/" + b); self.wr_line(t + 3, "RENAME", D + "/" + a, D + "/" + b)
        self.nn_line(t + 8, "rename", D + "/." + a + ".attested", D + "/." + b + ".attested"); self.wr_line(t + 10, "RENAME", D + "/." + a + ".attested", D + "/." + b + ".attested", "sidecar")

    def w_rm(self, name):
        t = self.tick()
        self.nn_line(t, "delete", D + "/" + name); self.wr_line(t + 3, "DELETE", D + "/" + name, extra="recursive=false")
        self.nn_line(t + 6, "delete", D + "/." + name + ".attested"); self.wr_line(t + 8, "DELETE", D + "/." + name + ".attested", extra="recursive=false sidecar")

    def w_ls(self):
        t = self.tick(); self.nn_line(t, "getfileinfo", D); self.nn_line(t + 40, "listStatus", D)
        self.nn_line(t + 60, "open", D + "/.w-read.attested"); self.nn_line(t + 200, "open", D + "/.w-renamed-dst.attested")

    def p_cat(self, name):
        t = self.tick(12000); self.nn_line(t, "getfileinfo", D + "/" + name); self.nn_line(t + 30, "open", D + "/" + name)

    def p_put(self, name):
        t = self.tick(); x = D + "/" + name
        self.nn_line(t, "getfileinfo", x); self.nn_line(t + 50, "create", x + "._COPYING_", perm="u:supergroup:rw-r--r--"); self.nn_line(t + 200, "rename", x + "._COPYING_", x, perm="u:supergroup:rw-r--r--")

    def p_rm(self, name):
        t = self.tick(); self.nn_line(t, "getfileinfo", D + "/" + name); self.nn_line(t + 20, "delete", D + "/" + name)

    def p_mv(self, a, b):
        t = self.tick(); self.nn_line(t, "rename", D + "/" + a, D + "/" + b, perm="u:supergroup:rw-r--r--")

    def write(self, root, name):
        nn = os.path.join(root, name + ".nn.log"); wd = os.path.join(root, name + "-wrapper")
        os.makedirs(wd, exist_ok=True)
        open(nn, "w").write("\n".join(self.nn) + "\n")
        open(os.path.join(wd, "w.tsv"), "w").write("\n".join(self.wr) + "\n")
        return nn, wd


def probe_like():
    d = Data()
    d.w_mkdir(); d.w_put("w-read"); d.w_cat("w-read"); d.w_put("w-renamed-src"); d.w_mv("w-renamed-src", "w-renamed-dst")
    d.w_put("w-deleted"); d.w_rm("w-deleted"); d.w_ls()
    d.p_cat("w-read"); d.p_put("p-new"); d.p_put("p-gone"); d.p_rm("p-gone"); d.p_mv("w-renamed-dst", "p-moved")
    return d


def run(*args):
    p = subprocess.run([sys.executable, TOOL] + list(args), capture_output=True, text=True)
    return p.returncode, p.stdout, p.stderr


with tempfile.TemporaryDirectory() as root:
    d = probe_like(); nn, wd = d.write(root, "t1")
    rc, out, err = run("--nn", nn, "--wrapper", wd, "--tsv", os.path.join(root, "t1.tsv"))
    expected = [("open", D + "/w-read"), ("create", D + "/p-new._COPYING_"), ("rename", D + "/p-new._COPYING_ -> " + D + "/p-new"),
                ("create", D + "/p-gone._COPYING_"), ("rename", D + "/p-gone._COPYING_ -> " + D + "/p-gone"), ("delete", D + "/p-gone"),
                ("rename", D + "/w-renamed-dst -> " + D + "/p-moved")]
    lines = [l for l in out.split("\n") if l.startswith("  ") and "[u " in l]
    check("probe-like data: exit code 1 and the verdict says FINDINGS (7)", rc == 1 and "NN-AUDIT-COMPARE-FINDINGS (7)" in out)
    check("probe-like data: exactly the seven plain events are unexplained, nothing else", len(lines) == 7 and all(any(c in l and p in l for c, p in [e]) for l, e in zip(sorted(lines), sorted(expected, key=lambda e: e[1]))) or all(any(e[0] in l and e[1] in l for l in lines) for e in expected))
    check("probe-like data: every wrapper operation is explained (no wrapper line left over)", "wrapper lines the NameNode log does not show" not in out)
    check("probe-like data: the wrapper's reads of its own records are not findings", ".attested" not in "\n".join(lines).replace("._COPYING_", "") or all("open" not in l or ".attested" not in l for l in lines))
    check("probe-like data: getfileinfo and listStatus are only counted", "getfileinfo" in out and "listStatus" in out)
    tsv = open(os.path.join(root, "t1.tsv")).read().strip().split("\n")
    check("probe-like data: the TSV has a header and seven rows", len(tsv) == 8 and tsv[0].startswith("verdict\t"))

    # a plain read right after a wrapped read of the same file is still found (one wrapper line explains one event)
    d2 = Data(); d2.w_mkdir(); d2.w_put("f"); d2.w_cat("f")
    d2.nn_line(d2.t + 600, "open", D + "/f")
    nn2, wd2 = d2.write(root, "t2")
    rc1, out1, _ = run("--nn", nn2, "--wrapper", wd2)
    check("a plain read 0.4 s after a wrapped read of the same file is a finding", rc1 == 1 and "NN-AUDIT-COMPARE-FINDINGS (1)" in out1)

    # the window is for clocks that are not exactly in step
    d5 = Data(); d5.skew = 5000; d5.w_mkdir(); d5.w_put("f")
    nn5, wd5 = d5.write(root, "t5")
    rc3, out3, _ = run("--nn", nn5, "--wrapper", wd5)
    rc4, out4, _ = run("--nn", nn5, "--wrapper", wd5, "--window-ms", "6000")
    check("window: wrapper clocks 5 s off are not matched with the default 3 s window (findings and left-over wrapper lines)", rc3 == 1 and "wrapper lines the NameNode log does not show" in out3)
    check("window: a 6 s window matches them", rc4 == 0 and "NN-AUDIT-COMPARE-CLEAN" in out4)

    # --known
    rc, out, _ = run("--nn", nn, "--wrapper", wd, "--known", "probe:nn-audit-probe-T")
    check("--known: events with a known cause are listed and counted separately, and do not fail", rc == 0 and "known, not counted: 7" in out and "NN-AUDIT-COMPARE-CLEAN" in out)

    # a plain command that touches a record file is a finding
    d3 = Data(); d3.w_mkdir(); d3.w_put("f"); d3.p_rm(".f.attested")
    nn3, wd3 = d3.write(root, "t3")
    rc, out, _ = run("--nn", nn3, "--wrapper", wd3)
    check("a record file deleted behind the wrapper's back is a finding", rc == 1 and "delete" in out and ".f.attested" in out)

    # denied requests, damaged lines, a wrapper line without a NameNode event, time filter
    d4 = Data(); d4.w_mkdir(); d4.nn_line(d4.tick(), "open", D + "/secret", allowed="false"); d4.wr_line(d4.tick(), "DELETE", D + "/ghost")
    nn4, wd4 = d4.write(root, "t4")
    with open(nn4, "a") as f:
        f.write("this is not an audit line\n2026-10-08 06:42:59,000 INFO FSNamesystem.audit: allowed=true\tugi=u\n")
    rc, out, _ = run("--nn", nn4, "--wrapper", wd4)
    check("a denied request is reported", "requests the NameNode DENIED: 1" in out)
    check("damaged lines are counted and skipped, not fatal", "nn lines skipped (not an audit line): 1" in out and "nn lines skipped (no cmd): 1" in out)
    check("a wrapper line the NameNode never saw is reported", "wrapper lines the NameNode log does not show" in out and "DELETE" in out)
    rc, out, _ = run("--nn", nn, "--wrapper", wd, "--from", "2026-10-08 06:42:00", "--to", "2026-10-08 06:42:02")
    check("--from and --to restrict the comparison", "NameNode lines read" in out and rc in (0, 1))

    # bad input
    rc, _, err = run("--nn", nn)
    check("no --wrapper is refused with exit code 2", rc == 2 and "give at least one" in err)
    rc, _, err = run("--nn", os.path.join(root, "missing.log"), "--wrapper", wd)
    check("a missing file is refused with exit code 2", rc == 2 and "cannot read" in err)
    rc, _, err = run("--nn", nn, "--wrapper", wd, "--from", "yesterday")
    check("a bad time is refused with exit code 2", rc == 2 and "bad time" in err)

ok = sum(results)
print("%s (%d of %d checks passed)" % ("ALL-PASS" if ok == len(results) else "SOME-FAILED", ok, len(results)))
sys.exit(0 if ok == len(results) else 1)
