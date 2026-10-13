#!/usr/bin/env python3
"""Render, or check, the four Hadoop configuration files of the lab cluster from conf/*.props.

  hadoop_conf.py render PROPS_DIR OUT_DIR HOME     write core-site.xml, hdfs-site.xml, yarn-site.xml, mapred-site.xml
  hadoop_conf.py check  PROPS_DIR CONF_DIR HOME    compare the properties of the files in CONF_DIR with the specification

The check compares properties (name and value), not formatting. It reports MISSING (in the specification, not in
the file), DIFFERENT (another value) and EXTRA (in the file, not in the specification: the specification is then
incomplete, which is worth knowing). Exit code 0 only when there is nothing to report.
"""
import os
import sys
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape

FILES = ["core-site", "hdfs-site", "yarn-site", "mapred-site"]


def load_props(path, home):
    props = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            k, v = line.split("=", 1)
            props[k.strip()] = v.strip().replace("@HOME@", home)
    return props


def render(props):
    out = ['<?xml version="1.0" encoding="UTF-8"?>', '<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>',
           "<configuration>"]
    for k, v in props.items():
        out.append("  <property>\n    <name>%s</name>\n    <value>%s</value>\n  </property>" % (escape(k), escape(v)))
    out.append("</configuration>")
    return "\n".join(out) + "\n"


def read_xml(path):
    props = {}
    for p in ET.parse(path).getroot().findall("property"):
        name = p.findtext("name")
        if name is not None:
            props[name.strip()] = (p.findtext("value") or "").strip()
    return props


def main(argv):
    if len(argv) != 5 or argv[1] not in ("render", "check"):
        print(__doc__)
        return 2
    mode, props_dir, target, home = argv[1:]
    if mode == "render":
        os.makedirs(target, exist_ok=True)
        for name in FILES:
            with open(os.path.join(target, name + ".xml"), "w", encoding="utf-8", newline="\n") as f:
                f.write(render(load_props(os.path.join(props_dir, name + ".props"), home)))
        print("rendered: " + ", ".join(n + ".xml" for n in FILES))
        return 0
    problems = 0
    for name in FILES:
        want = load_props(os.path.join(props_dir, name + ".props"), home)
        path = os.path.join(target, name + ".xml")
        if not os.path.isfile(path):
            print("MISSING-FILE  %s.xml" % name)
            problems += 1
            continue
        have = read_xml(path)
        for k, v in want.items():
            if k not in have:
                print("MISSING    %s.xml  %s" % (name, k))
                problems += 1
            elif have[k] != v:
                print("DIFFERENT  %s.xml  %s: specification %r, file %r" % (name, k, v, have[k]))
                problems += 1
        for k in have:
            if k not in want:
                print("EXTRA      %s.xml  %s=%s" % (name, k, have[k]))
                problems += 1
    print("CONFIG-SAME" if problems == 0 else "CONFIG-DIFFERS (%d)" % problems)
    return 0 if problems == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
