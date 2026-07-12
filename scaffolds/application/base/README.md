# __ENVIRONMENT_NAME__

This public repository was generated from the `__GOLDEN_PATH__` golden path by [`__PLATFORM_REPOSITORY__`](https://github.com/__PLATFORM_REPOSITORY__). It is a disposable learning environment, not a production workload.

## Lifecycle

- Environment ID: `__ENVIRONMENT_ID__`
- Expires: `__EXPIRES_AT__`
- Deployment authentication: GitHub Actions OIDC, scoped to the `deployment` environment
- Azure client secrets: none

Pushes to `main` run tests and deploy after the platform sets the non-secret `PLATFORM_READY` repository variable. The platform disables Actions and archives this repository before Azure teardown. It deletes the repository only after two clean Azure-absence checks and immutable repository identity verification.

## Local use

```bash
npm ci
npm test
npm start
curl http://localhost:3000/healthz
```

The service exposes `/`, `/healthz`, `/readyz`, and non-sensitive `/metadata`.

> Public forks and third-party caches cannot be recalled when the platform deletes this repository. Never commit secrets or sensitive data.
