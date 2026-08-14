# Eclipse Startup Trace

Sampling profiler for Eclipse startup and UI freezes, built on repeated JVM thread dumps.
Linux and Windows versions with the same options and the same output format.

## Why sampling

A single thread dump tells you what the UI thread was doing at one instant and nothing about how long it stayed there.
A frame that looks alarming may be a fast call you happened to catch, and the real cost may sit in a caller that appears in every dump.

Taking many dumps in a row fixes that.
If the same call appears in twenty consecutive samples it is the freeze, and if it appears once it is noise.
This needs nothing but a JDK, and for a stall lasting seconds it is as good as a real profiler.

Reading the leaf frames tells you which kind of problem you have.
Leaf frames that keep changing while a caller stays put mean the code is grinding through work.
A leaf frame that never changes means the thread is blocked, and the `- locked` lines in the dump tell you on which monitors.

## Usage

Linux:

```bash
./profile-eclipse-startup.sh --eclipse /path/to/eclipse --data ~/workspace/platform

# re-summarize an existing dump file, restricted to the startup window
./profile-eclipse-startup.sh --analyze-only --until 7000

# full stack of the samples you care about
./show-blocking-stack.sh --match 'Workbench[.]initializeImages' --count 2
```

Windows:

```powershell
.\profile-eclipse-startup.ps1 -EclipseExe C:\eclipse\eclipse.exe -Data C:\ws\platform
.\profile-eclipse-startup.ps1 -AnalyzeOnly -UntilMs 7000
.\show-blocking-stack.ps1 -Match 'Workbench\.initializeImages' -Count 2
```

Both write the dumps to `eclipse-startup-stacks.txt` in the current directory by default, and both assume exactly one running Eclipse so the process id is unambiguous.
Use `--pid` / `-TargetPid` to sample an IDE the script did not start, which is how you catch a freeze in a running instance rather than a slow startup.

The regex options are shell-quoted differently on the two platforms.
In Bash, prefer a character class such as `'Workbench[.]initializeImages'` over `\.`, because a backslash escape inside a string passed to `awk` triggers a warning and is treated as a plain dot anyway.

## Sampling the right thread

`--thread` / `-Thread` matches on a prefix, so `--thread "Start Level"` finds the Equinox thread whose full name carries a per run UUID.

This matters more than it sounds.
Sampling only `main` can attribute a large block to a flat idle wait: during OSGi start level the UI thread parks on a semaphore in `EclipseStarter.updateSplash` while bundle activation happens on the `Start Level` thread.
If a stretch of the timeline shows `main` in `TIMED_WAITING`, re-run the analysis against the thread that is actually working.

## Linux samples faster

Windows has no SIGQUIT, so the PowerShell version uses `jcmd Thread.print` per sample.
Each `jcmd` call starts its own JVM, measured at 80 to 250 ms, so on a startup that finishes in a few seconds the sampler itself sets the resolution floor.

The Linux version defaults to `kill -QUIT`, which makes the JVM print the dump to its own stdout at no cost to the sampler and allows a 50 ms interval.
It redirects the launcher's stdout, records a millisecond timestamp per signal, then rewrites the JVM output into the same `===== sample N t=NNNNms =====` format the `jcmd` path produces, so both methods feed the same analyzer.
`--method jcmd` is still available on Linux and is required with `--pid`, because the stdout of a process the script did not start cannot be captured.

Sampling at 50 ms costs roughly 10 percent in measured startup time.
Cross-check anything important at a coarser interval before trusting an absolute number.

## Output

Four sections:

*   **Timeline**, one line per sample with the elapsed time, the thread state and the most interesting frame.
    A stall appears as a run of identical lines, which is the primary signal.
*   **Most frequent triggering frame**, which counts the UI code that led into the expensive work.
*   **Hottest leaf frames**, which shows where the time was actually burned.
*   **Inclusive cost**, frames ranked by how many samples contain them anywhere in the stack.
    Read down the list: the deepest frame with a high count is the expensive subtree.

`--until` / `-UntilMs` restricts the analysis to a time window, which matters because the idle event loop after startup otherwise dominates every table.

## Worked example

Against an Eclipse 4.41 SDK on Linux with a 211 MB platform workspace, four runs at a 50 ms interval:

*   The UI thread first reaches the event loop between 5.1 and 6.1 s and settles between 5.7 and 7.7 s.
*   800 to 1150 ms of that is OSGi start level, with `main` parked and `org.apache.felix.scr.impl.Activator$ScrExtension.start` dominating the `Start Level` thread.
*   190 to 320 ms is `Workbench.initializeImages`, which turned out to be rasterizing three SVG window icons on the UI thread before any window exists.
*   Cross cutting, and overlapping: OSGi class loading 1.4 to 1.5 s, custom tab and frame rendering 0.9 to 1.1 s, SWT image loading 0.5 to 0.8 s, CSS and theme engine 0.5 to 0.6 s.

A single sampled stack was also enough to find file I/O in a paint path, `GC.drawImage` reaching `ImageLoader.isDynamicallySizable` and `FileInputStream.open`.

## Caveats

A sampling profiler attributes time to whatever is on the stack at the sample instant.
Single sample entries are noise, and only repeated blocks are meaningful.
Attribution is granular to the sampling interval, so a block reported as 190 ms from three samples is approximate.

Every `Thread.print` walks all threads at a safepoint, so dump files grow quickly.
A 25 s run at 50 ms produced 22 MB.

## Requirements

*   A JDK on `PATH` for `jcmd`, ideally the one that runs the IDE.
    The Linux script resolves `jcmd` from the target JVM automatically; on Windows pass `-JcmdExe` if it is not on `PATH`.
*   Linux: Bash 4, `awk`, `pgrep`, and a `/proc` filesystem.
*   Windows: PowerShell 5.1 or PowerShell 7.
