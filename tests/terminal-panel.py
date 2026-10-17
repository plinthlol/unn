#!/usr/bin/env python3
"""A window narrower than the terminal's grid needs still gives way: the grid keeps sane rows and
columns at high scale, without a runaway allocation (the negative-width relics once reached
268 million columns a second). The terminal takes the whole window now, so the grid is the one
thing this guards."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
# the binary under test: build/unn from this tree, or whatever UNN_TEST_EXE points at
EXE = Path(os.environ.get('UNN_TEST_EXE', ROOT / 'build/unn')).resolve()


class TerminalPanel(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='unn-terminal-panel-')
        self.home = Path(self.tmp.name).resolve()
        self.project = self.home / 'project'
        self.project.mkdir()
        (self.project / 'long.txt').write_text(
            ''.join(f'line {i:04d}\n' for i in range(1, 2001)), encoding='utf-8')
        self.env = dict(os.environ, HOME=self.home.as_posix(),
                        XDG_CONFIG_HOME=(self.home / 'config').as_posix(),
                        XDG_STATE_HOME=(self.home / 'state').as_posix())
        self.config = self.home / 'config/unn/config'
        self.config.parent.mkdir(parents=True)

    def tearDown(self):
        for _ in range(50):
            try:
                self.tmp.cleanup()
                return
            except OSError:
                time.sleep(0.2)
        self.tmp.cleanup()

    def test_a_window_narrower_than_its_panels(self):
        self.config.write_text(
            '[terminal]\nshell = /bin/sh\n', encoding='utf-8')
        script = self.home / 'commands.rsc'
        script.write_text('\n'.join(['wait 200',
                                     'type echo R$((1+1))X $(stty size)', 'key Return', 'wait-term R2X',
                                     'print-term', 'print-state', 'quit']) + '\n', encoding='utf-8')
        out_path = self.home / 'out.txt'
        self.script = script

        def limits():
            # the child gets 30 s CPU and 2 GiB address space, so if the runaway grid
            # allocation comes back it dies here instead of eating the machine
            import resource
            resource.setrlimit(resource.RLIMIT_CPU, (30, 30))
            resource.setrlimit(resource.RLIMIT_AS, (2 << 30, 2 << 30))

        def rss_mb(pid):
            # peak RSS straight from /proc when readable, else via ps
            try:
                for line in Path(f'/proc/{pid}/status').read_text().splitlines():
                    if line.startswith('VmRSS:'):
                        return int(line.split()[1]) // 1024
            except OSError:
                pass
            ps = subprocess.run(['ps', '-o', 'rss=', '-p', str(pid)], capture_output=True, text=True)
            return int(ps.stdout.strip() or 0) // 1024

        with open(out_path, 'wb') as out:
            proc = subprocess.Popen([str(EXE), str(self.project), '--headless', '1000x600', '--scale', '2',
                                     '--script', str(script)], env=self.env, stdout=out,
                                    stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, preexec_fn=limits)
            peak = 0
            # watch the child the whole way: kill it if RSS passes 500 MB or it hangs
            # 30 s, either of which means the bug is back
            deadline = time.monotonic() + 30
            while proc.poll() is None:
                peak = max(peak, rss_mb(proc.pid))
                if peak > 500 or time.monotonic() > deadline:
                    proc.kill()
                    proc.wait()
                    break
                time.sleep(0.05)
        output = out_path.read_text(encoding='utf-8', errors='replace')
        self.assertLess(peak, 500, output[-2000:])
        self.assertEqual(proc.returncode, 0, output[-2000:])
        self.assertIn('theme=unn term=1', output)
        size = re.search(r'R2X (\d+) (\d+)', output)
        self.assertIsNotNone(size, output[-2000:])
        rows, cols = int(size.group(1)), int(size.group(2))
        self.assertGreaterEqual(rows, 2)
        # the grid spans the 1000 px window (500 pt at scale 2): about its width divided by
        # a normal cell width, never a runaway
        self.assertTrue(40 <= cols <= 90, cols)


if __name__ == '__main__':
    unittest.main(verbosity=2)
