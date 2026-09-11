#!/usr/bin/env node
const fs = require('node:fs');
const args = process.argv.slice(2);
if (JSON.stringify(args) === JSON.stringify(['clients', '-j'])) {
  process.stdout.write(fs.readFileSync(process.env.FIXTURE_CLIENTS));
} else if (JSON.stringify(args) === JSON.stringify(['monitors', '-j'])) {
  console.log(JSON.stringify([{ id: 0, name: 'DP-1', width: 1920, height: 1080, x: 0, y: 0, transform: 0 }]));
} else if (JSON.stringify(args) === JSON.stringify(['version'])) {
  console.log('Hyprland fixture');
} else if (JSON.stringify(args) === JSON.stringify(['getoption', 'general.layout'])) {
  console.log('str: dwindle\nset: true');
} else if (JSON.stringify(args) === JSON.stringify(['-j', 'getoption', 'decoration:rounding'])) {
  console.log(JSON.stringify({ int: 0 }));
} else if (JSON.stringify(args) === JSON.stringify(['-j', 'getoption', 'general:gaps_out'])) {
  console.log(JSON.stringify({ custom: '10 10 10 10' }));
} else {
  fs.appendFileSync(process.env.FIXTURE_UNEXPECTED, JSON.stringify(args) + '\n');
  console.error('Forbidden compositor operation');
  process.exit(99);
}
