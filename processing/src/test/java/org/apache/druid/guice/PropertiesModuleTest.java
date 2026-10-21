/*
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied.  See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */

package org.apache.druid.guice;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Properties;

public class PropertiesModuleTest
{
  private static final String FILE_NAME = "properties-module-test.runtime.properties";

  @TempDir
  public Path tempDir;

  @Test
  public void testOpenPropertiesFileSearchesClassPathDirectories() throws IOException
  {
    final Path confDir = writePropertiesFile("conf", "fromClassPath");

    final Properties systemProps = new Properties();
    systemProps.setProperty(
        "java.class.path",
        tempDir.resolve("missing") + File.pathSeparator + confDir + File.pathSeparator + "lib/*"
    );

    Assertions.assertEquals("fromClassPath", load(systemProps));
  }

  @Test
  public void testOpenPropertiesFileReturnsNullWhenNotFound() throws IOException
  {
    final Properties systemProps = new Properties();
    systemProps.setProperty("java.class.path", tempDir.toString());

    Assertions.assertNull(PropertiesModule.openPropertiesFile(FILE_NAME, systemProps));
  }

  @Test
  public void testOpenPropertiesFilePrefersExplicitFile() throws IOException
  {
    final Path explicitFile = tempDir.resolve("explicit.properties");
    Files.writeString(explicitFile, "druid.test=explicit\n", StandardCharsets.UTF_8);
    final Path confDir = writePropertiesFile("conf", "fromClassPath");

    final Properties systemProps = new Properties();
    systemProps.setProperty("druid.properties.file", explicitFile.toString());
    systemProps.setProperty("java.class.path", confDir.toString());

    Assertions.assertEquals("explicit", load(systemProps));
  }

  private Path writePropertiesFile(final String directory, final String value) throws IOException
  {
    final Path confDir = Files.createDirectories(tempDir.resolve(directory));
    Files.writeString(confDir.resolve(FILE_NAME), "druid.test=" + value + "\n", StandardCharsets.UTF_8);
    return confDir;
  }

  private static String load(final Properties systemProps) throws IOException
  {
    try (InputStream stream = PropertiesModule.openPropertiesFile(FILE_NAME, systemProps)) {
      Assertions.assertNotNull(stream);
      final Properties loaded = new Properties();
      loaded.load(stream);
      return loaded.getProperty("druid.test");
    }
  }
}
