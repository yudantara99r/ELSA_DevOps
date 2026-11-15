# CI migration

`ci/legacy.gitlab-ci.yml` stays as the source we migrated from. The replacement is `.github/workflows/quote-api.yml`. It runs on pull requests and on pushes to `main`.

## What changed

| Legacy | Replacement |
| --- | --- |
| Sonar scanner 4.6 with `allow_failure: true` | Semgrep `1.185.0`, ruleset `p/default`, `--error`. A finding fails the job. No Sonar server and no token. |
| `npm test \|\| echo "tests flaky, continuing"` on `node:16` | `python -m unittest` on Python 3.13, the same command the image runs. A failure stops the workflow. |
| `docker:20.10` build, push `:latest` only | `docker build` on the runner, then push `ghcr.io/<owner>/quote-api:<git sha>`. There is no floating `latest` tag. |
| `kubectl set image` from a kubeconfig written to disk, manual, `only: master` | No deploy job. Argo CD syncs `charts/quote-api` from git. Promoting a build is a change to `image.tag` in the chart. |
| `only: master` | `pull_request` plus `push` to `main`. |
| Static `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` in the file | Not copied. The example values were AWS documentation keys, and the new workflow does not call AWS. |

Trivy `0.76.2` scans the built image and exits 1 on a fixable HIGH or CRITICAL finding. That runs before the push, so a failing image is not published. Unfixed findings are reported and do not fail the job: an Alpine CVE with no patched package would otherwise keep `main` red with nothing to upgrade.

Cosign `3.1.4` signs the image digest with GitHub's OIDC token. There is no signing key in the repo or in Actions secrets. The publish job is the only one with `id-token: write` and `packages: write`, and it runs only for a push to `main`. Pull request jobs can run the untrusted head, so they build and scan without a registry token or a signing token.

## Secrets

For a real GitLab to GitHub move:

- `CI_REGISTRY_USER` and `CI_REGISTRY_PASSWORD` become the built-in `GITHUB_TOKEN` with `packages: write` against GHCR. No registry password is stored.
- `SONAR_HOST_URL` and `SONAR_TOKEN` are retired with the Sonar job. Semgrep's public ruleset does not need a token. A Semgrep AppSec Platform org would be a repository secret, not a committed value.
- `KUBECONFIG_CONTENT` is not recreated. Cluster credentials do not belong in CI for this service. If a break-glass job ever needed the cluster, it would use a short-lived token from a GitHub environment with required reviewers, not a kubeconfig checked into a variable.
- `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` are not migrated. A job that needed AWS would use GitHub OIDC (`id-token: write`) and `aws-actions/configure-aws-credentials` with a role ARN. The region would be a variable, not a committed key.
- `AWS_DEFAULT_REGION` is unused and was dropped.
