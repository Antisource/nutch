/*
 * Licensed to the Apache Software Foundation (ASF) under one or more
 * contributor license agreements.  See the NOTICE file distributed with
 * this work for additional information regarding copyright ownership.
 * The ASF licenses this file to You under the Apache License, Version 2.0
 * (the "License"); you may not use this file except in compliance with
 * the License.  You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package org.apache.nutch.attested;

import java.io.BufferedReader;
import java.io.Closeable;
import java.io.File;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.io.Writer;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardOpenOption;
import java.nio.file.attribute.PosixFilePermissions;
import java.security.GeneralSecurityException;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.MessageDigest;
import java.security.PrivateKey;
import java.security.SecureRandom;
import java.security.Signature;
import java.security.spec.ECGenParameterSpec;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.Base64;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;

/**
 * The small signing service of step 5.1.3. It runs as its own process on each machine: it makes the machine's signing key when it
 * starts, keeps it in memory only (the key is never written anywhere and dies with the process), and signs on request over a
 * loopback socket. When it is given a quote command it asks the hardware for a quote whose REPORTDATA is the SHA-512 of the key's
 * statement (attest/quote.sh does that), and writes the key bundle (statement and quote) for the key lists of the machines.
 *
 * <p>It signs only the statements that the wrapper builds (the three signed formats), and only for its own key id, so it is not a
 * general signing oracle. Every request is logged. A caller must know the token. The wrapper's JVM asks it; it cannot take the key.</p>
 *
 * <pre>
 * java -cp attested-hdfs.jar org.apache.nutch.attested.KeyService --dir DIR [--port N] [--list-dir DIR] [--quote-cmd CMD] [--host NAME]
 * </pre>
 */
public final class KeyService implements Closeable {
  static final int MAX_STATEMENT = 16384;
  private static final byte[][] TAGS = {
    "ATTEST02-SIGNED\n".getBytes(StandardCharsets.US_ASCII),
    "ATTEST03-SIGNED\n".getBytes(StandardCharsets.US_ASCII),
    "ATTESTFD-SIGNED\n".getBytes(StandardCharsets.US_ASCII)};

  private final PrivateKey priv;
  private final String keyId;
  private final KeyBundle bundle;
  private final ServerSocket server;
  private final byte[] token;
  private final Path dir;
  private final Path bundleFile;
  private final Object auditLock = new Object();
  private final AtomicLong signed = new AtomicLong();
  private final AtomicLong refused = new AtomicLong();
  private volatile boolean closed;

  /**
   * Starts the service. quoteCommand may be null (a service key without a quote, SVC-, for tests); otherwise it is run as
   * "COMMAND statementFile quoteFile" and must succeed (a TDX- key without its quote is never made).
   */
  static KeyService start(Path dir, int port, Path listDir, String quoteCommand, String host) throws IOException {
    try {
      Files.createDirectories(dir);
      KeyPairGenerator g = KeyPairGenerator.getInstance("EC");
      g.initialize(new ECGenParameterSpec("secp256r1"));
      KeyPair kp = g.generateKeyPair();
      byte[] pub = kp.getPublic().getEncoded();
      String prefix = quoteCommand == null ? KeyBundle.SVC : KeyBundle.TDX;
      String id = KeyBundle.idOf(prefix, pub);
      byte[] nonceBytes = new byte[16];
      new SecureRandom().nextBytes(nonceBytes);
      String created = Instant.now().truncatedTo(ChronoUnit.SECONDS).toString();
      byte[] statement = KeyBundle.statementBytes(id, pub, host, created, MerkleHasher.hex(nonceBytes));
      byte[] quote = null;
      if (quoteCommand != null) {
        quote = obtainQuote(quoteCommand, dir, statement);
      }
      KeyBundle b = KeyBundle.of(prefix, pub, host, created, MerkleHasher.hex(nonceBytes), quote);
      b.checkBinding();
      Path token = dir.resolve("token");
      if (!Files.exists(token)) {
        byte[] t = new byte[24];
        new SecureRandom().nextBytes(t);
        writePrivate(token, (Base64.getUrlEncoder().withoutPadding().encodeToString(t) + "\n").getBytes(StandardCharsets.US_ASCII));
      }
      String tokenText = new String(Files.readAllBytes(token), StandardCharsets.US_ASCII).trim();
      Path bundleFile = dir.resolve(id + KeyBundle.FILE_SUFFIX);
      Files.write(bundleFile, b.encode());
      if (listDir != null) {
        Files.createDirectories(listDir);
        Files.write(listDir.resolve(id + KeyBundle.FILE_SUFFIX), b.encode());
      }
      ServerSocket s = new ServerSocket(port, 50, InetAddress.getByName("127.0.0.1"));
      KeyService svc = new KeyService(kp.getPrivate(), id, b, s, tokenText.getBytes(StandardCharsets.US_ASCII), dir, bundleFile);
      Files.write(dir.resolve("port"), (s.getLocalPort() + "\n").getBytes(StandardCharsets.US_ASCII));
      svc.audit("START", "key=" + id + " quote=" + (quote == null ? "none" : "yes") + " port=" + s.getLocalPort());
      svc.acceptLoop();
      return svc;
    } catch (GeneralSecurityException e) {
      throw new IOException("cannot start the signing service: " + e);
    }
  }

  private KeyService(PrivateKey priv, String keyId, KeyBundle bundle, ServerSocket server, byte[] token, Path dir, Path bundleFile) {
    this.priv = priv;
    this.keyId = keyId;
    this.bundle = bundle;
    this.server = server;
    this.token = token;
    this.dir = dir;
    this.bundleFile = bundleFile;
  }

  private static byte[] obtainQuote(String command, Path dir, byte[] statement) throws IOException {
    Path st = dir.resolve("statement.txt");
    Path q = dir.resolve("quote.bin");
    Files.write(st, statement);
    Files.deleteIfExists(q);
    String[] parts = command.trim().split("\\s+");
    String[] cmd = new String[parts.length + 2];
    System.arraycopy(parts, 0, cmd, 0, parts.length);
    cmd[parts.length] = st.toString();
    cmd[parts.length + 1] = q.toString();
    try {
      Process p = new ProcessBuilder(cmd).redirectErrorStream(true).redirectOutput(dir.resolve("quote.log").toFile()).start();
      if (!p.waitFor(60, TimeUnit.SECONDS)) {
        p.destroyForcibly();
        throw new IOException("the quote command did not finish in 60 seconds");
      }
      if (p.exitValue() != 0 || !Files.isRegularFile(q)) {
        throw new IOException("the quote command failed (exit " + p.exitValue() + "; see " + dir.resolve("quote.log") + ")");
      }
      return Files.readAllBytes(q);
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
      throw new IOException("interrupted while asking for the quote");
    }
  }

  private static void writePrivate(Path file, byte[] content) throws IOException {
    try {
      Files.createFile(file, java.nio.file.attribute.PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------")));
    } catch (UnsupportedOperationException e) {
      Files.createFile(file);
    }
    Files.write(file, content, StandardOpenOption.WRITE);
  }

  String keyId() {
    return keyId;
  }

  int port() {
    return server.getLocalPort();
  }

  Path bundleFile() {
    return bundleFile;
  }

  KeyBundle bundle() {
    return bundle;
  }

  long signedCount() {
    return signed.get();
  }

  long refusedCount() {
    return refused.get();
  }

  /** For the test that the private key is never written anywhere: the key's encoding. */
  byte[] privateEncodedForTest() {
    return priv.getEncoded();
  }

  private void acceptLoop() {
    Thread t = new Thread(() -> {
      while (!closed) {
        try {
          Socket c = server.accept();
          Thread h = new Thread(() -> handle(c), "key-service-client");
          h.setDaemon(true);
          h.start();
        } catch (IOException e) {
          if (!closed) {
            audit("ERROR", "accept: " + e.getMessage());
          }
        }
      }
    }, "key-service-accept");
    t.setDaemon(true);
    t.start();
  }

  private void handle(Socket c) {
    String peer = String.valueOf(c.getPort());
    try (Socket s = c) {
      s.setSoTimeout(5000);
      BufferedReader r = new BufferedReader(new InputStreamReader(s.getInputStream(), StandardCharsets.US_ASCII), 4096);
      Writer w = new OutputStreamWriter(s.getOutputStream(), StandardCharsets.US_ASCII);
      String auth = readLine(r);
      if (auth == null || !auth.startsWith("AUTH ")
          || !MessageDigest.isEqual(auth.substring(5).getBytes(StandardCharsets.US_ASCII), token)) {
        refused.incrementAndGet();
        audit("REFUSED", "peer=" + peer + " reason=bad or missing token");
        w.write("ERR not authorized\n");
        w.flush();
        return;
      }
      w.write("OK\n");
      String line = readLine(r);
      if (line == null) {
        w.write("ERR no command\n");
      } else if (line.equals("ID")) {
        w.write("OK " + keyId + "\n");
      } else if (line.equals("PUBLIC")) {
        w.write("OK " + Base64.getEncoder().encodeToString(bundle.publicEncoded) + "\n");
      } else if (line.startsWith("SIGN ")) {
        w.write(sign(line.substring(5), peer) + "\n");
      } else {
        refused.incrementAndGet();
        audit("REFUSED", "peer=" + peer + " reason=unknown command");
        w.write("ERR unknown command\n");
      }
      w.flush();
    } catch (IOException e) {
      audit("ERROR", "peer=" + peer + " " + e.getMessage());
    }
  }

  private static String readLine(BufferedReader r) throws IOException {
    StringBuilder sb = new StringBuilder();
    int ch;
    while ((ch = r.read()) >= 0) {
      if (ch == '\n') {
        return sb.toString();
      }
      sb.append((char) ch);
      if (sb.length() > MAX_STATEMENT * 2) {
        throw new IOException("a line is too long");
      }
    }
    return sb.length() == 0 ? null : sb.toString();
  }

  private String sign(String b64, String peer) {
    byte[] st;
    try {
      st = Base64.getDecoder().decode(b64);
    } catch (IllegalArgumentException e) {
      return refuse(peer, "bad base64", null);
    }
    if (st.length > MAX_STATEMENT) {
      return refuse(peer, "statement too long", null);
    }
    byte[] tag = null;
    for (byte[] t : TAGS) {
      if (startsWith(st, t)) {
        tag = t;
      }
    }
    if (tag == null) {
      return refuse(peer, "not a statement of the wrapper (unknown tag)", st);
    }
    byte[] id = keyId.getBytes(StandardCharsets.US_ASCII);
    int at = tag.length;
    if (st.length < at + 1 + id.length || (st[at] & 0xff) != id.length) {
      return refuse(peer, "the statement names another key id", st);
    }
    for (int i = 0; i < id.length; i++) {
      if (st[at + 1 + i] != id[i]) {
        return refuse(peer, "the statement names another key id", st);
      }
    }
    try {
      Signature sig = Signature.getInstance("SHA256withECDSA");
      sig.initSign(priv);
      sig.update(st);
      byte[] out = sig.sign();
      signed.incrementAndGet();
      audit("SIGNED", "peer=" + peer + " tag=" + new String(tag, StandardCharsets.US_ASCII).trim() + " statement=" + digest(st));
      return "OK " + Base64.getEncoder().encodeToString(out);
    } catch (GeneralSecurityException e) {
      return refuse(peer, "signing failed: " + e.getMessage(), st);
    }
  }

  private String refuse(String peer, String why, byte[] st) {
    refused.incrementAndGet();
    audit("REFUSED", "peer=" + peer + " reason=" + why + (st == null ? "" : " statement=" + digest(st)));
    return "ERR " + why;
  }

  private static boolean startsWith(byte[] a, byte[] prefix) {
    if (a.length < prefix.length) {
      return false;
    }
    for (int i = 0; i < prefix.length; i++) {
      if (a[i] != prefix[i]) {
        return false;
      }
    }
    return true;
  }

  private static String digest(byte[] st) {
    try {
      return MerkleHasher.hex(MessageDigest.getInstance("SHA-256").digest(st)).substring(0, 16);
    } catch (GeneralSecurityException e) {
      return "?";
    }
  }

  private void audit(String what, String detail) {
    synchronized (auditLock) {
      try {
        Files.write(dir.resolve("audit.log"), (Instant.now() + " " + what + " " + detail + "\n").getBytes(StandardCharsets.UTF_8),
            StandardOpenOption.CREATE, StandardOpenOption.APPEND);
      } catch (IOException e) {
        // the service goes on: the log is for people, the signing does not depend on it
      }
    }
  }

  @Override
  public void close() {
    closed = true;
    try {
      server.close();
    } catch (IOException e) {
      // already closed
    }
    audit("STOP", "signed=" + signed.get() + " refused=" + refused.get());
  }

  public static void main(String[] args) throws Exception {
    Path dir = Paths.get(System.getProperty("user.home"), "tc-keyservice");
    Path listDir = null;
    int port = 0;
    String quote = null;
    String host = InetAddress.getLocalHost().getHostName().replaceAll("[^A-Za-z0-9._-]", "-");
    for (int i = 0; i < args.length; i++) {
      switch (args[i]) {
        case "--dir": dir = Paths.get(args[++i]); break;
        case "--port": port = Integer.parseInt(args[++i]); break;
        case "--list-dir": listDir = Paths.get(args[++i]); break;
        case "--quote-cmd": quote = args[++i]; break;
        case "--host": host = args[++i]; break;
        default:
          System.err.println("usage: KeyService --dir DIR [--port N] [--list-dir DIR] [--quote-cmd CMD] [--host NAME]");
          System.exit(2);
      }
    }
    KeyService svc = start(dir, port, listDir, quote, host);
    System.out.println("key-service: listening on 127.0.0.1:" + svc.port() + "   key id " + svc.keyId() + "   bundle " + svc.bundleFile());
    System.out.flush();
    new CountDownLatch(1).await();
  }
}
