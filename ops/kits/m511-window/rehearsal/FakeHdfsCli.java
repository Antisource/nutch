package org.apache.nutch.attested;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.URI;
import java.nio.file.Files;
import java.nio.file.Paths;
import org.apache.hadoop.conf.Configuration;
import org.apache.hadoop.fs.FSDataInputStream;
import org.apache.hadoop.fs.FSDataOutputStream;
import org.apache.hadoop.fs.FileStatus;
import org.apache.hadoop.fs.FileSystem;
import org.apache.hadoop.fs.Path;

/**
 * REHEARSAL ONLY: a stand-in for "hdfs" that runs the REAL wrapper over a local folder (the smoke test's fake HDFS).
 * Environment: FAKE_ROOT (the folder that plays the HDFS root), FAKE_STATE (audit and record logs), HADOOP_CONF_DIR (core-site.xml).
 * Commands: getconf -confKey K | dfs [-D k=v] -mkdir [-p] | -put [-f] | -cat | -get | -rm [-r] [-skipTrash] | -ls [-R] | -test -e|-d.
 */
public final class FakeHdfsCli {
  static String root;

  static Path p(String hdfsPath) {
    return new Path("hdfs://fake:9000" + root + hdfsPath);
  }

  static String show(Path path) {
    String s = path.toUri().getPath();
    return s.startsWith(root) ? s.substring(root.length()) : s;
  }

  public static void main(String[] argv) throws Exception {
    root = new File(System.getenv("FAKE_ROOT")).getAbsolutePath();
    boolean plain = false;
    java.util.List<String> a = new java.util.ArrayList<>();
    Configuration conf = AttestedFsSmoke.fakeConf(Paths.get(System.getenv("FAKE_STATE")));
    AttestedSettings.trustAllSourcesForTesting(true);
    String confDir = System.getenv("HADOOP_CONF_DIR");
    if (confDir != null && new File(confDir, "core-site.xml").exists()) {
      Configuration site = new Configuration(false);
      site.addResource(new Path(new File(confDir, "core-site.xml").toURI()));
      for (java.util.Map.Entry<String, String> e : site) {
        if (e.getKey().startsWith("attested.") && !e.getKey().equals(AttestedAudit.DIR_KEY) && !e.getKey().equals(AttestedRecords.DIR_KEY)) {
          conf.set(e.getKey(), e.getValue());
        }
      }
    }
    for (int i = 0; i < argv.length; i++) {
      if (argv[i].equals("-D")) {
        String kv = argv[++i];
        if (kv.startsWith("fs.hdfs.impl=") && kv.endsWith("DistributedFileSystem")) {
          plain = true;
        } else if (kv.startsWith("attested.")) {
          conf.set(kv.substring(0, kv.indexOf('=')), kv.substring(kv.indexOf('=') + 1));
        }
      } else {
        a.add(argv[i]);
      }
    }
    int rc;
    try {
      if (a.get(0).equals("getconf")) {
        String v = conf.get(a.get(2));
        if (v == null) {
          System.err.println("Configuration " + a.get(2) + " is missing.");
          System.exit(1);
        }
        System.out.println(v);
        return;
      }
      FileSystem fs;
      if (plain) {
        AttestedFsSmoke.FakeHdfs raw = new AttestedFsSmoke.FakeHdfs();
        raw.initialize(URI.create("hdfs://fake:9000"), new Configuration(false));
        fs = raw;
      } else {
        fs = FileSystem.newInstance(URI.create("hdfs://fake:9000"), conf);
      }
      rc = dfs(fs, a.subList(1, a.size()));
    } catch (IOException e) {
      System.err.println(e.getClass().getSimpleName() + ": " + e.getMessage());
      rc = 1;
    }
    System.out.flush();
    System.exit(rc);
  }

  static int dfs(FileSystem fs, java.util.List<String> a) throws IOException {
    String cmd = a.get(0);
    java.util.List<String> r = new java.util.ArrayList<>(a.subList(1, a.size()));
    boolean flagP = r.remove("-p"), flagF = r.remove("-f"), flagR = r.remove("-r") | r.remove("-R"), skip = r.remove("-skipTrash");
    switch (cmd) {
      case "-mkdir":
        return fs.mkdirs(p(r.get(0))) ? 0 : 1;
      case "-test": {
        String flag = r.get(0);
        Path t = p(r.get(1));
        return fs.exists(t) && (!flag.equals("-d") || fs.getFileStatus(t).isDirectory()) ? 0 : 1;
      }
      case "-put": {
        Path dst = p(r.get(1));
        if (fs.exists(dst) && fs.getFileStatus(dst).isDirectory()) {
          dst = new Path(dst, new File(r.get(0)).getName());
        } else if (fs.exists(dst) && !flagF) {
          System.err.println("put: `" + show(dst) + "': File exists");
          return 1;
        }
        try (InputStream in = r.get(0).equals("-") ? System.in : Files.newInputStream(Paths.get(r.get(0)));
            FSDataOutputStream out = fs.create(dst, true)) {
          byte[] buf = new byte[8192];
          for (int n; (n = in.read(buf)) > 0;) {
            out.write(buf, 0, n);
          }
        }
        return 0;
      }
      case "-cat": {
        try (FSDataInputStream in = fs.open(p(r.get(0)))) {
          byte[] buf = new byte[8192];
          for (int n; (n = in.read(buf)) > 0;) {
            System.out.write(buf, 0, n);
          }
        }
        return 0;
      }
      case "-get": {
        copy(fs, p(r.get(0)), new File(r.get(1)));
        return 0;
      }
      case "-rm":
        return fs.delete(p(r.get(0)), flagR) ? 0 : 1;
      case "-ls": {
        Path t = p(r.get(0));
        if (!fs.exists(t)) {
          return 1;
        }
        list(fs, t, flagR);
        return 0;
      }
      default:
        System.err.println("unsupported: " + cmd);
        return 2;
    }
  }

  static void list(FileSystem fs, Path t, boolean recursive) throws IOException {
    FileStatus[] all = fs.getFileStatus(t).isDirectory() ? fs.listStatus(t) : new FileStatus[] {fs.getFileStatus(t)};
    for (FileStatus s : all) {
      System.out.println((s.isDirectory() ? "d" : "-") + "rw-r--r--   1 u g " + s.getLen() + " 2026-10-15 08:00 " + show(s.getPath()));
      if (recursive && s.isDirectory()) {
        list(fs, s.getPath(), true);
      }
    }
  }

  static void copy(FileSystem fs, Path src, File dst) throws IOException {
    if (fs.getFileStatus(src).isDirectory()) {
      File d = dst.isDirectory() ? new File(dst, src.getName()) : dst;
      d.mkdirs();
      for (FileStatus s : fs.listStatus(src)) {
        copy(fs, s.getPath(), new File(d, s.getPath().getName()));
      }
    } else {
      File f = dst.isDirectory() ? new File(dst, src.getName()) : dst;
      try (FSDataInputStream in = fs.open(src); OutputStream out = Files.newOutputStream(f.toPath())) {
        byte[] buf = new byte[8192];
        for (int n; (n = in.read(buf)) > 0;) {
          out.write(buf, 0, n);
        }
      }
    }
  }
}
