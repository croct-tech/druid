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

import org.objectweb.asm.AnnotationVisitor;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.FieldVisitor;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.PrintWriter;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Enumeration;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;
import java.util.jar.JarEntry;
import java.util.jar.JarFile;
import java.util.jar.JarInputStream;
import java.util.jar.JarOutputStream;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Collectors;
import java.util.stream.Stream;

/**
 * Helper for the GraalVM native image build of Druid (distribution/docker/Dockerfile.native). Run as a single-file
 * program with {@code java -cp <asm.jar> NativeImageBuildTool.java <command> ...}; besides the JDK it only needs ASM,
 * which the Druid distribution ships.
 *
 * <pre>
 * collect &lt;druid-home&gt; &lt;output-dir&gt; &lt;extension&gt;...
 *     Assembles the flat class path of the native image in &lt;output-dir&gt;/lib: the core libraries plus the jars of
 *     the given extensions. Jars that only exist to embed GraalVM's own JavaScript engine are left out, because they
 *     clash with the native image builder, and so is the JAXB runtime, which only Jersey's unused XML providers
 *     reach and which slows the analysis down badly. All other core libraries are kept. When an extension jar
 *     contains classes that
 *     are already present, one of the two is dropped: against a core library the newer version wins, against another
 *     extension the extension listed first wins. Embedded native-image.properties files that ask for classes to be
 *     initialized at build time (Netty's do) are removed while copying: initialized on the build JVM, those classes
 *     capture state the native runtime cannot use (Log4j loggers, a direct-buffer cleaner backed by shared arenas).
 *     The extension names are written to &lt;output-dir&gt;/extensions.txt.
 *
 * generate-config &lt;lib-dir&gt; &lt;output-dir&gt; [--reflect-package &lt;prefix&gt;]... [--reflect-jar &lt;prefix&gt;]...
 *                 [--reflect-package-constructors &lt;prefix&gt;]... [--reflect-methods &lt;prefix&gt;]...
 *                 [--reflect-fields &lt;prefix&gt;]... [--reflect-exclude &lt;regex&gt;]... [--resource-pattern &lt;regex&gt;]...
 *     Writes reflect-config.json and resource-config.json for the jars in &lt;lib-dir&gt;. Declared constructors are
 *     registered for every service provider named in a META-INF/services file, for every class in a package with one
 *     of the --reflect-package prefixes, and for every class in a jar whose file name starts with one of the
 *     --reflect-jar prefixes. Classes in a --reflect-package-constructors package only get their constructors:
 *     enough for libraries that instantiate classes by name. In every other class, members that Guice reaches
 *     reflectively are registered: constructors, methods and fields annotated with Inject, and Provides methods.
 *     Methods and fields are registered only where they can be
 *     reached reflectively: methods on classes that carry any annotation (Jackson, Guice, JAX-RS, lifecycle and
 *     validation annotations all mean members are called reflectively; service providers always get their methods),
 *     fields on classes that declare an annotated field, plus everything in --reflect-methods and --reflect-fields
 *     packages. Every registered member is a root for the native image builder's analysis, and every registered
 *     field is treated as potentially Unsafe-accessed, so the fewer the better: plain engine internals are reached
 *     through code, not reflection. Classes whose name matches a --reflect-exclude pattern are left out of the
 *     package and jar rules (for example generated builder APIs).
 * </pre>
 */
public final class NativeImageBuildTool
{
  /**
   * Jars of GraalVM's JavaScript engine and SDK, pulled in for Druid's optional JavaScript support. They ship
   * classes that are part of the native image builder itself and cannot be compiled into an image.
   */
  private static final Pattern GRAALVM_JAR = Pattern.compile(
      "^(polyglot|truffle-api|truffle-compiler|truffle-runtime|js-language|js-scriptengine|nativeimage|collections"
      + "|word|jniutils|icu4j|regex|xz)-\\d+\\.\\d+\\.\\d+(\\.\\d+)?\\.jar$"
  );

  /**
   * The JAXB runtime. Only Jersey's XML entity providers reach it, which Druid never uses, and its Unsafe-based
   * accessors make the native image analysis several times slower. Without the runtime those providers fail to link
   * and Jersey skips them, as it does on a JVM without JAXB. The {@code javax.xml.bind} API jar stays, for the
   * annotations Jackson's JAXB module reads.
   */
  private static final Pattern JAXB_RUNTIME_JAR = Pattern.compile("^(jaxb-runtime|istack-commons-runtime|txw2)-.*\\.jar$");

  private static final Pattern VERSIONED_JAR = Pattern.compile("^(.*?)-(\\d+(?:\\.\\d+)*)([.-][0-9A-Za-z.-]*)?\\.jar$");

  /**
   * A build-time initialization request in a library's native-image.properties. Netty's codec jars ask for all of
   * io.netty, which pulls Log4j loggers into the image heap, and netty-common asks for CleanerJava25, whose static
   * initializer probes Arena.ofShared: run on the build JVM the probe succeeds, and the image keeps a direct-buffer
   * cleaner the native runtime cannot use. Build-time initialization is only an optimization, so every such request
   * is dropped and the classes initialize at run time.
   */
  private static final Pattern BUILD_TIME_INIT = Pattern.compile("--initialize-at-build-time=");

  private NativeImageBuildTool()
  {
  }

  public static void main(String[] args) throws IOException
  {
    if (args.length == 0) {
      usage();
    }
    switch (args[0]) {
      case "collect":
        collect(Arrays.asList(args).subList(1, args.length));
        break;
      case "generate-config":
        generateConfig(Arrays.asList(args).subList(1, args.length));
        break;
      default:
        usage();
    }
  }

  private static void usage()
  {
    System.err.println("usage: NativeImageBuildTool collect <druid-home> <output-dir> <extension>...");
    System.err.println("       NativeImageBuildTool generate-config <lib-dir> <output-dir> [options]");
    System.exit(2);
  }

  // ---------------------------------------------------------------------------------------------------------------
  // collect
  // ---------------------------------------------------------------------------------------------------------------

  private static void collect(List<String> args) throws IOException
  {
    if (args.size() < 2) {
      usage();
    }
    final Path druidHome = Path.of(args.get(0));
    final Path outputDir = Path.of(args.get(1));
    final List<String> extensions = args.subList(2, args.size());
    final Path libDir = Files.createDirectories(outputDir.resolve("lib"));

    final Map<String, CollectedJar> jarsByName = new HashMap<>();
    final Map<String, String> classOwners = new HashMap<>();
    final List<String> report = new ArrayList<>();

    try (Stream<Path> coreJars = Files.list(druidHome.resolve("lib"))) {
      for (Path jar : coreJars.filter(p -> p.toString().endsWith(".jar")).sorted().collect(Collectors.toList())) {
        if (GRAALVM_JAR.matcher(jar.getFileName().toString()).matches()) {
          report.add("skip     " + jar.getFileName() + " (GraalVM SDK jar, part of the native image builder)");
          continue;
        }
        if (JAXB_RUNTIME_JAR.matcher(jar.getFileName().toString()).matches()) {
          report.add("skip     " + jar.getFileName() + " (JAXB runtime, only reachable through unused Jersey XML providers)");
          continue;
        }
        add(new CollectedJar(jar, "lib", 0), libDir, jarsByName, classOwners, report);
      }
    }

    int order = 1;
    for (String extension : extensions) {
      final Path extensionDir = druidHome.resolve("extensions").resolve(extension);
      if (!Files.isDirectory(extensionDir)) {
        throw new IOException("Extension directory not found: " + extensionDir);
      }
      try (Stream<Path> jars = Files.list(extensionDir)) {
        for (Path jar : jars.filter(p -> p.toString().endsWith(".jar")).sorted().collect(Collectors.toList())) {
          add(new CollectedJar(jar, extension, order), libDir, jarsByName, classOwners, report);
        }
      }
      order++;
    }

    Files.write(outputDir.resolve("extensions.txt"), extensions, StandardCharsets.UTF_8);
    Files.write(outputDir.resolve("classpath-report.txt"), report, StandardCharsets.UTF_8);
    report.forEach(System.out::println);
    System.out.println("Collected " + jarsByName.size() + " jars into " + libDir);
  }

  private static void add(
      CollectedJar candidate,
      Path libDir,
      Map<String, CollectedJar> jarsByName,
      Map<String, String> classOwners,
      List<String> report
  ) throws IOException
  {
    final String name = candidate.name();
    if (jarsByName.containsKey(name)) {
      report.add("same     " + candidate.origin + "/" + name + " (already present)");
      return;
    }

    final Set<String> classes = classEntries(candidate.path);
    final Map<String, Integer> overlaps = new HashMap<>();
    if (candidate.order > 0) {
      // Core libraries are kept as they are, duplicates included: that is the class path a JVM would see.
      for (String clazz : classes) {
        final String owner = classOwners.get(clazz);
        if (owner != null) {
          overlaps.merge(owner, 1, Integer::sum);
        }
      }
    }

    for (Map.Entry<String, Integer> overlap : overlaps.entrySet()) {
      final CollectedJar existing = jarsByName.get(overlap.getKey());
      if (!candidate.replaces(existing)) {
        report.add(
            "drop     " + candidate.origin + "/" + name + " (" + overlap.getValue() + " classes also in "
            + existing.origin + "/" + existing.name() + ", keeping that one)"
        );
        return;
      }
    }

    for (String overlappingJar : overlaps.keySet()) {
      final CollectedJar existing = jarsByName.remove(overlappingJar);
      Files.delete(libDir.resolve(overlappingJar));
      classOwners.values().removeIf(overlappingJar::equals);
      report.add(
          "replace  " + existing.origin + "/" + existing.name() + " with " + candidate.origin + "/" + name
          + " (" + overlaps.get(overlappingJar) + " shared classes, newer version)"
      );
    }

    final List<String> stripped = copyWithoutBuildTimeInit(candidate.path, libDir.resolve(name));
    for (String entry : stripped) {
      report.add("strip    " + candidate.origin + "/" + name + "!" + entry + " (build-time initialization)");
    }
    jarsByName.put(name, candidate);
    for (String clazz : classes) {
      classOwners.putIfAbsent(clazz, name);
    }
    if (overlaps.isEmpty()) {
      report.add("add      " + candidate.origin + "/" + name);
    }
  }

  /**
   * Copies a jar, leaving out native-image.properties entries that request build-time initialization. Returns the
   * names of the entries left out.
   */
  private static List<String> copyWithoutBuildTimeInit(Path source, Path target) throws IOException
  {
    final List<String> toStrip = new ArrayList<>();
    try (JarFile jarFile = new JarFile(source.toFile())) {
      final Enumeration<JarEntry> entries = jarFile.entries();
      while (entries.hasMoreElements()) {
        final JarEntry entry = entries.nextElement();
        if (entry.getName().startsWith("META-INF/native-image/") && entry.getName().endsWith("native-image.properties")) {
          final String content = new String(jarFile.getInputStream(entry).readAllBytes(), StandardCharsets.UTF_8);
          if (BUILD_TIME_INIT.matcher(content).find()) {
            toStrip.add(entry.getName());
          }
        }
      }
    }
    if (toStrip.isEmpty()) {
      Files.copy(source, target, StandardCopyOption.REPLACE_EXISTING);
      return toStrip;
    }
    try (JarInputStream in = new JarInputStream(Files.newInputStream(source));
         JarOutputStream out = in.getManifest() == null
                               ? new JarOutputStream(Files.newOutputStream(target))
                               : new JarOutputStream(Files.newOutputStream(target), in.getManifest())) {
      JarEntry entry;
      while ((entry = in.getNextJarEntry()) != null) {
        if (toStrip.contains(entry.getName())) {
          continue;
        }
        out.putNextEntry(new JarEntry(entry.getName()));
        in.transferTo(out);
        out.closeEntry();
      }
    }
    return toStrip;
  }

  private static Set<String> classEntries(Path jar) throws IOException
  {
    final Set<String> classes = new HashSet<>();
    try (JarFile jarFile = new JarFile(jar.toFile())) {
      final Enumeration<JarEntry> entries = jarFile.entries();
      while (entries.hasMoreElements()) {
        final String entry = entries.nextElement().getName();
        if (entry.endsWith(".class") && !entry.startsWith("META-INF/") && !entry.endsWith("module-info.class")) {
          classes.add(entry);
        }
      }
    }
    return classes;
  }

  private static final class CollectedJar
  {
    private final Path path;
    private final String origin;
    private final int order;

    private CollectedJar(Path path, String origin, int order)
    {
      this.path = path;
      this.origin = origin;
      this.order = order;
    }

    private String name()
    {
      return path.getFileName().toString();
    }

    /**
     * Whether this jar should replace {@code existing}, which contains some of the same classes. Between a core
     * library (order 0) and an extension the newer version wins; between extensions the one listed first wins.
     */
    private boolean replaces(CollectedJar existing)
    {
      if (existing.order > 0) {
        return false;
      }
      return compareVersions(version(name()), version(existing.name())) > 0;
    }

    private static String version(String jarName)
    {
      final Matcher matcher = VERSIONED_JAR.matcher(jarName);
      return matcher.matches() ? matcher.group(2) : "";
    }

    /**
     * Compares dotted versions component by component: numerically where both components are numbers, otherwise as
     * strings. A missing component (including an unversioned jar) counts as zero.
     */
    private static int compareVersions(String left, String right)
    {
      final String[] leftParts = left.split("[.\\-_]");
      final String[] rightParts = right.split("[.\\-_]");
      for (int i = 0; i < Math.max(leftParts.length, rightParts.length); i++) {
        final String l = i < leftParts.length && !leftParts[i].isEmpty() ? leftParts[i] : "0";
        final String r = i < rightParts.length && !rightParts[i].isEmpty() ? rightParts[i] : "0";
        final int comparison = isNumeric(l) && isNumeric(r)
                               ? Long.compare(Long.parseLong(l), Long.parseLong(r))
                               : l.compareTo(r);
        if (comparison != 0) {
          return comparison;
        }
      }
      return 0;
    }

    private static boolean isNumeric(String s)
    {
      return s.length() <= 18 && s.chars().allMatch(Character::isDigit);
    }
  }

  // ---------------------------------------------------------------------------------------------------------------
  // generate-config
  // ---------------------------------------------------------------------------------------------------------------

  private static void generateConfig(List<String> args) throws IOException
  {
    if (args.size() < 2) {
      usage();
    }
    final Path libDir = Path.of(args.get(0));
    final Path outputDir = Files.createDirectories(Path.of(args.get(1)));
    final List<String> reflectPackages = new ArrayList<>();
    final List<String> reflectJars = new ArrayList<>();
    final List<String> constructorPackages = new ArrayList<>();
    final List<String> methodPackages = new ArrayList<>();
    final List<String> fieldPackages = new ArrayList<>();
    final List<Pattern> excludes = new ArrayList<>();
    final List<String> resourcePatterns = new ArrayList<>();
    for (int i = 2; i < args.size(); i += 2) {
      if (i + 1 >= args.size()) {
        usage();
      }
      switch (args.get(i)) {
        case "--reflect-package":
          reflectPackages.add(args.get(i + 1));
          break;
        case "--reflect-jar":
          reflectJars.add(args.get(i + 1));
          break;
        case "--reflect-package-constructors":
          constructorPackages.add(args.get(i + 1));
          break;
        case "--reflect-exclude":
          excludes.add(Pattern.compile(args.get(i + 1)));
          break;
        case "--reflect-fields":
          fieldPackages.add(args.get(i + 1));
          break;
        case "--reflect-methods":
          methodPackages.add(args.get(i + 1));
          break;
        case "--resource-pattern":
          resourcePatterns.add(args.get(i + 1));
          break;
        default:
          usage();
      }
    }

    final Set<String> reflectClasses = new TreeSet<>();
    final Set<String> constructorClasses = new TreeSet<>();
    final Set<String> methodClasses = new TreeSet<>();
    final Set<String> fieldClasses = new TreeSet<>();
    final Set<String> serviceProviders = new TreeSet<>();
    final Set<String> knownClasses = new HashSet<>();
    int jarCount = 0;

    try (Stream<Path> jars = Files.list(libDir)) {
      for (Path jar : jars.filter(p -> p.toString().endsWith(".jar")).sorted().collect(Collectors.toList())) {
        jarCount++;
        final boolean reflectWholeJar = reflectJars.stream().anyMatch(jar.getFileName().toString()::startsWith);
        try (JarFile jarFile = new JarFile(jar.toFile())) {
          final Enumeration<JarEntry> entries = jarFile.entries();
          while (entries.hasMoreElements()) {
            final JarEntry entry = entries.nextElement();
            final String name = entry.getName();
            if (name.startsWith("META-INF/services/") && !entry.isDirectory()) {
              try (BufferedReader reader = new BufferedReader(
                  new InputStreamReader(jarFile.getInputStream(entry), StandardCharsets.UTF_8)
              )) {
                String line;
                while ((line = reader.readLine()) != null) {
                  final String provider = line.replaceFirst("#.*", "").trim();
                  if (!provider.isEmpty()) {
                    serviceProviders.add(provider);
                  }
                }
              }
            } else if (name.endsWith(".class") && !name.endsWith("module-info.class")
                       && !name.endsWith("package-info.class")) {
              final String className = className(name);
              if (className == null) {
                continue;
              }
              knownClasses.add(className);
              if (excludes.stream().anyMatch(exclude -> exclude.matcher(className).find())) {
                continue;
              }
              if (reflectWholeJar || reflectPackages.stream().anyMatch(className::startsWith)) {
                reflectClasses.add(className);
                final Annotations annotations = scanAnnotations(jarFile.getInputStream(entry).readAllBytes());
                if (methodPackages.stream().anyMatch(className::startsWith) || annotations.anywhere) {
                  methodClasses.add(className);
                }
                if (fieldPackages.stream().anyMatch(className::startsWith) || annotations.onFields) {
                  fieldClasses.add(className);
                }
              } else if (constructorPackages.stream().anyMatch(className::startsWith)) {
                constructorClasses.add(className);
              } else {
                // Guice constructs bound classes and calls injection points and provider methods reflectively (the
                // native image runs with Guice's bytecode generation disabled), wherever the class comes from.
                final Annotations annotations = scanAnnotations(jarFile.getInputStream(entry).readAllBytes());
                if (annotations.injectedMethods) {
                  reflectClasses.add(className);
                  methodClasses.add(className);
                } else if (annotations.injectedConstructor) {
                  constructorClasses.add(className);
                }
                if (annotations.injectedFields) {
                  reflectClasses.add(className);
                  fieldClasses.add(className);
                }
              }
            }
          }
        }
      }
    }

    // Service files may name providers from jars that are not on this class path; those entries would only
    // produce warnings from the native image builder.
    int unknownProviders = 0;
    for (String provider : serviceProviders) {
      if (knownClasses.contains(provider)) {
        reflectClasses.add(provider);
        methodClasses.add(provider);
      } else {
        unknownProviders++;
      }
    }

    constructorClasses.removeAll(reflectClasses);
    writeReflectConfig(
        outputDir.resolve("reflect-config.json"),
        reflectClasses,
        methodClasses,
        fieldClasses,
        constructorClasses
    );
    writeResourceConfig(outputDir.resolve("resource-config.json"), resourcePatterns);

    System.out.println(
        "Scanned " + jarCount + " jars: " + reflectClasses.size() + " classes registered ("
        + methodClasses.size() + " with methods, " + fieldClasses.size() + " with fields; "
        + serviceProviders.size() + " service providers, " + unknownProviders + " of them absent from the class path), "
        + constructorClasses.size() + " more classes with constructors only, "
        + resourcePatterns.size() + " resource patterns"
    );
  }

  private static final class Annotations
  {
    private boolean anywhere;
    private boolean onFields;
    private boolean injectedConstructor;
    private boolean injectedMethods;
    private boolean injectedFields;
  }

  private static final Set<String> INJECT_ANNOTATIONS = Set.of(
      "Lcom/google/inject/Inject;",
      "Ljavax/inject/Inject;",
      "Ljakarta/inject/Inject;"
  );
  private static final String PROVIDES_ANNOTATION = "Lcom/google/inject/Provides;";

  /**
   * Where the class carries annotations. Jackson, Guice, JSR-330, JAX-RS, lifecycle and validation annotations are
   * the reasons members get called, read or written reflectively; a class without any annotation is only reached
   * through code. Guice's own injection points are tracked separately, because they matter in every jar.
   */
  private static Annotations scanAnnotations(byte[] classBytes)
  {
    final Annotations annotations = new Annotations();
    new ClassReader(classBytes).accept(
        new ClassVisitor(Opcodes.ASM9)
        {
          @Override
          public AnnotationVisitor visitAnnotation(String descriptor, boolean visible)
          {
            annotations.anywhere = true;
            return null;
          }

          @Override
          public FieldVisitor visitField(int access, String name, String descriptor, String signature, Object value)
          {
            return new FieldVisitor(Opcodes.ASM9)
            {
              @Override
              public AnnotationVisitor visitAnnotation(String annotationDescriptor, boolean visible)
              {
                annotations.anywhere = true;
                annotations.onFields = true;
                if (INJECT_ANNOTATIONS.contains(annotationDescriptor)) {
                  annotations.injectedFields = true;
                }
                return null;
              }
            };
          }

          @Override
          public MethodVisitor visitMethod(
              int access,
              String name,
              String descriptor,
              String signature,
              String[] exceptions
          )
          {
            return new MethodVisitor(Opcodes.ASM9)
            {
              @Override
              public AnnotationVisitor visitAnnotation(String annotationDescriptor, boolean visible)
              {
                annotations.anywhere = true;
                if (INJECT_ANNOTATIONS.contains(annotationDescriptor)) {
                  if ("<init>".equals(name)) {
                    annotations.injectedConstructor = true;
                  } else {
                    annotations.injectedMethods = true;
                  }
                } else if (PROVIDES_ANNOTATION.equals(annotationDescriptor)) {
                  annotations.injectedMethods = true;
                }
                return null;
              }

              @Override
              public AnnotationVisitor visitParameterAnnotation(int parameter, String annotationDescriptor, boolean visible)
              {
                annotations.anywhere = true;
                return null;
              }
            };
          }
        },
        ClassReader.SKIP_CODE | ClassReader.SKIP_DEBUG | ClassReader.SKIP_FRAMES
    );
    return annotations;
  }

  private static String className(String entryName)
  {
    String name = entryName;
    if (name.startsWith("META-INF/versions/")) {
      // Multi-release jar: META-INF/versions/<n>/<class path>
      final int slash = name.indexOf('/', "META-INF/versions/".length());
      if (slash < 0) {
        return null;
      }
      name = name.substring(slash + 1);
    }
    return name.substring(0, name.length() - ".class".length()).replace('/', '.');
  }

  private static void writeReflectConfig(
      Path file,
      Set<String> fullClasses,
      Set<String> methodClasses,
      Set<String> fieldClasses,
      Set<String> constructorClasses
  ) throws IOException
  {
    try (PrintWriter writer = new PrintWriter(Files.newBufferedWriter(file, StandardCharsets.UTF_8))) {
      writer.println("[");
      boolean first = true;
      for (String clazz : fullClasses) {
        writer.print(first ? "  " : ",\n  ");
        // Declared members only: inherited members are registered on the class that declares them, which the
        // package rules cover as well. Registering the public views too would only duplicate work for the builder.
        writer.print(
            "{\"name\":\"" + clazz + "\",\"allDeclaredConstructors\":true"
            + (methodClasses.contains(clazz) ? ",\"allDeclaredMethods\":true" : "")
            + (fieldClasses.contains(clazz) ? ",\"allDeclaredFields\":true" : "")
            + "}"
        );
        first = false;
      }
      for (String clazz : constructorClasses) {
        writer.print(first ? "  " : ",\n  ");
        writer.print("{\"name\":\"" + clazz + "\",\"allDeclaredConstructors\":true}");
        first = false;
      }
      writer.println();
      writer.println("]");
    }
  }

  private static void writeResourceConfig(Path file, List<String> patterns) throws IOException
  {
    try (PrintWriter writer = new PrintWriter(Files.newBufferedWriter(file, StandardCharsets.UTF_8))) {
      writer.println("{");
      writer.println("  \"resources\": {");
      writer.println("    \"includes\": [");
      for (int i = 0; i < patterns.size(); i++) {
        writer.println(
            "      {\"pattern\": \"" + patterns.get(i).replace("\\", "\\\\").replace("\"", "\\\"") + "\"}"
            + (i + 1 < patterns.size() ? "," : "")
        );
      }
      writer.println("    ]");
      writer.println("  },");
      writer.println("  \"bundles\": []");
      writer.println("}");
    }
  }
}
