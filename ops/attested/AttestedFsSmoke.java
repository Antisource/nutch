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
import java.io.EOFException;
import java.util.StringTokenizer;
import java.util.TreeMap;
import java.util.TreeSet;

import org.apache.hadoop.conf.Configuration;
import org.apache.hadoop.fs.ContentSummary;
import org.apache.hadoop.fs.FileUtil;
import org.apache.hadoop.fs.ChecksumException;
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
 *   AttestedFsSmoke hash            the hashing: records and Merkle roots against an independent computation
 *                                   (fake and hdfs also run the verification checks of stage B2: reads are
 *                                   checked against the records, and changed, shortened or lengthened files,
 *                                   damaged records and missing records are handled as specified)
 *   AttestedFsSmoke hdfs HOST:PORT  the wrapper over the real HDFS at HOST:PORT
 *
 * The two settings fs.hdfs.impl and fs.AbstractFileSystem.hdfs.impl are the only
 * thing that puts the wrapper in place; the test sets them on a Configuration, as
 * the crawl driver does with -D options.
 */
public class AttestedFsSmoke {

  static int checks = 0;
  static int failures = 0;
  static String RECORDS_DIR;

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
    case "hash":
      runHash();
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
    conf.set(AttestedRecords.DIR_KEY, tmp + "/records");
    RECORDS_DIR = tmp + "/records";
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
    verifyChecks(conf, base, plain);
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
    conf.set(AttestedRecords.DIR_KEY, tmp + "/records");
    RECORDS_DIR = tmp + "/records";
    String user = UserGroupInformation.getCurrentUser().getShortUserName();
    String work = "/user/" + user + "/attested-smoke-" + System.currentTimeMillis();
    URI uri = URI.create("hdfs://" + authority + "/");
    Path base = new Path("hdfs://" + authority + work);
    // an independent client, built directly (never through the wrapper)
    DistributedFileSystem plain = new DistributedFileSystem();
    plain.initialize(uri, new Configuration());
    try {
      exercise(conf, base, plain, DistributedFileSystem.class.getName());
      verifyChecks(conf, base, plain);
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
    eq("record for the small file: root equals the independent computation",
        refRoot(small, 16384), recordRoot(f1.toUri().getPath()));
    eq("record for the 3 MB file: root equals the independent computation",
        refRoot(big, 16384), recordRoot(f2.toUri().getPath()));

    try (FSDataInputStream in = fs.openFile(f1).build().get()) {
      byte[] buf = new byte[small.length];
      in.readFully(buf);
      check("openFile builder reads the file", Arrays.equals(small, buf));
    }

    try (FSDataOutputStream out = fs.append(f1)) {
      out.write("++".getBytes(StandardCharsets.UTF_8));
    }
    eq("append grows the file", (long) small.length + 2, fs.getFileStatus(f1).getLen());
    check("an append is flagged in the records as not hashed",
        recordFlag(f1.toUri().getPath(), "append-unhashed"));

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
    eq("FileContext: the file created through it has a record with the right root",
        refRoot("via FileContext".getBytes(StandardCharsets.UTF_8), 16384), recordRoot(f.toUri().getPath()));
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
    check("the records show the job's output part files being hashed",
        recordCountContaining("/part-r-") > 0);
    check("the audit log shows the job's commit (a rename into the output folder)",
        log.stream().anyMatch(c -> c[3].equals("RENAME") && c[5].contains("/out/")));
    check("the audit log shows the job's input being read with verification",
        log.stream().anyMatch(c -> c[3].equals("OPEN") && c[4].contains("/in/") && c[6].contains("verify=ok")));

    // an operator changes one byte of an input file with the plain client: the next job must fail
    FakeHdfs plainFs = new FakeHdfs();
    plainFs.initialize(URI.create("hdfs://fake:9000"), new Configuration(false));
    Path victim = new Path(in, "part0.txt");
    byte[] orig = readAll(plainFs, victim);
    byte[] changed = orig.clone();
    changed[3] ^= 0x20;
    put(plainFs, victim, changed);
    check("a job reading a changed input file fails", !runWordCount(conf, in, new Path("hdfs://fake:9000" + tmp + "/out2")));
    check("the audit log shows the verification failure of the input",
        auditEntries(tmp + "/audit").stream().anyMatch(c -> c[3].equals("VERIFY-FAIL") && c[4].contains("/in/part0.txt")));
    put(plainFs, victim, orig);
    check("with the original bytes put back the same job completes again",
        runWordCount(conf, in, new Path("hdfs://fake:9000" + tmp + "/out3")));
    deleteTree(tmp.toFile());
  }

  static boolean runWordCount(Configuration conf, Path in, Path out) throws Exception {
    Job job = Job.getInstance(conf, "attested-wordcount-again");
    job.setJarByClass(AttestedFsSmoke.class);
    job.setMapperClass(TokMapper.class);
    job.setCombinerClass(SumReducer.class);
    job.setReducerClass(SumReducer.class);
    job.setOutputKeyClass(Text.class);
    job.setOutputValueClass(IntWritable.class);
    FileInputFormat.addInputPath(job, in);
    FileOutputFormat.setOutputPath(job, out);
    try {
      return job.waitForCompletion(false);
    } catch (IOException e) {
      return false;
    }
  }

  // ------------------------------------------------------ verification (B2)

  static Path sc(Path p) {
    return new Path(p.getParent(), "." + p.getName() + ".attested");
  }

  static byte[] data(int n, long seed) {
    byte[] d = new byte[n];
    new Random(seed).nextBytes(d);
    return d;
  }

  static void put(FileSystem f, Path p, byte[] d) throws IOException {
    try (FSDataOutputStream o = f.create(p, true)) {
      o.write(d);
    }
  }

  static String lastError;

  static byte[] tryRead(FileSystem fs, Path p) {
    lastError = null;
    try {
      return readAll(fs, p);
    } catch (IOException e) {
      lastError = e.toString();
      return null;
    }
  }

  static List<String[]> auditEntries(String dir) throws IOException {
    List<String[]> out = new ArrayList<>();
    File[] fs = new File(dir).listFiles((d, n) -> n.endsWith(".tsv"));
    if (fs != null) {
      for (File f : fs) {
        for (String l : Files.readAllLines(f.toPath(), StandardCharsets.UTF_8)) {
          String[] c = l.split("\t", -1);
          if (c.length == 7) {
            out.add(c);
          }
        }
      }
    }
    return out;
  }

  static long auditCount(String dir, String op, String extraPart) throws IOException {
    return auditEntries(dir).stream()
        .filter(c -> c[3].equals(op) && c[6].contains(extraPart)).count();
  }

  /** Stage B2: reads are checked against the records; every way of changing a file is caught. */
  static void verifyChecks(Configuration conf, Path base, FileSystem plain) throws Exception {
    FileSystem fs = FileSystem.newInstance(base.toUri(), conf);
    String auditDir = conf.get(AttestedAudit.DIR_KEY);
    Path dir = new Path(base, "verify");
    fs.mkdirs(dir);
    int[] sizes = { 0, 1, 16383, 16384, 16385, 100000, 3 * 1024 * 1024 + 17 };
    boolean recordsOk = true, readOk = true, builderOk = true, seekOk = true, lenOk = true;
    for (int n : sizes) {
      Path f = new Path(dir, "v" + n);
      byte[] d = data(n, 500 + n);
      put(fs, f, d);
      recordsOk &= plain.exists(sc(f));
      readOk &= Arrays.equals(d, readAll(fs, f));
      lenOk &= fs.getFileStatus(f).getLen() == n;
      try (FSDataInputStream in = fs.openFile(f).build().get()) {
        byte[] b = new byte[n];
        in.readFully(b);
        builderOk &= Arrays.equals(d, b) && in.read() == -1;
      }
      if (n >= 16385) {
        try (FSDataInputStream in = fs.open(f)) {
          byte[] b = new byte[Math.min(10, n - 16380)];
          in.seek(16380);
          in.readFully(b);
          seekOk &= Arrays.equals(Arrays.copyOfRange(d, 16380, 16380 + b.length), b);
          if (n >= 30000) {
            byte[] c = new byte[5000];
            in.readFully(20000, c);
            seekOk &= Arrays.equals(Arrays.copyOfRange(d, 20000, 25000), c);
            seekOk &= in.getPos() == 16380 + b.length;
          }
          in.seek(n);
          seekOk &= in.read() == -1;
          boolean threw = false;
          try {
            in.seek(n + 1L);
          } catch (EOFException e) {
            threw = true;
          }
          seekOk &= threw;
        }
      }
    }
    check("every file written through the wrapper has a record next to it (all sizes)", recordsOk);
    check("reads through the wrapper return the bytes that were written (all sizes)", readOk);
    check("the builder form of open (openFile) reads and verifies too (all sizes)", builderOk);
    check("seeks, positioned reads and reads at the end work (all sizes)", seekOk);
    check("the length reported by the wrapper is unchanged (all sizes)", lenOk);
    check("listings through the wrapper do not show the records",
        fs.listStatus(dir).length == sizes.length && plain.listStatus(dir).length == 2 * sizes.length);
    int viaIterator = 0;
    RemoteIterator<LocatedFileStatus> it = fs.listFiles(dir, false);
    while (it.hasNext()) {
      it.next();
      viaIterator++;
    }
    check("listFiles and glob do not show the records either",
        viaIterator == sizes.length && fs.globStatus(new Path(dir, "*")).length == sizes.length);

    // the headline test: one byte of a stored file is changed with the plain client
    Path t = new Path(dir, "v100000");
    byte[] d = data(100000, 500 + 100000);
    byte[] bad = d.clone();
    bad[50000] ^= 0x01;
    put(plain, t, bad);
    try (FSDataInputStream in = fs.open(t)) {
      byte[] head = new byte[49152];
      in.readFully(head);
      check("changed byte: the chunks before the changed one still read (checked one by one)",
          Arrays.equals(Arrays.copyOf(d, 49152), head));
      boolean failed = false;
      String msg = "";
      try {
        in.readFully(new byte[100000 - 49152]);
      } catch (ChecksumException e) {
        failed = true;
        msg = e.getMessage();
      }
      check("changed byte: reading the changed chunk fails with a verification error",
          failed && msg.contains("chunk 3"));
    }
    check("changed byte: reading the whole file fails",
        tryRead(fs, t) == null && lastError.contains("Attested verification failed"));
    put(plain, t, d);
    check("changed byte: with the original bytes put back the file verifies again",
        Arrays.equals(d, readAll(fs, t)));

    put(plain, t, Arrays.copyOf(d, 99999));
    check("shortened file: the open fails and says why",
        tryRead(fs, t) == null && lastError.contains("length is 99999"));
    boolean viaFuture = false;
    try {
      org.apache.hadoop.util.functional.FutureIO.awaitFuture(fs.openFile(t).build());
    } catch (IOException | RuntimeException e) {
      viaFuture = String.valueOf(e).contains("Attested verification failed")
          || String.valueOf(e.getCause()).contains("Attested verification failed");
    }
    check("shortened file: the builder form of open (openFile) fails too, with the same message", viaFuture);
    put(plain, t, Arrays.copyOf(d, 100001));
    check("lengthened file: the open fails and says why",
        tryRead(fs, t) == null && lastError.contains("length is 100001"));
    put(plain, t, d);

    // damaged records
    byte[] sb = readAll(plain, sc(t));
    boolean damagedOk = true;
    byte[][] damaged = new byte[4][];
    damaged[0] = sb.clone();
    damaged[0][damaged[0].length - 1] ^= 1;
    damaged[1] = sb.clone();
    damaged[1][20] ^= 1;
    damaged[2] = Arrays.copyOf(sb, sb.length - 5);
    damaged[3] = new byte[10];
    for (byte[] dm : damaged) {
      put(plain, sc(t), dm);
      damagedOk &= tryRead(fs, t) == null && lastError.contains("record is damaged");
    }
    check("a damaged record (changed hash, changed root, cut short, garbage) fails the open", damagedOk);
    put(plain, sc(t), sb);
    check("with the original record put back the file verifies again", Arrays.equals(d, readAll(fs, t)));

    // the known limit, stated as a test: file and record rewritten together are accepted
    byte[] other = data(100000, 999);
    MerkleHasher mh = new MerkleHasher(16384, true);
    mh.update(other, 0, other.length);
    byte[] root = mh.finish();
    put(plain, t, other);
    put(plain, sc(t), AttestedSidecar.encode(16384, other.length, root, mh.leaves()));
    check("known limit until records are signed: a file and its record rewritten together are accepted",
        Arrays.equals(other, readAll(fs, t)));
    put(fs, t, d);

    // a missing record follows the policy
    plain.delete(sc(t), false);
    check("missing record, default policy (warn): the file reads, unverified",
        Arrays.equals(d, readAll(fs, t)) && auditCount(auditDir, "OPEN", "verify=missing") > 0);
    Configuration failConf = new Configuration(conf);
    failConf.set(AttestedHdfsFileSystem.MISSING_KEY, "fail");
    FileSystem failFs = FileSystem.newInstance(base.toUri(), failConf);
    check("missing record, policy fail: the open is refused",
        tryRead(failFs, t) == null && lastError.contains("has no record"));
    Configuration allowConf = new Configuration(conf);
    allowConf.set(AttestedHdfsFileSystem.MISSING_KEY, "allow");
    FileSystem allowFs = FileSystem.newInstance(base.toUri(), allowConf);
    check("missing record, policy allow: the file reads and the audit says skipped",
        Arrays.equals(d, readAll(allowFs, t)) && auditCount(auditDir, "OPEN", "verify=skipped") > 0);
    put(fs, t, d);

    // verification switched off: the same change goes unnoticed (the control for the setting)
    Configuration offConf = new Configuration(conf);
    offConf.setBoolean(AttestedHdfsFileSystem.VERIFY_KEY, false);
    FileSystem offFs = FileSystem.newInstance(base.toUri(), offConf);
    put(plain, t, bad);
    check("verification off: a changed file reads without complaint",
        Arrays.equals(bad, readAll(offFs, t)));
    put(fs, t, d);

    // records follow their files
    Path a = new Path(dir, "ren-a");
    byte[] da = data(40000, 7);
    put(fs, a, da);
    Path b = new Path(dir, "ren-b");
    check("rename of a file works", fs.rename(a, b));
    check("rename: its record moved with it", plain.exists(sc(b)) && !plain.exists(sc(a)));
    check("rename: the renamed file verifies", Arrays.equals(da, readAll(fs, b)));
    Path into = new Path(dir, "into");
    fs.mkdirs(into);
    check("rename into an existing folder works", fs.rename(b, into));
    Path inb = new Path(into, "ren-b");
    check("rename into a folder: the record moved and the file verifies",
        plain.exists(sc(inb)) && !plain.exists(sc(b)) && Arrays.equals(da, readAll(fs, inb)));
    Path sub = new Path(dir, "sub");
    fs.mkdirs(sub);
    put(fs, new Path(sub, "x"), da);
    Path sub2 = new Path(dir, "sub2");
    check("rename of a folder works", fs.rename(sub, sub2));
    check("folder rename: the files in it still verify",
        Arrays.equals(da, readAll(fs, new Path(sub2, "x"))) && plain.exists(sc(new Path(sub2, "x"))));
    put(plain, inb, Arrays.copyOf(da, 40000 - 1));
    check("a changed file is still caught after it was renamed", tryRead(fs, inb) == null);
    check("delete of a file works", fs.delete(inb, false));
    check("delete: its record is gone too", !plain.exists(sc(inb)));
    check("recursive delete of a folder removes the records inside",
        fs.delete(sub2, true) && !plain.exists(sc(new Path(sub2, "x"))) && !plain.exists(sub2));
    Path ow = new Path(dir, "ow");
    put(fs, ow, data(30000, 1));
    byte[] d2 = data(20000, 2);
    put(fs, ow, d2);
    check("writing over a file replaces its record: the new content verifies",
        Arrays.equals(d2, readAll(fs, ow)));
    Path copy = new Path(dir, "copy");
    check("a copy made through the wrapper", FileUtil.copy(fs, t, fs, copy, false, conf));
    check("the copy has its own record and verifies",
        plain.exists(sc(copy)) && Arrays.equals(d, readAll(fs, copy)));
    Path ap = new Path(dir, "ap");
    put(fs, ap, data(1000, 3));
    try (FSDataOutputStream o = fs.append(ap)) {
      o.write(1);
    }
    check("append: the old record is removed (the file changed), and it still reads (warn)",
        !plain.exists(sc(ap)) && readAll(fs, ap).length == 1001);

    check("the audit log has VERIFY-FAIL lines for the changed files and records",
        auditCount(auditDir, "VERIFY-FAIL", "") >= 8);
    check("the audit log marks verified opens", auditCount(auditDir, "OPEN", "verify=ok") > 10);
    plain.delete(dir, true);
  }

  // ------------------------------------------------------------ hashing

  /** The hash mode: roots against an independent computation, several sizes and settings. */
  static void runHash() throws Exception {
    java.nio.file.Path tmp = Files.createTempDirectory("attested-hash");
    Configuration conf = fakeConf(tmp);
    URI root = URI.create("hdfs://fake:9000/");
    FileSystem fs = FileSystem.newInstance(root, conf);
    String work = tmp.toString() + "/work";
    fs.mkdirs(new Path("hdfs://fake:9000" + work));
    int[] sizes = { 0, 1, 16383, 16384, 16385, 32768, 49152, 100000, 3 * 1024 * 1024 + 17 };
    for (int n : sizes) {
      byte[] data = new byte[n];
      new Random(1000 + n).nextBytes(data);
      Path f = new Path("hdfs://fake:9000" + work + "/f" + n);
      try (FSDataOutputStream out = fs.create(f)) {
        Random r = new Random(n);
        int off = 0;
        while (off < n) {  // odd-sized pieces, to cross chunk boundaries in every way
          int k = Math.min(n - off, 1 + r.nextInt(5000));
          out.write(data, off, k);
          off += k;
        }
      }
      String got = recordRoot(work + "/f" + n);
      eq("size " + n + ": record root equals the independent computation", refRoot(data, 16384), got);
      System.out.println("ROOTLINE " + n + " 16384 " + got);
    }
    // one byte at a time gives the same root
    byte[] one = new byte[40000];
    new Random(7).nextBytes(one);
    Path fb = new Path("hdfs://fake:9000" + work + "/bytewise");
    try (FSDataOutputStream out = fs.create(fb)) {
      for (byte b : one) {
        out.write(b);
      }
    }
    eq("one byte at a time: same root as the independent computation", refRoot(one, 16384), recordRoot(work + "/bytewise"));
    // flush and sync are forwarded and do not disturb the hash
    byte[] two = new byte[30000];
    new Random(8).nextBytes(two);
    Path fs2p = new Path("hdfs://fake:9000" + work + "/synced");
    try (FSDataOutputStream out = fs.create(fs2p)) {
      out.write(two, 0, 10000);
      out.hflush();
      out.write(two, 10000, 10000);
      out.hsync();
      out.write(two, 20000, 10000);
    }
    eq("hflush and hsync in the middle: same root", refRoot(two, 16384), recordRoot(work + "/synced"));
    check("the length in the record equals the length of the file",
        recordLength(work + "/synced") == fs.getFileStatus(fs2p).getLen());
    // another chunk size, through a second wrapper instance
    Configuration conf2 = new Configuration(conf);
    conf2.setLong(AttestedHdfsFileSystem.CHUNK_SIZE_KEY, 1000);
    FileSystem fsSmall = FileSystem.newInstance(root, conf2);
    byte[] three = new byte[5555];
    new Random(9).nextBytes(three);
    Path f3 = new Path("hdfs://fake:9000" + work + "/chunk1000");
    try (FSDataOutputStream out = fsSmall.create(f3)) {
      out.write(three);
    }
    eq("chunk size 1000: root equals the independent computation", refRoot(three, 1000), recordRoot(work + "/chunk1000"));
    eq("the record carries the chunk size", "1000", recordField(work + "/chunk1000", 7));
    eq("the record carries the number of chunks", "6", recordField(work + "/chunk1000", 8));
    // hashing switched off: no record
    Configuration conf3 = new Configuration(conf);
    conf3.setBoolean(AttestedHdfsFileSystem.HASH_ENABLED_KEY, false);
    FileSystem fsOff = FileSystem.newInstance(root, conf3);
    Path f4 = new Path("hdfs://fake:9000" + work + "/unhashed");
    try (FSDataOutputStream out = fsOff.create(f4)) {
      out.write(three);
    }
    check("hashing off: no record is written", recordRoot(work + "/unhashed") == null && fsOff.exists(f4));
    // copy from local goes through the hashing
    java.io.File local = new java.io.File(tmp.toFile(), "local.bin");
    byte[] four = new byte[70000];
    new Random(10).nextBytes(four);
    Files.write(local.toPath(), four);
    Path f5 = new Path("hdfs://fake:9000" + work + "/copied");
    fs.copyFromLocalFile(false, new Path(local.toURI()), f5);
    eq("copyFromLocalFile: the copied file has a record with the right root", refRoot(four, 16384), recordRoot(work + "/copied"));
    check("copyFromLocalFile: the bytes arrived intact", Arrays.equals(four, readAll(fs, f5)));
    if (System.getProperty("smoke.keep") != null) {
      System.out.println("KEPT " + tmp);
    } else {
      deleteTree(tmp.toFile());
    }
  }

  /** The independent reference: Merkle root of RFC 6962, written recursively. */
  static String refRoot(byte[] data, int chunk) throws Exception {
    java.util.ArrayList<byte[]> leaves = new java.util.ArrayList<>();
    for (int off = 0; off < data.length; off += chunk) {
      int n = Math.min(chunk, data.length - off);
      MessageDigest d = MessageDigest.getInstance("SHA-256");
      d.update((byte) 0);
      d.update(data, off, n);
      leaves.add(d.digest());
    }
    if (leaves.isEmpty()) {
      return hexOf(MessageDigest.getInstance("SHA-256").digest());
    }
    return hexOf(mth(leaves, 0, leaves.size()));
  }

  static byte[] mth(java.util.List<byte[]> l, int lo, int hi) throws Exception {
    int n = hi - lo;
    if (n == 1) {
      return l.get(lo);
    }
    int k = 1;
    while (k * 2 < n) {
      k *= 2;
    }
    MessageDigest d = MessageDigest.getInstance("SHA-256");
    d.update((byte) 1);
    d.update(mth(l, lo, lo + k));
    d.update(mth(l, lo + k, hi));
    return d.digest();
  }

  static String hexOf(byte[] b) {
    StringBuilder sb = new StringBuilder();
    for (byte x : b) {
      sb.append(String.format("%02x", x));
    }
    return sb.toString();
  }

  /** All record lines of this test run (every JVM file in the records folder). */
  static List<String[]> recordLines() throws IOException {
    List<String[]> out = new ArrayList<>();
    File[] fs = new File(RECORDS_DIR).listFiles((d, n) -> n.endsWith(".tsv"));
    if (fs != null) {
      for (File f : fs) {
        for (String l : Files.readAllLines(f.toPath(), StandardCharsets.UTF_8)) {
          out.add(l.split("\t", -1));
        }
      }
    }
    return out;
  }

  /** The root of the last complete record for a path, or null. */
  static String recordRoot(String path) throws IOException {
    return recordField(path, 9);
  }

  static String recordField(String path, int field) throws IOException {
    String found = null;
    for (String[] c : recordLines()) {
      if (c.length == 11 && c[5].equals(path) && c[10].equals("closed")) {
        found = c[field];
      }
    }
    return found;
  }

  static long recordLength(String path) throws IOException {
    String v = recordField(path, 6);
    return v == null ? -1 : Long.parseLong(v);
  }

  static boolean recordFlag(String path, String flag) throws IOException {
    for (String[] c : recordLines()) {
      if (c.length == 11 && c[5].equals(path) && c[10].equals(flag)) {
        return true;
      }
    }
    return false;
  }

  static int recordCountContaining(String part) throws IOException {
    int n = 0;
    for (String[] c : recordLines()) {
      if (c.length == 11 && c[5].contains(part) && c[10].equals("closed")) {
        n++;
      }
    }
    return n;
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
