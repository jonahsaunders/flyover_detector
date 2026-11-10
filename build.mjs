import { spawnSync } from 'node:child_process';
import { closeSync, mkdirSync, openSync, readFileSync, readdirSync, rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('.', import.meta.url));
process.chdir(root);
mkdirSync('build', { recursive: true });

function run(program, args, log) {
  console.log(`Running ${program}${log ? ` (${log})` : ''}`);
  const fd = log ? openSync(log, 'w') : null;
  const result = spawnSync(program, args, { stdio: fd === null ? 'inherit' : ['ignore', fd, fd] });
  if (fd !== null) closeSync(fd);
  if (result.error) throw result.error;
  if (result.status !== 0) {
    if (log) console.error(readFileSync(log, 'utf8').split(/\r?\n/).slice(-35).join('\n'));
    throw new Error(`${program} exited with status ${result.status}.`);
  }
}

const rtl = readdirSync('rtl').filter(name => name.endsWith('.v')).sort().map(name => `rtl/${name}`);
run(process.execPath, ['scripts/tables.mjs']);
if (process.argv[2] === 'test') {
  for (const name of readdirSync('sim').filter(name => /^tb_.*\.sv$/.test(name)).sort()) {
    const top = name.slice(0, -3);
    const simulation = `build/${top}.vvp`;
    run('iverilog', ['-g2012', '-s', top, '-o', simulation, ...rtl, 'sim/sdram_model.sv', `sim/${name}`]);
    run('vvp', [simulation]);
  }
} else if (process.argv.length === 2) {
  rmSync('build/flyover-tang-nano-20k.fs', { force: true });
  // Avoid the GW2AR-18C carry-chain miscompute reported in Apicula issue #514.
  run('yosys', ['-Q', '-T', '-p', `read_verilog ${rtl.join(' ')}; synth_gowin -family gw2a -noalu -top flyover_top -json build/synth.json`], 'build/yosys.log');
  run('nextpnr-himbaechel', [
    '--json', 'build/synth.json', '--write', 'build/routed.json', '--report', 'build/timing.json',
    '--device', 'GW2AR-LV18QN88C8/I7', '--vopt', 'family=GW2A-18C',
    '--vopt', 'cst=tangnano20k.cst', '--freq', '49.152',
  ], 'build/nextpnr.log');
  run('gowin_pack', ['-d', 'GW2A-18C', '-o', 'build/flyover-tang-nano-20k.fs', 'build/routed.json'], 'build/pack.log');
  console.log('Built build/flyover-tang-nano-20k.fs');
} else {
  throw new Error('Usage: node build.mjs [test]');
}
