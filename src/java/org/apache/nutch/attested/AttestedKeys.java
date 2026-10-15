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
import java.security.PublicKey;

/**
 * Where the signing key and the trusted public keys come from. The wrapper knows only this
 * interface, so that the test key of step 5.1.1 can be replaced by the real key of step 5.1.3
 * (generated per machine at boot, held by a small signing service, bound to the quote)
 * without changing the wrapper.
 */
interface AttestedKeys {

  /** The id of the key this JVM signs with, or null when it cannot sign. */
  String signingKeyId();

  /** Signs the statement of a record (ECDSA, P-256, SHA-256, DER). */
  byte[] sign(byte[] statement) throws IOException;

  /** The public key behind a key id, or null when that key is not trusted here. */
  PublicKey publicKey(String keyId);
}
