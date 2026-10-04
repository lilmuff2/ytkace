const assert = require('node:assert/strict');
const cases = require('./link_cases.json');
const youtubeAppURL = require('../Extensions/Safari/link.js');
for (const test of cases) assert.equal(youtubeAppURL(test.input), test.output, test.input);
console.log(`Safari: ${cases.length} link cases passed`);
