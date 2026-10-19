#pragma once

// p4: deterministic scripted console execution for the visual regression
// harness (docs/VISUAL_HARNESS.md). `-harness <file>` runs the file as a
// timed command sequence once the main loop is up:
//
//   # comment
//   wait <seconds>      — advance the schedule (waits are cumulative)
//   <console command>   — Console->ExecuteCommand
//
// The sequence starts after a short settle grace. When the sequence ends the
// driver idles; cases may end with a `quit` command for unattended runs.
void harness_init();
