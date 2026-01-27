# JVM Performance Optimization Guide

This guide provides the minimal configuration required to optimize a Java application for both HotSpot and OpenJ9.
It is based on Java 25.

---

### 1. Eclipse Temurin

Supports AOT Linking.

#### 🛠️ Configuration (Add to eclipse.ini)
```ini
# --- GC & String Optimization ---
-XX:+UseG1GC
-XX:+UseStringDeduplication
-XX:+UseCompressedOops
-XX:ReservedCodeCacheSize=512m

# --- Startup (AppCDS/AOT) ---
# Note: Requires a training run first to create 'eclipse.aot'
-XX:AOTCache=eclipse.aot
-XX:+AutoCreateSharedArchive

# --- Reporting ---
-Xlog:stringdedup*=info
-Xlog:startuptime
```

#### 📉 Memory Release Optimization

The following flags enforce the release of unused RAM back to the OS when idle.

```ini
-XX:-ShrinkHeapInSteps
-XX:G1PeriodicGCInterval=3000
```

**Why use these?**
*   **`-XX:-ShrinkHeapInSteps`**:
    *   *Standard Behavior:* The JVM releases memory back to the OS in small, gradual steps to avoid performance glitches.
    *   *With Flag:* Forces the JVM to release **all** identified unused memory immediately after a full GC. This makes the OS memory meter reflect the "true" usage much faster.
*   **`-XX:G1PeriodicGCInterval=3000`**:
    *   *Standard Behavior:* G1GC only runs when the heap is full. If you leave Eclipse open but idle overnight, it might hold onto gigabytes of RAM unnecessarily.
    *   *With Flag:* Forces a garbage collection check every 3000ms (3 seconds) of **idleness**. If unused memory is found, it is compacted and returned to the OS (especially effective when combined with the shrink flag above).

#### 🔍 How to Verify
Look for this in the console or log:
`[gc,stringdedup] GC(15) De-duplicated: 2405 objects, 120 KB saved, total 45 MB saved`

#### ⚡ Alternative: Generational ZGC (Low Latency)
**Best for:** Huge heaps (16GB+) and users who want **zero** UI freezes.
*In Java 25, ZGC is "Generational" by default, meaning it handles young objects efficiently (like G1GC) but with sub-millisecond pause times.*

**Replace** `-XX:+UseG1GC` with:
```ini
-XX:+UseZGC
-XX:+ZGenerational
-XX:+UseStringDeduplication
```
*(Note: In Java 25, ZGC's string deduplication is highly optimized to ignore short-lived "young" strings, reducing CPU overhead compared to previous versions).*

### 2. Eclipse OpenJ9 (IBM / Semeru)

Support fast startup via "Shared Classes" caching and has a small RAM footprint.
*(Note: ZGC is a HotSpot-only feature. OpenJ9 achieves low-latency via different policies).*

#### 🛠️ Configuration (Add to eclipse.ini)
```ini
# --- GC & String Optimization ---
-Xgcpolicy:balanced
-XX:+UseStringDeduplication
```

#### 🔍 How to Verify
OpenJ9 will print a table to stdout during GC cycles:
`String deduplication stats: [X] objects processed, [Y] bytes freed.`

---

### 📊 Quick Comparison Matrix
| Feature | HotSpot (Java 25) | Eclipse OpenJ9 |
| :--- | :--- | :--- |
| GC Policy | G1GC | balanced |
| Dedupe Flag | -XX:+UseStringDeduplication | -XX:+UseStringDeduplication |
| Pointer Comp. | -XX:+UseCompressedOops | -Xcompressedrefs (Default) |
| AOT Storage | -XX:AOTCache | -Xshareclasses |
| Logging | -Xlog:stringdedup | -XX:+PrintStringDeduplicationStatistics |

---

### 🔍 Visual VM (Monitoring & Profiling)
To analyze an Eclipse RCP application with Visual VM, you must ensure the application is running on a **JDK** (not just a JRE). Additionally, add the following JMX parameters to your `eclipse.ini` to enable remote monitoring:

```ini
-Dcom.sun.management.jmxremote
-Dcom.sun.management.jmxremote.port=9010
-Dcom.sun.management.jmxremote.authenticate=false
-Dcom.sun.management.jmxremote.ssl=false
```

---

### ⚠️ Implementation Tips
- **The VMArgs Rule:** In `eclipse.ini`, all these flags must appear on separate lines below the `-vmargs` entry.
- **First Run:** Startup optimizations (AOT/AppCDS) usually require one "cold start" to generate the cache before you see the speed benefits on the second "warm start."
- **Memory Savings:** 
  - **String deduplication** is most effective in Eclipse when you have many open projects or a large workspace index.
  - **Compressed Oops (`-XX:+UseCompressedOops`)** reduces the size of object pointers from 64-bit to 32-bit (for heaps < 32GB), significantly reducing memory overhead. (OpenJ9 does this automatically with `-Xcompressedrefs`).
