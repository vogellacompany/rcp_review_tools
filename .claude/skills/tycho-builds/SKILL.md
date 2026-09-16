---
name: tycho-builds
description: Build, compile and test any Maven Tycho project (Eclipse plug-ins, OSGi bundles, features, RCP products, target platforms) from the command line, including pomless builds, without silently testing a published baseline jar or a target-platform jar instead of your own code. Use whenever you run `mvn verify` or `mvn clean verify` on a Tycho or PDE bundle, run a single test bundle or test class, pick the `-pl` module list, run SWT/JFace/UI tests headless, or debug "my fix does not take effect", "the test still sees the old behaviour", "cannot be resolved", "shadowed by a reactor project", "has been replaced with the baseline version" or "Only qualifier changed".
---

# Tycho builds

Applies to any build using the `org.eclipse.tycho` plugins, whatever the parent POM or repository.
Property names and mojo parameters below are from Tycho 5.x and are Tycho's own, not project inventions.
The Eclipse platform repositories appear only as worked examples at the end.

## Mental model: reactor versus target platform

Tycho resolves every bundle a module needs from one of two places.

1. The **reactor**: modules in the current build, taken from the working tree.
2. The **target platform**: p2 repositories and `.target` files, serving **published** jars.

The reactor wins only for modules actually in the build.
`-pl` shrinks the reactor, so every module you leave out silently falls back to the published jar.
That single fact causes most "my change has no effect" reports.

Two further layers can also substitute a published jar for your compiled one, even when the module *is* in the reactor:

* **baseline replacement** in `tycho-p2-plugin`, which swaps the packaged jar for the baseline one when versions match;
* **p2 version pinning**, where a feature or an `extraRequirements` entry demands an exact released version and p2 may install only one version of a bundle.

So "the module is in `-pl`" is necessary, not sufficient.
Always verify from the build log, see [Verify what actually ran](#verify-what-actually-ran).

## Step 0: read the build before running it

```bash
cat .mvn/extensions.xml .mvn/maven.config 2>/dev/null     # pomless extension, forced CLI flags
sed -n '1,60p' pom.xml                                     # parent, properties, profiles
grep -rn 'target-platform-configuration' -A20 pom.xml      # target platform source
mvn help:effective-pom -pl :<bundle> | less                # what is really configured
```

* `.mvn/extensions.xml` containing `org.eclipse.tycho:tycho-build` means a **pomless** build.
  Bundles have no `pom.xml`; the POM is synthesized from `MANIFEST.MF` and `build.properties`.
* `.mvn/maven.config` is applied to every invocation.
  Read it before concluding a flag has no effect, and remember it does not apply if you invoke Maven from outside the project directory.
* The effective POM is the only reliable source for whether baseline comparison, the API tools or the version comparator are active here.

### Per-bundle properties in a pomless build

There is no `pom.xml` to edit, so a single bundle's Maven properties go into its `build.properties`:

```
pom.model.property.testClass = org.example.tests.AllTests
pom.model.property.surefire.timeout = 1800
```

Repository-wide properties go into the root `pom.xml` `<properties>`.
Never hand-write a `pom.xml` for a pomless module; it changes how the module is built.

## The baseline trap

`tycho-p2-plugin` can compare each built artifact against a **baseline repository** (usually the last release or integration build) and, on a content difference at the same fully qualified version, **replace your freshly compiled jar with the published one**.
`target/classes` then holds your new code while the packaged jar and the whole test runtime hold the released bytecode.
Tests pass or fail against code you did not write, and the fix appears not to work.

Two mojo parameters control it, both with Tycho user properties:

| Parameter | User property | Default | Meaning |
| --- | --- | --- | --- |
| `baselineMode` | `-Dtycho.baseline` | `warn` | `disable` switches the comparison off entirely |
| `baselineReplace` | `-Dtycho.baseline.replace` | `all` | `none` compares but never substitutes |

For a local build that must exercise your own code:

```bash
mvn clean verify -Dtycho.baseline.replace=none
```

A **literal** value in the POM beats the user property, because the expression is only the parameter default.
If a project configures `<baselineMode>warnCommon</baselineMode>` literally, `-Dtycho.baseline=disable` does nothing while `-Dtycho.baseline.replace=none` still works, since that parameter kept its `${tycho.baseline.replace}` default.
Check the effective POM rather than guessing which of the two to pass; passing both is harmless.

Why the trap is intermittent rather than constant: the qualifier usually comes from `tycho-buildtimestamp-jgit`, which derives it from the last commit touching the module and, with `jgit.dirtyWorkingTree=ignore`, ignores your uncommitted edits.
An uncommitted change therefore keeps the published qualifier and matches the baseline exactly, while a committed change gets a fresh qualifier and escapes by accident.
Any module you did not touch matches too.

Do not work around it by bumping `Bundle-Version`.
It is not reliable (p2 can still pin the released version through a feature) and in most Eclipse projects version increments are produced by tooling, not by hand.

Some projects offer a profile that sets both parameters, for example `-Pjavac` in `eclipse-platform-parent`.
Prefer the properties: that particular profile also swaps ECJ for javac and clears `compilerArgs`, which hides exactly the compile errors CI will hit.

## Choosing the `-pl` module list

Rules, in order of how often they are missed:

1. Include the **module under test**, not only its test module.
   `mvn verify -pl :com.example.core.tests` alone tests the published `com.example.core`.
2. Include every **in-repo module the test module depends on**, including test-support and harness modules.
   A missing support module produces a compile error CI does not have, so before blaming the error check whether the symbol lives in another module of the same repository.
3. Test modules are usually **not published**, so they are not in the target platform.
   If a test bundle `Require-Bundle`s another test bundle, that one must be in `-pl` too.
4. Include a **feature module** when a test module requires that feature, through `extraRequirements` or a `.target`.
   A p2 feature pins its bundles to exact released versions, so without the feature in the reactor the released bundle wins over your SNAPSHOT no matter what else is in `-pl`.
5. Add `-Dtest=<Class> -DfailIfNoTests=false`, otherwise every other reactor module runs its own full suite.
6. Prefer `:artifactId` coordinates, which work regardless of module path, but use **directory paths** for pomless features and wherever a derived artifactId collides with a bundle id.

`-am` (`--also-make`) is not a substitute for a correct list.
It pulls in the transitive closure, which for a platform-level test bundle is most of the repository, and it does nothing about baseline replacement or p2 pinning.

When the `-pl` list is genuinely hard to get right, building the **whole reactor** with `-Dtest=` filtering is often faster than the guessing:

```bash
mvn clean verify -Dtest=<TestClass> -DfailIfNoTests=false -Dtycho.baseline.replace=none
```

### Symptoms of a wrong `-pl` list

* `[ERROR] Cannot resolve project dependencies: ... requires 'osgi.bundle; <id> 0.0.0' but it could not be found`, a module is missing from both reactor and target platform.
* The test module fails to **compile** with "method is undefined" or "must override or implement a supertype method" after you added new API.
  That is a resolution problem, not a broken test.
* Everything builds and the test reports the old behaviour, the silent case.

## Running tests

Tycho binds `tycho-surefire-plugin` to the `integration-test` phase for `eclipse-test-plugin` packaging, so **`mvn test` runs nothing**; use `mvn verify`.

Verified Tycho user properties (Tycho 5.x, `tycho-surefire-plugin`):

| Flag | Effect |
| --- | --- |
| `-Dtest=<Class>` | filter test classes, supports patterns |
| `-DtestClass=<FQCN>` | the single class or suite to run |
| `-DfailIfNoTests=false` | do not fail modules the filter does not match |
| `-DskipTests` / `-Dmaven.test.skip=true` | skip running / skip compiling and running |
| `-Dsurefire.timeout=<seconds>` | forked process timeout, a whole-module wall-clock cap |
| `-Dsurefire.rerunFailingTestsCount=<n>` | retry flaky tests |
| `-Dtycho.surefire.useUIHarness=true` | run inside a workbench instead of a plain OSGi runtime |
| `-Dtycho.surefire.useUIThread` | run the tests on the UI thread |
| `-Dtycho.testArgLine=...` | extra JVM arguments for the forked test VM |
| `-Dosgi.debug=<options-file>` | enable Equinox tracing inside the test runtime |
| `-DdebugPort=<port>` | suspend the test VM for a remote debugger |
| `-Dtycho.showEclipseLog=true` | print the Eclipse `.log` after the run |
| `-Dtycho.printBundles=true`, `-Dtycho.printWires=true` | dump the test runtime's bundles and wiring |
| `-Dtycho.surefire.deleteWorkDir` | control whether `target/work` survives the run |

`-Dtycho.testArgLine` is only the **default** for the `argLine` parameter.
A project that configures `<argLine>` literally, as `eclipse-platform-parent` does, makes the flag a no-op; there, set whatever property the POM interpolates, or fall back to the `JAVA_TOOL_OPTIONS` environment variable, which the forked VM always honours.
When overriding such an argLine property, keep the parts the project put there, typically `--add-modules=ALL-SYSTEM`.

A broad `-Dtest=` pattern can match both the individual test classes **and** the aggregating `AllXTests` suite, running the same classes twice in one JVM against one workspace.
The resulting state pollution produces failures that do not reproduce otherwise.
Filter on the suite alone, or on exactly one class.

Whether a test module also runs under a different harness matters for CI parity.
Older Eclipse test bundles carry a `test.xml` where `core-test` means headless with no workbench and `ui-test` launches one, while the local Tycho run may auto-select the UI harness from the bundle's dependencies.
A test that loads a class from a lazy-activated UI bundle then passes locally and fails on the other harness with `NoClassDefFoundError` from a failed bundle activation.
To see which harness a local run used, look for workbench state under `<test-module>/target/work/data/.metadata/.plugins/`.

## Headless UI tests on Linux

Any Tycho build running SWT, JFace or workbench tests needs a display.
Pin GTK to X11 under Xvfb and unset the Wayland variables:

```bash
env -u WAYLAND_DISPLAY -u XDG_SESSION_TYPE GDK_BACKEND=x11 \
  xvfb-run -a mvn clean verify -pl :<bundle>,:<test-bundle> -Dtycho.baseline.replace=none
```

* `-a` picks a free display number, so parallel runs do not collide.
* Plain `xvfb-run` on a Wayland session still renders on the real compositor, so the run is not headless.
* The two unsets matter because failure screenshots are taken by AWT, which `GDK_BACKEND` does not redirect.
  With the Wayland variables set, that path goes through the desktop screencast portal and blocks about 15 seconds per failure behind a share dialog.

For behaviour that depends on the GTK theme, point `XDG_CONFIG_HOME` at a scratch directory holding `gtk-3.0/settings.ini` with `gtk-theme-name=<theme>`, and leave `GTK_THEME` unset.
`GTK_THEME=<name>` pins the theme and makes `gtk-application-prefer-dark-theme` be ignored silently, so dark-mode behaviour cannot be reproduced that way.
Xvfb without any theme configuration falls back to Adwaita.

Pixel comparison and screenshot tests are the usual casualties: they frequently fail under Xvfb on an unmodified tree, so establish a baseline before believing them.

## Verify what actually ran

Never trust a green or red local run without checking the log.

```bash
mvn ... 2>&1 | tee build.log
grep -n "has been replaced with the baseline version\|shadowed by a reactor\|same version but different contents" build.log
```

* `The main artifact has been replaced with the baseline version.` means the run tested published code.
* `[WARNING] Your build strictly depends on unit <id> <version> that is shadowed by a reactor project, this can lead to unexpected build results!` means a module resolved a published jar although your build contains it.
  Its **absence** is the green light; this is a more reliable tell than inspecting `target/work/configuration/config.ini`.
* `baseline and build artifacts have same version but different contents` is the baseline comparison firing at all.

To see where a specific bundle came from, run with `-X` and look for the resolution lines naming either a reactor project or a path under `~/.m2/repository/p2/`.

## When a run looks wrong

* **Use `clean`.**
  A stale bad compile surfaces at runtime as `Unresolved compilation problem` and reads as a test failure.
* **Stale IDE output folders.**
  `mvn clean` does not delete the git-ignored `bin/` directory, and `build.properties` often has `output.. = bin/`, so old classes can be packaged. Delete `bin/` in touched bundles; afterwards refresh and clean the project in any IDE using that workspace, which otherwise throws `ClassNotFoundException`.
* **Stash round trips.**
  After `git stash` and `git stash pop`, a restored file can carry an older mtime than `target/classes`, so a build without `clean` skips recompiling it.
* **Locally installed artifacts.**
  Some projects set `-Dtycho.localArtifacts=ignore` in `.mvn/maven.config`, which makes the "`mvn install` the module first, then build the test module alone" workaround silently ineffective.
* **Leftover test workspaces.**
  Test runs leave state under `<test-module>/target/work`, and some suites write outside it; check `git status` for untracked directories after a run.

### Other builds' checks that fail without being your fault

* **`Only qualifier changed for (<bundle>/x.y.z). Expected to have bigger x.y.z`** from `tycho-p2-extras` `compare-version-with-baselines`.
  When the change does not touch that bundle, the usual cause is an upstream commit forcing a qualifier update without the matching version increment, which fails every branch built against it. The fix belongs upstream, not in your branch.
* **Whole-module timeouts** rather than assertion failures: `process returned error code 143` together with `Timeout of <n>s exceeded. Process was killed` is `surefire.timeout` on a slow agent, not a regression.
* **API tools findings** from `tycho-apitools-plugin`, skippable with `-Dtycho.apitools.verify.skip=true` while iterating.
  Note its `skipIfReplaced` parameter defaults to true, so a baseline-replaced artifact quietly skips API analysis as well.

Before blaming a change for any local failure, re-run the identical command with the change stashed and compare.

## Before pushing

Build every touched module the way CI does:

```bash
mvn verify -pl :<bundle> -DskipTests -Dtycho.baseline.replace=none
```

Tycho compiles with ECJ using the project's `.settings/org.eclipse.jdt.core.prefs`, so problems that an IDE shows as warnings (unused imports, missing `@Override`, non-externalized strings) can be **errors** here.
A change that looks clean in an editor still fails the build.

## Worked examples: the Eclipse platform repositories

`eclipse.platform`, `eclipse.platform.ui`, `eclipse.pde` and `eclipse.platform.swt` are pomless `tycho-build` repositories under `org.eclipse:eclipse-platform-parent`.
All four already pass `-Pbuild-individual-bundles` through `.mvn/maven.config`; platform and platform.ui add `-Dtycho.target.eager=true`, platform.ui and pde add `-Dtycho.localArtifacts=ignore`.
The parent points the baseline at the current I-build repository and sets `<baselineMode>warnCommon</baselineMode>` literally, so `-Dtycho.baseline.replace=none` is the flag that works and `-Dtycho.baseline=disable` is not.
It also configures `<argLine>` from `${surefire.testArgLine}` and friends, so `-Dtycho.testArgLine` is ignored and `-Dsurefire.testArgLine` is the hook.
`surefire.timeout` defaults to 1200 there.

`eclipse.platform`, several test bundles needing support modules (rule 2):

```bash
env -u WAYLAND_DISPLAY -u XDG_SESSION_TYPE GDK_BACKEND=x11 xvfb-run -a \
  mvn clean verify -pl team/bundles/org.eclipse.compare,\
runtime/tests/org.eclipse.core.tests.harness,\
resources/tests/org.eclipse.core.tests.filesystem.feature,\
resources/tests/org.eclipse.core.tests.resources,\
team/tests/org.eclipse.compare.tests \
  -Dtycho.baseline.replace=none -Dtest=UnifiedDiffOpenTest -DfailIfNoTests=false
```

`org.eclipse.team.tests.core` needs those same support modules plus `:org.eclipse.compare` and `team/tests/org.eclipse.compare.tests` (rule 3).
Note the feature artifactId is `org.eclipse.core.tests.filesystem.feature`, with `tests.`.

`eclipse.pde`, a feature module in the reactor (rule 4):

```bash
env -u WAYLAND_DISPLAY -u XDG_SESSION_TYPE GDK_BACKEND=x11 xvfb-run -a \
  mvn clean verify -pl ui/org.eclipse.pde.core,features/org.eclipse.pde-feature,ui/org.eclipse.pde.ui.tests \
  -Dtycho.baseline.replace=none -Dtest=<TestClass> -DfailIfNoTests=false
```

`ui/org.eclipse.pde.ui.tests/pom.xml` declares an `extraRequirements` entry on the `org.eclipse.pde` feature, which pins its bundles to exact released versions.
Use the directory path, because the pomless feature's derived artifactId `org.eclipse.pde` collides with the `ui/org.eclipse.pde` bundle.
This run takes about 30 seconds against roughly 2 minutes for the whole reactor.

`eclipse.platform.ui` sets `tycho.surefire.useUIHarness` and `tycho.surefire.useUIThread` to true in the root POM, so tests run inside a workbench by default.

`eclipse.platform.swt` has `tests/org.eclipse.swt.tests` plus per-window-system `tests/org.eclipse.swt.tests.gtk`, `.cocoa` and `.win32`.
For iteration and benchmarking, skip Tycho entirely: the whole GTK `org.eclipse.swt` bundle compiles with plain `javac` in about 16 seconds by feeding it the source folders listed under `source..` in `binaries/org.eclipse.swt.gtk.linux.x86_64/build.properties`, with no target platform and no p2 resolution.
Quote the entries in a `javac` argfile, since the paths contain spaces.
