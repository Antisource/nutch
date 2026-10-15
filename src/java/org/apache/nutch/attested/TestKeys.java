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

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.FileAlreadyExistsException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.nio.file.attribute.PosixFilePermissions;
import java.security.GeneralSecurityException;
import java.security.KeyFactory;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.MessageDigest;
import java.security.PrivateKey;
import java.security.PublicKey;
import java.security.Signature;
import java.security.spec.ECGenParameterSpec;
import java.security.spec.PKCS8EncodedKeySpec;
import java.security.spec.X509EncodedKeySpec;
import java.util.Base64;
import java.util.List;

/**
 * The TEST key of step 5.1.1: one ECDSA P-256 key pair kept in a small text file. Its id always
 * starts with {@code TEST-} and is derived from the public key, so a record signed with it
 * says so in every signature, and the checks can refuse test keys once the real key exists.
 * It is never to be used in evidence.
 *
 * <p>File format: line 1 {@code ATTESTED-TEST-KEY 1}, line 2 {@code id=TEST-...}, line 3
 * {@code public=<base64 X.509>}, and optionally line 4 {@code private=<base64 PKCS#8>}. A file
 * without the private line can verify but not sign.</p>
 */
final class TestKeys implements AttestedKeys {

  static final String PREFIX = "TEST-";
  private static final String HEADER = "ATTESTED-TEST-KEY 1";

  private final String id;
  private final PublicKey pub;
  private final PrivateKey priv;

  private TestKeys(String id, PublicKey pub, PrivateKey priv) {
    this.id = id;
    this.pub = pub;
    this.priv = priv;
  }

  static boolean isTestKeyId(String id) {
    return id != null && id.startsWith(PREFIX);
  }

  private static String idOf(byte[] publicEncoded) throws GeneralSecurityException {
    byte[] h = MessageDigest.getInstance("SHA-256").digest(publicEncoded);
    return PREFIX + MerkleHasher.hex(h).substring(0, 16);
  }

  /** Makes a new key pair and writes it, readable by its owner only; never overwrites a file. */
  static TestKeys generate(Path file) throws IOException {
    try {
      KeyPairGenerator g = KeyPairGenerator.getInstance("EC");
      g.initialize(new ECGenParameterSpec("secp256r1"));
      KeyPair kp = g.generateKeyPair();
      String id = idOf(kp.getPublic().getEncoded());
      String text = HEADER + "\nid=" + id + "\npublic="
          + Base64.getEncoder().encodeToString(kp.getPublic().getEncoded()) + "\nprivate="
          + Base64.getEncoder().encodeToString(kp.getPrivate().getEncoded()) + "\n";
      Path parent = file.toAbsolutePath().getParent();
      if (parent != null) {
        Files.createDirectories(parent);
      }
      try {
        Files.createFile(file,
            PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------")));
      } catch (UnsupportedOperationException e) {
        Files.createFile(file);
      }
      Files.write(file, text.getBytes(StandardCharsets.US_ASCII), StandardOpenOption.WRITE);
      return new TestKeys(id, kp.getPublic(), kp.getPrivate());
    } catch (FileAlreadyExistsException e) {
      throw new IOException("the test key file exists already: " + file);
    } catch (GeneralSecurityException e) {
      throw new IOException("cannot make a test key: " + e);
    }
  }

  /** Reads a test key file (with or without the private part). */
  static TestKeys load(Path file) throws IOException {
    List<String> lines = Files.readAllLines(file, StandardCharsets.US_ASCII);
    if (lines.size() < 3 || !HEADER.equals(lines.get(0))) {
      throw new IOException("not a test key file: " + file);
    }
    String id = value(lines.get(1), "id=");
    String pubText = value(lines.get(2), "public=");
    String privText = lines.size() > 3 ? value(lines.get(3), "private=") : null;
    try {
      byte[] pubBytes = Base64.getDecoder().decode(pubText);
      KeyFactory kf = KeyFactory.getInstance("EC");
      PublicKey pub = kf.generatePublic(new X509EncodedKeySpec(pubBytes));
      if (!id.equals(idOf(pubBytes)) || !isTestKeyId(id)) {
        throw new IOException("the key id in " + file + " does not match its public key");
      }
      PrivateKey priv = privText == null ? null
          : kf.generatePrivate(new PKCS8EncodedKeySpec(Base64.getDecoder().decode(privText)));
      return new TestKeys(id, pub, priv);
    } catch (GeneralSecurityException | IllegalArgumentException e) {
      throw new IOException("cannot read the test key file " + file + ": " + e);
    }
  }

  private static String value(String line, String prefix) throws IOException {
    if (!line.startsWith(prefix) || line.length() == prefix.length()) {
      throw new IOException("the test key file is damaged (expected " + prefix + ")");
    }
    return line.substring(prefix.length());
  }

  /** A copy that can only verify (what a machine without the private key would hold). */
  TestKeys publicOnly() {
    return new TestKeys(id, pub, null);
  }

  /** The text of a public-only key file. */
  String publicFileText() {
    return HEADER + "\nid=" + id + "\npublic="
        + Base64.getEncoder().encodeToString(pub.getEncoded()) + "\n";
  }

  /** The key id, also for a public-only file (which cannot sign). */
  String keyId() {
    return id;
  }

  @Override
  public String signingKeyId() {
    return priv == null ? null : id;
  }

  @Override
  public byte[] sign(byte[] statement) throws IOException {
    if (priv == null) {
      throw new IOException("this test key file has no private key, so it cannot sign");
    }
    try {
      Signature s = Signature.getInstance("SHA256withECDSA");
      s.initSign(priv);
      s.update(statement);
      return s.sign();
    } catch (GeneralSecurityException e) {
      throw new IOException("signing failed: " + e);
    }
  }

  @Override
  public PublicKey publicKey(String keyId) {
    return id.equals(keyId) ? pub : null;
  }
}
