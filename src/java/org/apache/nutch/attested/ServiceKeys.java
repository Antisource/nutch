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
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.io.Writer;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.security.PublicKey;
import java.util.Base64;

/**
 * The real key of step 5.1.3, as the wrapper sees it: signing is done by the small signing service on this machine
 * (the private key never enters this JVM), and the public keys that are trusted come from the key list. Reading needs
 * only the list; the service is needed only for writing.
 */
final class ServiceKeys implements AttestedKeys {
  private final String host;
  private final int port;
  private final String token;
  private final KeyList list;
  private final int timeoutMillis;
  private volatile String id;
  private volatile String lastError = "";

  /** A null host means that this JVM cannot sign (it only verifies). */
  ServiceKeys(String host, int port, String token, KeyList list, int timeoutMillis) {
    this.host = host;
    this.port = port;
    this.token = token;
    this.list = list;
    this.timeoutMillis = timeoutMillis;
  }

  /** Why the last request to the service failed, for messages. */
  String lastError() {
    return lastError;
  }

  KeyList list() {
    return list;
  }

  @Override
  public String signingKeyId() {
    if (host == null) {
      return null;
    }
    String x = id;
    if (x == null) {
      try {
        x = request("ID");
        id = x;
      } catch (IOException e) {
        lastError = e.getMessage();
        return null;
      }
    }
    return x;
  }

  @Override
  public byte[] sign(byte[] statement) throws IOException {
    if (host == null) {
      throw new IOException("this JVM has no signing service to ask");
    }
    String reply = request("SIGN " + Base64.getEncoder().encodeToString(statement));
    try {
      return Base64.getDecoder().decode(reply);
    } catch (IllegalArgumentException e) {
      throw new IOException("the signing service sent a bad signature: " + e.getMessage());
    }
  }

  @Override
  public PublicKey publicKey(String keyId) {
    return list == null ? null : list.publicKey(keyId);
  }

  private String request(String command) throws IOException {
    try (Socket s = new Socket()) {
      s.connect(new InetSocketAddress(host, port), timeoutMillis);
      s.setSoTimeout(timeoutMillis);
      Writer w = new OutputStreamWriter(s.getOutputStream(), StandardCharsets.US_ASCII);
      w.write("AUTH " + token + "\n" + command + "\n");
      w.flush();
      BufferedReader r = new BufferedReader(new InputStreamReader(s.getInputStream(), StandardCharsets.US_ASCII));
      String auth = r.readLine();
      if (auth == null || !auth.startsWith("OK")) {
        throw new IOException("the signing service at " + host + ":" + port + " refused: " + clip(auth));
      }
      String reply = r.readLine();
      if (reply == null || !reply.startsWith("OK ")) {
        throw new IOException("the signing service at " + host + ":" + port + " refused: " + clip(reply));
      }
      return reply.substring(3);
    } catch (IOException e) {
      lastError = e.getMessage();
      if (e.getMessage() != null && e.getMessage().startsWith("the signing service")) {
        throw e;
      }
      throw new IOException("cannot reach the signing service at " + host + ":" + port + ": " + e.getMessage());
    }
  }

  private static String clip(String s) {
    return s == null ? "no answer" : s.length() > 120 ? s.substring(0, 120) : s;
  }
}
