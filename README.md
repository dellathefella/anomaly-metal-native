## X-Ray Monolith Edition for S.T.A.L.K.E.R. Anomaly
----

> **macOS / Apple Silicon:** this fork adds a native Metal renderer. See [README-METAL.md](README-METAL.md) for build, run, status and testing.

* based on Open X-Ray Call of Chernobyl Edition
* based on X-Ray 1.6 Engine

This repository contains XRAY Engine sources based on version 1.6.02 and the Call of Chernobyl 1.4.22 modifications.
The original engine is used in S.T.A.L.K.E.R. Call of Pripyat game released by GSC Game World and any changes to this engine are allowed for ***non-commercial*** use only.

This code repository contain the code for the `X-Ray Monolith Edition` that is used in `S.T.A.L.K.E.R. Anomaly version 1.5.2`.
To build on macOS: `cmake -S . -B build-gl -DCMAKE_BUILD_TYPE=Release && cmake --build build-gl -j 12` (see README-METAL.md).
