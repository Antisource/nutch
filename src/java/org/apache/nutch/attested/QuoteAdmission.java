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
import java.time.Instant;
import java.util.Collections;
import java.util.LinkedHashSet;
import java.util.Locale;
import java.util.Set;
import java.util.function.Supplier;

/**
 * Admission of a key by its quote (step 5.2.1), the BundleCheck that the key list runs on every bundle: the quote must be a genuine TDX quote (the chain leads
 * to a pinned Intel root and the signatures verify, QuoteVerifier), and every ENFORCED register (MRTD, RTMR0 to RTMR3; the settings choose which) must have a
 * value that the reference allows for the host of the key's statement. The binding of the quote to the key (REPORTDATA) is checked by KeyBundle before this
 * runs. Registers that are not enforced are shown in the audit note and decide nothing.
 */
final class QuoteAdmission implements BundleCheck {
  /** SHA-256 of Intel's SGX Root CA certificate, the root of the PCK chain in a TDX quote. */
  static final String INTEL_SGX_ROOT_SHA256 = "44a0196b2b99f889b8e149e95b807a350e7424964399e885a7cbb8ccfab674d3";
  static final String DEFAULT_ENFORCE = "mrtd,rtmr0,rtmr1,rtmr2";

  private final AdmissionReference reference;
  private final Set<String> enforce;
  private final Set<String> roots;
  private final boolean checkDates;
  private final Supplier<Instant> clock;

  QuoteAdmission(AdmissionReference reference, Set<String> enforce, Set<String> roots, boolean checkDates, Supplier<Instant> clock) {
    this.reference = reference;
    this.enforce = enforce;
    this.roots = roots;
    this.checkDates = checkDates;
    this.clock = clock;
  }

  /** "mrtd,rtmr0" to a set; every name must be a register. */
  static Set<String> registers(String list) throws IOException {
    Set<String> out = new LinkedHashSet<>();
    for (String s : list.split(",")) {
      String t = s.trim().toLowerCase(Locale.ROOT);
      if (t.isEmpty()) {
        continue;
      }
      boolean known = false;
      for (String k : QuoteVerifier.REGISTERS) {
        known |= k.equals(t);
      }
      if (!known) {
        throw new IOException("unknown register in the enforce list: " + s.trim() + " (use mrtd, rtmr0, rtmr1, rtmr2, rtmr3)");
      }
      out.add(t);
    }
    return out;
  }

  static Set<String> rootList(String list) throws IOException {
    Set<String> out = new LinkedHashSet<>();
    for (String s : list.split(",")) {
      String t = s.trim().toLowerCase(Locale.ROOT).replace(":", "");
      if (t.isEmpty()) {
        continue;
      }
      if (!t.matches("[0-9a-f]{64}")) {
        throw new IOException("a trusted root must be the SHA-256 of a certificate (64 hex digits), got " + s.trim());
      }
      out.add(t);
    }
    return Collections.unmodifiableSet(out);
  }

  @Override
  public void check(KeyBundle b) throws IOException {
    if (!b.hasQuote()) {
      throw new IOException("the key " + b.keyId + " has no quote, so it cannot be admitted");
    }
    checkQuote(b.quote, b.host);
  }

  /** The same check for any quote of the host named: a genuine quote, and every enforced register allowed by the reference for that host. */
  void checkQuote(byte[] quote, String host) throws IOException {
    QuoteVerifier.Quote q = QuoteVerifier.parse(quote);
    QuoteVerifier.verify(q, roots, checkDates, clock.get());
    for (String reg : enforce) {
      String v = q.register(reg);
      if (!reference.hasRegister(reg)) {
        throw new IOException("the reference has no value for " + reg.toUpperCase(Locale.ROOT) + ", which is enforced");
      }
      if (!reference.allows(reg, v, host)) {
        throw new IOException(reg.toUpperCase(Locale.ROOT) + " of " + host + " is " + v.substring(0, 12) + "..., which the reference does not allow (allowed: "
            + reference.allowedFor(reg, host) + ")");
      }
    }
  }

  @Override
  public String note(KeyBundle b) {
    return noteOf(b.quote);
  }

  /** The registers of a quote with the word enforced or shown only, for the audit. */
  String noteOf(byte[] quote) {
    try {
      QuoteVerifier.Quote q = QuoteVerifier.parse(quote);
      StringBuilder sb = new StringBuilder("admitted by quote:");
      for (String reg : QuoteVerifier.REGISTERS) {
        sb.append(' ').append(reg).append('=').append(q.register(reg), 0, 12).append(enforce.contains(reg) ? "(enforced)" : "(shown only)");
      }
      return sb.toString();
    } catch (IOException e) {
      return "";
    }
  }
}
