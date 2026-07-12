'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const { createServer, responseFor } = require('../src/server');

test('exposes the required health and metadata contracts', () => {
  assert.deepEqual(responseFor('/healthz').body, { status: 'ok' });
  assert.deepEqual(responseFor('/readyz').body, { status: 'ready' });
  assert.deepEqual(
    responseFor('/metadata', {
      GOLDEN_PATH: 'aks',
      ENVIRONMENT_ID: '018f8f5e-8c4a-7abc-8def-1234567890ab',
      ENVIRONMENT_NAME: 'demo',
      REGION_NAME: 'westeurope',
      SECRET_VALUE: 'must-not-leak',
    }).body,
    {
      service: 'azure-platform-engineering-lab-sample',
      environmentId: '018f8f5e-8c4a-7abc-8def-1234567890ab',
      goldenPath: 'aks',
      environment: 'demo',
      region: 'westeurope',
    },
  );
});

test('serves JSON over HTTP', async (context) => {
  const server = createServer({ GOLDEN_PATH: 'web-app' });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  context.after(() => new Promise((resolve) => server.close(resolve)));
  const { port } = server.address();
  const response = await fetch(`http://127.0.0.1:${port}/healthz`);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { status: 'ok' });
});
