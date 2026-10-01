#!/usr/bin/env python3
"""End-to-end app-owned sessions. Only disposable fixture profiles and processes."""
import concurrent.futures
import hashlib
import http.server
import threading
import integration
import json
import os
from pathlib import Path
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
APP = Path(os.environ.get('MCP_BRIDGE_APP', ROOT / '.build/debug/MCPBridgeApp'))
CLI = Path(os.environ.get('MCP_BRIDGE_CLI', ROOT / '.build/debug/mcp-bridge'))

class PersistentTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='bridge-session-')
        self.root = Path(self.tmp.name).resolve()
        self.profile = self.root / 'profile.json'
        self.pidfile = self.root / 'pid.json'
        self.counter = self.root / 'calls.txt'
        self.server = {'id':'fixture','transport':'stdio','command':sys.executable,
            'arguments':[str(ROOT/'Tests/Fixtures/server.py'),'--pid-file',str(self.pidfile),'--counter-file',str(self.counter), '--tools-ready-after','0.1'],
            'keepConnected':True}
        self.save()
        key = hashlib.sha256(str(self.profile).encode()).hexdigest()[:32]
        self.socket = Path('/tmp/mcp-bridge-%d' % os.geteuid()) / (key + '.sock')
        existing_sockets=set(Path('/tmp/mcp-bridge-%d' % os.geteuid()).glob('*.sock'))
        self.app_log = (self.root/'app.log').open('w')
        self.app = subprocess.Popen([str(APP),'--config',str(self.profile)], stdout=self.app_log, stderr=self.app_log)
        for _ in range(200):
            new_sockets=set(Path('/tmp/mcp-bridge-%d' % os.geteuid()).glob('*.sock'))-existing_sockets
            if new_sockets and self.pidfile.exists():
                self.socket=next(iter(new_sockets)); break
            if self.app.poll() is not None: self.fail('App exited during startup')
            time.sleep(0.025)
        self.assertTrue(self.pidfile.exists(), 'Persistent fixture was not launched')
        self.pid = json.loads(self.pidfile.read_text())['pid']
        self.run_cli('server','test','fixture','--session')

    def save(self):
        self.profile.write_text(json.dumps({'version':1,'servers':[self.server]}))

    def tearDown(self):
        if hasattr(self,'app') and self.app.poll() is None:
            self.app.terminate()
            try: self.app.wait(timeout=8)
            except subprocess.TimeoutExpired:
                self.app.kill(); self.app.wait(); self.fail('App did not finish shutdown')
        if self.pidfile.exists():
            pid = json.loads(self.pidfile.read_text())['pid']
            try: os.kill(pid, signal.SIGKILL)
            except ProcessLookupError: pass
        self.app_log.close()
        self.tmp.cleanup()

    def run_cli(self,*args,code=0,input=None):
        p=subprocess.run([str(CLI),'--config',str(self.profile),*args],input=input,text=True,capture_output=True,timeout=10)
        self.assertEqual(p.returncode,code,p.stdout+p.stderr)
        return json.loads(p.stdout)

    def call(self,tool='structured',args=None,code=0,extra=()):
        return self.run_cli('call','fixture',tool,'--stdin',*extra,code=code,input=json.dumps(args or {}))

    def dead(self):
        for _ in range(100):
            try: os.kill(self.pid,0)
            except ProcessLookupError: return
            time.sleep(0.02)
        self.fail('Owned server was not reaped')

    def test_reuses_one_process_and_no_tcp(self):
        result=self.run_cli('tools','list','fixture','--live','--session')
        self.assertEqual(len(result['result']['tools']),8)
        self.assertEqual(result['catalog']['source'],'live')
        for text in ['hello 世界 🌉','second call']:
            self.assertEqual(self.call(args={'text':text})['result']['structuredContent']['echo']['text'],text)
            self.assertEqual(json.loads(self.pidfile.read_text())['pid'],self.pid)
            os.kill(self.pid,0)
        self.assertEqual(self.counter.read_text().splitlines(),['call','call'])
        self.assertEqual(stat.S_IMODE(self.socket.stat().st_mode),0o600)
        self.assertEqual(stat.S_IMODE(self.socket.parent.stat().st_mode),0o700)
        p=subprocess.run(['/usr/sbin/lsof','-nP','-a','-p',str(self.app.pid),'-iTCP','-sTCP:LISTEN'],capture_output=True,text=True)
        self.assertEqual(p.returncode,1,p.stdout+p.stderr)
        self.call('image')
        self.call('fail',code=4)
        self.call() # MCP tool-error indicator does not break the connection.

    def test_concurrent_calls_are_serialized(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            results=list(pool.map(lambda i:self.call(args={'n':i}),range(8)))
        self.assertEqual([r['result']['structuredContent']['echo']['n'] for r in results],list(range(8)))
        self.assertEqual(len(self.counter.read_text().splitlines()),8)
        self.assertEqual(json.loads(self.pidfile.read_text())['pid'],self.pid)

    def test_timeout_closes_session_and_never_replays(self):
        self.call('slow',{'seconds':5},code=5,extra=('--timeout','0.15'))
        self.dead()
        self.assertEqual(self.counter.read_text().splitlines(),['call'])
        self.call(code=3)
        self.assertEqual(self.counter.read_text().splitlines(),['call'])

    def test_queued_timeout_does_not_cancel_active_call(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            active=pool.submit(self.call,'slow',{'seconds':0.6})
            for _ in range(100):
                if self.counter.exists():break
                time.sleep(0.01)
            self.call(code=5,extra=('--timeout','0.1'))
            self.assertTrue(active.result()['ok'])
        self.call()
        self.assertEqual(self.counter.read_text().splitlines(),['call','call'])

    def test_stale_socket_recovered_after_app_crash(self):
        self.app.kill();self.app.wait()
        self.assertTrue(self.socket.exists())
        self.app=subprocess.Popen([str(APP),'--config',str(self.profile)],stdout=self.app_log,stderr=self.app_log)
        for _ in range(200):
            if json.loads(self.pidfile.read_text())['pid'] != self.pid:break
            time.sleep(0.02)
        self.assertNotEqual(json.loads(self.pidfile.read_text())['pid'],self.pid)
        self.pid=json.loads(self.pidfile.read_text())['pid']
        self.call()

    def test_cancel_closes_active_request(self):
        p=subprocess.Popen([str(CLI),'--config',str(self.profile),'call','fixture','slow','--stdin'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            p.stdin.write('{"seconds":5}');p.stdin.close();p.stdin=None
            for _ in range(100):
                if self.counter.exists():break
                time.sleep(0.02)
            self.assertTrue(self.counter.exists())
            p.send_signal(signal.SIGINT)
            stdout,stderr=p.communicate(timeout=5)
            self.assertEqual(p.returncode,3,stdout+stderr)
            json.loads(stdout)
            self.dead()
            self.assertEqual(self.counter.read_text().splitlines(),['call'])
        finally:
            if p.poll() is None:p.kill()
            p.communicate()

    def test_quit_cleans_socket_and_process_no_fallback(self):
        self.app.terminate();self.app.wait(timeout=8)
        self.dead()
        self.assertFalse(self.socket.exists())
        self.call(code=3)
        self.assertFalse(self.counter.exists())
        self.call(extra=('--direct',))

    def test_configuration_change_is_rejected(self):
        self.server['arguments'] += ['--no-list-notification']
        self.save()
        self.call(code=3)
        self.assertFalse(self.counter.exists())
        self.server['enabled']=False;self.save()
        self.call(code=2)

    def test_http_session_reused_until_app_quits(self):
        self.app.terminate();self.app.wait(timeout=8)
        self.dead()
        class Handler(integration.Handler):
            deletes=0
        http_fixture=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
        thread=threading.Thread(target=http_fixture.serve_forever,daemon=True);thread.start()
        original=integration.fixture.response
        methods=[]
        def record(request):
            methods.append(request.get('method'))
            return original(request)
        integration.fixture.response=record
        try:
            self.server={'id':'fixture','transport':'http','url':'http://127.0.0.1:%d/mcp'%http_fixture.server_port,'keepConnected':True}
            self.save()
            self.app=subprocess.Popen([str(APP),'--config',str(self.profile)],stdout=self.app_log,stderr=self.app_log)
            for _ in range(200):
                if 'notifications/initialized' in methods:break
                time.sleep(0.02)
            self.run_cli('tools','list','fixture','--live')
            self.call();self.call()
            self.assertEqual(methods.count('initialize'),1)
            self.assertEqual(methods.count('tools/call'),2)
            self.assertEqual(Handler.deletes,0)
            self.app.terminate();self.app.wait(timeout=8)
            self.assertEqual(Handler.deletes,1)
        finally:
            integration.fixture.response=original
            http_fixture.shutdown();http_fixture.server_close()

    def test_malformed_ipc_does_not_execute(self):
        with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as client:
            client.connect(str(self.socket))
            client.sendall((100_000_000).to_bytes(4,'big'))
            client.settimeout(2)
            self.assertEqual(client.recv(1),b'')
        self.assertFalse(self.counter.exists())
        self.call()

    def test_unexpected_server_exit_requires_reconnect(self):
        self.call('exit',code=3)
        self.dead()
        self.call(code=3)
        self.assertEqual(self.counter.read_text().splitlines(),['call'])

if __name__=='__main__':unittest.main(verbosity=2)
