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
import java.net.URI;
import java.net.URISyntaxException;

import org.apache.hadoop.conf.Configuration;
import org.apache.hadoop.fs.DelegateToFileSystem;

/**
 * The second lookup. Hadoop has two APIs for storage: <code>FileSystem</code>
 * (found through <code>fs.hdfs.impl</code>) and <code>FileContext</code>
 * (found through <code>fs.AbstractFileSystem.hdfs.impl</code>, whose default
 * is Hadoop's own <code>org.apache.hadoop.fs.Hdfs</code>). To cover both, this
 * small adapter hands the wrapper to <code>FileContext</code>.
 *
 * <p>The pattern is the one Hadoop uses for S3A and the local file system: a
 * class that extends {@link DelegateToFileSystem}, has a
 * <code>(URI, Configuration)</code> constructor and passes the file system
 * object it wraps to the parent. {@link DelegateToFileSystem} initialises that
 * object itself.</p>
 */
public class AttestedHdfs extends DelegateToFileSystem {

  /** Used by Hadoop, through the setting fs.AbstractFileSystem.hdfs.impl. */
  public AttestedHdfs(URI theUri, Configuration conf)
      throws IOException, URISyntaxException {
    this(theUri, new AttestedHdfsFileSystem(), conf);
  }

  /** For tests, which hand in a wrapper over a fake storage. */
  protected AttestedHdfs(URI theUri, AttestedHdfsFileSystem impl,
      Configuration conf) throws IOException, URISyntaxException {
    super(theUri, impl, conf, AttestedHdfsFileSystem.SCHEME, true);
  }

  @Override
  public int getUriDefaultPort() {
    return AttestedHdfsFileSystem.DEFAULT_PORT;
  }
}
