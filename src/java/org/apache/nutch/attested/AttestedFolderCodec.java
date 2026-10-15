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
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.EOFException;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;

/**
 * The folder identity file of step 5.1.2 ("_attested-folder" inside every folder the wrapper made or adopted), with no Hadoop in it.
 *
 * <p>Bytes: "ATTESTFD", the 16-byte folder ID, an unsigned short for the length of the folder's own name and the name in UTF-8, a kind
 * byte, then for kind 0 (a child) the 16-byte ID of the parent folder, and for kind 1 (a top folder) an unsigned short for the length of
 * the folder's full path and the path in UTF-8, then the signature block (key id length, key id, signature length, signature).
 * The signature covers {@link #statement}: the same fields behind a fixed tag. A folder is therefore tied to its own name and to its
 * parent (or, at the top, to its full path), and renaming a folder means signing its identity file again, nothing else.</p>
 */
final class AttestedFolderCodec {

  static final byte[] MAGIC = "ATTESTFD".getBytes(StandardCharsets.US_ASCII);
  static final String FILE_NAME = "_attested-folder";
  static final int KIND_CHILD = 0;
  static final int KIND_TOP = 1;
  private static final byte[] STATEMENT_TAG = "ATTESTFD-SIGNED\n".getBytes(StandardCharsets.US_ASCII);
  private static final int MAX_PATH = 4096;

  private AttestedFolderCodec() {
  }

  static boolean isIdentityName(String name) {
    return FILE_NAME.equals(name);
  }

  /** A decoded identity file. */
  static final class Decoded {
    final byte[] folderId;
    final String name;
    /** The parent's ID for a child, null for a top folder. */
    final byte[] parentId;
    /** The full path for a top folder, null for a child. */
    final String topPath;
    final String keyId;
    final byte[] signature;

    Decoded(byte[] folderId, String name, byte[] parentId, String topPath, String keyId, byte[] signature) {
      this.folderId = folderId;
      this.name = name;
      this.parentId = parentId;
      this.topPath = topPath;
      this.keyId = keyId;
      this.signature = signature;
    }

    boolean top() {
      return topPath != null;
    }
  }

  private static void fields(DataOutputStream out, byte[] folderId, String name, byte[] parentId, String topPath)
      throws IOException {
    byte[] n = name.getBytes(StandardCharsets.UTF_8);
    out.write(folderId);
    out.writeShort(n.length);
    out.write(n);
    if (topPath == null) {
      out.writeByte(KIND_CHILD);
      out.write(parentId);
    } else {
      byte[] p = topPath.getBytes(StandardCharsets.UTF_8);
      out.writeByte(KIND_TOP);
      out.writeShort(p.length);
      out.write(p);
    }
  }

  private static void check(byte[] folderId, String name, byte[] parentId, String topPath) throws IOException {
    boolean ok = folderId != null && folderId.length == AttestedRecordCodec.FOLDER_ID && AttestedRecordCodec.validName(name)
        && ((topPath == null && parentId != null && parentId.length == AttestedRecordCodec.FOLDER_ID)
            || (topPath != null && parentId == null && !topPath.isEmpty() && topPath.getBytes(StandardCharsets.UTF_8).length <= MAX_PATH));
    if (!ok) {
      throw new IOException("cannot build a folder identity (bad folder ID, name, parent or path)");
    }
  }

  /** The bytes that are signed. */
  static byte[] statement(String keyId, byte[] folderId, String name, byte[] parentId, String topPath)
      throws IOException {
    check(folderId, name, parentId, topPath);
    if (!AttestedRecordCodec.validKeyId(keyId)) {
      throw new IOException("cannot build the statement to sign (bad key id)");
    }
    byte[] id = keyId.getBytes(StandardCharsets.US_ASCII);
    ByteArrayOutputStream bytes = new ByteArrayOutputStream();
    DataOutputStream out = new DataOutputStream(bytes);
    out.write(STATEMENT_TAG);
    out.writeByte(id.length);
    out.write(id);
    fields(out, folderId, name, parentId, topPath);
    out.flush();
    return bytes.toByteArray();
  }

  static byte[] encode(byte[] folderId, String name, byte[] parentId, String topPath, String keyId, byte[] signature)
      throws IOException {
    check(folderId, name, parentId, topPath);
    if (!AttestedRecordCodec.validKeyId(keyId) || signature == null || signature.length < 1
        || signature.length > AttestedRecordCodec.MAX_SIGNATURE) {
      throw new IOException("cannot write a folder identity (bad key id or signature)");
    }
    byte[] id = keyId.getBytes(StandardCharsets.US_ASCII);
    ByteArrayOutputStream bytes = new ByteArrayOutputStream();
    DataOutputStream out = new DataOutputStream(bytes);
    out.write(MAGIC);
    fields(out, folderId, name, parentId, topPath);
    out.writeByte(id.length);
    out.write(id);
    out.writeShort(signature.length);
    out.write(signature);
    out.flush();
    return bytes.toByteArray();
  }

  static Decoded decode(byte[] all) throws IOException {
    if (all.length > 16384) {
      throw new IOException("folder identity is damaged (too long)");
    }
    DataInputStream in = new DataInputStream(new ByteArrayInputStream(all));
    try {
      byte[] magic = new byte[MAGIC.length];
      in.readFully(magic);
      if (!Arrays.equals(magic, MAGIC)) {
        throw new IOException("folder identity is damaged (wrong header)");
      }
      byte[] folderId = new byte[AttestedRecordCodec.FOLDER_ID];
      in.readFully(folderId);
      int nameLen = in.readUnsignedShort();
      if (nameLen < 1 || nameLen > AttestedRecordCodec.MAX_NAME) {
        throw new IOException("folder identity is damaged (impossible name length)");
      }
      String name = utf8(in, nameLen, "name");
      if (!AttestedRecordCodec.validName(name)) {
        throw new IOException("folder identity is damaged (impossible name)");
      }
      int kind = in.readUnsignedByte();
      byte[] parentId = null;
      String topPath = null;
      if (kind == KIND_CHILD) {
        parentId = new byte[AttestedRecordCodec.FOLDER_ID];
        in.readFully(parentId);
      } else if (kind == KIND_TOP) {
        int pathLen = in.readUnsignedShort();
        if (pathLen < 1 || pathLen > MAX_PATH) {
          throw new IOException("folder identity is damaged (impossible path length)");
        }
        topPath = utf8(in, pathLen, "path");
      } else {
        throw new IOException("folder identity is damaged (impossible kind)");
      }
      int idLen = in.readUnsignedByte();
      if (idLen < 1 || idLen > AttestedRecordCodec.MAX_KEY_ID) {
        throw new IOException("folder identity is damaged (impossible key id length)");
      }
      byte[] idBytes = new byte[idLen];
      in.readFully(idBytes);
      String keyId = new String(idBytes, StandardCharsets.US_ASCII);
      if (!AttestedRecordCodec.validKeyId(keyId)) {
        throw new IOException("folder identity is damaged (impossible key id)");
      }
      int sigLen = in.readUnsignedShort();
      if (sigLen < 1 || sigLen > AttestedRecordCodec.MAX_SIGNATURE) {
        throw new IOException("folder identity is damaged (impossible signature length)");
      }
      byte[] sig = new byte[sigLen];
      in.readFully(sig);
      if (in.read() != -1) {
        throw new IOException("folder identity is damaged (extra bytes at the end)");
      }
      return new Decoded(folderId, name, parentId, topPath, keyId, sig);
    } catch (EOFException e) {
      throw new IOException("folder identity is damaged (too short)");
    }
  }

  private static String utf8(DataInputStream in, int len, String what) throws IOException {
    byte[] b = new byte[len];
    in.readFully(b);
    try {
      return StandardCharsets.UTF_8.newDecoder().decode(ByteBuffer.wrap(b)).toString();
    } catch (CharacterCodingException e) {
      throw new IOException("folder identity is damaged (the " + what + " is not UTF-8)");
    }
  }
}
