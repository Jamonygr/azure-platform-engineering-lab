'use strict';

const http = require('node:http');

const jsonHeaders = Object.freeze({
  'cache-control': 'no-store',
  'content-type': 'application/json; charset=utf-8',
  'x-content-type-options': 'nosniff',
});

function responseFor(pathname, environment = process.env) {
  switch (pathname) {
    case '/':
      return {
        statusCode: 200,
        body: {
          message: 'Azure Platform Engineering Lab',
          goldenPath: environment.GOLDEN_PATH || 'unknown',
        },
      };
    case '/healthz':
      return { statusCode: 200, body: { status: 'ok' } };
    case '/readyz':
      return { statusCode: 200, body: { status: 'ready' } };
    case '/metadata':
      return {
        statusCode: 200,
        body: {
          service: 'azure-platform-engineering-lab-sample',
          environmentId: environment.ENVIRONMENT_ID || 'unknown',
          goldenPath: environment.GOLDEN_PATH || 'unknown',
          environment: environment.ENVIRONMENT_NAME || 'unknown',
          region: environment.REGION_NAME || 'unknown',
        },
      };
    default:
      return { statusCode: 404, body: { error: 'not_found' } };
  }
}

function createServer(environment = process.env) {
  return http.createServer((request, response) => {
    const pathname = new URL(request.url, 'http://localhost').pathname;
    const result = responseFor(pathname, environment);
    response.writeHead(result.statusCode, jsonHeaders);
    response.end(`${JSON.stringify(result.body)}\n`);
  });
}

if (require.main === module) {
  const port = Number.parseInt(process.env.PORT || '3000', 10);
  const server = createServer();
  server.listen(port, '0.0.0.0', () => {
    process.stdout.write(`sample listening on ${port}\n`);
  });

  for (const signal of ['SIGINT', 'SIGTERM']) {
    process.on(signal, () => server.close(() => process.exit(0)));
  }
}

module.exports = { createServer, responseFor };
