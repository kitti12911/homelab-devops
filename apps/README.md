# Application CI/CD Guidelines

This document covers the CI/CD pipeline standards for applications in this repository using GitHub Actions.

## Stack Coverage

| Language | Linting | Type Check | Tests | Security | Deps |
| --- | --- | --- | --- | --- | --- |
| Go | golangci-lint | go vet | go test -race | govulncheck, gitleaks, semgrep | renovate |
| TypeScript | eslint / biome | tsc --noEmit | vitest / jest | npm audit, gitleaks, semgrep | renovate |

---

## Pipeline Stages

```text
PR opened     → lint → test → security scan   (blocking, fast feedback)
Merge to main → build → container scan → push (blocking)
Scheduled     → renovate dep updates          (async)
```

---

## Go Pipeline

### Full example: `.github/workflows/go-ci.yml`

```yaml
name: Go CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  lint:
    name: Lint
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-go@v5
        with:
          go-version-file: go.mod
          cache: true

      - name: golangci-lint
        uses: golangci/golangci-lint-action@v6
        with:
          version: latest

  test:
    name: Test
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-go@v5
        with:
          go-version-file: go.mod
          cache: true

      - name: Run tests with race detector and coverage
        run: go test -race -coverprofile=coverage.out -covermode=atomic ./...

      - name: Upload coverage to Codecov
        uses: codecov/codecov-action@v4
        with:
          files: coverage.out
          token: ${{ secrets.CODECOV_TOKEN }}

  security:
    name: Security
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0  # required for gitleaks history scan

      - uses: actions/setup-go@v5
        with:
          go-version-file: go.mod
          cache: true

      - name: govulncheck
        run: |
          go install golang.org/x/vuln/cmd/govulncheck@latest
          govulncheck ./...

      - name: Gitleaks (secret detection)
        uses: gitleaks/gitleaks-action@v2
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

      - name: Semgrep
        uses: semgrep/semgrep-action@v1
        with:
          config: >-
            p/golang
            p/secrets
        env:
          SEMGREP_APP_TOKEN: ${{ secrets.SEMGREP_APP_TOKEN }}

  build:
    name: Build & Container Scan
    runs-on: ubuntu-latest
    needs: [lint, test, security]
    if: github.ref == 'refs/heads/main'
    steps:
      - uses: actions/checkout@v4

      - name: Build Docker image
        run: docker build -t ${{ github.repository }}:${{ github.sha }} .

      - name: Trivy container scan
        uses: aquasecurity/trivy-action@master
        with:
          image-ref: ${{ github.repository }}:${{ github.sha }}
          format: table
          exit-code: 1
          severity: CRITICAL,HIGH
```

### Recommended `.golangci.yml`

```yaml
run:
  timeout: 5m

linters:
  enable:
    # --- correctness (these catch real bugs) ---
    - govet          # reports suspicious constructs (shadow, printf args, struct tags)
    - errcheck       # ensures error return values are checked
    - staticcheck    # the most comprehensive Go static analyzer
    - bodyclose      # checks HTTP response bodies are closed
    - nilerr         # catches returning nil when err is not nil
    - sqlclosecheck  # checks sql.Rows and sql.Stmt are closed

    # --- security ---
    - gosec          # security-oriented linter (hardcoded creds, weak crypto, injections)

    # --- code quality ---
    - unused         # finds unused code
    - gosimple       # suggests simpler code
    - ineffassign    # detects assignments to variables that are never read
    - gocritic       # opinionated but catches many real issues
    - revive         # fast, extensible replacement for golint
    - unconvert      # removes unnecessary type conversions
    - unparam        # finds unused function parameters
    - prealloc       # suggests slice pre-allocation where possible
    - misspell       # catches common English typos in comments and strings

    # --- formatting (keeps code consistent) ---
    - gofmt
    - goimports

    # --- error handling ---
    - errorlint      # checks for incorrect error wrapping (Go 1.13+ errors.Is/As)
    - wrapcheck      # ensures errors from external packages are wrapped

linters-settings:
  govet:
    enable-all: true
  gocritic:
    enabled-tags:
      - diagnostic
      - style
      - performance
  revive:
    rules:
      - name: exported
      - name: var-naming
      - name: blank-imports
      - name: context-as-argument
      - name: error-return
      - name: error-strings
      - name: increment-decrement
      - name: range
      - name: receiver-naming
  errorlint:
    errorf: true
    asserts: true
    comparison: true
  wrapcheck:
    ignoreSigs:
      - .Errorf(
      - errors.New(
      - errors.Unwrap(
      - errors.Join(
      - .Wrap(
      - .Wrapf(
      - .WithMessage(
      - .WithMessagef(
      - .WithStack(

issues:
  exclude-use-default: false
  max-issues-per-linter: 0
  max-same-issues: 0
```

#### Linter tiers explained

| Tier | Linters | Why |
| --- | --- | --- |
| Non-negotiable | govet, errcheck, staticcheck, gosec | Catches real bugs and security issues. Never disable. |
| Highly recommended | bodyclose, nilerr, errorlint, wrapcheck | Prevents subtle resource leaks and error handling mistakes. |
| Quality of life | gocritic, revive, unused, gosimple, misspell | Keeps code clean and idiomatic. Low noise. |
| Formatting | gofmt, goimports | Consistency. Never argue about style again. |
| Nice to have | prealloc, unconvert, unparam | Micro-optimizations. Can disable if too noisy for your taste. |

---

## TypeScript Pipeline

> Note: TypeScript tooling varies by project setup. This covers the most common patterns.
> Your coworker may already have ESLint/Biome configured — check for `.eslintrc.*`, `biome.json`, or `eslint.config.*` before adding new config.

### Full example: `.github/workflows/ts-ci.yml`

```yaml
name: TypeScript CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  lint-and-typecheck:
    name: Lint & Type Check
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version-file: .nvmrc       # or pin: node-version: '22'
          cache: npm                       # or pnpm / yarn

      - name: Install dependencies
        run: npm ci

      - name: Type check
        run: npx tsc --noEmit

      # Choose ONE of the two options below based on your project setup:

      # Option A: ESLint (most common)
      - name: ESLint
        run: npx eslint . --ext .ts,.tsx

      # Option B: Biome (if your project uses it instead of ESLint+Prettier)
      # - name: Biome
      #   run: npx biome ci .

  test:
    name: Test
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version-file: .nvmrc
          cache: npm

      - name: Install dependencies
        run: npm ci

      # Adjust the test command to match your test runner (vitest / jest)
      - name: Run tests with coverage
        run: npm run test -- --coverage

      - name: Upload coverage to Codecov
        uses: codecov/codecov-action@v4
        with:
          token: ${{ secrets.CODECOV_TOKEN }}

  security:
    name: Security
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - uses: actions/setup-node@v4
        with:
          node-version-file: .nvmrc
          cache: npm

      - name: Install dependencies
        run: npm ci

      - name: npm audit
        # --audit-level=high ignores low/moderate findings to reduce noise
        run: npm audit --audit-level=high

      - name: Gitleaks (secret detection)
        uses: gitleaks/gitleaks-action@v2
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

      - name: Semgrep
        uses: semgrep/semgrep-action@v1
        with:
          config: >-
            p/typescript
            p/secrets
        env:
          SEMGREP_APP_TOKEN: ${{ secrets.SEMGREP_APP_TOKEN }}

  build:
    name: Build & Container Scan
    runs-on: ubuntu-latest
    needs: [lint-and-typecheck, test, security]
    if: github.ref == 'refs/heads/main'
    steps:
      - uses: actions/checkout@v4

      - name: Build Docker image
        run: docker build -t ${{ github.repository }}:${{ github.sha }} .

      - name: Trivy container scan
        uses: aquasecurity/trivy-action@master
        with:
          image-ref: ${{ github.repository }}:${{ github.sha }}
          format: table
          exit-code: 1
          severity: CRITICAL,HIGH
```

---

## Shared: Renovate (dependency updates)

Add a `renovate.json` at the repo root to enable automatic dependency update PRs for both Go and TypeScript.

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["config:recommended"],
  "schedule": ["before 9am on Monday"],
  "labels": ["dependencies"],
  "packageRules": [
    {
      "matchUpdateTypes": ["minor", "patch"],
      "automerge": true
    },
    {
      "matchUpdateTypes": ["major"],
      "automerge": false
    }
  ]
}
```

Enable Renovate via the [Renovate GitHub App](https://github.com/apps/renovate).

---

## Required GitHub Secrets

| Secret | Used by | How to get |
| --- | --- | --- |
| `CODECOV_TOKEN` | codecov-action | [codecov.io](https://codecov.io) → project settings |
| `SEMGREP_APP_TOKEN` | semgrep-action | [semgrep.dev](https://semgrep.dev) → Settings → Tokens (optional for public rules) |

> `GITHUB_TOKEN` is provided automatically by GitHub Actions — no setup needed.

---

## Protecting CI/CD Config Files (CODEOWNERS)

> **Do NOT gitignore workflow or lint config files** — that would remove them from git entirely and CI would stop working.
> Instead, use GitHub's CODEOWNERS to require approval from trusted people before these files can be changed.

Create `.github/CODEOWNERS` in your repo:

```text
# CI/CD workflows — only repo owner can approve changes
.github/                @your-github-username

# Lint and tool config — only repo owner can approve changes
.golangci.yml           @your-github-username
biome.json              @your-github-username
.eslintrc.*             @your-github-username
eslint.config.*         @your-github-username
renovate.json           @your-github-username
```

Then enable this branch protection rule:

- [x] **Require review from Code Owners** (Settings → Branches → Branch protection)

This means anyone can submit a PR that touches these files, but only `@your-github-username` (or a team you specify) can approve and merge it.

---

## Branch Protection Recommendations

In GitHub → Settings → Branches → Add rule for `main`:

- [x] Require status checks to pass before merging
  - Add: `Lint`, `Test`, `Security` (all jobs above)
- [x] Require a pull request before merging
- [x] Require review from Code Owners
- [x] Require branches to be up to date before merging
- [x] Do not allow bypassing the above settings

---

## Quick Reference

```bash
# Go — run locally before pushing
go vet ./...
go test -race ./...
golangci-lint run
govulncheck ./...

# TypeScript — run locally before pushing
npx tsc --noEmit
npx eslint . --ext .ts,.tsx     # or: npx biome ci .
npm audit
npm run test
```
