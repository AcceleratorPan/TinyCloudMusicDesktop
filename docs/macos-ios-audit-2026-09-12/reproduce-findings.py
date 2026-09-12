#!/usr/bin/env python3
"""Isolated probes using current Swift source; never launch the app or read credentials.

Run only while all project builds/tests are stopped. This script compiles one small
Swift program with one job. Source files and fixtures live in its own temp directory.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--expect-fixed", action="store_true", help="Fail if either audited defect remains")
args = parser.parse_args()
ROOT = Path(__file__).resolve().parents[2]
processes = subprocess.check_output(["ps", "-ax", "-o", "pid=,comm="], text=True)
compilers = {"swift", "swiftc", "swift-build", "swift-test", "swift-run",
             "swift-driver", "swift-frontend", "xcodebuild"}
if any(Path(line.split(None, 1)[-1]).name in compilers for line in processes.splitlines()):
    raise SystemExit("Stop: another Swift/Xcode command is active.")
if subprocess.check_output(["sysctl", "-n", "kern.memorystatus_vm_pressure_level"], text=True).strip() != "1":
    raise SystemExit("Stop: memory pressure is not normal.")

models = (ROOT / "Sources/TinyCloudMusic/CloudMusicModels.swift").read_text()
view = (ROOT / "iOS/TinyCloudMusicIOS/UI/LibraryMedia/IOSLibraryView.swift").read_text()
worker = (ROOT / "Sources/TinyCloudMusic/MusicSheetWorker.swift").read_text()

# Extract complete declarations at their original indentation, without rewriting logic.
page = models[models.index("struct CloudSongPage:"):models.index("struct CloudDownloadSource:")]
offset = re.search(r"let offset = reset \? 0 : (.*)", view).group(1)
cloud_start = view.index("struct IOSCloudMusicView")
cloud_end = view.index("private struct IOSCloudSongDetailView", cloud_start)
cloud = view[cloud_start:cloud_end]
size = re.search(r"static let pageSize = (\d+)", cloud).group(1)
next_start = cloud.index("    static func nextOffset(")
next_end = cloud.index("\n    }", next_start) + len("\n    }")
next_offset = cloud[next_start:next_end]
offset = offset.replace("Self.", "CloudProbe.")
assert "replacingInvalidDestination: false" in worker[worker.index("    func savePDF("):worker.index("    func cleanupExpired(")]

def method(name):
    start = worker.index("    private static func " + name + "(")
    end = worker.index("\n    }", start) + len("\n    }")
    return worker[start:end].replace("private static func", "static func", 1)

swift = """import Darwin
import Foundation
struct CloudSong: Equatable, Sendable { let id: Int64 }
""" + page + "\nenum CloudProbe {\n    static let pageSize = " + size + "\n" + next_offset + "\n}\n" + "\nenum SheetProbe {\n" + method("installPDF") + "\n" + method("isValidPDF") + "\n}\n" + """
func fixturePage(_ offset: Int) -> CloudSongPage {
    CloudSongPage(songs: (offset..<(offset + 30)).map { CloudSong(id: Int64($0)) },
                  offset: offset, hasMore: true, totalCount: 300)
}
var page: CloudSongPage? = fixturePage(0)
var offsets = [0]
for _ in 0..<3 {
    let offset = """ + offset + """
    offsets.append(offset)
    page = page!.appending(fixturePage(offset))
}
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let source = root.appending(path: "source.pdf")
let destination = root.appending(path: "user-document.pdf")
// This is a minimal byte fixture accepted by the production file validator,
// not a PDF rendering test. No user files are accessed.
let pdf = Data("%PDF-1.4\\nprobe\\n%%EOF".utf8)
let sentinel = Data("existing user-owned document".utf8)
try pdf.write(to: source)
try sentinel.write(to: destination)
let saved = try SheetProbe.installPDF(at: source, to: destination, maximumBytes: nil, replacingInvalidDestination: false)
let preserved = try Data(contentsOf: destination) == sentinel
let savedBytes = try Data(contentsOf: saved)
precondition(savedBytes == pdf)
print("cloud_offsets=\\(offsets)")
print("cloud_expected_offsets=[0, 30, 60, 90]")
print("existing_sheet_file_preserved=\\(preserved)")
print("sheet_expected_preserved=true")
"""

print(json.dumps({"extracted_source_sha256": hashlib.sha256(swift.encode()).hexdigest(),
                  "note": "Actual merge method, offset expression and PDF installation helpers; UI lifecycle is not exercised."}), flush=True)
with tempfile.TemporaryDirectory(prefix="tcm-audit-probes-") as directory:
    temporary = Path(directory)
    source = temporary / "main.swift"
    binary = temporary / "probe"
    source.write_text(swift)
    subprocess.run(["swiftc", "-j", "1", "-disable-batch-mode", str(source), "-o", str(binary)], check=True)
    result = subprocess.run([str(binary), str(temporary)], check=True, capture_output=True, text=True)
    print(result.stdout, end="")
    if args.expect_fixed:
        if "cloud_offsets=[0, 30, 60, 90]" not in result.stdout or "existing_sheet_file_preserved=true" not in result.stdout:
            raise SystemExit("Audit regression failed")
        print("Audit regressions passed")
