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
package org.apache.nutch.attested.contracttest;

import java.io.IOException;
import java.net.URI;

import org.apache.hadoop.conf.Configuration;
import org.apache.hadoop.fs.FileSystem;
import org.apache.hadoop.fs.Path;
import org.apache.hadoop.fs.contract.AbstractFSContract;
import org.apache.hadoop.fs.contract.ContractOptions;
import org.apache.hadoop.hdfs.DistributedFileSystem;
import org.apache.nutch.attested.AttestedAudit;
import org.apache.nutch.attested.AttestedHdfs;
import org.apache.nutch.attested.AttestedHdfsFileSystem;
import org.apache.nutch.attested.AttestedRecords;
import org.junit.Assert;

/**
 * Hadoop's file-system contract for the real cluster's HDFS, reached either through the
 * wrapper or, as the control, through the plain HDFS client.
 *
 * <p>SAFETY: Hadoop's contract tests create their test folder before each test and
 * <b>delete it with everything in it</b> after each test. This contract therefore refuses
 * to run unless the test folder is a dedicated one: an absolute path of at least three
 * parts whose last part contains "contract-tests". Hadoop's root-directory test is not part
 * of the suite and its option is off in the options file.</p>
 *
 * <p>Three further settings exist so that the suite can be rehearsed against a fake file system
 * without a cluster: <code>attested.contract.wrapper.impl</code> (the class used as the wrapper,
 * default the real one), <code>attested.contract.plain.impl</code> (the class used for the control,
 * default: Hadoop's own HDFS client) and <code>attested.contract.plain.expect</code> (the class the
 * control file system must be an instance of, default DistributedFileSystem). The safety rule on the
 * test folder does not depend on them.</p>
 *
 * <p>Settings (system properties): <code>attested.contract.uri</code> (for example
 * hdfs://hadoop-master:9000), <code>attested.contract.dir</code> (the dedicated folder),
 * <code>attested.contract.wrapper</code> (true: through the wrapper; false: plain client),
 * <code>attested.contract.audit.dir</code> and <code>attested.contract.records.dir</code>
 * (where the wrapper's logs go during the tests).</p>
 */
public class AttestedHdfsContract extends AbstractFSContract {

  public static final String OPTIONS = "contract/attested-hdfs.xml";
  public static final String URI_PROP = "attested.contract.uri";
  public static final String DIR_PROP = "attested.contract.dir";
  public static final String WRAPPER_PROP = "attested.contract.wrapper";
  public static final String AUDIT_PROP = "attested.contract.audit.dir";
  public static final String RECORDS_PROP = "attested.contract.records.dir";
  public static final String WRAPPER_IMPL_PROP = "attested.contract.wrapper.impl";
  public static final String PLAIN_IMPL_PROP = "attested.contract.plain.impl";
  public static final String PLAIN_EXPECT_PROP = "attested.contract.plain.expect";

  private FileSystem testFs;

  public AttestedHdfsContract(Configuration conf) {
    super(conf);
    addConfResource(OPTIONS);
  }

  private static boolean useWrapper() {
    return Boolean.parseBoolean(System.getProperty(WRAPPER_PROP, "true"));
  }

  /** Throws unless the folder is dedicated to these tests. */
  static void requireDedicatedFolder(String dir) {
    if (dir == null || !dir.startsWith("/")) {
      throw new IllegalStateException("set -D" + DIR_PROP + " to an absolute folder, got: " + dir);
    }
    String[] parts = dir.substring(1).split("/");
    boolean ok = parts.length >= 3 && parts[parts.length - 1].contains("contract-tests");
    if (!ok) {
      throw new IllegalStateException("REFUSED: the contract tests delete their test folder after every test, "
          + "so it must be dedicated: at least three parts and a last part containing \"contract-tests\"; got: " + dir);
    }
  }

  @Override
  public void init() throws IOException {
    super.init();
    Assert.assertTrue("contract options not loaded from " + OPTIONS,
        isSupported(ContractOptions.IS_CASE_SENSITIVE, false));
    requireDedicatedFolder(System.getProperty(DIR_PROP));
    Assert.assertNotNull("set -D" + URI_PROP, System.getProperty(URI_PROP));
  }

  @Override
  public FileSystem getTestFileSystem() throws IOException {
    Configuration conf = new Configuration(getConf());
    URI uri = URI.create(System.getProperty(URI_PROP));
    if (useWrapper()) {
      conf.set("fs.hdfs.impl", System.getProperty(WRAPPER_IMPL_PROP, AttestedHdfsFileSystem.class.getName()));
      conf.set("fs.AbstractFileSystem.hdfs.impl", AttestedHdfs.class.getName());
      conf.set(AttestedAudit.DIR_KEY, System.getProperty(AUDIT_PROP, "/tmp/attested-contract-audit"));
      conf.set(AttestedRecords.DIR_KEY, System.getProperty(RECORDS_PROP, "/tmp/attested-contract-records"));
      testFs = FileSystem.newInstance(uri, conf);
      Assert.assertTrue("the test file system is not the wrapper: " + testFs.getClass().getName(),
          testFs instanceof AttestedHdfsFileSystem);
    } else {
      String plainImpl = System.getProperty(PLAIN_IMPL_PROP);
      if (plainImpl == null) {
        conf.unset("fs.hdfs.impl");
      } else {
        conf.set("fs.hdfs.impl", plainImpl);
      }
      testFs = FileSystem.newInstance(uri, conf);
      String expect = System.getProperty(PLAIN_EXPECT_PROP, DistributedFileSystem.class.getName());
      boolean isExpected;
      try {
        isExpected = Class.forName(expect).isInstance(testFs);
      } catch (ClassNotFoundException e) {
        throw new IOException("unknown class in -D" + PLAIN_EXPECT_PROP + ": " + expect, e);
      }
      Assert.assertTrue("the control file system is not the expected plain client (" + expect + "): "
          + testFs.getClass().getName(), isExpected);
    }
    return testFs;
  }

  @Override
  public void teardown() throws IOException {
    super.teardown();
    if (testFs != null) {
      testFs.close();
      testFs = null;
    }
  }

  @Override
  public String getScheme() {
    return "hdfs";
  }

  @Override
  public Path getTestPath() {
    return new Path(System.getProperty(DIR_PROP));
  }

  @Override
  public String toString() {
    return "AttestedHdfsContract(" + (useWrapper() ? "wrapper" : "plain") + " " + System.getProperty(URI_PROP)
        + " " + System.getProperty(DIR_PROP) + ")";
  }
}
