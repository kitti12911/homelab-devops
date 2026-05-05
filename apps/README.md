# Application CI/CD Guidelines

This document defines the default CI/CD standard for application repositories in
this homelab. Start from these examples, then trim jobs that do not apply to the
project.

## Core Rules

- Pin every third-party GitHub Action by full commit SHA.
- Add a readable comment above each pinned action with the resolved version.
- Use `paths` filters so workflows run only when relevant files change.
- Pin tool versions in CI. Avoid `latest`, `master`, and floating major tags.
- Keep security checks fast enough for pull requests.
- Use Renovate to update pinned actions and dependency lockfiles.
- Put workflow and tool config files under CODEOWNERS review.

## Stack Coverage

| Stack      | Lint              | Type Check | Tests          | Security           |
| ---------- | ----------------- | ---------- | -------------- | ------------------ |
| Go         | golangci-lint     | go vet     | go test -race  | govulncheck, Trivy |
| TypeScript | ESLint or oxlint  | tsc        | Vitest or Jest | OSV, Trivy, Socket |
| Markdown   | markdownlint-cli2 | n/a        | n/a            | CODEOWNERS         |
| Shared     | Gitleaks, Semgrep | n/a        | optional smoke | Renovate           |

## Action Pins

Resolve action SHAs again when creating a real workflow. These were current when
this document was written.

- `actions/checkout` v6.0.2:
  `de0fac2e4500dabe0009e67214ff5f5447ce83dd`
- `actions/setup-go` v6.4.0:
  `4a3601121dd01d1626a1e23e37211e3254c1c06c`
- `actions/setup-node` v6.4.0:
  `48b55a011bda9f5d6aeb4c2d9c7362e8dae4041e`
- `golangci/golangci-lint-action` v9.2.0:
  `1e7e51e771db61008b38414a730f564565cf7c20`
- `codecov/codecov-action` v6.0.0:
  `57e3a136b779b570ffcdbf80b3bdc90e7fab3de2`
- `aquasecurity/trivy-action` v0.36.0:
  `a9c7b0f06e461e9d4b4d1711f154ee024b8d7ab8`
- `gitleaks/gitleaks-action` v2.3.9:
  `ff98106e4c7b2bc287b24eaf42907196329070c7`
- `sigstore/cosign-installer` v4.1.1:
  `cad07c2e89fa2edd6e2d7bab4c1aa38e53f76003`
- `docker/setup-buildx-action` v3.11.1:
  `e468171a9de216ec08956ac3ada2f0791b6bd435`
- `docker/build-push-action` v6.18.0:
  `263435318d21b8e681c14492fe198d362a7d2c83`
- `docker/login-action` v4.1.0:
  `4907a6ddec9925e35a0a9e82d7399ccc52663121`
- `bufbuild/buf-action` v1.4.0:
  `fd21066df7214747548607aaa45548ba2b9bc1ff`
- `googleapis/release-please-action` v5.0.0:
  `45996ed1f6d02564a971a2fa1b5860e934307cf7`
- `google/osv-scanner-action` v2.3.5:
  `c51854704019a247608d928f370c98740469d4b5`
- `DavidAnson/markdownlint-cli2-action` v23.1.0:
  `6b51ade7a9e4a75a7ad929842dd298a3804ebe8b`

## Pipeline Stages

```text
Pull request  -> lint -> test -> security
Main branch   -> build -> container scan -> release/deploy
Scheduled     -> Renovate dependency updates
```

## Go Pipeline

### Go Workflow

Use this for Go services and libraries. Remove the Docker build job for pure
libraries.

```yaml
name: Go CI

on:
    push:
        branches:
            - main
        paths:
            - ".github/workflows/go-ci.yml"
            - ".golangci.yml"
            - "Dockerfile"
            - "Makefile"
            - "go.mod"
            - "go.sum"
            - "**/*.go"
    pull_request:
        paths:
            - ".github/workflows/go-ci.yml"
            - ".golangci.yml"
            - "Dockerfile"
            - "Makefile"
            - "go.mod"
            - "go.sum"
            - "**/*.go"

permissions:
    contents: read

jobs:
    lint:
        name: Lint
        runs-on: ubuntu-latest
        steps:
            # actions/checkout v6.0.2
            - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd

            # actions/setup-go v6.4.0
            - uses: actions/setup-go@4a3601121dd01d1626a1e23e37211e3254c1c06c
              with:
                  go-version-file: go.mod
                  cache: true

            - name: Go vet
              run: go vet ./...

            # golangci/golangci-lint-action v9.2.0
            - uses: golangci/golangci-lint-action@1e7e51e771db61008b38414a730f564565cf7c20
              with:
                  version: v2.12.1
                  args: --timeout=5m

    test:
        name: Test
        runs-on: ubuntu-latest
        steps:
            # actions/checkout v6.0.2
            - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd

            # actions/setup-go v6.4.0
            - uses: actions/setup-go@4a3601121dd01d1626a1e23e37211e3254c1c06c
              with:
                  go-version-file: go.mod
                  cache: true

            - name: Test with race detector and coverage
              run: go test -race -coverprofile=coverage.out -covermode=atomic ./...

            # codecov/codecov-action v6.0.0
            - uses: codecov/codecov-action@57e3a136b779b570ffcdbf80b3bdc90e7fab3de2
              with:
                  files: coverage.out
                  token: ${{ secrets.CODECOV_TOKEN }}

    security:
        name: Security
        runs-on: ubuntu-latest
        steps:
            # actions/checkout v6.0.2
            - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd
              with:
                  fetch-depth: 0

            # actions/setup-go v6.4.0
            - uses: actions/setup-go@4a3601121dd01d1626a1e23e37211e3254c1c06c
              with:
                  go-version-file: go.mod
                  cache: true

            - name: govulncheck
              run: |
                  go install golang.org/x/vuln/cmd/govulncheck@v1.3.0
                  govulncheck ./...

            # aquasecurity/trivy-action v0.36.0
            - uses: aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25
              with:
                  scan-type: fs
                  scan-ref: .
                  scanners: vuln,secret,misconfig
                  exit-code: 1
                  severity: CRITICAL,HIGH
                  ignore-unfixed: true

            # gitleaks/gitleaks-action v2.3.9
            - uses: gitleaks/gitleaks-action@ff98106e4c7b2bc287b24eaf42907196329070c7
              env:
                  GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

            - name: Semgrep
              run: |
                  python3 -m pip install --user semgrep==1.161.0
                  ~/.local/bin/semgrep scan --config=p/golang --config=p/secrets --error

    build:
        name: Build and Container Scan
        runs-on: ubuntu-latest
        needs:
            - lint
            - test
            - security
        if: github.ref == 'refs/heads/main'
        steps:
            # actions/checkout v6.0.2
            - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd

            - name: Build Docker image
              run: docker build -t ${{ github.repository }}:${{ github.sha }} .

            # aquasecurity/trivy-action v0.36.0
            - uses: aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25
              with:
                  image-ref: ${{ github.repository }}:${{ github.sha }}
                  format: table
                  exit-code: 1
                  severity: CRITICAL,HIGH
```

### Recommended `.golangci.yml`

This uses golangci-lint v2 config format.

```yaml
version: "2"

run:
    timeout: 5m

linters:
    enable:
        - bodyclose
        - cyclop
        - errcheck
        - errorlint
        - exhaustive
        - gocritic
        - godot
        - gosec
        - govet
        - ineffassign
        - misspell
        - nilerr
        - noctx
        - prealloc
        - revive
        - sqlclosecheck
        - staticcheck
        - unconvert
        - unparam
        - unused
        - wrapcheck

    settings:
        cyclop:
            max-complexity: 15
            skip-tests: true

        exhaustive:
            default-signifies-exhaustive: true

        gocritic:
            enabled-tags:
                - diagnostic
                - performance
                - style
            disabled-checks:
                - hugeParam
                - rangeValCopy

        gosec:
            excludes:
                - G404

        govet:
            enable-all: true

        misspell:
            locale: US

        revive:
            rules:
                - name: exported
                  arguments:
                      - disableStutteringCheck
                - name: var-naming
                - name: blank-imports
                - name: context-as-argument
                - name: error-return
                - name: error-strings
                - name: increment-decrement
                - name: range
                - name: receiver-naming
                - name: unused-parameter
                  disabled: true

        unparam:
            check-exported: false

        wrapcheck:
            ignore-package-globs:
                - google.golang.org/grpc/status
            ignore-sigs:
                - .Errorf(
                - errors.New(
                - errors.Unwrap(
                - errors.Join(
                - .Wrap(
                - .Wrapf(
                - .WithMessage(
                - .WithMessagef(
                - .WithStack(

    exclusions:
        generated: lax
        presets:
            - comments
            - common-false-positives
            - legacy
            - std-error-handling
        rules:
            - path: \.pb\.go$
              linters:
                  - cyclop
                  - exhaustive
                  - gocritic
                  - godot
                  - revive
                  - wrapcheck
            - path: graph/generated/.*\.go$
              linters:
                  - cyclop
                  - gocritic
                  - godot
                  - wrapcheck
            - path: _test\.go$
              linters:
                  - errcheck
                  - godot
                  - wrapcheck

formatters:
    enable:
        - gofmt
        - goimports
    settings:
        goimports:
            local-prefixes:
                - github.com/kitti12911

issues:
    max-issues-per-linter: 0
    max-same-issues: 0
```

### Go Linter Tiers

| Tier     | Linters                                 |
| -------- | --------------------------------------- |
| Required | govet, errcheck, staticcheck, gosec     |
| Strong   | bodyclose, nilerr, errorlint, wrapcheck |
| Quality  | gocritic, revive, unused, misspell      |
| Optional | cyclop, exhaustive, prealloc, unconvert |

Keep `gochecknoglobals` out of the default app profile. It is useful for strict
library packages, but it is noisy for real services with config, metrics,
registries, and generated code.

## OpenAPI Compatibility

For services that generate an OpenAPI document from code, keep generation behind
a project-native Makefile target such as `make gen-openapi`. The target should
write only the OpenAPI document to stdout so it can be redirected in CI.

On pull requests, compare the generated OpenAPI document from the base branch
against the generated document from the pull request revision. Use a pinned
`oasdiff` CLI version, write both the changelog and breaking report to the
GitHub step summary, and fail the job when `oasdiff breaking` reports breaking
changes.

Recommended tool pin:

- `github.com/oasdiff/oasdiff` v1.14.0

## Container Publishing And Signing

For services that publish container images, push immutable commit tags and sign
the resolved image digest with cosign. Keep registry credentials and private
signing keys in GitHub Actions secrets; never commit key material.

Recommended secrets for the homelab Zot registry:

- `ZOT_USERNAME`: registry username.
- `ZOT_TOKEN`: registry access token.
- `COSIGN_PRIVATE_KEY`: PEM contents of the cosign private key.

Use repository secrets for normal app repositories. Use environment secrets only
when the repository needs manual deployment approvals or different credentials
per target environment.

Add these steps after a successful Docker build and Trivy image scan:

```yaml
env:
    REGISTRY: zot.kittiaccess.work

jobs:
    build:
        name: Build, Push, And Sign
        runs-on: ubuntu-latest
        if: github.ref == 'refs/heads/main'
        env:
            IMAGE_REF: zot.kittiaccess.work/${{ github.repository }}
        steps:
            - name: Log in to Zot
              env:
                  ZOT_USERNAME: ${{ secrets.ZOT_USERNAME }}
                  ZOT_TOKEN: ${{ secrets.ZOT_TOKEN }}
              run: |
                  echo "${ZOT_TOKEN}" \
                      | docker login "${REGISTRY}" \
                          --username "${ZOT_USERNAME}" \
                          --password-stdin

            - name: Push Docker image
              run: |
                  docker tag "${IMAGE_REF}:${GITHUB_SHA}" "${IMAGE_REF}:latest"
                  docker push "${IMAGE_REF}:${GITHUB_SHA}"
                  docker push "${IMAGE_REF}:latest"

            - name: Resolve image digest
              id: image
              run: |
                  digest="$(docker buildx imagetools inspect "${IMAGE_REF}:${GITHUB_SHA}" --format '{{.Manifest.Digest}}')"
                  echo "digest=${digest}" >> "${GITHUB_OUTPUT}"

            # sigstore/cosign-installer v4.1.1
            - uses: sigstore/cosign-installer@cad07c2e89fa2edd6e2d7bab4c1aa38e53f76003

            - name: Sign image digest
              env:
                  COSIGN_PRIVATE_KEY: ${{ secrets.COSIGN_PRIVATE_KEY }}
              run: |
                  key_file="$(mktemp)"
                  trap 'rm -f "${key_file}"' EXIT
                  printf '%s' "${COSIGN_PRIVATE_KEY}" > "${key_file}"
                  chmod 600 "${key_file}"
                  cosign sign --yes \
                      --new-bundle-format=false \
                      --use-signing-config=false \
                      --key "${key_file}" \
                      "${IMAGE_REF}@${{ steps.image.outputs.digest }}"
```

For passwordless cosign keys, do not set `COSIGN_PASSWORD`. For encrypted keys,
store the password as a separate secret and pass it through the step environment.

For multi-architecture images, sign the manifest-list digest and each
architecture-specific manifest digest. Zot tracks signatures by digest, so
signing only the manifest list can leave `amd64` and `arm64` tags appearing
unsigned even when `latest` is signed.

## TypeScript Pipeline

Prefer the package manager already used by the project. The example below uses
`npm`; replace with `pnpm` or `yarn` when the lockfile says so.

### TypeScript Workflow

```yaml
name: TypeScript CI

on:
    push:
        branches:
            - main
        paths:
            - ".github/workflows/ts-ci.yml"
            - "Dockerfile"
            - "package.json"
            - "package-lock.json"
            - "tsconfig*.json"
            - "vite.config.*"
            - "vitest.config.*"
            - "eslint.config.*"
            - ".oxlintrc*"
            - "src/**"
            - "test/**"
            - "tests/**"
    pull_request:
        paths:
            - ".github/workflows/ts-ci.yml"
            - "Dockerfile"
            - "package.json"
            - "package-lock.json"
            - "tsconfig*.json"
            - "vite.config.*"
            - "vitest.config.*"
            - "eslint.config.*"
            - ".oxlintrc*"
            - "src/**"
            - "test/**"
            - "tests/**"

permissions:
    contents: read

jobs:
    lint-and-typecheck:
        name: Lint and Type Check
        runs-on: ubuntu-latest
        steps:
            # actions/checkout v6.0.2
            - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd

            # actions/setup-node v6.4.0
            - uses: actions/setup-node@48b55a011bda9f5d6aeb4c2d9c7362e8dae4041e
              with:
                  node-version-file: .nvmrc
                  cache: npm

            - name: Install dependencies
              run: npm ci

            - name: Type check
              run: npm run typecheck --if-present

            - name: ESLint
              run: npm run lint --if-present

            - name: oxlint
              run: npm run lint:ox --if-present

    test:
        name: Test
        runs-on: ubuntu-latest
        steps:
            # actions/checkout v6.0.2
            - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd

            # actions/setup-node v6.4.0
            - uses: actions/setup-node@48b55a011bda9f5d6aeb4c2d9c7362e8dae4041e
              with:
                  node-version-file: .nvmrc
                  cache: npm

            - name: Install dependencies
              run: npm ci

            - name: Test
              run: npm run test --if-present -- --coverage

            # codecov/codecov-action v6.0.0
            - uses: codecov/codecov-action@57e3a136b779b570ffcdbf80b3bdc90e7fab3de2
              with:
                  token: ${{ secrets.CODECOV_TOKEN }}

    security:
        name: Security
        runs-on: ubuntu-latest
        steps:
            # actions/checkout v6.0.2
            - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd
              with:
                  fetch-depth: 0

            # actions/setup-node v6.4.0
            - uses: actions/setup-node@48b55a011bda9f5d6aeb4c2d9c7362e8dae4041e
              with:
                  node-version-file: .nvmrc
                  cache: npm

            - name: Install dependencies
              run: npm ci

            # google/osv-scanner-action v2.3.5
            - uses: google/osv-scanner-action/osv-scanner-action@c51854704019a247608d928f370c98740469d4b5
              with:
                  scan-args: |-
                      --lockfile=package-lock.json
                      --recursive
                      ./

            # aquasecurity/trivy-action v0.36.0
            - uses: aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25
              with:
                  scan-type: fs
                  scan-ref: .
                  scanners: vuln,secret,misconfig
                  exit-code: 1
                  severity: CRITICAL,HIGH
                  ignore-unfixed: true

            # gitleaks/gitleaks-action v2.3.9
            - uses: gitleaks/gitleaks-action@ff98106e4c7b2bc287b24eaf42907196329070c7
              env:
                  GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

            - name: Semgrep
              run: |
                  python3 -m pip install --user semgrep==1.161.0
                  ~/.local/bin/semgrep scan --config=p/typescript --config=p/secrets --error

    build:
        name: Build and Container Scan
        runs-on: ubuntu-latest
        needs:
            - lint-and-typecheck
            - test
            - security
        if: github.ref == 'refs/heads/main'
        steps:
            # actions/checkout v6.0.2
            - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd

            # actions/setup-node v6.4.0
            - uses: actions/setup-node@48b55a011bda9f5d6aeb4c2d9c7362e8dae4041e
              with:
                  node-version-file: .nvmrc
                  cache: npm

            - name: Install dependencies
              run: npm ci

            - name: Build app
              run: npm run build --if-present

            - name: Build Docker image
              run: docker build -t ${{ github.repository }}:${{ github.sha }} .

            # aquasecurity/trivy-action v0.36.0
            - uses: aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25
              with:
                  image-ref: ${{ github.repository }}:${{ github.sha }}
                  format: table
                  exit-code: 1
                  severity: CRITICAL,HIGH
```

### TypeScript Notes

- Prefer project scripts: `lint`, `lint:ox`, `typecheck`, `test`, and `build`.
- Use ESLint when the project needs framework-specific rules.
- Use oxlint when speed matters and the supported rule set is enough.
- Use Socket's GitHub App for npm supply-chain behavior analysis. It is better
  than `npm audit` for malicious package behavior and runs directly on PRs.
- Do not use `npm audit` as the blocking security baseline. It is reactive and
  misses many malicious-package behaviors.

## Renovate

Add `.github/renovate.json`:

```json
{
    "$schema": "https://docs.renovatebot.com/renovate-schema.json",
    "extends": ["config:recommended"],
    "timezone": "Asia/Bangkok",
    "schedule": ["* 0-4 1 * *"],
    "updateNotScheduled": false,
    "enabledManagers": ["gomod", "npm", "github-actions"],
    "reviewersFromCodeOwners": true,
    "assigneesFromCodeOwners": true,
    "assignAutomerge": true
}
```

For pure Go libraries, add:

```json
"postUpdateOptions": ["gomodTidy"]
```

## Markdownlint

Use `markdownlint-cli2` locally and in CI. It is the same engine used by the
VS Code `DavidAnson.vscode-markdownlint` extension.

Add `.markdownlint-cli2.jsonc`:

```jsonc
{
    "config": {
        "MD013": false
    },
    "globs": ["**/*.{md,markdown}"],
    "ignores": [".cursor/**"]
}
```

Add `.github/workflows/markdownlint.yml`:

```yaml
name: Markdownlint

on:
    push:
        branches:
            - main
        paths:
            - ".github/workflows/markdownlint.yml"
            - ".markdownlint-cli2.*"
            - ".markdownlint.*"
            - "**/*.md"
            - "**/*.markdown"
    pull_request:
        paths:
            - ".github/workflows/markdownlint.yml"
            - ".markdownlint-cli2.*"
            - ".markdownlint.*"
            - "**/*.md"
            - "**/*.markdown"

permissions:
    contents: read

jobs:
    markdownlint:
        name: Markdownlint
        runs-on: ubuntu-latest
        steps:
            # actions/checkout v6.0.2
            - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd

            # DavidAnson/markdownlint-cli2-action v23.1.0
            - uses: DavidAnson/markdownlint-cli2-action@6b51ade7a9e4a75a7ad929842dd298a3804ebe8b
```

## CODEOWNERS

Add `.github/CODEOWNERS`:

```text
* @kitti12911

/.github/ @kitti12911
/.markdownlint-cli2.jsonc @kitti12911
/.golangci.yml @kitti12911
/eslint.config.* @kitti12911
/.oxlintrc* @kitti12911
/package.json @kitti12911
/package-lock.json @kitti12911
/go.mod @kitti12911
/go.sum @kitti12911
```

Then enable "Require review from Code Owners" in branch protection.

## Required Secrets

| Secret                    | Used By                  | Required |
| ------------------------- | ------------------------ | -------- |
| `CODECOV_TOKEN`           | Codecov uploads          | Yes      |
| `SOCKET_SECURITY_API_KEY` | Socket CLI/firewall only | Optional |
| `ZOT_USERNAME`            | Zot registry login       | Services |
| `ZOT_TOKEN`               | Zot registry login       | Services |
| `COSIGN_PRIVATE_KEY`      | Container image signing  | Services |

`GITHUB_TOKEN` is provided automatically by GitHub Actions.

## Branch Protection

For `main`, require:

- Pull request before merge
- Status checks: `Lint`, `Test`, and `Security`
- Code owner review
- Branch up to date before merge
- No bypass for administrators unless there is a specific operational reason

## Local Commands

Go:

```bash
go vet ./...
go test -race ./...
golangci-lint run
govulncheck ./...
trivy fs --severity CRITICAL,HIGH --ignore-unfixed .
markdownlint-cli2
cosign sign --new-bundle-format=false --use-signing-config=false \
    --key cosign.key zot.lan/<app>@sha256:<digest>
```

TypeScript:

```bash
npm ci
npm run typecheck --if-present
npm run lint --if-present
npm run lint:ox --if-present
npm run test --if-present
npx osv-scanner --lockfile=package-lock.json --recursive ./
trivy fs --severity CRITICAL,HIGH --ignore-unfixed .
```
