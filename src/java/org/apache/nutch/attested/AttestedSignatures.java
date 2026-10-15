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
import java.security.GeneralSecurityException;
import java.security.PublicKey;
import java.security.Signature;
import java.util.List;

/**
 * Signs records when they are written and checks signatures when they are read.
 *
 * <p>The rules: a record with a signature that does not verify is always refused. A record
 * signed by a key that is not trusted here is always refused. A record signed with a test key
 * is refused when test keys are not allowed. A record with no signature (the old format) is
 * refused only when signatures are required; otherwise it is accepted and reported as
 * {@code none}. Whether a signature is required is a setting, off by default in step 5.1.1 so
 * that the files of earlier runs stay readable; with signatures required, a file cannot be
 * rewritten together with its record by someone who has no key.</p>
 */
final class AttestedSignatures {

  private final AttestedKeys keys;
  private final boolean sign;
  private final boolean required;
  private final boolean allowTestKeys;

  AttestedSignatures(AttestedKeys keys, boolean sign, boolean required, boolean allowTestKeys)
      throws IOException {
    this.keys = keys;
    this.sign = sign;
    this.required = required;
    this.allowTestKeys = allowTestKeys;
    if (sign && (keys == null || keys.signingKeyId() == null)) {
      throw new IOException("signing is switched on but this JVM has no private key");
    }
    if (sign && !allowTestKeys && TestKeys.isTestKeyId(keys.signingKeyId())) {
      throw new IOException("signing is switched on with a test key, which is not allowed");
    }
  }

  boolean signing() {
    return sign;
  }

  boolean required() {
    return required;
  }

  boolean allowTestKeys() {
    return allowTestKeys;
  }

  String signingKeyId() {
    return sign ? keys.signingKeyId() : null;
  }

  /** The bytes of a finished record: signed when signing is on, the old format otherwise. */
  byte[] encode(int chunkSize, long length, byte[] root, List<byte[]> leaves)
      throws IOException {
    if (!sign) {
      return AttestedRecordCodec.encode(chunkSize, length, root, leaves);
    }
    String id = keys.signingKeyId();
    byte[] sig = keys.sign(AttestedRecordCodec.statement(id, chunkSize, length, root));
    return AttestedRecordCodec.encodeSigned(chunkSize, length, root, leaves, id, sig);
  }

  /**
   * Checks the signature of a decoded record. Returns "none" (an unsigned record that is
   * accepted), "ok" or "ok-test" (a test key). Throws an IOException saying why when the record
   * must be refused. For a record bound to a folder (ATTEST03) this checks the signature only; that the
   * folder ID and the name are the right ones is the caller's job (see AttestedFolders).
   */
  String check(AttestedRecordCodec.Decoded rec) throws IOException {
    if (!rec.signed()) {
      if (required) {
        throw new IOException("the record is not signed and signatures are required");
      }
      return "none";
    }
    byte[] statement = rec.bound()
        ? AttestedRecordCodec.statementBound(rec.keyId, rec.folderId, rec.fileName, rec.chunkSize, rec.length, rec.root)
        : AttestedRecordCodec.statement(rec.keyId, rec.chunkSize, rec.length, rec.root);
    return verify("record", rec.keyId, statement, rec.signature);
  }

  /** The signature of a folder identity file: always signed, so there is no legacy form. */
  String checkFolder(AttestedFolderCodec.Decoded d) throws IOException {
    return verify("folder identity", d.keyId,
        AttestedFolderCodec.statement(d.keyId, d.folderId, d.name, d.parentId, d.topPath), d.signature);
  }

  private String verify(String what, String keyId, byte[] statement, byte[] signature) throws IOException {
    boolean test = TestKeys.isTestKeyId(keyId);
    if (test && !allowTestKeys) {
      throw new IOException("the " + what + " is signed with a test key (" + keyId + "), which is not accepted");
    }
    PublicKey pub = keys == null ? null : keys.publicKey(keyId);
    if (pub == null) {
      throw new IOException("the " + what + " is signed by a key that is not trusted here (" + keyId + ")");
    }
    try {
      Signature s = Signature.getInstance("SHA256withECDSA");
      s.initVerify(pub);
      s.update(statement);
      if (!s.verify(signature)) {
        throw new IOException("the signature of the " + what + " does not verify (" + keyId + ")");
      }
    } catch (GeneralSecurityException e) {
      throw new IOException("the signature of the " + what + " does not verify (" + keyId + "): " + e.getMessage());
    }
    return test ? "ok-test" : "ok";
  }

  /** The bytes of a finished record bound to a folder and a name (ATTEST03); signing must be on. */
  byte[] encodeBound(int chunkSize, long length, byte[] root, List<byte[]> leaves, byte[] folderId,
      String fileName) throws IOException {
    if (!sign) {
      throw new IOException("a record bound to a folder needs signing to be on");
    }
    String id = keys.signingKeyId();
    byte[] sig = keys.sign(AttestedRecordCodec.statementBound(id, folderId, fileName, chunkSize, length, root));
    return AttestedRecordCodec.encodeBound(chunkSize, length, root, leaves, folderId, fileName, id, sig);
  }

  /** The bytes of a signed folder identity file; signing must be on. */
  byte[] encodeFolder(byte[] folderId, String name, byte[] parentId, String topPath) throws IOException {
    if (!sign) {
      throw new IOException("a folder identity needs signing to be on");
    }
    String id = keys.signingKeyId();
    byte[] sig = keys.sign(AttestedFolderCodec.statement(id, folderId, name, parentId, topPath));
    return AttestedFolderCodec.encode(folderId, name, parentId, topPath, id, sig);
  }
}
