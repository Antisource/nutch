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

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.math.BigInteger;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.security.AlgorithmParameters;
import java.security.GeneralSecurityException;
import java.security.KeyFactory;
import java.security.MessageDigest;
import java.security.PublicKey;
import java.security.Signature;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.security.spec.ECGenParameterSpec;
import java.security.spec.ECParameterSpec;
import java.security.spec.ECPoint;
import java.security.spec.ECPublicKeySpec;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collection;
import java.util.Date;
import java.util.List;
import java.util.Set;

/**
 * Reads and verifies a TDX quote (version 4, ECDSA P-256) without any network access (step 5.2.1). The checks are the offline part of Intel's quote
 * verification: the certificate chain in the quote leads to a pinned Intel root; the leaf (PCK) certificate's key signed the quoting enclave's report;
 * that report names the attestation key; and the attestation key signed the quote's header and TD report body. What needs Intel's online collateral
 * (revocation lists, the TCB status, the quoting enclave's identity) is NOT checked here; go-tdx-guest's check with -get_collateral covers it.
 *
 * <p>Layout (little endian): header 48 bytes; TD report body 584 bytes (offsets as in docs/quote-verification.md); then a 4-byte length of the signature data:
 * the quote signature (64, r then s), the attestation key (64, x then y), the quoting enclave's certification data (type 6: size, then the QE report 384,
 * its signature 64, the QE authentication data (2-byte size and bytes), and the certification data proper: type 5, the PEM certificate chain).</p>
 */
final class QuoteVerifier {
  static final int HEADER = 48;
  static final int BODY_END = 632;
  static final String[] REGISTERS = {"mrtd", "rtmr0", "rtmr1", "rtmr2", "rtmr3"};
  private static final int[] REGISTER_OFFSET = {184, 376, 424, 472, 520};

  private QuoteVerifier() {
  }

  /** A quote taken apart. */
  static final class Quote {
    final byte[] raw;
    final int version;
    final int attKeyType;
    final long teeType;
    final byte[] signedData;
    final byte[] isvSignature;
    final byte[] attKey;
    final byte[] qeReport;
    final byte[] qeSignature;
    final byte[] qeAuth;
    final byte[] pemChain;

    private Quote(byte[] raw, int version, int attKeyType, long teeType, byte[] signedData, byte[] isvSignature, byte[] attKey, byte[] qeReport,
        byte[] qeSignature, byte[] qeAuth, byte[] pemChain) {
      this.raw = raw;
      this.version = version;
      this.attKeyType = attKeyType;
      this.teeType = teeType;
      this.signedData = signedData;
      this.isvSignature = isvSignature;
      this.attKey = attKey;
      this.qeReport = qeReport;
      this.qeSignature = qeSignature;
      this.qeAuth = qeAuth;
      this.pemChain = pemChain;
    }

    /** A measurement register (mrtd, rtmr0 to rtmr3) as 96 lower-case hex digits. */
    String register(String name) throws IOException {
      for (int i = 0; i < REGISTERS.length; i++) {
        if (REGISTERS[i].equals(name)) {
          return MerkleHasher.hex(Arrays.copyOfRange(raw, REGISTER_OFFSET[i], REGISTER_OFFSET[i] + 48));
        }
      }
      throw new IOException("unknown register " + name);
    }
  }

  static Quote parse(byte[] q) throws IOException {
    if (q == null || q.length < BODY_END + 4) {
      throw new IOException("the quote is too short (" + (q == null ? 0 : q.length) + " bytes)");
    }
    ByteBuffer b = ByteBuffer.wrap(q).order(ByteOrder.LITTLE_ENDIAN);
    int version = b.getShort(0) & 0xffff;
    int attKeyType = b.getShort(2) & 0xffff;
    long teeType = b.getInt(4) & 0xffffffffL;
    if (version != 4) {
      throw new IOException("quote version " + version + " is not supported (only 4)");
    }
    if (attKeyType != 2) {
      throw new IOException("attestation key type " + attKeyType + " is not supported (only 2, ECDSA P-256)");
    }
    if (teeType != 0x81) {
      throw new IOException("the quote is not a TDX quote (tee type 0x" + Long.toHexString(teeType) + ")");
    }
    long sigLen = b.getInt(BODY_END) & 0xffffffffL;
    int o = BODY_END + 4;
    long end = o + sigLen;
    if (sigLen < 64 + 64 + 6 || end > q.length) {
      throw new IOException("the signature data length " + sigLen + " does not fit the quote");
    }
    for (int i = (int) end; i < q.length; i++) {
      if (q[i] != 0) {
        throw new IOException("the quote has non-zero bytes after its signature data (offset " + i + ")");
      }
    }
    byte[] isv = Arrays.copyOfRange(q, o, o + 64);
    byte[] attKey = Arrays.copyOfRange(q, o + 64, o + 128);
    o += 128;
    int outerType = b.getShort(o) & 0xffff;
    long outerSize = b.getInt(o + 2) & 0xffffffffL;
    o += 6;
    if (outerType != 6 || o + outerSize != end) {
      throw new IOException("the quoting enclave's certification data is not of type 6 or does not fill the signature data (type " + outerType + ")");
    }
    if (outerSize < 384 + 64 + 2 + 6) {
      throw new IOException("the quoting enclave's certification data is too short");
    }
    byte[] qeReport = Arrays.copyOfRange(q, o, o + 384);
    byte[] qeSig = Arrays.copyOfRange(q, o + 384, o + 448);
    o += 448;
    int authLen = b.getShort(o) & 0xffff;
    o += 2;
    if (o + authLen + 6 > end) {
      throw new IOException("the quoting enclave's authentication data does not fit");
    }
    byte[] auth = Arrays.copyOfRange(q, o, o + authLen);
    o += authLen;
    int innerType = b.getShort(o) & 0xffff;
    long innerSize = b.getInt(o + 2) & 0xffffffffL;
    o += 6;
    if (innerType != 5) {
      throw new IOException("the certification data is of type " + innerType + ", not 5 (a PCK certificate chain)");
    }
    if (o + innerSize != end) {
      throw new IOException("the certificate chain does not fill the rest of the signature data");
    }
    byte[] pem = Arrays.copyOfRange(q, o, (int) end);
    int n = pem.length;
    while (n > 0 && pem[n - 1] == 0) {
      n--;
    }
    return new Quote(q, version, attKeyType, teeType, Arrays.copyOfRange(q, 0, BODY_END), isv, attKey, qeReport, qeSig, auth, Arrays.copyOf(pem, n));
  }

  /**
   * Verifies the quote's signatures and certificate chain. pinnedRoots are SHA-256 fingerprints (lower-case hex, no colons) of the root certificates that
   * are trusted; the chain must end in one of them. With checkDates the validity of every certificate at 'now' is checked.
   */
  static void verify(Quote q, Set<String> pinnedRoots, boolean checkDates, Instant now) throws IOException {
    if (pinnedRoots == null || pinnedRoots.isEmpty()) {
      throw new IOException("no trusted root certificate is configured, so no quote can be verified");
    }
    List<X509Certificate> chain = new ArrayList<>();
    try {
      CertificateFactory cf = CertificateFactory.getInstance("X.509");
      Collection<?> certs = cf.generateCertificates(new ByteArrayInputStream(q.pemChain));
      for (Object c : certs) {
        chain.add((X509Certificate) c);
      }
    } catch (GeneralSecurityException | ClassCastException e) {
      throw new IOException("the certificate chain in the quote cannot be read: " + e.getMessage());
    }
    if (chain.size() < 2) {
      throw new IOException("the certificate chain in the quote has " + chain.size() + " certificate(s): it does not reach a root");
    }
    try {
      for (int i = 0; i < chain.size() - 1; i++) {
        chain.get(i).verify(chain.get(i + 1).getPublicKey());
      }
      X509Certificate root = chain.get(chain.size() - 1);
      root.verify(root.getPublicKey());
      String fp = MerkleHasher.hex(MessageDigest.getInstance("SHA-256").digest(root.getEncoded()));
      if (!pinnedRoots.contains(fp)) {
        throw new IOException("the root certificate of the chain (" + fp.substring(0, 16) + "...) is not one of the trusted roots");
      }
      if (checkDates) {
        for (X509Certificate c : chain) {
          c.checkValidity(Date.from(now));
        }
      }
    } catch (GeneralSecurityException e) {
      throw new IOException("the certificate chain in the quote is not valid: " + e.getMessage());
    }
    PublicKey pck = chain.get(0).getPublicKey();
    if (!verifyEcdsa(pck, q.qeReport, q.qeSignature)) {
      throw new IOException("the signature of the quoting enclave's report does not verify with the PCK certificate");
    }
    byte[] reportData = Arrays.copyOfRange(q.qeReport, 320, 384);
    byte[] expect;
    try {
      MessageDigest md = MessageDigest.getInstance("SHA-256");
      md.update(q.attKey);
      md.update(q.qeAuth);
      expect = md.digest();
    } catch (GeneralSecurityException e) {
      throw new IOException("no SHA-256: " + e);
    }
    byte[] zeros = new byte[32];
    if (!MessageDigest.isEqual(Arrays.copyOfRange(reportData, 0, 32), expect) || !MessageDigest.isEqual(Arrays.copyOfRange(reportData, 32, 64), zeros)) {
      throw new IOException("the quoting enclave's report does not name the attestation key of the quote");
    }
    if (!verifyEcdsa(attestationKey(q.attKey), q.signedData, q.isvSignature)) {
      throw new IOException("the signature of the quote does not verify with its attestation key");
    }
  }

  private static PublicKey attestationKey(byte[] xy) throws IOException {
    try {
      AlgorithmParameters ap = AlgorithmParameters.getInstance("EC");
      ap.init(new ECGenParameterSpec("secp256r1"));
      ECParameterSpec spec = ap.getParameterSpec(ECParameterSpec.class);
      ECPoint p = new ECPoint(new BigInteger(1, Arrays.copyOfRange(xy, 0, 32)), new BigInteger(1, Arrays.copyOfRange(xy, 32, 64)));
      return KeyFactory.getInstance("EC").generatePublic(new ECPublicKeySpec(p, spec));
    } catch (GeneralSecurityException e) {
      throw new IOException("the attestation key in the quote is not a valid P-256 key: " + e.getMessage());
    }
  }

  private static boolean verifyEcdsa(PublicKey key, byte[] data, byte[] rawSig) throws IOException {
    try {
      Signature s = Signature.getInstance("SHA256withECDSA");
      s.initVerify(key);
      s.update(data);
      return s.verify(derOf(rawSig));
    } catch (GeneralSecurityException e) {
      return false;
    }
  }

  /** r and s (32 bytes each) as a DER SEQUENCE of two INTEGERs. */
  static byte[] derOf(byte[] raw) throws IOException {
    if (raw.length != 64) {
      throw new IOException("a raw ECDSA signature has 64 bytes");
    }
    byte[] r = derInt(Arrays.copyOfRange(raw, 0, 32));
    byte[] s = derInt(Arrays.copyOfRange(raw, 32, 64));
    byte[] out = new byte[2 + r.length + s.length];
    out[0] = 0x30;
    out[1] = (byte) (r.length + s.length);
    System.arraycopy(r, 0, out, 2, r.length);
    System.arraycopy(s, 0, out, 2 + r.length, s.length);
    return out;
  }

  private static byte[] derInt(byte[] v) {
    int i = 0;
    while (i < v.length - 1 && v[i] == 0) {
      i++;
    }
    int len = v.length - i + ((v[i] & 0x80) != 0 ? 1 : 0);
    byte[] out = new byte[2 + len];
    out[0] = 0x02;
    out[1] = (byte) len;
    System.arraycopy(v, i, out, 2 + len - (v.length - i), v.length - i);
    return out;
  }
}
