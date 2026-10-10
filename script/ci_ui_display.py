"""Prepare a measured desktop for real macOS UI clicks, without installing tools."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

MIN_WIDTH = 1600
MIN_HEIGHT = 1000
VMWARE_TOOL = Path('/Library/Application Support/VMware Tools/vmware-resolutionSet')

# CGDisplayBounds is the desktop coordinate space used by UI hit testing.
# Mode width/height, rather than pixelWidth/pixelHeight, avoids counting Retina
# backing pixels as extra space for a window.
NATIVE_SOURCE = r'''
import CoreGraphics
import Foundation

let display = CGMainDisplayID()
let modes = (CGDisplayCopyAllDisplayModes(display, nil) as? [CGDisplayMode]) ?? []
if CommandLine.arguments.count == 2 {
    guard let requested = Int32(CommandLine.arguments[1]),
          let mode = modes.first(where: { $0.ioDisplayModeID == requested }) else {
        fputs("Requested display mode is unavailable.\n", stderr)
        exit(1)
    }
    var configuration: CGDisplayConfigRef?
    let beginError = CGBeginDisplayConfiguration(&configuration)
    guard beginError == .success, let configuration else {
        fputs("CGBeginDisplayConfiguration failed: \(beginError.rawValue)\n", stderr)
        exit(1)
    }
    let configureError = CGConfigureDisplayWithDisplayMode(configuration, display, mode, nil)
    guard configureError == .success else {
        CGCancelDisplayConfiguration(configuration)
        fputs("CGConfigureDisplayWithDisplayMode failed: \(configureError.rawValue)\n", stderr)
        exit(1)
    }
    // Session scope survives this helper's exit without changing saved settings.
    let completeError = CGCompleteDisplayConfiguration(configuration, .forSession)
    guard completeError == .success else {
        fputs("CGCompleteDisplayConfiguration failed: \(completeError.rawValue)\n", stderr)
        exit(1)
    }
    let deadline = ProcessInfo.processInfo.systemUptime + 8
    while ProcessInfo.processInfo.systemUptime < deadline {
        let bounds = CGDisplayBounds(display)
        if bounds.width >= 1600 && bounds.height >= 1000 { break }
        Thread.sleep(forTimeInterval: 0.1)
    }
}
let bounds = CGDisplayBounds(display)
let result: [String: Any] = [
    "width": bounds.width, "height": bounds.height,
    "modes": modes.map { mode -> [String: Any] in
        ["id": mode.ioDisplayModeID, "width": mode.width, "height": mode.height,
         "pixelWidth": mode.pixelWidth, "pixelHeight": mode.pixelHeight]
    }
]
let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
'''


def adequate(viewport):
    return viewport['width'] >= MIN_WIDTH and viewport['height'] >= MIN_HEIGHT


def select_mode(modes):
    eligible = [mode for mode in modes if adequate(mode)]
    return min(eligible, key=lambda mode: (
        mode['width'] * mode['height'], mode['width'], mode['height'],
        mode['pixelWidth'] * mode['pixelHeight'], mode['id'],
    ), default=None)


class NativeDisplay:
    def __init__(self, directory):
        self.source = Path(directory) / 'display.swift'
        self.source.write_text(NATIVE_SOURCE)

    def _run(self, *arguments):
        result = subprocess.run(
            ['xcrun', 'swift', str(self.source), *arguments],
            capture_output=True, text=True, timeout=30,
        )
        if result.returncode:
            raise RuntimeError(f'Display probe failed: {result.stderr.strip()}')
        return json.loads(result.stdout)

    def probe(self):
        return self._run()

    def apply(self, mode):
        return self._run(str(mode['id']))


def prepare_display(display, tool=VMWARE_TOOL, run=subprocess.run, sleep=time.sleep):
    before = display.probe()
    if adequate(before):
        return {'method': 'already adequate', 'before': before, 'after': before}
    mode = select_mode(before['modes'])
    mode_error = None
    if mode is not None:
        try:
            display.apply(mode)
            # Probe from a new process after the mode-setting process has exited.
            after = display.probe()
            if adequate(after):
                return {'method': 'CoreGraphics', 'before': before, 'after': after}
        except RuntimeError as error:
            mode_error = str(error)
    # Hosted VMware images can expose only their current mode until their
    # bundled resolution tool creates the requested mode. Never download it.
    if tool.is_file() and os.access(tool, os.X_OK):
        result = run([str(tool), str(MIN_WIDTH), str(MIN_HEIGHT)],
                     capture_output=True, text=True, timeout=30)
        if result.returncode:
            raise RuntimeError(f'Bundled display tool failed: {result.stderr.strip()}')
        sleep(2)
        after = display.probe()
        if adequate(after):
            return {'method': 'bundled VMware tool', 'before': before, 'after': after}
    raise RuntimeError(
        f'UI tests require a measured {MIN_WIDTH}x{MIN_HEIGHT} desktop; '
        f'initial viewport was {before["width"]}x{before["height"]}. '
        f'No supported display change produced that viewport. Mode error: {mode_error}'
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inspect', action='store_true', help='Read display bounds and modes without changing them.')
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('This display helper requires macOS.')
    if not args.inspect and os.environ.get('GITHUB_ACTIONS') != 'true':
        parser.error('Display changes are restricted to GitHub Actions; use --inspect locally.')
    with tempfile.TemporaryDirectory(prefix='intents-ci-display-') as directory:
        display = NativeDisplay(directory)
        result = display.probe() if args.inspect else prepare_display(display)
        print(json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
