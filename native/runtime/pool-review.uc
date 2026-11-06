'use strict';

import { readfile } from 'fs';
const pool = require('native_pool');
if (length(ARGV) != 1) die('usage: ucode -L payload pool-review.uc private-inventory.json\n');
const raw = readfile(ARGV[0], 2097153);
if (!raw || length(raw) > 2097152) die('missing or oversized native inventory\n');
const request = json(raw);
printf('%J\n', pool.select(request.candidates, request.inventory, request.required));
