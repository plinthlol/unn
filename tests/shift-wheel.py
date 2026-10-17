#!/usr/bin/env python3
"""Shift turns the wheel sideways (discussion 67); the terminal keeps Shift's wheel for its
scrollback instead of scrolling x."""
import hashlib
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
# the binary under test: build/unn from this tree, or whatever UNN_TEST_EXE points at
EXE = Path(os.environ.get('UNN_TEST_EXE', ROOT / 'build/unn')).resolve()


class ShiftWheel(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='unn-shift-wheel-', dir='/tmp')
        self.work = Path(self.tmp.name).resolve()
        self.project = self.work / 'project'
        self.project.mkdir()
        lines = [f'line {i:02d} ' + 'wide ' * 60 for i in range(80)]
        (self.project / 'wide.txt').write_text('\n'.join(lines) + '\n', encoding='utf-8')
        self.env = dict(os.environ, HOME=str(self.work), SHELL='/bin/sh',
                        PS1='$ ', ENV='', HISTFILE='/dev/null')
        self.process = self.client = self.reader = None

    def tearDown(self):
        if self.process is not None:
            if self.process.poll() is None:
                self.process.terminate()
                self.process.wait(timeout=10)
            self.reader.close()
            self.client.close()
            self.process.stderr.close()
        # the shell goes on a moment after unn and can still write in its home folder
        for _ in range(50):
            try:
                self.tmp.cleanup()
                return
            except OSError:
                time.sleep(0.1)
        self.tmp.cleanup()

    def start(self, *paths):
        # unn headless with a --control socket; the client connects as soon as the socket
        # file appears, bailing when unn dies or the deadline passes
        control = self.work / 'control'
        self.process = subprocess.Popen([str(EXE), str(self.project), *map(str, paths),
                                         '--headless', '1280x800', '--scale', '1',
                                         '--control', str(control)], env=self.env,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self.client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.client.settimeout(15)
        deadline = time.monotonic() + 10
        while True:
            try:
                self.client.connect(str(control))
                break
            except (FileNotFoundError, ConnectionRefusedError):
                if self.process.poll() is not None or time.monotonic() > deadline:
                    self.fail('editor did not start')
                time.sleep(0.01)
        self.reader = self.client.makefile('r', encoding='utf-8')
        self.command('wait 100')

    def command(self, line):
        # the control protocol: one command per line, replies streamed until a bare 'ok'
        self.client.sendall((line + '\n').encode('utf-8'))
        output = []
        while True:
            reply = self.reader.readline()
            if reply == 'ok\n':
                return ''.join(output)
            self.assertNotIn(reply, ('', 'error\n'), line)
            output.append(reply)

    def shot(self):
        # screenshots are compared by sha256, so a hash pins a whole frame without
        # keeping pixels around
        path = self.work / 'shot.ppm'
        self.command(f'shot {path}')
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def test_the_terminal_keeps_shift_for_its_scrollback(self):
        # 80 lines of 60 "wide "s: anything wider than the viewport so plain wheel
        # scrolls x, and Shift's wheel can scroll the terminal's y
        self.start()
        self.command('type seq 1 300; echo done$((1000 + 1))')
        self.command('key Return')
        self.command('wait-term done1001')
        x, y = self.command('print-term-cell 1 4').split()
        self.command(f'move {x} {y}')
        # print-term shows the live screen: the scrollback shows in pictures, taken once the thumb's
        # flash after a scroll (or after output, when frames saw the scrollback grow) has passed
        self.command('wait 900')
        bottom = self.shot()
        self.command('scroll -200 shift')
        up = self.shot()
        self.assertNotEqual(up, bottom)
        # the same as the wheel without Shift
        self.command('scroll 2000')
        self.command('wait 900')
        self.assertEqual(self.shot(), bottom)
        self.command('scroll -200')
        self.assertEqual(self.shot(), up)
