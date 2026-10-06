package org.apache.nutch.attested;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.net.URI;
import java.net.URISyntaxException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.EnumSet;
import java.util.List;
import java.util.Random;
import java.util.StringTokenizer;
import java.util.TreeMap;
import java.util.TreeSet;

import org.apache.hadoop.conf.Configuration;
import org.apache.hadoop.fs.ContentSummary;
import org.apache.hadoop.fs.CreateFlag;
import org.apache.hadoop.fs.FSDataInputStream;
import org.apache.hadoop.fs.FSDataOutputStream;
import org.apache.hadoop.fs.FileContext;
import org.apache.hadoop.fs.FileStatus;
import org.apache.hadoop.fs.FileSystem;
import org.apache.hadoop.fs.LocatedFileStatus;
import org.apache.hadoop.fs.Options;
import org.apache.hadoop.fs.Path;
import org.apache.hadoop.fs.RawLocalFileSystem;
import org.apache.hadoop.fs.RemoteIterator;
import org.apache.hadoop.fs.permission.FsPermission;
import org.apache.hadoop.hdfs.DistributedFileSystem;
import org.apache.hadoop.io.IntWritable;
import org.apache.hadoop.io.LongWritable;
import org.apache.hadoop.io.Text;
import org.apache.hadoop.mapreduce.Job;
import org.apache.hadoop.mapreduce.Mapper;
import org.apache.hadoop.mapreduce.Reducer;
import org.apache.hadoop.mapreduce.lib.input.FileInputFormat;
import org.apache.hadoop.mapreduce.lib.output.FileOutputFormat;
import org.apache.hadoop.security.UserGroupInformation;

/**
 * Smoke test for the hdfs:// wrapper. Plain Java, no test framework.
 *
 * Usage:
 *   AttestedFsSmoke fake            the wrapper over a fake HDFS that keeps its files on local disk
 *   AttestedFsSmoke mr-fake         a small MapReduce job (local runner) through the wrapper
 *   AttestedFsSmoke hdfs HOST:PORT  the wrapper over the real HDFS at HOST:PORT
 *
 * The two settings fs.hdfs.impl and fs.AbstractFileSystem.hdfs.impl are the only
 * thing that puts the wrapper in place; the test sets them on a Configuration, as
 * the crawl driver does with -D options.
 */
public class AttestedFsSmoke {

  static int checks = 0;
  static int failures = 0;

  static void check(String name, boolean ok) {
    checks++;
    if (!ok) {
      failures++;
    }
    System.out.println((ok ? "PASS  " : "FAIL  ") + name);
  }

  static void eq(String name, Object expected, Object actual) {
    boolean ok = expected == null ? actual == null : expected.equals(actual);
    check(name + (ok ? "" : "   expected=" + expected + " actual=" + actual),
        ok);
  }

  // ------------------------------------------------------------ the fakes

  /** A fake HDFS: accepts hdfs:// paths and keeps the files on local disk at the same path. */
  public static class FakeHdfs extends RawLocalFileSystem {
    private URI myUri; // set by initialize; the parent constructor calls getUri() before it exists

    @Override
    public void initialize(URI uri, Configuration conf) throws IOException {
      super.initialize(uri, conf);
      if (uri.getAuthority() != null) {
        myUri = URI.create("hdfs://" + uri.getAuthority());
      }
    }

    @Override
    public URI getUri() {
      return myUri != null ? myUri : URI.create("hdfs://fake:9000");
    }

    @Override
    public String getScheme() {
      return "hdfs";
    }

    @Override
    protected void checkPath(Path path) {
      // accept any hdfs address
    }

    @Override
    public File pathToFile(Path path) {
      Path p = path.isAbsolute() ? path : new Path(getWorkingDirectory(), path);
      return new File(p.toUri().getPath());
    }

    @Override
    public Path getWorkingDirectory() {
      return new Path(getUri().toString() + "/user/"
          + System.getProperty("user.name"));
    }

    // RawLocalFileSystem's own statuses assume file: paths; build plain ones instead
    private FileStatus statusOf(File f, Path qualified) {
      boolean dir = f.isDirectory();
      return new FileStatus(f.length(), dir, 1, 1L << 20, f.lastModified(),
          f.lastModified(), new FsPermission((short) (dir ? 0755 : 0644)),
          System.getProperty("user.name"), "supergroup", qualified);
    }

    @Override
    public FileStatus getFileStatus(Path p) throws IOException {
      File f = pathToFile(p);
      if (!f.exists()) {
        throw new java.io.FileNotFoundException("File " + p + " does not exist");
      }
      return statusOf(f, makeQualified(p));
    }

    @Override
    public FileStatus[] listStatus(Path p) throws IOException {
      File f = pathToFile(p);
      if (!f.exists()) {
        throw new java.io.FileNotFoundException("File " + p + " does not exist");
      }
      if (f.isFile()) {
        return new FileStatus[] { statusOf(f, makeQualified(p)) };
      }
      File[] kids = f.listFiles();
      Arrays.sort(kids);
      FileStatus[] out = new FileStatus[kids.length];
      for (int i = 0; i < kids.length; i++) {
        out[i] = statusOf(kids[i], new Path(makeQualified(p), kids[i].getName()));
      }
      return out;
    }
  }

  public static class FakeWrapper extends AttestedHdfsFileSystem {
    @Override
    protected FileSystem createInner() {
      return new FakeHdfs();
    }
  }

  public static class FakeAdapter extends AttestedHdfs {
    public FakeAdapter(URI uri, Configuration conf)
        throws IOException, URISyntaxException {
      super(uri, new FakeWrapper(), conf);
    }
  }

  /** A broken wrapper whose inner file system is another wrapper (a loop). */
  public static class LoopWrapper extends AttestedHdfsFileSystem {
    @Override
    protected FileSystem createInner() {
      return new FakeWrapper();
    }
  }

  // ----------------------------------------------------------------- main

  public static void main(String[] args) throws Exception {
    String mode = args.length > 0 ? args[0] : "fake";
    switch (mode) {
    case "fake":
      runFake();
      break;
    case "mr-fake":
      runMr();
      break;
    case "hdfs":
      runHdfs(args[1]);
      break;
    default:
      System.err.println("unknown mode " + mode);
      System.exit(2);
    }
    System.out.println();
    System.out.println(
        (failures == 0 ? "ALL-PASS" : "SOME-FAILED") + " (" + (checks - failures)
            + " of " + checks + " checks passed) mode=" + mode);
    System.exit(failures == 0 ? 0 : 1);
  }

  static Configuration fakeConf(java.nio.file.Path tmp) {
    Configuration conf = new Configuration(false);
    conf.set("fs.defaultFS", "hdfs://fake:9000");
    conf.set("fs.hdfs.impl", FakeWrapper.class.getName());
    conf.set("fs.AbstractFileSystem.hdfs.impl", FakeAdapter.class.getName());
    conf.set(AttestedAudit.DIR_KEY, tmp + "/audit");
    return conf;
  }

  static void runFake() throws Exception {
    java.nio.file.Path tmp = Files.createTempDirectory("attested-smoke");
    Configuration conf = fakeConf(tmp);
    String work = tmp.toString() + "/work";
    Path base = new Path("hdfs://fake:9000" + work);
    FakeHdfs plain = new FakeHdfs();
    plain.initialize(URI.create("hdfs://fake:9000"), new Configuration(false));

    // a wrapper whose inner file system is another wrapper must refuse to start
    boolean loopRefused = false;
    try {
      new LoopWrapper().initialize(URI.create("hdfs://fake:9000"), conf);
    } catch (IOException e) {
      loopRefused = e.getMessage().contains("loop");
    }
    check("a wrapper over another wrapper refuses to start (no loop)",
        loopRefused);

    exercise(conf, base, plain, FakeHdfs.class.getName());
    fileContext(conf, new Path("hdfs://fake:9000" + tmp + "/fc"));
    auditLines(conf, tmp + "/audit", FakeHdfs.class.getName(), work);
    deleteTree(tmp.toFile());
  }

  static void runHdfs(String authority) throws Exception {
    Configuration conf = new Configuration();
    java.nio.file.Path tmp = Files.createTempDirectory("attested-smoke-hdfs");
    conf.set("fs.hdfs.impl", AttestedHdfsFileSystem.class.getName());
    conf.set("fs.AbstractFileSystem.hdfs.impl", AttestedHdfs.class.getName());
    conf.set(AttestedAudit.DIR_KEY, tmp + "/audit");
    String user = UserGroupInformation.getCurrentUser().getShortUserName();
    String work = "/user/" + user + "/attested-smoke-" + System.currentTimeMillis();
    URI uri = URI.create("hdfs://" + authority + "/");
    Path base = new Path("hdfs://" + authority + work);
    // an independent client, built directly (never through the wrapper)
    DistributedFileSystem plain = new DistributedFileSystem();
    plain.initialize(uri, new Configuration());
    try {
      exercise(conf, base, plain, DistributedFileSystem.class.getName());
      fileContext(conf, new Path("hdfs://" + authority + work + "-fc"));
      auditLines(conf, tmp + "/audit", DistributedFileSystem.class.getName(),
          work);
    } finally {
      plain.delete(new Path(work), true);
      plain.delete(new Path(work + "-fc"), true);
      deleteTree(tmp.toFile());
    }
  }

  // ------------------------------------------------------- the checks

  static void exercise(Configuration conf, Path base, FileSystem plain,
      String expectedInner) throws Exception {
    FileSystem fs = base.getFileSystem(conf);
    check("fs.hdfs.impl puts the wrapper behind hdfs:// (paths unchanged)",
        fs instanceof AttestedHdfsFileSystem);
    eq("fs.getUri() scheme", "hdfs", fs.getUri().getScheme());

    Path a = new Path(base, "a");
    Path ab = new Path(a, "b");
    check("mkdirs a/b", fs.mkdirs(ab));
    FileStatus st = fs.getFileStatus(ab);
    check("getFileStatus: is a folder", st.isDirectory());
    eq("status path keeps the hdfs scheme", "hdfs",
        st.getPath().toUri().getScheme());
    check("a status path leads back to the wrapper",
        st.getPath().getFileSystem(conf) instanceof AttestedHdfsFileSystem);

    Path f1 = new Path(a, "f1");
    byte[] small = "hello attested".getBytes(StandardCharsets.UTF_8);
    try (FSDataOutputStream out = fs.create(f1)) {
      out.write(small);
    }
    check("exists after create", fs.exists(f1));
    eq("length of small file", (long) small.length, fs.getFileStatus(f1).getLen());
    check("read back small file", Arrays.equals(small, readAll(fs, f1)));
    check("the independent real client sees the same file",
        plain.exists(f1) && Arrays.equals(small, readAll(plain, f1)));

    byte[] big = new byte[3 * 1024 * 1024 + 17];
    new Random(42).nextBytes(big);
    Path f2 = new Path(ab, "big.bin");
    try (FSDataOutputStream out = fs.create(f2, true, 4096)) {
      out.write(big);
    }
    eq("sha-256 of 3 MB file read back", sha(big), sha(readAll(fs, f2)));

    try (FSDataInputStream in = fs.openFile(f1).build().get()) {
      byte[] buf = new byte[small.length];
      in.readFully(buf);
      check("openFile builder reads the file", Arrays.equals(small, buf));
    }

    try (FSDataOutputStream out = fs.append(f1)) {
      out.write("++".getBytes(StandardCharsets.UTF_8));
    }
    eq("append grows the file", (long) small.length + 2, fs.getFileStatus(f1).getLen());

    TreeSet<String> names = new TreeSet<>();
    for (FileStatus s : fs.listStatus(a)) {
      names.add(s.getPath().getName());
    }
    eq("listStatus(a) names", new TreeSet<>(Arrays.asList("b", "f1")), names);
    int files = 0;
    RemoteIterator<LocatedFileStatus> it = fs.listFiles(base, true);
    while (it.hasNext()) {
      it.next();
      files++;
    }
    eq("listFiles(recursive) finds both files", 2, files);
    FileStatus[] globbed = fs.globStatus(new Path(a, "*"));
    eq("globStatus(a/*) count", 2, globbed == null ? -1 : globbed.length);
    ContentSummary cs = fs.getContentSummary(base);
    eq("content summary: files", 2L, cs.getFileCount());

    Path f3 = new Path(ab, "renamed");
    check("rename file", fs.rename(f1, f3));
    check("old name gone, new name present", !fs.exists(f1) && fs.exists(f3));
    Path ab2 = new Path(a, "b2");
    check("rename folder", fs.rename(ab, ab2));
    check("file moved with the folder", fs.exists(new Path(ab2, "big.bin")));
    check("the real client sees the renamed folder",
        plain.exists(new Path(ab2, "big.bin")));

    boolean notEmptyRefused;
    try {
      notEmptyRefused = !fs.delete(a, false);
    } catch (IOException e) {
      notEmptyRefused = true;
    }
    check("delete(non-empty folder, recursive=false) is refused", notEmptyRefused);
    check("delete recursive", fs.delete(base, true));
    check("gone after delete", !fs.exists(base) && !plain.exists(base));
  }

  /** The FileContext side: the second lookup, fs.AbstractFileSystem.hdfs.impl. */
  static void fileContext(Configuration conf, Path dir) throws Exception {
    FileContext fc = FileContext.getFileContext(dir.toUri(), conf);
    check("fs.AbstractFileSystem.hdfs.impl puts the adapter behind FileContext",
        fc.getDefaultFileSystem() instanceof AttestedHdfs);
    Path d = new Path(dir, "sub");
    fc.mkdir(d, FsPermission.getDirDefault(), true);
    Path f = new Path(d, "file");
    try (FSDataOutputStream out = fc.create(f,
        EnumSet.of(CreateFlag.CREATE, CreateFlag.OVERWRITE))) {
      out.write("via FileContext".getBytes(StandardCharsets.UTF_8));
    }
    check("FileContext: file exists", fc.util().exists(f));
    Path g = new Path(d, "renamed");
    fc.rename(f, g, Options.Rename.NONE);
    check("FileContext: rename worked", !fc.util().exists(f) && fc.util().exists(g));
    try (FSDataInputStream in = fc.open(g)) {
      byte[] buf = new byte["via FileContext".length()];
      in.readFully(buf);
      eq("FileContext: read back", "via FileContext",
          new String(buf, StandardCharsets.UTF_8));
    }
    check("FileContext: delete recursive", fc.delete(dir, true));
  }

  /** The audit log holds one line for each request that changes storage. */
  static void auditLines(Configuration conf, String dir, String expectedInner,
      String work) throws Exception {
    File[] logs = new File(dir).listFiles((d, n) -> n.endsWith(".tsv"));
    check("the audit folder holds this JVM's log", logs != null && logs.length == 1);
    List<String[]> lines = new ArrayList<>();
    for (String l : Files.readAllLines(logs[0].toPath(), StandardCharsets.UTF_8)) {
      lines.add(l.split("\t", -1));
    }
    boolean initOk = false;
    for (String[] c : lines) {
      if (c[3].equals("INIT") && c[6].contains("inner=" + expectedInner)) {
        initOk = true;
      }
    }
    check("INIT line names the real client class (" + expectedInner + ")", initOk);
    check("every line has 7 fields", lines.stream().allMatch(c -> c.length == 7));
    check("MKDIRS logged for a/b", has(lines, "MKDIRS", work + "/a/b", null));
    check("CREATE logged for f1", has(lines, "CREATE", work + "/a/f1", null));
    check("CREATE logged for big.bin", has(lines, "CREATE", work + "/a/b/big.bin", null));
    check("APPEND logged for f1", has(lines, "APPEND", work + "/a/f1", null));
    check("OPEN logged for f1", has(lines, "OPEN", work + "/a/f1", null));
    check("RENAME logged for the file", has(lines, "RENAME", work + "/a/f1", work + "/a/b/renamed"));
    check("RENAME logged for the folder", has(lines, "RENAME", work + "/a/b", work + "/a/b2"));
    check("DELETE logged for the folder", has(lines, "DELETE", work, null));
    check("FileContext requests are logged too (create, rename, delete)",
        hasPrefix(lines, "CREATE", work.replace("/work", "/fc") + "/sub/file")
            && hasPrefix(lines, "RENAME", work.replace("/work", "/fc") + "/sub/file")
            && hasPrefix(lines, "DELETE", work.replace("/work", "/fc")));
  }

  static boolean has(List<String[]> lines, String op, String p1, String p2) {
    for (String[] c : lines) {
      if (c[3].equals(op) && c[4].equals(p1) && (p2 == null || c[5].equals(p2))) {
        return true;
      }
    }
    return false;
  }

  /** Like has(), but for the FileContext part, where the folder name differs for the real HDFS. */
  static boolean hasPrefix(List<String[]> lines, String op, String path) {
    for (String[] c : lines) {
      if (c[3].equals(op) && (c[4].equals(path) || c[4].endsWith(path.substring(path.lastIndexOf('/'))))) {
        return true;
      }
    }
    return false;
  }

  // ------------------------------------------------------ a tiny MR job

  public static class TokMapper
      extends Mapper<LongWritable, Text, Text, IntWritable> {
    private final static IntWritable ONE = new IntWritable(1);
    private final Text word = new Text();

    @Override
    protected void map(LongWritable key, Text value, Context context)
        throws IOException, InterruptedException {
      StringTokenizer t = new StringTokenizer(value.toString());
      while (t.hasMoreTokens()) {
        word.set(t.nextToken());
        context.write(word, ONE);
      }
    }
  }

  public static class SumReducer
      extends Reducer<Text, IntWritable, Text, IntWritable> {
    @Override
    protected void reduce(Text key, Iterable<IntWritable> values,
        Context context) throws IOException, InterruptedException {
      int sum = 0;
      for (IntWritable v : values) {
        sum += v.get();
      }
      context.write(key, new IntWritable(sum));
    }
  }

  static void runMr() throws Exception {
    java.nio.file.Path tmp = Files.createTempDirectory("attested-mr");
    Configuration conf = fakeConf(tmp);
    conf.set("mapreduce.framework.name", "local");
    conf.set("hadoop.tmp.dir", tmp + "/hadoop-tmp");
    conf.set("mapreduce.jobtracker.staging.root.dir", tmp + "/staging");
    Path in = new Path("hdfs://fake:9000" + tmp + "/in");
    Path out = new Path("hdfs://fake:9000" + tmp + "/out");
    FileSystem fs = in.getFileSystem(conf);
    check("the job's file system is the wrapper", fs instanceof AttestedHdfsFileSystem);
    fs.mkdirs(in);
    String[] lines = { "to be or not to be", "that is the question", "to be is to do" };
    TreeMap<String, Integer> expected = new TreeMap<>();
    for (int i = 0; i < 2; i++) {
      try (FSDataOutputStream o = fs.create(new Path(in, "part" + i + ".txt"))) {
        for (String l : lines) {
          o.write((l + "\n").getBytes(StandardCharsets.UTF_8));
          for (String w : l.split(" ")) {
            expected.merge(w, 1, Integer::sum);
          }
        }
      }
    }
    Job job = Job.getInstance(conf, "attested-wordcount");
    job.setJarByClass(AttestedFsSmoke.class);
    job.setMapperClass(TokMapper.class);
    job.setCombinerClass(SumReducer.class);
    job.setReducerClass(SumReducer.class);
    job.setOutputKeyClass(Text.class);
    job.setOutputValueClass(IntWritable.class);
    FileInputFormat.addInputPath(job, in);
    FileOutputFormat.setOutputPath(job, out);
    check("MapReduce job reading and writing hdfs:// through the wrapper completes",
        job.waitForCompletion(false));
    check("_SUCCESS marker exists", fs.exists(new Path(out, "_SUCCESS")));
    check("no _temporary folder is left behind", !fs.exists(new Path(out, "_temporary")));
    TreeMap<String, Integer> got = new TreeMap<>();
    for (FileStatus s : fs.listStatus(out)) {
      if (s.getPath().getName().startsWith("part-")) {
        for (String line : new String(readAll(fs, s.getPath()), StandardCharsets.UTF_8).split("\n")) {
          if (!line.isEmpty()) {
            String[] kv = line.split("\t");
            got.put(kv[0], Integer.parseInt(kv[1]));
          }
        }
      }
    }
    eq("word counts equal the expected counts", expected, got);
    List<String[]> log = new ArrayList<>();
    File[] logs = new File(tmp + "/audit").listFiles((d, n) -> n.endsWith(".tsv"));
    for (String l : Files.readAllLines(logs[0].toPath(), StandardCharsets.UTF_8)) {
      log.add(l.split("\t", -1));
    }
    check("the audit log shows the job's output being created",
        log.stream().anyMatch(c -> c[3].equals("CREATE") && c[4].contains("/out/") && c[4].contains("part-r-")));
    check("the audit log shows the job's commit (a rename into the output folder)",
        log.stream().anyMatch(c -> c[3].equals("RENAME") && c[5].contains("/out/")));
    deleteTree(tmp.toFile());
  }

  // --------------------------------------------------------------- helpers

  static byte[] readAll(FileSystem fs, Path p) throws IOException {
    try (InputStream in = fs.open(p)) {
      ByteArrayOutputStream bo = new ByteArrayOutputStream();
      byte[] buf = new byte[8192];
      int n;
      while ((n = in.read(buf)) > 0) {
        bo.write(buf, 0, n);
      }
      return bo.toByteArray();
    }
  }

  static String sha(byte[] b) throws Exception {
    byte[] d = MessageDigest.getInstance("SHA-256").digest(b);
    StringBuilder sb = new StringBuilder();
    for (byte x : d) {
      sb.append(String.format("%02x", x));
    }
    return sb.toString();
  }

  static void deleteTree(File f) {
    File[] kids = f.listFiles();
    if (kids != null) {
      for (File k : kids) {
        deleteTree(k);
      }
    }
    f.delete();
  }
}
