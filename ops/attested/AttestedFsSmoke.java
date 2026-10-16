package org.apache.nutch.attested;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileNotFoundException;
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
    // the tests feed the wrapper its settings from code; step A3 ignores such settings unless told otherwise
    AttestedSettings.trustAllSourcesForTesting(true);
    switch (mode) {
    case "fake":
      runFake();
      break;
    case "mr-fake":
      runMr(false);
      break;
    case "mr-bound":
      runMr(true);
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
    signatureChecks(conf, base, plain);
    bindingChecks(conf, base, plain);
    keyServiceChecks(conf, base, plain);
    keyAdmissionChecks(conf, base, plain);
    metadataChecks(conf, base, plain);
    fileContext(conf, new Path("hdfs://fake:9000" + tmp + "/fc"));
    refusalChecks(conf, base, plain);
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
      metadataChecks(conf, base, plain);
      signatureChecks(conf, base, plain);
      bindingChecks(conf, base, plain);
      keyServiceChecks(conf, base, plain);
      keyAdmissionChecks(conf, base, plain);
      fileContext(conf, new Path("hdfs://" + authority + work + "-fc"));
      refusalChecks(conf, base, plain);
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

    // step A1: append is refused; the file stays as it was
    check("append is refused (step A1)", throwsIo(() -> fs.append(f1)));
    eq("the file is unchanged by the refused append", (long) small.length,
        fs.getFileStatus(f1).getLen());

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


  // ------------------------------------------------------- steps A1 to A4

  /**
   * A1: append, concat and truncate are refused. A2: a file without a record fails the
   * read by default. A3: the wrapper's settings count only when the site configuration
   * set them. A4: the doors to the plain file system are closed.
   */
  static void refusalChecks(Configuration conf, Path base, FileSystem plain) throws Exception {
    FileSystem fs = base.getFileSystem(conf);
    Path dir = new Path(base, "refusals");
    fs.mkdirs(dir);
    Path f = new Path(dir, "f");
    Path g = new Path(dir, "g");
    byte[] d = data(3000, 21);
    put(fs, f, d);
    put(fs, g, data(100, 22));

    // A1
    check("A1: append is refused", throwsIo(() -> fs.append(f)));
    check("A1: the builder form of append is refused", throwsIo(() -> fs.appendFile(f).build()));
    check("A1: concat is refused", throwsUnsupported(() -> {
      fs.concat(f, new Path[] {g});
      return null;
    }));
    check("A1: truncate is refused", throwsUnsupported(() -> fs.truncate(f, 10)));
    FileContext fc = FileContext.getFileContext(conf);
    check("A1: truncate through FileContext is refused", throwsUnsupported(() -> fc.truncate(f, 10)));
    check("A1: after the refused calls the file is unchanged and still has its record",
        plain.exists(sc(f)) && Arrays.equals(d, readAll(fs, f)));

    // A2: the default for a file without a record is to fail the read
    Path nr = new Path(dir, "no-record");
    put(plain, nr, data(500, 23));
    check("A2: a file with no record cannot be read by default", throwsIo(() -> readAll(fs, nr)));
    check("A2: a status question about a file with no record is answered (it exposes no content)",
        fs.getFileStatus(nr).getLen() == 500);
    Path writing = new Path(dir, "being-written");
    try (FSDataOutputStream o = fs.create(writing)) {
      o.write(data(100, 25));
      o.hflush();
      check("A2: a file that is still being written (no record yet) can be asked about",
          fs.getFileStatus(writing) != null);
    }

    // A4: the doors to the plain file system
    org.apache.hadoop.fs.PathHandle handle = () -> java.nio.ByteBuffer.allocate(0);
    check("A4: opening by path handle is refused", throwsUnsupported(() -> fs.open(handle, 4096)));
    check("A4: the builder for opening by path handle is refused", throwsUnsupported(() -> fs.openFile(handle)));
    check("A4: making a path handle is refused",
        throwsUnsupported(() -> fs.getPathHandle(fs.getFileStatus(f))));
    check("A4: the plain file system under the wrapper is not handed out",
        throwsUnsupported(() -> ((org.apache.hadoop.fs.FilterFileSystem) fs).getRawFileSystem()));
    FileSystem[] kids = fs.getChildFileSystems();
    check("A4: the wrapper has no child file systems to hand out", kids == null || kids.length == 0);
    check("A4: staging an output on the local disk is refused (start)",
        throwsUnsupported(() -> fs.startLocalOutput(f, new Path("/tmp/attested-local-out"))));
    check("A4: staging an output on the local disk is refused (complete)",
        throwsUnsupported(() -> {
          fs.completeLocalOutput(f, new Path("/tmp/attested-local-out"));
          return null;
        }));

    // A3: settings count only when the site configuration set them
    String auditDir = conf.get(AttestedAudit.DIR_KEY);
    java.nio.file.Path tmpDir = Files.createTempDirectory("attested-settings");
    File siteFile = new File(tmpDir.toFile(), "core-site.xml");
    File jobFile = new File(tmpDir.toFile(), "job.xml");
    String allow = "<configuration><property><name>attested.verify.missing</name>"
        + "<value>allow</value></property></configuration>";
    Files.write(siteFile.toPath(), allow.getBytes(StandardCharsets.UTF_8));
    Files.write(jobFile.toPath(), allow.getBytes(StandardCharsets.UTF_8));
    AttestedSettings.trustAllSourcesForTesting(false);
    try {
      Configuration bad = new Configuration(conf);
      bad.setBoolean(AttestedHdfsFileSystem.VERIFY_KEY, false);
      bad.set(AttestedHdfsFileSystem.MISSING_KEY, "allow");
      bad.setBoolean(AttestedHdfsFileSystem.HASH_ENABLED_KEY, false);
      FileSystem fsBad = FileSystem.newInstance(base.toUri(), bad);
      Path victim = new Path(dir, "victim");
      byte[] v = data(40000, 24);
      put(fsBad, victim, v);
      check("A3: with hashing switched off from code, the file still gets a record",
          plain.exists(sc(victim)));
      byte[] changed = v.clone();
      changed[12345] ^= 1;
      put(plain, victim, changed);
      check("A3: with verify.reads off from code, a changed file is still refused",
          throwsChecksum(() -> readAll(fsBad, victim)));
      check("A3: with verify.missing=allow from code, a file with no record is still refused",
          throwsIo(() -> readAll(fsBad, nr)));
      boolean noted = false;
      for (String[] c : auditEntries(auditDir)) {
        if (c[3].equals("INIT") && c[6].contains("ignored=") && c[6].contains("attested.verify.reads")
            && c[6].contains("attested.hash.enabled")) {
          noted = true;
        }
      }
      check("A3: the ignored settings and their source are written to the audit log (INIT line)", noted);

      Configuration viaJob = new Configuration(conf);
      viaJob.addResource(new Path(jobFile.toURI()));
      FileSystem fsJob = FileSystem.newInstance(base.toUri(), viaJob);
      check("A3: verify.missing=allow from a job file is ignored", throwsIo(() -> readAll(fsJob, nr)));

      Configuration viaSite = new Configuration(conf);
      viaSite.addResource(new Path(siteFile.toURI()));
      FileSystem fsSite = FileSystem.newInstance(base.toUri(), viaSite);
      check("A3: verify.missing=allow from the site configuration (core-site.xml) is obeyed",
          readAll(fsSite, nr).length == 500);
    } finally {
      AttestedSettings.trustAllSourcesForTesting(true);
      deleteTree(tmpDir.toFile());
    }
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
    check("the refused append is logged as REFUSED for f1",
        hasDetail(lines, "REFUSED", work + "/a/f1", "op=APPEND"));
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

  static boolean hasDetail(List<String[]> lines, String op, String p1, String detailPart) {
    for (String[] c : lines) {
      if (c[3].equals(op) && c[4].equals(p1) && c[6].contains(detailPart)) {
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

  /**
   * The word-count job through Hadoop's real output committer. With bound true (mode mr-bound) signing and folder binding are on and
   * required, as in the combined crawl: the committer's folders, renames and merges must leave every file with a record bound to its
   * folder and every folder with an identity, and the output must read back through the wrapper.
   */
  static void runMr(boolean bound) throws Exception {
    java.nio.file.Path tmp = Files.createTempDirectory("attested-mr");
    Configuration conf = fakeConf(tmp);
    if (bound) {
      TestKeys key = TestKeys.generate(tmp.resolve("test-key.txt"));
      conf.setBoolean(AttestedHdfsFileSystem.SIGN_KEY, true);
      conf.setBoolean(AttestedHdfsFileSystem.SIGN_REQUIRED_KEY, true);
      conf.setBoolean(AttestedHdfsFileSystem.FOLDER_BIND_KEY, true);
      conf.setBoolean(AttestedHdfsFileSystem.FOLDER_REQUIRED_KEY, true);
      conf.set(AttestedHdfsFileSystem.SIGN_TESTKEY_FILE_KEY, tmp.resolve("test-key.txt").toString());
    }
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
    if (bound) {
      FakeHdfs rawFs = new FakeHdfs();
      rawFs.initialize(URI.create("hdfs://fake:9000"), new Configuration(false));
      int[] inCount = boundCount(rawFs, in), outCount = boundCount(rawFs, out);
      check("every file of the job's input (" + inCount[0] + ") has a record bound to its folder (ATTEST03)", inCount[0] >= 2 && inCount[0] == inCount[1]);
      check("every file of the job's output (" + outCount[0] + ", with _SUCCESS) has a record bound to its folder (ATTEST03), after the committer's folders, renames and merges", outCount[0] >= 2 && outCount[0] == outCount[1]);
      check("the output folder has a signed identity as a top folder, and the input folder too", identityOf(rawFs, out).top() && identityOf(rawFs, in).top());
      check("the committer's _temporary folder and its identity files are gone with the commit", !rawFs.exists(new Path(out, "_temporary")));
    }
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

  /** {files, files whose record is ATTEST03 and names the identity of the folder they are in}, for the files directly in the folder. */
  static int[] boundCount(FileSystem raw, Path dir) throws Exception {
    int files = 0, ok = 0;
    AttestedFolderCodec.Decoded id = raw.exists(new Path(dir, AttestedFolderCodec.FILE_NAME)) ? identityOf(raw, dir) : null;
    for (FileStatus s : raw.listStatus(dir)) {
      String n = s.getPath().getName();
      if (s.isDirectory() || AttestedFolderCodec.isIdentityName(n) || (n.startsWith(".") && n.endsWith(".attested"))) {
        continue;
      }
      files++;
      if (raw.exists(sc(s.getPath())) && id != null) {
        AttestedRecordCodec.Decoded r = AttestedRecordCodec.decode(readAll(raw, sc(s.getPath())));
        if (r.bound() && Arrays.equals(r.folderId, id.folderId) && r.fileName.equals(n)) {
          ok++;
        }
      }
    }
    return new int[] {files, ok};
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


  /** Findings of the metadata checks in the audit log of this run: op starts with META-, path contains the part. */
  static long metaCount(String dir, String op, String pathPart) throws IOException {
    return auditEntries(dir).stream().filter(c -> c[3].startsWith("META-")
        && (op.isEmpty() || c[3].equals(op)) && c[4].contains(pathPart)).count();
  }

  static boolean throwsChecksum(java.util.concurrent.Callable<Object> call) {
    try {
      call.call();
      return false;
    } catch (ChecksumException e) {
      return true;
    } catch (Exception e) {
      return false;
    }
  }

  static boolean throwsNotFound(java.util.concurrent.Callable<Object> call) {
    try {
      call.call();
      return false;
    } catch (FileNotFoundException e) {
      return true;
    } catch (Exception e) {
      return false;
    }
  }

  /** The wrapper refuses with an UnsupportedOperationException that says so ("attested: ..."). */
  static boolean throwsUnsupported(java.util.concurrent.Callable<Object> call) {
    try {
      call.call();
      return false;
    } catch (UnsupportedOperationException e) {
      return e.getMessage() != null && e.getMessage().startsWith("attested:");
    } catch (Exception e) {
      return false;
    }
  }

  static boolean throwsIo(java.util.concurrent.Callable<Object> call) {
    try {
      call.call();
      return false;
    } catch (IOException e) {
      return true;
    } catch (Exception e) {
      return false;
    }
  }

  static int countOf(RemoteIterator<? extends FileStatus> it) throws IOException {
    int n = 0;
    while (it.hasNext()) {
      it.next();
      n++;
    }
    return n;
  }

  /** Step 4.5: answers about files (length, existence, listings) are checked against the records. */
  static void metadataChecks(Configuration conf, Path base, FileSystem plain) throws Exception {
    final FileSystem fs = FileSystem.newInstance(base.toUri(), conf);
    final String auditDir = conf.get(AttestedAudit.DIR_KEY);
    final Path dir = new Path(base, "meta");
    fs.mkdirs(dir);
    final byte[] d1 = data(5000, 1);
    final byte[] d2 = data(40000, 2);
    final byte[] d3 = data(300, 3);
    final Path f1 = new Path(dir, "m1");
    final Path f2 = new Path(dir, "m2");
    final Path f3 = new Path(dir, "m3");
    put(fs, f1, d1);
    put(fs, f2, d2);
    put(fs, f3, d3);

    // a clean folder: nothing is reported, and every way of asking agrees
    check("metadata: a clean folder lists three files, and lengths and existence agree with the records",
        fs.listStatus(dir).length == 3 && fs.getFileStatus(f2).getLen() == d2.length
            && fs.exists(f1) && fs.getFileStatus(f3).isFile() && fs.getFileStatus(dir).isDirectory());
    check("metadata: listing one file shows that file and raises no finding",
        fs.listStatus(f1).length == 1 && fs.listStatus(f1)[0].getLen() == d1.length);
    check("metadata: listFiles, listLocatedStatus, listStatusIterator and glob agree on a clean folder",
        countOf(fs.listFiles(dir, false)) == 3 && countOf(fs.listLocatedStatus(dir)) == 3
            && countOf(fs.listStatusIterator(dir)) == 3 && fs.globStatus(new Path(dir, "m*")).length == 3);
    check("metadata: a clean folder produces no finding in the audit log",
        metaCount(auditDir, "", "/meta/") == 0);

    // a file whose length was changed behind the wrapper's back
    put(plain, f1, data(5001, 9));
    check("metadata: getFileStatus refuses a file whose length differs from its record",
        throwsChecksum(() -> fs.getFileStatus(f1)));
    check("metadata: exists refuses it too",
        throwsChecksum(() -> fs.exists(f1)) && throwsChecksum(() -> fs.getFileStatus(f1).isFile()));
    check("metadata: a listing of the folder refuses it, whichever way it is asked",
        throwsChecksum(() -> fs.listStatus(dir)) && throwsChecksum(() -> countOf(fs.listFiles(dir, false)))
            && throwsChecksum(() -> countOf(fs.listStatusIterator(dir)))
            && throwsChecksum(() -> fs.globStatus(new Path(dir, "m*"))));
    check("metadata: the finding names the two lengths in the audit log",
        auditEntries(auditDir).stream().anyMatch(c -> c[3].equals("META-FAIL") && c[4].endsWith("/meta/m1")
            && c[6].contains("length is 5001 in storage but 5000 in its record")));
    put(plain, f1, d1);
    check("metadata: once the file is as recorded again, the answers are normal",
        fs.getFileStatus(f1).getLen() == d1.length && fs.listStatus(dir).length == 3);

    // a file removed behind the wrapper's back (its record is left)
    plain.delete(f3, false);
    check("metadata: a recorded file that is gone is a finding, not an ordinary 'not found'",
        throwsChecksum(() -> fs.getFileStatus(f3)) && throwsChecksum(() -> fs.exists(f3)));
    check("metadata: a listing refuses a record without its file",
        throwsChecksum(() -> fs.listStatus(dir)) && throwsChecksum(() -> countOf(fs.listStatusIterator(dir))));
    check("metadata: the finding is in the audit log",
        metaCount(auditDir, "META-ORPHAN", "/meta/m3") >= 1);
    plain.delete(sc(f3), false);
    check("metadata: without file and record the answers are the ordinary ones",
        throwsNotFound(() -> fs.getFileStatus(f3)) && !fs.exists(f3) && fs.listStatus(dir).length == 2);

    // a file slipped in without a record: allowed and logged once (the default for a status question
    // is warn; opening such a file fails, step A2)
    final Path f4 = new Path(dir, "m4");
    put(plain, f4, data(77, 4));
    long m0 = metaCount(auditDir, "META-MISSING", "/meta/m4");
    check("metadata: a file without a record is listed and answered (policy warn)",
        fs.listStatus(dir).length == 3 && fs.getFileStatus(f4).getLen() == 77);
    long m1 = metaCount(auditDir, "META-MISSING", "/meta/m4");
    fs.listStatus(dir);
    fs.getFileStatus(f4);
    check("metadata: it is logged once, not at every question",
        m1 == m0 + 1 && metaCount(auditDir, "META-MISSING", "/meta/m4") == m1);

    // the settings
    Configuration failConf = new Configuration(conf);
    failConf.set(AttestedHdfsFileSystem.META_MISSING_KEY, "fail");
    final FileSystem fsFail = FileSystem.newInstance(base.toUri(), failConf);
    check("metadata: with attested.metadata.missing=fail a file without a record is refused",
        throwsIo(() -> fsFail.getFileStatus(f4)) && throwsIo(() -> fsFail.listStatus(dir)));
    Configuration readFail = new Configuration(conf);
    readFail.set(AttestedHdfsFileSystem.MISSING_KEY, "fail");
    final FileSystem fsReadFail = FileSystem.newInstance(base.toUri(), readFail);
    check("metadata: attested.verify.missing=fail (the read policy) does not refuse a status question, but opening the file fails",
        fsReadFail.getFileStatus(f4).getLen() == 77 && throwsIo(() -> readAll(fsReadFail, f4)));
    Configuration allowConf = new Configuration(conf);
    allowConf.set(AttestedHdfsFileSystem.META_MISSING_KEY, "allow");
    final FileSystem fsAllow = FileSystem.newInstance(base.toUri(), allowConf);
    long a0 = metaCount(auditDir, "META-MISSING", "/meta/m4");
    fsAllow.listStatus(dir);
    fsAllow.getFileStatus(f4);
    check("metadata: with attested.metadata.missing=allow the same file raises nothing in that program",
        metaCount(auditDir, "META-MISSING", "/meta/m4") == a0);
    plain.delete(f4, false);

    put(plain, f2, data(40001, 5));
    Configuration warnConf = new Configuration(conf);
    warnConf.set(AttestedHdfsFileSystem.META_MISMATCH_KEY, "warn");
    final FileSystem fsWarn = FileSystem.newInstance(base.toUri(), warnConf);
    long w0 = metaCount(auditDir, "META-FAIL", "/meta/m2");
    check("metadata: with attested.metadata.mismatch=warn the changed file is answered and logged once",
        fsWarn.getFileStatus(f2).getLen() == 40001 && fsWarn.listStatus(dir).length == 2
            && metaCount(auditDir, "META-FAIL", "/meta/m2") == w0 + 1);
    Configuration allowMismatch = new Configuration(conf);
    allowMismatch.set(AttestedHdfsFileSystem.META_MISMATCH_KEY, "allow");
    final FileSystem fsAllowMismatch = FileSystem.newInstance(base.toUri(), allowMismatch);
    check("metadata: with attested.metadata.mismatch=allow it is answered and not logged",
        fsAllowMismatch.getFileStatus(f2).getLen() == 40001
            && metaCount(auditDir, "META-FAIL", "/meta/m2") == w0 + 1);
    Configuration offConf = new Configuration(conf);
    offConf.setBoolean(AttestedHdfsFileSystem.META_KEY, false);
    final FileSystem fsOff = FileSystem.newInstance(base.toUri(), offConf);
    check("metadata: with attested.metadata.check=false the wrapper does not check",
        fsOff.getFileStatus(f2).getLen() == 40001 && fsOff.listStatus(dir).length == 2
            && metaCount(auditDir, "META-FAIL", "/meta/m2") == w0 + 1);
    put(plain, f2, d2);

    // changes made through the wrapper are not findings
    long before = metaCount(auditDir, "", "/meta/");
    fs.getFileStatus(f1);
    byte[] d1b = data(6000, 11);
    put(fs, f1, d1b);
    check("metadata: a rewrite through the wrapper is not a finding (the remembered length is dropped)",
        fs.getFileStatus(f1).getLen() == d1b.length);
    final Path f1r = new Path(dir, "m1r");
    check("metadata: renaming through the wrapper moves the record", fs.rename(f1, f1r)
        && fs.getFileStatus(f1r).getLen() == d1b.length);
    check("metadata: after a rename the old name is simply not found (no finding)",
        throwsNotFound(() -> fs.getFileStatus(f1)));
    fs.delete(f1r, false);
    check("metadata: after a delete through the wrapper the name is simply not found (no finding)",
        throwsNotFound(() -> fs.getFileStatus(f1r)) && !fs.exists(f1r));
    check("metadata: none of these changes raised a finding", metaCount(auditDir, "", "/meta/") == before);

    // another program rewrote the file and its record while this one remembered the old length
    final FileSystem other = FileSystem.newInstance(base.toUri(), conf);
    fs.getFileStatus(f2);
    put(other, f2, data(1234, 12));
    check("metadata: a rewrite by another program is not a finding (the record is read afresh)",
        fs.getFileStatus(f2).getLen() == 1234 && metaCount(auditDir, "", "/meta/") == before);
    fs.delete(dir, true);
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
    check("missing record, default policy (fail, step A2): the open is refused",
        tryRead(fs, t) == null && lastError.contains("has no record"));
    Configuration warnMissingConf = new Configuration(conf);
    warnMissingConf.set(AttestedHdfsFileSystem.MISSING_KEY, "warn");
    FileSystem warnMissingFs = FileSystem.newInstance(base.toUri(), warnMissingConf);
    check("missing record, policy warn: the file reads, unverified",
        Arrays.equals(d, readAll(warnMissingFs, t)) && auditCount(auditDir, "OPEN", "verify=missing") > 0);
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
    check("append is refused, and the file keeps its record and still verifies",
        throwsIo(() -> fs.append(ap)) && plain.exists(sc(ap)) && readAll(fs, ap).length == 1000);

    // the builder forms of create and append go through the wrapper (hashed; the record is kept or dropped)
    Path bc = new Path(dir, "builder-create");
    byte[] bcData = data(30000, 11);
    try (FSDataOutputStream o = fs.createFile(bc).build()) {
      o.write(bcData);
    }
    check("builder create: the file has a record and verifies",
        plain.exists(sc(bc)) && Arrays.equals(bcData, readAll(fs, bc)));
    byte[] bcData2 = data(5000, 12);
    try (FSDataOutputStream o = fs.createFile(bc).build()) {
      o.write(bcData2);
    }
    check("builder create over an existing file: the new content verifies (no stale record)",
        Arrays.equals(bcData2, readAll(fs, bc)));
    check("builder append is refused, and the file keeps its record and still verifies",
        throwsIo(() -> fs.appendFile(bc).build()) && plain.exists(sc(bc))
            && Arrays.equals(bcData2, readAll(fs, bc)));

    // I/O statistics and unbuffer behave as they do through the plain client
    Path st = new Path(dir, "stats");
    byte[] stData = data(40000, 13);
    put(fs, st, stData);
    try (FSDataInputStream ra = fs.open(st); FSDataInputStream rb = plain.open(st)) {
      check("I/O statistics of a read stream are offered exactly when the plain client offers them",
          (ra.getIOStatistics() != null) == (rb.getIOStatistics() != null));
      byte[] x = new byte[100];
      ra.readFully(x);
      ra.unbuffer();
      byte[] y = new byte[100];
      ra.readFully(y);
      check("unbuffer in the middle of a read: the reading goes on with the right bytes",
          Arrays.equals(Arrays.copyOfRange(stData, 0, 100), x) && Arrays.equals(Arrays.copyOfRange(stData, 100, 200), y));
    }
    try (FSDataOutputStream wa = fs.create(new Path(dir, "stats2")); FSDataOutputStream wb = plain.create(new Path(dir, "stats3"))) {
      check("I/O statistics of a write stream are offered exactly when the plain client offers them",
          (wa.getIOStatistics() != null) == (wb.getIOStatistics() != null));
    }

    check("the audit log has VERIFY-FAIL lines for the changed files and records",
        auditCount(auditDir, "VERIFY-FAIL", "") >= 8);
    check("the audit log marks verified opens", auditCount(auditDir, "OPEN", "verify=ok") > 10);
    plain.delete(dir, true);
  }

  // ------------------------------------------------------------ hashing

  /** The hash mode: roots against an independent computation, several sizes and settings. */

  /** True when any audit log file in the folder contains the text. */
  static boolean auditHas(String dir, String needle) throws IOException {
    File[] files = new File(dir).listFiles();
    if (files != null) {
      for (File f : files) {
        if (new String(Files.readAllBytes(f.toPath()), StandardCharsets.UTF_8).contains(needle)) {
          return true;
        }
      }
    }
    return false;
  }

  static byte[] unsignedRecordFor(byte[] content) throws IOException {
    MerkleHasher mh = new MerkleHasher(16384, true);
    mh.update(content, 0, content.length);
    byte[] root = mh.finish();
    return AttestedSidecar.encode(16384, content.length, root, mh.leaves());
  }

  /**
   * Step 5.1.1: records are signed with a test key, and a file that is rewritten together with its
   * record, by someone without the key, fails the read.
   */
  static void signatureChecks(Configuration baseConf, Path base, FileSystem plain) throws Exception {
    java.nio.file.Path keyDir = Files.createTempDirectory("sigkeys");
    java.nio.file.Path keyFile = keyDir.resolve("test-key.txt");
    TestKeys key = TestKeys.generate(keyFile);
    String auditDir = baseConf.get(AttestedAudit.DIR_KEY);

    Configuration signedConf = new Configuration(baseConf);
    signedConf.setBoolean(AttestedHdfsFileSystem.SIGN_KEY, true);
    signedConf.setBoolean(AttestedHdfsFileSystem.SIGN_REQUIRED_KEY, true);
    signedConf.set(AttestedHdfsFileSystem.SIGN_TESTKEY_FILE_KEY, keyFile.toString());
    FileSystem fs = FileSystem.newInstance(base.toUri(), signedConf);
    Path dir = new Path(base, "signed");
    fs.mkdirs(dir);

    // 1. a signed write and read
    Path f = new Path(dir, "a.bin");
    byte[] d = data(50000, 71);
    put(fs, f, d);
    byte[] rec = readAll(plain, sc(f));
    check("a file written with signing on has an ATTEST02 record next to it",
        rec.length > 8 && new String(rec, 0, 8, StandardCharsets.US_ASCII).equals("ATTEST02"));
    check("the record names the test key (its id starts with TEST-)",
        new String(rec, StandardCharsets.ISO_8859_1).contains(key.signingKeyId()));
    check("reading it through the wrapper returns the bytes (signature checked, required)",
        Arrays.equals(d, readAll(fs, f)));
    check("the audit log says how it was checked: verify=ok sig=ok-test",
        auditHas(auditDir, "verify=ok sig=ok-test"));
    check("the audit log of the write names the key: sidecar signed=" + key.signingKeyId(),
        auditHas(auditDir, "sidecar signed=" + key.signingKeyId()));
    check("the INIT line says that signing is on, required, with test keys allowed, and names the key",
        auditHas(auditDir, "sign=true sigrequired=true testkeys=true key=" + key.signingKeyId()));
    check("status questions work on a signed file (length) and listings do not show the record",
        fs.getFileStatus(f).getLen() == 50000 && fs.listStatus(dir).length == 1 && plain.listStatus(dir).length == 2);
    Path g = new Path(dir, "b.bin");
    check("renaming a signed file keeps it readable (the signature does not cover the name yet: step 5.1.2)",
        fs.rename(f, g) && Arrays.equals(d, readAll(fs, g)) && !plain.exists(sc(f)) && plain.exists(sc(g)));

    // 2. the pass condition: someone without the key rewrites the file together with its record
    byte[] evil = data(50000, 99);
    put(plain, g, evil);                                          // new content, behind the wrapper's back
    check("only the file changed: the read fails (the chunk hashes no longer match)", tryRead(fs, g) == null);
    put(plain, sc(g), unsignedRecordFor(evil));                   // and a matching record in the old format
    check("file and record rewritten, the record unsigned: the read fails (signatures are required)",
        tryRead(fs, g) == null && lastError.contains("not signed"));
    MerkleHasher mh = new MerkleHasher(16384, true);
    mh.update(evil, 0, evil.length);
    byte[] evilRoot = mh.finish();
    java.nio.file.Path other = keyDir.resolve("attacker.txt");
    TestKeys attacker = TestKeys.generate(other);
    byte[] oldSig = AttestedRecordCodec.decode(rec).signature;
    put(plain, sc(g), AttestedRecordCodec.encodeSigned(16384, evil.length, evilRoot, mh.leaves(), key.signingKeyId(), oldSig));
    check("file and record rewritten, the OLD signature copied over: the read fails",
        tryRead(fs, g) == null && lastError.contains("does not verify"));
    byte[] ownSig = attacker.sign(AttestedRecordCodec.statement(key.signingKeyId(), 16384, evil.length, evilRoot));
    put(plain, sc(g), AttestedRecordCodec.encodeSigned(16384, evil.length, evilRoot, mh.leaves(), key.signingKeyId(), ownSig));
    check("signed with the attacker's own key under the real key id: the read fails",
        tryRead(fs, g) == null && lastError.contains("does not verify"));
    byte[] ownSig2 = attacker.sign(AttestedRecordCodec.statement(attacker.signingKeyId(), 16384, evil.length, evilRoot));
    put(plain, sc(g), AttestedRecordCodec.encodeSigned(16384, evil.length, evilRoot, mh.leaves(), attacker.signingKeyId(), ownSig2));
    check("signed with the attacker's own key under its own id: the read fails (not a trusted key)",
        tryRead(fs, g) == null && lastError.contains("not trusted"));
    check("each of these failures is in the audit log as VERIFY-FAIL", auditHas(auditDir, "VERIFY-FAIL"));
    put(plain, g, d);                                             // restore the honest content
    put(plain, sc(g), rec);                                       // and the honest record
    check("the honest file with its honest record reads again", Arrays.equals(d, readAll(fs, g)));

    // 3. legacy files and the settings
    Configuration legacyConf = new Configuration(baseConf);
    legacyConf.setBoolean(AttestedHdfsFileSystem.SIGN_KEY, false);
    legacyConf.setBoolean(AttestedHdfsFileSystem.SIGN_REQUIRED_KEY, false);
    legacyConf.set(AttestedHdfsFileSystem.SIGN_TESTKEY_FILE_KEY, keyDir.resolve("none.txt").toString());
    FileSystem legacy = FileSystem.newInstance(base.toUri(), legacyConf);
    Path old = new Path(dir, "legacy.bin");
    byte[] od = data(20000, 5);
    put(legacy, old, od);
    byte[] oldRec = readAll(plain, sc(old));
    check("with signing off the record is the old format, byte for byte (ATTEST01)",
        new String(oldRec, 0, 8, StandardCharsets.US_ASCII).equals("ATTEST01") && Arrays.equals(oldRec, unsignedRecordFor(od)));
    check("a legacy file reads when signatures are not required (and is logged as sig=none)",
        Arrays.equals(od, readAll(legacy, old)) && auditHas(auditDir, "verify=ok sig=none"));
    check("the same legacy file is refused when signatures are required", tryRead(fs, old) == null && lastError.contains("not signed"));
    check("a signed file is refused by a reader that has no key file (not a trusted key)",
        tryRead(legacy, g) == null && lastError.contains("not trusted"));
    Configuration noTest = new Configuration(signedConf);
    noTest.setBoolean(AttestedHdfsFileSystem.SIGN_ALLOW_TEST_KEY, false);
    boolean refusedAtStart = false;
    try {
      FileSystem.newInstance(base.toUri(), noTest);
    } catch (IOException e) {
      refusedAtStart = e.getMessage().contains("test key, which is not allowed");
    }
    check("signing with a test key is refused at start when test keys are not allowed", refusedAtStart);
    Configuration readNoTest = new Configuration(signedConf);
    readNoTest.setBoolean(AttestedHdfsFileSystem.SIGN_KEY, false);
    readNoTest.setBoolean(AttestedHdfsFileSystem.SIGN_ALLOW_TEST_KEY, false);
    FileSystem strict = FileSystem.newInstance(base.toUri(), readNoTest);
    check("a reader that does not allow test keys refuses a test-signed file (the real-key mode)",
        tryRead(strict, g) == null && lastError.contains("not accepted"));
    Configuration missingKey = new Configuration(signedConf);
    missingKey.set(AttestedHdfsFileSystem.SIGN_TESTKEY_FILE_KEY, keyDir.resolve("missing.txt").toString());
    boolean missingRefused = false;
    try {
      FileSystem.newInstance(base.toUri(), missingKey);
    } catch (IOException e) {
      missingRefused = e.getMessage().contains("test key file is missing");
    }
    check("signing on with no key file refuses to start (no unsigned files are written by mistake)", missingRefused);
    Configuration noRecords = new Configuration(signedConf);
    noRecords.setBoolean(AttestedHdfsFileSystem.SIDECAR_KEY, false);
    boolean needRecords = false;
    try {
      FileSystem.newInstance(base.toUri(), noRecords);
    } catch (IOException e) {
      needRecords = e.getMessage().contains("need records");
    }
    check("signatures without records are refused at start", needRecords);
    Configuration publicOnly = new Configuration(signedConf);
    publicOnly.setBoolean(AttestedHdfsFileSystem.SIGN_KEY, false);
    java.nio.file.Path pubFile = keyDir.resolve("public.txt");
    Files.write(pubFile, key.publicFileText().getBytes(StandardCharsets.US_ASCII));
    publicOnly.set(AttestedHdfsFileSystem.SIGN_TESTKEY_FILE_KEY, pubFile.toString());
    FileSystem reader = FileSystem.newInstance(base.toUri(), publicOnly);
    check("a reader with only the public key verifies signed files, and cannot sign",
        Arrays.equals(d, readAll(reader, g)));
    // 4. a signed file inside a job's folder tree still works with the other operations
    Path sub = new Path(dir, "tree/deep");
    fs.mkdirs(sub);
    put(fs, new Path(sub, "x"), data(300, 8));
    fs.rename(new Path(dir, "tree"), new Path(dir, "moved"));
    check("a folder of signed files can be renamed and its files still verify",
        Arrays.equals(data(300, 8), readAll(fs, new Path(dir, "moved/deep/x"))));
    fs.delete(new Path(dir, "moved"), true);
    check("deleting signed files removes their records", !plain.exists(new Path(dir, "moved")));
  }


  /**
   * A fake HDFS in which a writer that loses the race to create a file gets what the real HDFS gives it while the winner is still writing:
   * an IOException that says the file is already being created (the real one is AlreadyBeingCreatedException), not FileAlreadyExistsException.
   * The barrier makes all racers try at the same moment, so the race is certain and not a matter of timing.
   */
  public static class RacingHdfs extends FakeHdfs {
    static volatile java.util.concurrent.CyclicBarrier barrier;

    /** The race itself, for both overloads of create that a caller can reach (the local file system routes one around the other). */
    private void race(Path f, boolean overwrite) throws IOException {
      if (!overwrite && AttestedFolderCodec.isIdentityName(f.getName()) && barrier != null) {
        try {
          barrier.await(5, java.util.concurrent.TimeUnit.SECONDS);
        } catch (Exception e) {
          // the others did not come: go on alone
        }
      }
    }

    private void loser(Path f, boolean overwrite) throws IOException {
      if (!overwrite && exists(f)) {
        throw new IOException("Failed to create file " + f + " for DFSClient_NONMAPREDUCE_1 because this file is already being created by DFSClient_NONMAPREDUCE_2");
      }
    }

    @Override
    public FSDataOutputStream create(Path f, org.apache.hadoop.fs.permission.FsPermission permission, boolean overwrite, int bufferSize,
        short replication, long blockSize, org.apache.hadoop.util.Progressable progress) throws IOException {
      race(f, overwrite);
      synchronized (RacingHdfs.class) {
        loser(f, overwrite);
        return super.create(f, permission, overwrite, bufferSize, replication, blockSize, progress);
      }
    }

    @Override
    public FSDataOutputStream create(Path f, boolean overwrite, int bufferSize, short replication, long blockSize,
        org.apache.hadoop.util.Progressable progress) throws IOException {
      race(f, overwrite);
      synchronized (RacingHdfs.class) {
        loser(f, overwrite);
        return super.create(f, overwrite, bufferSize, replication, blockSize, progress);
      }
    }
  }

  public static class RacingWrapper extends AttestedHdfsFileSystem {
    @Override
    protected FileSystem createInner() {
      try {
        FakeHdfs inner = new RacingHdfs();
        inner.initialize(URI.create("hdfs://fake:9000"), new Configuration(false));
        return inner;
      } catch (IOException e) {
        throw new IllegalStateException(e);
      }
    }
  }

  static AttestedFolderCodec.Decoded identityOf(FileSystem plain, Path dir) throws Exception {
    return AttestedFolderCodec.decode(readAll(plain, new Path(dir, AttestedFolderCodec.FILE_NAME)));
  }

  static void copyTree(FileSystem plain, Path from, Path to, Configuration conf) throws IOException {
    org.apache.hadoop.fs.FileUtil.copy(plain, from, plain, to, false, conf);
  }

  /**
   * Step 5.1.2: every file is bound to its folder. Folders have signed identity files, records name the folder and the file, renames sign a
   * new record (a folder rename only its identity file), and the attacks of the mentor's list that move or copy signed files fail the read.
   */
  /** A stand-in for attest/quote.sh: a 632-byte "quote" whose REPORTDATA (offset 568) is the SHA-512 of the statement file. */
  static java.nio.file.Path fakeQuoteScript(java.nio.file.Path dir) throws IOException {
    java.nio.file.Path f = dir.resolve("fake-quote.sh");
    String body = "#!/usr/bin/env bash\n"
        + "python3 - \"$1\" \"$2\" <<'PY'\n"
        + "import hashlib, sys\n"
        + "st = open(sys.argv[1], 'rb').read()\n"
        + "q = bytearray(b'\\x04\\x00' + b'\\x00' * 630)\n"
        + "q[568:632] = hashlib.sha512(st).digest()\n"
        + "open(sys.argv[2], 'wb').write(bytes(q))\n"
        + "PY\n";
    Files.write(f, body.getBytes(StandardCharsets.US_ASCII));
    Files.setPosixFilePermissions(f, java.nio.file.attribute.PosixFilePermissions.fromString("rwxr-xr-x"));
    return f;
  }

  static String tokenOf(java.nio.file.Path dir) throws IOException {
    return new String(Files.readAllBytes(dir.resolve("token")), StandardCharsets.US_ASCII).trim();
  }

  static Configuration serviceConf(Configuration baseConf, KeyService svc, java.nio.file.Path svcDir, java.nio.file.Path listDir,
      boolean allowUnquoted) throws Exception {
    Configuration c = new Configuration(baseConf);
    c.set(AttestedKeyFactory.PROVIDER_KEY, "service");
    c.set(AttestedKeyFactory.SERVICE_ADDRESS_KEY, "127.0.0.1:" + svc.port());
    c.set(AttestedKeyFactory.SERVICE_TOKEN_FILE_KEY, svcDir.resolve("token").toString());
    c.set(AttestedKeyFactory.LIST_DIR_KEY, listDir.toString());
    c.setLong(AttestedKeyFactory.LIST_CACHE_KEY, 0);
    c.setBoolean(AttestedKeyFactory.LIST_ALLOW_UNQUOTED_KEY, allowUnquoted);
    c.setBoolean(AttestedHdfsFileSystem.SIGN_KEY, true);
    c.setBoolean(AttestedHdfsFileSystem.SIGN_REQUIRED_KEY, true);
    c.setBoolean(AttestedHdfsFileSystem.SIGN_ALLOW_TEST_KEY, false);
    c.setBoolean(AttestedHdfsFileSystem.FOLDER_BIND_KEY, true);
    c.setBoolean(AttestedHdfsFileSystem.FOLDER_REQUIRED_KEY, true);
    c.setLong(AttestedHdfsFileSystem.META_CACHE_KEY, 0);
    return c;
  }

  /**
   * Step 5.1.3: the real key. The wrapper signs through the signing service (the private key never enters its JVM) and trusts only the
   * public keys of the key list, whose bundles hold a quote that vouches for the key. Test keys are not accepted any more.
   */
  static void keyServiceChecks(Configuration baseConf, Path base, FileSystem plain) throws Exception {
    java.nio.file.Path work = Files.createTempDirectory("keysvc");
    java.nio.file.Path listDir = work.resolve("list");
    java.nio.file.Path quote = fakeQuoteScript(work);
    String auditDir = baseConf.get(AttestedAudit.DIR_KEY);
    KeyService svc = KeyService.start(work.resolve("svc1"), 0, listDir, quote.toString(), "smoke-node");
    FileSystem fs = FileSystem.newInstance(base.toUri(), serviceConf(baseConf, svc, work.resolve("svc1"), listDir, false));
    Path top = new Path(base, "realkey");
    byte[] d = data(45000, 31);
    Path f = new Path(top, "seg1/a.bin");
    put(fs, f, d);
    byte[] rec = readAll(plain, sc(f));
    AttestedRecordCodec.Decoded genuine = AttestedRecordCodec.decode(rec);

    // 1. a write and a read with the real key
    check("a file written with the service provider has an ATTEST03 record that names the TDX- key of the service",
        new String(rec, 0, 8, StandardCharsets.US_ASCII).equals("ATTEST03") && genuine.keyId.equals(svc.keyId()) && svc.keyId().startsWith("TDX-"));
    check("reading it through the wrapper returns the bytes, and the audit log says sig=ok (a real key, not a test key)",
        Arrays.equals(d, readAll(fs, f)) && auditHas(auditDir, "verify=ok sig=ok bind=ok"));
    check("the INIT line says that the keys come from the service, that test keys are not allowed, and names the key",
        auditHas(auditDir, "testkeys=false key=" + svc.keyId()) && auditHas(auditDir, "keyprovider=service"));
    check("the folder identities are signed with the same key", identityOf(plain, top).keyId.equals(svc.keyId()) && identityOf(plain, new Path(top, "seg1")).keyId.equals(svc.keyId()));
    long before = svc.signedCount();
    Path g = new Path(top, "seg1/b.bin");
    check("renaming a file signs one new record through the service, and the file reads", fs.rename(f, g) && Arrays.equals(d, readAll(fs, g)) && svc.signedCount() == before + 1);
    byte[] genuineBytes = readAll(plain, sc(g));
    AttestedRecordCodec.Decoded gd = AttestedRecordCodec.decode(genuineBytes);

    // 2. the attacks that the real key must stop
    TestKeys attacker = TestKeys.generate(work.resolve("attacker.txt"));
    MerkleHasher mh = new MerkleHasher(gd.chunkSize, true);
    mh.update(d, 0, d.length);
    mh.finish();
    byte[] sigA = attacker.sign(AttestedRecordCodec.statementBound(attacker.signingKeyId(), gd.folderId, gd.fileName, gd.chunkSize, gd.length, gd.root));
    put(plain, sc(g), AttestedRecordCodec.encodeBound(gd.chunkSize, gd.length, gd.root, mh.leaves(), gd.folderId, gd.fileName, attacker.signingKeyId(), sigA));
    check("attack: the record re-signed with a test key (right folder, name and content): the read FAILS, test keys are not accepted",
        tryRead(fs, g) == null && lastError.contains("test key"));
    put(plain, sc(g), genuineBytes);
    check("undone: the file reads again", Arrays.equals(d, readAll(fs, g)));
    KeyService rogue = KeyService.start(work.resolve("svc-rogue"), 0, work.resolve("rogue-list"), quote.toString(), "rogue-node");
    ServiceKeys rogueClient = new ServiceKeys("127.0.0.1", rogue.port(), tokenOf(work.resolve("svc-rogue")), null, 3000);
    byte[] sigR = rogueClient.sign(AttestedRecordCodec.statementBound(rogue.keyId(), gd.folderId, gd.fileName, gd.chunkSize, gd.length, gd.root));
    put(plain, sc(g), AttestedRecordCodec.encodeBound(gd.chunkSize, gd.length, gd.root, mh.leaves(), gd.folderId, gd.fileName, rogue.keyId(), sigR));
    check("attack: the record signed by another machine's real key that is not in this key list: the read FAILS, not trusted here",
        tryRead(fs, g) == null && lastError.contains("not trusted here"));
    put(plain, sc(g), genuineBytes);
    byte[] moved = genuineBytes.clone();
    moved[moved.length - 4] ^= 1;
    put(plain, sc(g), moved);
    check("attack: one bit of the signature changed: the read FAILS", tryRead(fs, g) == null && lastError.contains("does not verify"));
    put(plain, sc(g), genuineBytes);
    check("undone: the file reads again", Arrays.equals(d, readAll(fs, g)));

    // 3. the service stops: reading goes on, writing fails closed
    svc.close();
    Thread.sleep(100);
    Path h = new Path(top, "seg1/c.bin");
    String why = null;
    try {
      put(fs, h, d);
    } catch (IOException e) {
      why = String.valueOf(e.getMessage());
    }
    check("with the service stopped, a write fails and the message names the signing service", why != null && why.contains("signing service"));
    check("the file that could not be signed has no record, so it cannot be read (fail closed)", plain.exists(h) && tryRead(fs, h) == null);
    check("existing files still read (verification needs only the key list)", Arrays.equals(d, readAll(fs, g)));
    String startFail = null;
    try {
      FileSystem.newInstance(base.toUri(), serviceConf(baseConf, svc, work.resolve("svc1"), listDir, false));
    } catch (IOException e) {
      startFail = String.valueOf(e.getMessage());
    }
    check("a wrapper that is told to sign cannot start while the service is down, and says so", startFail != null && startFail.contains("signing service"));

    // 4. a new service is a new key; the old key stays in the list
    KeyService svc2 = KeyService.start(work.resolve("svc2"), 0, listDir, quote.toString(), "smoke-node");
    FileSystem fs2 = FileSystem.newInstance(base.toUri(), serviceConf(baseConf, svc2, work.resolve("svc2"), listDir, false));
    Path k = new Path(top, "seg1/d.bin");
    put(fs2, k, d);
    check("after a restart the service has another key, and new files are signed with it", !svc2.keyId().equals(svc.keyId())
        && AttestedRecordCodec.decode(readAll(plain, sc(k))).keyId.equals(svc2.keyId()));
    check("the files of the old key and of the new key both read (both bundles are in the list)", Arrays.equals(d, readAll(fs2, g)) && Arrays.equals(d, readAll(fs2, k)));
    java.nio.file.Path oldBundle = listDir.resolve(svc.keyId() + KeyBundle.FILE_SUFFIX);
    byte[] oldBundleBytes = Files.readAllBytes(oldBundle);
    Files.delete(oldBundle);
    check("when the old key's bundle is removed from the list, its files fail: not trusted here (the list is the policy)", tryRead(fs2, g) == null && lastError.contains("not trusted here"));
    Files.write(oldBundle, oldBundleBytes);
    check("put back, they read again", Arrays.equals(d, readAll(fs2, g)));

    // 5. a machine without hardware proof: its records are not accepted unless the list says so
    java.nio.file.Path listSvc = work.resolve("list-svc");
    KeyService soft = KeyService.start(work.resolve("svc3"), 0, listSvc, null, "no-tdx");
    FileSystem fs3 = FileSystem.newInstance(base.toUri(), serviceConf(baseConf, soft, work.resolve("svc3"), listSvc, false));
    Path m = new Path(new Path(base, "softkey"), "seg1/e.bin");   // its own tree: the folders of the other tree are signed by another key
    String softWhy = null;
    try {
      put(fs3, m, d);
    } catch (IOException e) {
      softWhy = String.valueOf(e.getMessage());
    }
    check("a service key without a quote (SVC-) can sign, but a list that wants quotes does not trust it: even its own writer refuses (not trusted here)",
        soft.keyId().startsWith("SVC-") && softWhy != null && softWhy.contains("not trusted here"));
    FileSystem fs4 = FileSystem.newInstance(base.toUri(), serviceConf(baseConf, soft, work.resolve("svc3"), listSvc, true));
    put(fs4, m, d);
    check("with allow.unquoted on, the same machine writes and reads (a service key is accepted only when the list says so)", Arrays.equals(d, readAll(fs4, m)));
    check("... and a reader whose list wants quotes refuses that file", tryRead(fs3, m) == null && lastError.contains("not trusted here"));
    soft.close();
    rogue.close();
    svc2.close();
  }

  /**
   * Step 5.2.1: a list that admits keys by their quote refuses a key whose quote is a fake. The service here makes its bundle with a stand-in quote command (632
   * bytes with the right REPORTDATA, as in the other checks): it passes the binding check but has no Intel certificate chain, so the admitting list must not
   * trust it, and the wrapper must refuse its own records. The control is the same list without admission.
   */
  static void keyAdmissionChecks(Configuration baseConf, Path base, FileSystem plain) throws Exception {
    java.nio.file.Path work = Files.createTempDirectory("keyadm");
    java.nio.file.Path listDir = work.resolve("list");
    KeyService svc = KeyService.start(work.resolve("svc"), 0, listDir, fakeQuoteScript(work).toString(), "adm-node");
    java.nio.file.Path ref = work.resolve("reference.txt");
    Files.write(ref, ("MRTD " + "0".repeat(96) + " *\n").getBytes(StandardCharsets.US_ASCII));
    java.nio.file.Path auditFile = work.resolve("keylist-audit.log");
    Configuration on = serviceConf(baseConf, svc, work.resolve("svc"), listDir, false);
    on.set(AttestedKeyFactory.LIST_AUDIT_FILE_KEY, auditFile.toString());
    on.setBoolean(AttestedKeyFactory.ADMISSION_ENABLED_KEY, true);
    on.set(AttestedKeyFactory.ADMISSION_REFERENCE_KEY, ref.toString());
    on.set(AttestedKeyFactory.ADMISSION_ENFORCE_KEY, "mrtd");
    FileSystem fs = FileSystem.newInstance(base.toUri(), on);
    byte[] d = data(20000, 41);
    String why = null;
    try {
      put(fs, new Path(new Path(base, "admit-refused"), "x.bin"), d);
    } catch (IOException e) {
      why = String.valueOf(e.getMessage());
    }
    check("with admission on, a key whose quote has no Intel certificate chain is not trusted: even its own writer refuses (not trusted here)", why != null && why.contains("not trusted here"));
    check("the rejection is written to the key list's audit file, with its reason", Files.exists(auditFile)
        && Files.readAllLines(auditFile).stream().anyMatch(l -> l.contains(" REJECT file=" + svc.keyId()) && l.contains("reason=")));
    Configuration off = serviceConf(baseConf, svc, work.resolve("svc"), listDir, false);
    Path ok = new Path(new Path(base, "admit-control"), "y.bin");
    FileSystem fs2 = FileSystem.newInstance(base.toUri(), off);
    put(fs2, ok, d);
    check("control: the same list without admission trusts that key (the fake quote passes the binding check), so the write and the read work", Arrays.equals(d, readAll(fs2, ok)));
    check("the admission is off by default: the settings of the control do not mention it", !off.getBoolean(AttestedKeyFactory.ADMISSION_ENABLED_KEY, false));
    svc.close();
  }

  static void bindingChecks(Configuration baseConf, Path base, FileSystem plain) throws Exception {
    java.nio.file.Path keyDir = Files.createTempDirectory("bindkeys");
    java.nio.file.Path keyFile = keyDir.resolve("test-key.txt");
    TestKeys key = TestKeys.generate(keyFile);
    TestKeys attacker = TestKeys.generate(keyDir.resolve("attacker.txt"));
    String auditDir = baseConf.get(AttestedAudit.DIR_KEY);
    Configuration bc = new Configuration(baseConf);
    bc.setBoolean(AttestedHdfsFileSystem.SIGN_KEY, true);
    bc.setBoolean(AttestedHdfsFileSystem.SIGN_REQUIRED_KEY, true);
    bc.setBoolean(AttestedHdfsFileSystem.FOLDER_BIND_KEY, true);
    bc.setBoolean(AttestedHdfsFileSystem.FOLDER_REQUIRED_KEY, true);
    bc.set(AttestedHdfsFileSystem.SIGN_TESTKEY_FILE_KEY, keyFile.toString());
    bc.setLong(AttestedHdfsFileSystem.META_CACHE_KEY, 0);
    FileSystem fs = FileSystem.newInstance(base.toUri(), bc);
    Path top = new Path(base, "bound");
    byte[] d1 = data(40000, 21), d2 = data(30000, 22);

    // 1. folders get identities: a top folder (bound to its path) and children (bound to the parent's ID)
    check("making a folder through the wrapper gives it a signed identity file (a top folder, bound to its full path)",
        fs.mkdirs(new Path(top, "seg1")) && plain.exists(new Path(top, "_attested-folder")) && identityOf(plain, top).top() && identityOf(plain, top).topPath.equals(top.toUri().getPath()));
    AttestedFolderCodec.Decoded topId = identityOf(plain, top), seg1Id = identityOf(plain, new Path(top, "seg1"));
    check("the child folder's identity names its parent's ID and its own name", !seg1Id.top() && Arrays.equals(seg1Id.parentId, topId.folderId) && seg1Id.name.equals("seg1"));
    check("identity files are hidden from listings made through the wrapper, and visible to the plain client",
        fs.listStatus(top).length == 1 && plain.listStatus(top).length == 2);
    check("the INIT line says binding is on and required", auditHas(auditDir, "bind=true bindrequired=true"));
    check("making a folder that exists does not change its identity", fs.mkdirs(new Path(top, "seg1")) && Arrays.equals(identityOf(plain, new Path(top, "seg1")).folderId, seg1Id.folderId));

    // 2. a file in the folder: its record is bound
    Path f = new Path(top, "seg1/part-r-00000");
    put(fs, f, d1);
    AttestedRecordCodec.Decoded rec = AttestedRecordCodec.decode(readAll(plain, sc(f)));
    check("the record of a file is ATTEST03, names the folder's ID and the file's name", rec.bound() && Arrays.equals(rec.folderId, seg1Id.folderId) && rec.fileName.equals("part-r-00000"));
    check("reading it through the wrapper works and is logged as bind=ok", Arrays.equals(d1, readAll(fs, f)) && auditHas(auditDir, "sig=ok-test bind=ok"));
    check("the audit log of the write names the folder: sidecar signed=... bound=", auditHas(auditDir, "sidecar signed=" + key.signingKeyId() + " bound=" + MerkleHasher.hex(seg1Id.folderId).substring(0, 8)));

    // 3. creating a file creates the missing folders, each with an identity
    Path deep = new Path(top, "seg2/deep/x.bin");
    put(fs, deep, d2);
    check("creating a file in folders that do not exist makes each folder with an identity (parent ID chain)",
        identityOf(plain, new Path(top, "seg2")).parentId != null && Arrays.equals(identityOf(plain, new Path(top, "seg2/deep")).parentId, identityOf(plain, new Path(top, "seg2")).folderId)
        && Arrays.equals(identityOf(plain, new Path(top, "seg2")).parentId, topId.folderId) && Arrays.equals(d2, readAll(fs, deep)));

    // 4. renames: a file gets a new record, no data is read; a folder only a new identity file
    Path g = new Path(top, "seg2/part-r-00000");
    byte[] before = readAll(plain, sc(f));
    check("renaming a file into another folder works and the file reads", fs.rename(f, g) && Arrays.equals(d1, readAll(fs, g)));
    AttestedRecordCodec.Decoded recG = AttestedRecordCodec.decode(readAll(plain, sc(g)));
    check("the new record names the new folder's ID and the file's name, with the same content hash", Arrays.equals(recG.folderId, identityOf(plain, new Path(top, "seg2")).folderId) && Arrays.equals(recG.root, rec.root) && recG.fileName.equals("part-r-00000") && !Arrays.equals(readAll(plain, sc(g)), before));
    check("the old record is gone", !plain.exists(sc(f)));
    Path g2 = new Path(top, "seg2/renamed");
    check("renaming a file inside its folder signs a new record for the new name", fs.rename(g, g2) && Arrays.equals(d1, readAll(fs, g2)) && AttestedRecordCodec.decode(readAll(plain, sc(g2))).fileName.equals("renamed"));
    byte[] recBefore = readAll(plain, sc(deep));
    Path seg2b = new Path(top, "seg2b");
    AttestedFolderCodec.Decoded seg2Id = identityOf(plain, new Path(top, "seg2"));
    check("renaming a folder works, and the files and folders inside still read", fs.rename(new Path(top, "seg2"), seg2b) && Arrays.equals(d2, readAll(fs, new Path(seg2b, "deep/x.bin"))) && Arrays.equals(d1, readAll(fs, new Path(seg2b, "renamed"))));
    check("a folder rename signs only the folder's own identity file: same folder ID, new name, records inside byte for byte unchanged",
        Arrays.equals(identityOf(plain, seg2b).folderId, seg2Id.folderId) && identityOf(plain, seg2b).name.equals("seg2b") && Arrays.equals(readAll(plain, sc(new Path(seg2b, "deep/x.bin"))), recBefore));
    Path nested = new Path(top, "seg1/seg2c");
    check("renaming a folder into another parent re-signs it with the new parent's ID", fs.rename(seg2b, nested) && Arrays.equals(identityOf(plain, nested).parentId, seg1Id.folderId) && Arrays.equals(d2, readAll(fs, new Path(nested, "deep/x.bin"))));
    Path intoDir = new Path(top, "seg1");
    put(fs, new Path(top, "loose.bin"), data(500, 23));
    check("renaming a file onto a folder moves it into the folder, with a record for the new place", fs.rename(new Path(top, "loose.bin"), intoDir) && Arrays.equals(data(500, 23), readAll(fs, new Path(intoDir, "loose.bin"))));

    // 5. the attacks of the mentor's list, played with the plain client
    Path s1 = new Path(top, "att1"), s2 = new Path(top, "att2");
    put(fs, new Path(s1, "part-r-00000"), data(20000, 31));
    put(fs, new Path(s2, "part-r-00000"), data(20000, 32));
    check("both honest same-named files read", Arrays.equals(data(20000, 31), readAll(fs, new Path(s1, "part-r-00000"))) && Arrays.equals(data(20000, 32), readAll(fs, new Path(s2, "part-r-00000"))));
    byte[] f1 = readAll(plain, new Path(s1, "part-r-00000")), r1 = readAll(plain, sc(new Path(s1, "part-r-00000")));
    byte[] f2 = readAll(plain, new Path(s2, "part-r-00000")), r2 = readAll(plain, sc(new Path(s2, "part-r-00000")));
    put(plain, new Path(s1, "part-r-00000"), f2); put(plain, sc(new Path(s1, "part-r-00000")), r2);
    put(plain, new Path(s2, "part-r-00000"), f1); put(plain, sc(new Path(s2, "part-r-00000")), r1);
    check("swapping two same-named files (with their records) between folders: both reads fail",
        tryRead(fs, new Path(s1, "part-r-00000")) == null && lastError.contains("another folder") && tryRead(fs, new Path(s2, "part-r-00000")) == null && lastError.contains("another folder"));
    put(plain, new Path(s1, "part-r-00000"), f1); put(plain, sc(new Path(s1, "part-r-00000")), r1);
    put(plain, new Path(s2, "part-r-00000"), f2); put(plain, sc(new Path(s2, "part-r-00000")), r2);
    check("undone, both read again", Arrays.equals(data(20000, 31), readAll(fs, new Path(s1, "part-r-00000"))));
    Path moved = new Path(s2, "stolen");
    put(plain, moved, f1); put(plain, sc(moved), r1);
    check("moving a signed file and its record into another folder (and under another name): the read fails", tryRead(fs, moved) == null && (lastError.contains("another folder") || lastError.contains("named")));
    Path moved2 = new Path(s1, "renamed-behind");
    put(plain, moved2, f1); put(plain, sc(moved2), r1);
    check("renaming a signed file and its record behind the wrapper's back, in the same folder: the read fails", tryRead(fs, moved2) == null && lastError.contains("is for a file named"));
    Path copied = new Path(top, "copy-of-att1");
    copyTree(plain, s1, copied, bc);
    check("copying a whole folder elsewhere: its files fail the read (the identity belongs to the other folder)", tryRead(fs, new Path(copied, "part-r-00000")) == null && (lastError.contains("named") || lastError.contains("path") || lastError.contains("another")));
    put(plain, new Path(s1, "unsigned.bin"), data(100, 5));
    check("adding an unsigned file with no record: the read fails", tryRead(fs, new Path(s1, "unsigned.bin")) == null && lastError.contains("no record"));
    byte[] idS1 = readAll(plain, new Path(s1, "_attested-folder")), idS2 = readAll(plain, new Path(s2, "_attested-folder"));
    put(plain, new Path(s1, "_attested-folder"), idS2);
    check("putting the identity of another folder into this folder: the read fails", tryRead(fs, new Path(s1, "part-r-00000")) == null && (lastError.contains("named") || lastError.contains("another") || lastError.contains("path")));
    put(plain, new Path(s1, "_attested-folder"), idS1);
    check("restored, it reads again", Arrays.equals(data(20000, 31), readAll(fs, new Path(s1, "part-r-00000"))));
    plain.delete(new Path(s1, "_attested-folder"), false);
    check("deleting the identity file behind the wrapper's back: the read fails (the folder has no identity)", tryRead(fs, new Path(s1, "part-r-00000")) == null && lastError.contains("has no identity"));
    put(plain, new Path(s1, "_attested-folder"), idS1);
    AttestedFolderCodec.Decoded real1 = AttestedFolderCodec.decode(idS1);
    byte[] evilId = AttestedFolderCodec.encode(real1.folderId, real1.name, real1.parentId, real1.topPath, real1.keyId, attacker.sign(AttestedFolderCodec.statement(real1.keyId, real1.folderId, real1.name, real1.parentId, real1.topPath)));
    put(plain, new Path(s1, "_attested-folder"), evilId);
    check("an identity signed with the attacker's key: the read fails", tryRead(fs, new Path(s1, "part-r-00000")) == null && lastError.contains("does not verify"));
    put(plain, new Path(s1, "_attested-folder"), idS1);
    check("restored again, it reads", Arrays.equals(data(20000, 31), readAll(fs, new Path(s1, "part-r-00000"))));
    Path s1renamed = new Path(top, "att1-renamed");
    plain.rename(s1, s1renamed);
    check("renaming a folder behind the wrapper's back: the read fails (the identity names another folder name)", tryRead(fs, new Path(s1renamed, "part-r-00000")) == null && lastError.contains("is for a folder named"));
    boolean refusedRename = false;
    try { fs.rename(s1renamed, new Path(top, "att1-again")); } catch (IOException e) { refusedRename = e.getMessage().contains("rename refused"); }
    check("the wrapper does not sign a folder that was moved behind its back: its rename is refused", refusedRename);
    plain.rename(s1renamed, s1);
    Path victim = new Path(s2, "part-r-00000");
    MerkleHasher mh = new MerkleHasher(16384, true); byte[] evil = data(20000, 77); mh.update(evil, 0, evil.length); byte[] er = mh.finish();
    AttestedFolderCodec.Decoded s2Id = identityOf(plain, s2);
    byte[] forgedRec = AttestedRecordCodec.encodeBound(16384, evil.length, er, mh.leaves(), s2Id.folderId, "part-r-00000", key.signingKeyId(), attacker.sign(AttestedRecordCodec.statementBound(key.signingKeyId(), s2Id.folderId, "part-r-00000", 16384, evil.length, er)));
    put(plain, victim, evil); put(plain, sc(victim), forgedRec);
    boolean launder = false;
    try { fs.rename(victim, new Path(s2, "laundered")); } catch (IOException e) { launder = e.getMessage().contains("rename refused"); }
    check("a forged bound record is not signed again by a rename (the old record is checked first): the rename is refused", launder && tryRead(fs, victim) == null);
    put(plain, victim, f2); put(plain, sc(victim), r2);

    // the two copies that keep the folder's own name: only the top path and the parent link can catch them
    Path topB = new Path(base, "boundB");
    put(fs, new Path(topB, "t.bin"), data(900, 71));
    Path elsewhere = new Path(base, "elsewhere");
    plain.mkdirs(elsewhere);
    copyTree(plain, topB, new Path(elsewhere, "boundB"), bc);
    check("copying a top folder elsewhere under the same name: the read fails (the top identity is for another path)", tryRead(fs, new Path(elsewhere, "boundB/t.bin")) == null && lastError.contains("is for the path"));
    Path otherParent = new Path(top, "other");
    fs.mkdirs(otherParent);
    Path childCopy = new Path(otherParent, "att2");
    copyTree(plain, s2, childCopy, bc);
    check("copying a folder under another parent with the same name: the read fails (its identity points to another parent)", tryRead(fs, new Path(childCopy, "part-r-00000")) == null && lastError.contains("points to another parent"));

    // 6. the reserved name, legacy files, and the settings
    boolean denied = false;
    try { fs.create(new Path(s2, "_attested-folder"), true).close(); } catch (IOException e) { denied = e.getMessage().contains("reserved"); }
    boolean deniedRename = false;
    try { fs.rename(new Path(s2, "part-r-00000"), new Path(s2, "_attested-folder")); } catch (IOException e) { deniedRename = e.getMessage().contains("reserved"); }
    boolean deniedDelete = false;
    try { fs.delete(new Path(s2, "_attested-folder"), false); } catch (IOException e) { deniedDelete = e.getMessage().contains("reserved"); }
    check("the identity file's name cannot be created, renamed to or deleted through the wrapper", denied && deniedRename && deniedDelete && plain.exists(new Path(s2, "_attested-folder")));
    Configuration signOnly = new Configuration(bc);
    signOnly.setBoolean(AttestedHdfsFileSystem.FOLDER_BIND_KEY, false);
    signOnly.setBoolean(AttestedHdfsFileSystem.FOLDER_REQUIRED_KEY, false);
    FileSystem unbound = FileSystem.newInstance(base.toUri(), signOnly);
    Path legacy = new Path(top, "legacy.bin");
    put(unbound, legacy, data(700, 41));
    check("with binding off, a record is the signed unbound ATTEST02 and no identity is made for its folder", AttestedRecordCodec.decode(readAll(plain, sc(legacy))).version == 2);
    check("an unbound record is accepted when binding is not required (logged bind=none), and refused when it is",
        Arrays.equals(data(700, 41), readAll(unbound, legacy)) && auditHas(auditDir, "bind=none") && tryRead(fs, legacy) == null && lastError.contains("not bound to a folder"));
    check("a reader that does not require binding still checks a bound record (a swapped pair fails)",
        Arrays.equals(data(20000, 32), readAll(unbound, new Path(s2, "part-r-00000"))) && tryRead(unbound, moved) == null);
    Configuration noSign = new Configuration(baseConf);
    noSign.setBoolean(AttestedHdfsFileSystem.FOLDER_BIND_KEY, true);
    boolean needSign = false;
    try { FileSystem.newInstance(base.toUri(), noSign); } catch (IOException e) { needSign = e.getMessage().contains("needs signed records"); }
    check("folder binding without signing refuses to start", needSign);

    // 7. adopting a folder that the plain client made, and two tasks making the same folder at once
    Path adopted = new Path(top, "plain-made");
    plain.mkdirs(adopted);
    put(fs, new Path(adopted, "a.bin"), data(300, 51));
    check("writing into a folder that the plain client made adopts it: it gets an identity and the file reads", plain.exists(new Path(adopted, "_attested-folder")) && Arrays.equals(data(300, 51), readAll(fs, new Path(adopted, "a.bin"))));
    Path plainA = new Path(top, "plainA"), plainB = new Path(plainA, "plainB");
    plain.mkdirs(plainB);
    put(fs, new Path(plainB, "x.bin"), data(200, 52));
    check("writing two levels below an identified folder, where both folders in between were made by the plain client, adopts them as children (the chain is closed, no top folder inside the tree)",
        Arrays.equals(identityOf(plain, plainA).parentId, topId.folderId) && !identityOf(plain, plainA).top() && Arrays.equals(identityOf(plain, plainB).parentId, identityOf(plain, plainA).folderId) && Arrays.equals(data(200, 52), readAll(fs, new Path(plainB, "x.bin"))));
    Path nestedTopTry = new Path(base, "unrelated-plain/inner");
    plain.mkdirs(nestedTopTry);
    put(fs, new Path(nestedTopTry, "y.bin"), data(100, 53));
    check("writing into a folder under old folders where no ancestor has an identity makes that one folder a top folder, bound to its full path, and nothing above it is touched",
        identityOf(plain, nestedTopTry).top() && identityOf(plain, nestedTopTry).topPath.equals(nestedTopTry.toUri().getPath()) && !plain.exists(new Path(base, "unrelated-plain/_attested-folder")) && Arrays.equals(data(100, 53), readAll(fs, new Path(nestedTopTry, "y.bin"))));
    final Path race = new Path(top, "race/folder");
    final FileSystem[] fss = new FileSystem[] {FileSystem.newInstance(base.toUri(), bc), FileSystem.newInstance(base.toUri(), bc), FileSystem.newInstance(base.toUri(), bc), FileSystem.newInstance(base.toUri(), bc)};
    final Throwable[] errs = new Throwable[fss.length];
    Thread[] ts = new Thread[fss.length];
    for (int i = 0; i < ts.length; i++) {
      final int n = i;
      ts[i] = new Thread(() -> { try { put(fss[n], new Path(race, "f" + n), data(2000, 60 + n)); } catch (Throwable e) { errs[n] = e; } });
    }
    for (Thread t : ts) t.start();
    for (Thread t : ts) t.join();
    boolean noErr = true; for (Throwable e : errs) { if (e != null) { noErr = false; e.printStackTrace(); } }
    boolean allRead = true; for (int i = 0; i < fss.length; i++) { if (!Arrays.equals(data(2000, 60 + i), readAll(fs, new Path(race, "f" + i)))) allRead = false; }
    check("four writers making the same new folder at once: no error, one identity wins, every file reads", noErr && allRead && plain.exists(new Path(race, "_attested-folder")) && Arrays.equals(AttestedRecordCodec.decode(readAll(plain, sc(new Path(race, "f0")))).folderId, identityOf(plain, race).folderId));

    // the same race on a file system whose losers get "already being created" (as the real HDFS gives them): every racer must still succeed
    if (!plain.getClass().getName().contains("DistributedFileSystem")) {
      Configuration rc = new Configuration(bc);
      rc.set("fs.hdfs.impl", RacingWrapper.class.getName());
      final FileSystem[] racers = new FileSystem[] {FileSystem.newInstance(base.toUri(), rc), FileSystem.newInstance(base.toUri(), rc), FileSystem.newInstance(base.toUri(), rc), FileSystem.newInstance(base.toUri(), rc)};
      final Path race2 = new Path(top, "race2/folder");
      RacingHdfs.barrier = new java.util.concurrent.CyclicBarrier(racers.length);
      final Throwable[] errs2 = new Throwable[racers.length];
      Thread[] ts2 = new Thread[racers.length];
      for (int i = 0; i < ts2.length; i++) {
        final int n = i;
        ts2[i] = new Thread(() -> { try { put(racers[n], new Path(race2, "f" + n), data(1800, 90 + n)); } catch (Throwable e) { errs2[n] = e; } });
      }
      for (Thread th : ts2) th.start();
      for (Thread th : ts2) th.join();
      RacingHdfs.barrier = null;
      boolean clean = true; for (Throwable e : errs2) { if (e != null) { clean = false; e.printStackTrace(); } }
      boolean readable = true; for (int i = 0; i < racers.length; i++) { if (!Arrays.equals(data(1800, 90 + i), readAll(fs, new Path(race2, "f" + i)))) readable = false; }
      check("four writers racing for the same new folders, where the losers get \"already being created\" as on the real HDFS: no error, one identity per folder, every file reads",
          clean && readable && Arrays.equals(identityOf(plain, race2).parentId, identityOf(plain, race2.getParent()).folderId));
    }

    // with the identity cache on (the production setting), ordinary work still passes: create, read, rename a file and a folder, read again
    Configuration cached = new Configuration(bc);
    cached.setLong(AttestedHdfsFileSystem.META_CACHE_KEY, 10);
    FileSystem cfs = FileSystem.newInstance(base.toUri(), cached);
    Path ctop = new Path(base, "cached-top");
    for (int i = 0; i < 6; i++) { put(cfs, new Path(ctop, "a/f" + i), data(1500, 80 + i)); }
    boolean cacheOk = true;
    for (int i = 0; i < 6; i++) { if (!Arrays.equals(data(1500, 80 + i), readAll(cfs, new Path(ctop, "a/f" + i)))) cacheOk = false; }
    cacheOk &= cfs.rename(new Path(ctop, "a/f0"), new Path(ctop, "a/g0")) && Arrays.equals(data(1500, 80), readAll(cfs, new Path(ctop, "a/g0")));
    cacheOk &= cfs.rename(new Path(ctop, "a"), new Path(ctop, "b")) && Arrays.equals(data(1500, 85), readAll(cfs, new Path(ctop, "b/f5"))) && Arrays.equals(data(1500, 80), readAll(cfs, new Path(ctop, "b/g0")));
    check("with the identity cache on (10 s), creating, reading, renaming a file and renaming a folder all work", cacheOk && identityOf(plain, new Path(ctop, "b")).name.equals("b"));

    // 8. deleting
    check("deleting a folder removes it with its identity and records", fs.delete(new Path(top, "seg1"), true) && !plain.exists(new Path(top, "seg1")));
    check("deleting a file leaves its folder's identity", fs.delete(new Path(top, "att2/part-r-00000"), false) && plain.exists(new Path(top, "att2/_attested-folder")) && !plain.exists(sc(new Path(top, "att2/part-r-00000"))));
  }

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
