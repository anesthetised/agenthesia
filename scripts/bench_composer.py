#!/usr/bin/env python3
"""Measure 500 hosted draft updates with three attachments in three fresh processes."""

import argparse
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent
SOURCES = Path("Packages/AgenthesiaKit/Sources/AgenthesiaUI")
HARNESS = r'''
import AppKit
import SwiftUI

@main struct ComposerBenchmark {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let directory = URL(filePath: CommandLine.arguments[1])
        let attachments = ["first.swift", "second.txt", "third.json"].map { directory.appending(path: $0) }
        for url in attachments { try Data("attachment".utf8).write(to: url) }
        func composer(_ text: String) -> ComposerInput {
            ComposerInput(text: .constant(text), attachments: .constant(attachments),
                          commands: [], isEnabled: true, onSubmit: {})
        }
        let hosting = NSHostingView(rootView: composer("Warm up"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 180),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for index in 0..<500 {
                hosting.rootView = composer("Message \(index)")
                hosting.layoutSubtreeIfNeeded()
            }
        }
        print(elapsed)
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", help="Read composer sources from this Git revision instead of the working tree")
    args = parser.parse_args()
    products = ROOT / "Packages/AgenthesiaKit/.build/debug"
    with tempfile.TemporaryDirectory(prefix="agenthesia-composer-bench-") as temporary:
        directory = Path(temporary)
        sources = []
        for name in ("Composer.swift", "AttachmentChip.swift"):
            path = SOURCES / name
            if args.revision:
                result = subprocess.run(
                    ["git", "show", f"{args.revision}:{path}"], cwd=ROOT, capture_output=True, text=True
                )
                if result.returncode:
                    if name == "AttachmentChip.swift":
                        continue
                    raise RuntimeError(result.stderr)
                source = result.stdout
            else:
                source = (ROOT / path).read_text()
            target = directory / name
            target.write_text(source)
            sources.append(str(target))
        harness = directory / "Benchmark.swift"
        harness.write_text(HARNESS)
        executable = directory / "composer-bench"
        subprocess.run(
            ["swiftc", "-O", "-parse-as-library", "-swift-version", "6", "-default-isolation", "MainActor",
             "-target", "arm64-apple-macosx26.0", "-I", str(products), *sources, str(harness),
             str(products / "ACP.o"), str(products / "JSONRPC.o"), "-o", str(executable)],
            cwd=ROOT, check=True,
        )
        for run in range(1, 4):
            result = subprocess.run([str(executable), str(directory)], check=True, capture_output=True, text=True)
            print(f"Run {run}/3 ({args.revision or 'working tree'}): {result.stdout.strip()}", flush=True)


if __name__ == "__main__":
    main()
