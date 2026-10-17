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
import java.time.Duration;
import java.time.Instant;
import java.util.function.Supplier;

/**
 * The doorman's decision for one node (step 5.2.2): a node is admitted to the mesh only if (1) the quote's REPORTDATA binds its statement, (2) its host is in the policy table and asks for exactly the
 * address that the table gives it, (3) the statement is fresh, and (4) the quote is a genuine TDX quote whose enforced registers the reference allows for this host (the check of step 5.2.1). The
 * order puts the cheap checks first, so that the reason given is the first thing that is wrong.
 */
final class MeshAdmission {
  /** The quote check: throws with the reason, or returns the audit note. */
  interface QuoteChecker {
    String check(byte[] quote, String host) throws IOException;
  }

  /** What was admitted. */
  static final class Admitted {
    final String host;
    final String meshPublic;
    final String meshIp;
    final String vpcIp;
    final String note;

    Admitted(String host, String meshPublic, String meshIp, String vpcIp, String note) {
      this.host = host;
      this.meshPublic = meshPublic;
      this.meshIp = meshIp;
      this.vpcIp = vpcIp;
      this.note = note;
    }
  }

  /** The nodes admitted so far in one run: a host or a mesh key may be admitted once only. */
  static final class Roster {
    private final java.util.Map<String, Admitted> byHost = new java.util.LinkedHashMap<>();

    void add(Admitted a) throws IOException {
      if (byHost.containsKey(a.host)) {
        throw new IOException("the host " + a.host + " was already admitted from another bundle");
      }
      for (Admitted o : byHost.values()) {
        if (o.meshPublic.equals(a.meshPublic)) {
          throw new IOException("the mesh key is already used by the admitted host " + o.host);
        }
      }
      byHost.put(a.host, a);
    }

    java.util.Collection<Admitted> all() {
      return byHost.values();
    }

    int size() {
      return byHost.size();
    }
  }

  private final QuoteChecker quotes;
  private final MeshPolicy policy;
  private final long maxAgeSeconds;
  private final long skewSeconds;
  private final Supplier<Instant> clock;

  MeshAdmission(QuoteChecker quotes, MeshPolicy policy, long maxAgeSeconds, long skewSeconds, Supplier<Instant> clock) {
    this.quotes = quotes;
    this.policy = policy;
    this.maxAgeSeconds = maxAgeSeconds;
    this.skewSeconds = skewSeconds;
    this.clock = clock;
  }

  /** A checker that is QuoteAdmission: the genuine-quote and reference check of step 5.2.1. */
  static QuoteChecker of(QuoteAdmission qa) {
    return (quote, host) -> {
      qa.checkQuote(quote, host);
      return qa.noteOf(quote);
    };
  }

  Admitted admit(NodeBundle b) throws IOException {
    b.checkBinding();
    if (!policy.hasHost(b.host)) {
      throw new IOException("the host " + b.host + " is not in the mesh policy table");
    }
    if (!policy.meshIp(b.host).equals(b.meshIp)) {
      throw new IOException("the host " + b.host + " asks for the mesh address " + b.meshIp + " but the policy table gives it " + policy.meshIp(b.host));
    }
    Instant now = clock.get();
    if (b.created.isAfter(now.plusSeconds(skewSeconds))) {
      throw new IOException("the statement is dated in the future (" + b.created + ", now " + now + ", allowed skew " + skewSeconds + " s)");
    }
    long age = Duration.between(b.created, now).getSeconds();
    if (age > maxAgeSeconds) {
      throw new IOException("the statement is stale: it was made " + age + " s ago and the limit is " + maxAgeSeconds + " s");
    }
    String note = quotes.check(b.quote, b.host);
    return new Admitted(b.host, b.meshPublic, b.meshIp, policy.vpcIp(b.host), note);
  }
}
