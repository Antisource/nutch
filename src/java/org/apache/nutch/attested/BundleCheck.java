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

/**
 * An extra rule that a key bundle must pass before its public key is trusted (step 5.1.3 hook for step 5.2.1).
 * The key list always checks the bundle's own consistency (the key id is the hash of the public key, and the
 * quote's REPORTDATA is the hash of the statement). A class named by attested.keys.list.check.class adds more,
 * for example the verification of the quote's signature chain and of the measurements; it throws an
 * IOException saying why when the bundle must be refused.
 */
interface BundleCheck {
  void check(KeyBundle bundle) throws IOException;

  /** A short note for the audit line of an admitted key (for example the measurements that were checked). */
  default String note(KeyBundle bundle) {
    return "";
  }
}
