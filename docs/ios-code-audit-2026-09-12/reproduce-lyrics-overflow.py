#!/usr/bin/env python3
"""Run the repository's lyric parser in an isolated process; no app or network.

One sequential swiftc -j 1 invocation. Refuse to compile while another Swift
or Xcode compiler is active. Only generated temporary files are removed.
"""

import hashlib
from pathlib import Path
import resource
import signal
import subprocess
import sys
import tempfile


root = Path(__file__).resolve().parents[2]
processes = subprocess.check_output(["ps", "-axo", "comm="], text=True)
compiler_names = {"swift", "swiftc", "swift-driver", "swift-frontend", "xcodebuild"}
if any(Path(line.strip()).name in compiler_names for line in processes.splitlines()):
    raise SystemExit("Another compiler is active; wait before running this probe.")

source = (root / "Sources/TinyCloudMusic/Models.swift").read_text()
parser = source[source.index("struct SongLyrics:"):source.index("enum Appearance:")]
print("Parser SHA-256:", hashlib.sha256(parser.encode()).hexdigest(), flush=True)
main = r'''
if CommandLine.arguments[1] == "benchmark" {
    let count = Int(CommandLine.arguments[2])!
    let lrc = (0..<count).map { "[\($0 / 60):\(String(format: "%02d", $0 % 60))]line\($0)" }.joined(separator: "\n")
    let yrc = (0..<count).map { "[\($0 * 1000),1000](\($0 * 1000),1000,0)line\($0)" }.joined(separator: "\n")
    let start = Date()
    let lines = LRCParser.parse(SongLyrics(lineLyrics: lrc, wordLyrics: yrc))
    print("lines=\(lines.count) elapsed=\(Date().timeIntervalSince(start)) seconds")
} else {
    print(LRCParser.parse(primary: CommandLine.arguments[1]).map(\.timestampMilliseconds))
}
'''

resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
with tempfile.TemporaryDirectory(prefix="tcm-lyric-audit-") as directory:
    swift_source = Path(directory) / "main.swift"
    executable = Path(directory) / "lyric-probe"
    swift_source.write_text("import Foundation\n" + parser + main)
    subprocess.run(
        ["xcrun", "swiftc", "-j", "1", "-Onone", str(swift_source), "-o", str(executable)],
        check=True,
        timeout=60,
    )
    normal = subprocess.run([str(executable), "[00:03.100]normal"], capture_output=True, text=True, timeout=10)
    assert normal.returncode == 0 and normal.stdout.strip() == "[3100]", "Normal fixture failed"
    print("Normal fixture: PASS [3100]", flush=True)
    overflow = subprocess.run(
        [str(executable), "[9223372036854775807:00]overflow"],
        capture_output=True, text=True, timeout=10,
    )
    status = signal.Signals(-overflow.returncode).name if overflow.returncode < 0 else str(overflow.returncode)
    print("Oversized timestamp exit:", status, flush=True)
    print("Integer-overflow crash reproduced:", overflow.returncode < 0, flush=True)
    if "--expect-safe" in sys.argv:
        assert overflow.returncode == 0 and overflow.stdout.strip() == "[]", "Malformed lyric timestamp was not rejected safely"
        print("Overflow regression: PASS (malformed line ignored)", flush=True)
    for count in (500, 1500):
        benchmark = subprocess.run(
            [str(executable), "benchmark", str(count)],
            capture_output=True, text=True, timeout=30, check=True,
        )
        print("Synthetic parsing sample:", benchmark.stdout.strip(), flush=True)
