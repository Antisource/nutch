#!/usr/bin/env python3
"""Tests of contract_compare.py. Run: python3 test_contract_compare.py"""
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "contract_compare.py")
fails = 0


def check(label, ok):
    global fails
    print(("PASS  " if ok else "FAIL  ") + label)
    fails += 0 if ok else 1


def run(plain, wrapped, *extra):
    with tempfile.TemporaryDirectory() as d:
        paths = []
        for name, rows in (("plain.tsv", plain), ("wrapped.tsv", wrapped)):
            p = os.path.join(d, name)
            with open(p, "w", encoding="utf-8") as f:
                for r in rows:
                    f.write("\t".join(r) + "\n")
            paths.append(p)
        args = list(extra)
        for i, a in enumerate(args):
            if a.startswith("@"):
                e = os.path.join(d, "expected.tsv")
                with open(e, "w", encoding="utf-8") as f:
                    f.write(a[1:].replace("\\t", "\t") + "\n")
                args[i] = e
        r = subprocess.run([sys.executable, TOOL] + paths + args, capture_output=True, text=True)
        return r.returncode, r.stdout


SYNC_P = ("plain", "TestAttestedContractCreate", "testSyncable", "PASS", "")
SYNC_W = ("wrapped", "TestAttestedContractCreate", "testSyncable", "FAIL",
          "IOException: Attested verification failed for hdfs://x/testSyncable: the file has no record")
OTHER_P = ("plain", "TestAttestedContractSeek", "testSeek", "PASS", "")
OTHER_W = ("wrapped", "TestAttestedContractSeek", "testSeek", "PASS", "")

rc, out = run([SYNC_P, OTHER_P], [SYNC_W, OTHER_W])
check("the shipped list: testSyncable is an expected difference, and the verdict says so",
      rc == 0 and "EXPECTED-DIFFERENCE  TestAttestedContractCreate.testSyncable" in out
      and "CONTRACT-SAME-AS-HDFS (1 explained difference)" in out)
rc, out = run([SYNC_P, OTHER_P], [SYNC_W, OTHER_W], "--no-expected")
check("with --no-expected the same result is a real difference", rc == 1 and "CONTRACT-DIFFERENCES (1)" in out)
other_fail = ("wrapped", "TestAttestedContractCreate", "testSyncable", "FAIL", "IOException: something else broke")
rc, out = run([SYNC_P, OTHER_P], [other_fail, OTHER_W])
check("the same test failing for a different reason is a real difference", rc == 1 and "WRAPPER-DIFFERENCE  TestAttestedContractCreate.testSyncable" in out)
new_fail = ("wrapped", "TestAttestedContractSeek", "testSeek", "FAIL", "IOException: the file has no record")
rc, out = run([SYNC_P, OTHER_P], [SYNC_W, new_fail])
check("another test with the same message is not covered by the list", rc == 1 and "WRAPPER-DIFFERENCE  TestAttestedContractSeek.testSeek" in out)
sync_ok = ("wrapped", "TestAttestedContractCreate", "testSyncable", "PASS", "")
rc, out = run([SYNC_P, OTHER_P], [sync_ok, OTHER_W])
check("an expected difference that did not happen is reported, and the verdict is plain",
      rc == 0 and "EXPECTED-DIFFERENCE-NOT-SEEN  TestAttestedContractCreate.testSyncable" in out and "CONTRACT-SAME-AS-HDFS\n" in out)
rc, out = run([SYNC_P, OTHER_P], [SYNC_W, OTHER_W], "@TestAttestedContractCreate\\ttestSyncable\\tsome other phrase\\twhy")
check("a list entry whose phrase is not in the message does not hide the difference", rc == 1 and "CONTRACT-DIFFERENCES (1)" in out)
rc, out = run([SYNC_P, OTHER_P], [OTHER_W])
check("a test missing from the wrapped run is still a real difference", rc == 1 and "MISSING-IN-WRAPPED" in out)
print("ALL-PASS (%d checks)" % 7 if not fails else "SOME-FAILED (%d)" % fails)
sys.exit(1 if fails else 0)
