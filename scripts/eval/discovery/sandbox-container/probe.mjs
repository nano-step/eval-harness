// probe.mjs — runs INSIDE the confinement profile during preflight. It reports the effective
// restrictions as seen by an unprivileged process; the host verifies each claim and fails closed.
// Trusted file (mounted read-only); no dependencies.
import fs from 'node:fs';
import net from 'node:net';
import dns from 'node:dns';

const out = { nodeVersion: process.version, uid: process.getuid(), gid: process.getgid(), env: Object.keys(process.env).sort() };

const status = fs.readFileSync('/proc/self/status', 'utf8');
const field = (name) => (status.match(new RegExp(`^${name}:\\s*(.*)$`, 'm')) || [])[1] || null;
out.capEff = field('CapEff');
out.capBnd = field('CapBnd');
out.noNewPrivs = field('NoNewPrivs');
out.seccomp = field('Seccomp');

function canWrite(file) {
  try { fs.writeFileSync(file, 'x', { flag: 'wx' }); fs.unlinkSync(file); return true; } catch { return false; }
}
out.rootfsWritable = canWrite('/atd-probe-rootfs');
out.workWritable = canWrite('/work/atd-probe-work');
out.depsWritable = fs.existsSync('/deps') ? canWrite('/deps/atd-probe-deps') : null;
out.atdWritable = canWrite('/atd/atd-probe-atd');
out.tmpWritable = canWrite('/tmp/atd-probe-tmp');
out.outWritable = canWrite('/out/atd-probe-out');
out.hostSecrets = ['/root', '/home', '/Users', '/var/run/docker.sock', '/run/docker.sock'].filter((p) => {
  try { fs.accessSync(p, fs.constants.R_OK); return fs.statSync(p).isSocket() || p === '/var/run/docker.sock'; } catch { return false; }
});

try { out.routes = fs.readFileSync('/proc/net/route', 'utf8').trim().split('\n').slice(1).filter(Boolean).length; } catch { out.routes = null; }

function tcp(host, port) {
  return new Promise((resolve) => {
    const sock = net.connect({ host, port, timeout: 2500 });
    sock.once('connect', () => { sock.destroy(); resolve({ connected: true }); });
    sock.once('timeout', () => { sock.destroy(); resolve({ connected: false, error: 'timeout' }); });
    sock.once('error', (e) => { sock.destroy(); resolve({ connected: false, error: e.code || e.message }); });
  });
}
function lookup(name) {
  return new Promise((resolve) => dns.lookup(name, (err, addr) => resolve(err ? { resolved: false, error: err.code } : { resolved: true, address: addr })));
}
out.tcp4 = await tcp('1.1.1.1', 443);
out.tcp6 = await tcp('2606:4700:4700::1111', 443);
out.dns = await lookup('example.com');
out.limits = {};
for (const file of ['/sys/fs/cgroup/memory.max', '/sys/fs/cgroup/pids.max', '/sys/fs/cgroup/memory/memory.limit_in_bytes', '/sys/fs/cgroup/pids/pids.max']) {
  try { out.limits[file] = fs.readFileSync(file, 'utf8').trim(); } catch { /* absent on this cgroup layout */ }
}
process.stdout.write(`${JSON.stringify(out)}\n`);
