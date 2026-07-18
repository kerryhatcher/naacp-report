# Local CI mirror. `just ci` runs the same gates as GitHub Actions:
# the deploy workflow's tests/builds and the security workflow's scanners.

set shell := ["bash", "-uc"]

# Pinned scanner versions — kept in sync with .github/workflows/security.yml
# (`just security` fails fast on drift). DS = detect-secrets; the short name
# keeps secret-keyword scanners from flagging the assignment itself.
TRIVY_VERSION := "0.72.0"
GITLEAKS_VERSION := "8.30.1"
RUSTY_HOG_VERSION := "1.0.11"
KINGFISHER_VERSION := "1.108.0"
DS_VERSION := "1.5.0"
RIPSECRETS_VERSION := "0.1.11"
TRUFFLEHOG_VERSION := "3.95.9"
CLOAKRS_VERSION := "0.3.0"

default:
    @just --list

# Everything Actions runs: deploy-workflow gates, then all security scanners.
ci: test security

# Deploy-workflow gates (mirrors .github/workflows/deploy.yml).
test: generator-test web-test

generator-test:
    cd generator && uv run pytest
    cd generator && uv run ruff check .

generator-build:
    cd generator && uv run build.py

web-test: generator-build
    cd web && if [ ! -d node_modules ]; then npm ci; fi
    cd web && npm test
    cd web && npm run check
    cd web && npm run build

# All eight security scanners (mirrors .github/workflows/security.yml).
# Scans a pristine temp copy of the tree (tracked + unignored files), the
# same file set a CI checkout sees — local node_modules/.venv/dist stay out,
# and scanner binaries stay outside the scan root.
security:
    #!/usr/bin/env bash
    set -euo pipefail

    wf=.github/workflows/security.yml
    while read -r name ver; do
        grep -Eq "^\s+${name}: ${ver}$" "$wf" || {
            echo "version drift: justfile has ${name}=${ver}, not found in ${wf}" >&2
            exit 1
        }
    done <<'EOF'
    TRIVY_VERSION {{TRIVY_VERSION}}
    GITLEAKS_VERSION {{GITLEAKS_VERSION}}
    RUSTY_HOG_VERSION {{RUSTY_HOG_VERSION}}
    KINGFISHER_VERSION {{KINGFISHER_VERSION}}
    DETECT_SECRETS_VERSION {{DS_VERSION}}
    RIPSECRETS_VERSION {{RIPSECRETS_VERSION}}
    TRUFFLEHOG_VERSION {{TRUFFLEHOG_VERSION}}
    CLOAKRS_VERSION {{CLOAKRS_VERSION}}
    EOF

    TOOLS="${XDG_CACHE_HOME:-$HOME/.cache}/georgia-elections-report/security-tools"
    mkdir -p "$TOOLS"

    [ -x "$TOOLS/trivy" ] || curl -sSfL "https://github.com/aquasecurity/trivy/releases/download/v{{TRIVY_VERSION}}/trivy_{{TRIVY_VERSION}}_Linux-64bit.tar.gz" | tar xz -C "$TOOLS" trivy
    [ -x "$TOOLS/gitleaks" ] || curl -sSfL "https://github.com/gitleaks/gitleaks/releases/download/v{{GITLEAKS_VERSION}}/gitleaks_{{GITLEAKS_VERSION}}_linux_x64.tar.gz" | tar xz -C "$TOOLS" gitleaks
    [ -x "$TOOLS/duroc_hog" ] || {
        curl -sSfL -o "$TOOLS/rh.zip" "https://github.com/newrelic/rusty-hog/releases/download/v{{RUSTY_HOG_VERSION}}/rustyhogs-musl-duroc_hog-{{RUSTY_HOG_VERSION}}.zip"
        unzip -q -o -j "$TOOLS/rh.zip" -d "$TOOLS" && rm "$TOOLS/rh.zip" && chmod +x "$TOOLS/duroc_hog"
    }
    [ -x "$TOOLS/kingfisher" ] || curl -sSfL "https://github.com/mongodb/kingfisher/releases/download/v{{KINGFISHER_VERSION}}/kingfisher-linux-x64.tgz" | tar xz -C "$TOOLS" kingfisher
    [ -x "$TOOLS/ripsecrets" ] || curl -sSfL "https://github.com/sirwart/ripsecrets/releases/download/v{{RIPSECRETS_VERSION}}/ripsecrets-{{RIPSECRETS_VERSION}}-x86_64-unknown-linux-gnu.tar.gz" | tar xz -C "$TOOLS" --strip-components=1
    [ -x "$TOOLS/trufflehog" ] || curl -sSfL "https://github.com/trufflesecurity/trufflehog/releases/download/v{{TRUFFLEHOG_VERSION}}/trufflehog_{{TRUFFLEHOG_VERSION}}_linux_amd64.tar.gz" | tar xz -C "$TOOLS" trufflehog
    [ -x "$TOOLS/cloakrs" ] || curl -sSfL "https://github.com/kadir/cloakrs/releases/download/v{{CLOAKRS_VERSION}}/cloakrs-v{{CLOAKRS_VERSION}}-x86_64-unknown-linux-gnu.tar.gz" | tar xz -C "$TOOLS"

    SCANROOT=$(mktemp -d)
    WORK=$(mktemp -d)
    trap 'rm -rf "$SCANROOT" "$WORK"' EXIT
    git ls-files -coz --exclude-standard | tar --null -T - -cf - | tar -xf - -C "$SCANROOT"
    SEC="$SCANROOT/.github/security"

    scan_trivy() {
        "$TOOLS/trivy" fs \
            --scanners vuln,secret,misconfig \
            --secret-config "$SEC/trivy-secret.yaml" \
            --severity HIGH,CRITICAL \
            --ignore-unfixed \
            --exit-code 1 \
            "$SCANROOT"
    }

    scan_gitleaks() {
        "$TOOLS/gitleaks" dir "$SCANROOT" \
            --config "$SEC/gitleaks.toml" \
            --no-banner --redact -v --exit-code 1
    }

    scan_rusty_hog() {
        local out="$WORK/duroc.json"
        "$TOOLS/duroc_hog" -a "$SEC/rusty-hog-allowlist.json" "$SCANROOT" > "$out"
        jq . "$out"
        [ "$(jq length "$out")" -eq 0 ] || return 1
        "$TOOLS/duroc_hog" -a "$SEC/rusty-hog-allowlist.json" \
            --regex "$SEC/rusty-hog-org-rule.json" "$SCANROOT" > "$out"
        jq . "$out"
        [ "$(jq length "$out")" -eq 0 ]
    }

    scan_kingfisher() {
        "$TOOLS/kingfisher" scan "$SCANROOT" \
            --rules-path "$SEC/kingfisher-rules.yml" \
            --git-history none \
            --no-update-check
    }

    scan_detect_secrets() {
        local out="$WORK/ds.json"
        cp "$SEC/detect_secrets_org_plugin.py" "$WORK/org_plugin.py"
        (cd "$SCANROOT" && uvx --from "detect-secrets=={{DS_VERSION}}" detect-secrets scan --all-files \
            -p "$WORK/org_plugin.py" \
            --exclude-files 'package-lock\.json$|(^|/)\.git/') > "$out"
        jq .results "$out"
        [ "$(jq '.results | length' "$out")" -eq 0 ]
    }

    scan_ripsecrets() {
        (cd "$SCANROOT" && "$TOOLS/ripsecrets" --additional-pattern '(?i)n[a]acp')
    }

    scan_trufflehog() {
        "$TOOLS/trufflehog" filesystem "$SCANROOT" \
            --config "$SEC/trufflehog.yaml" \
            --no-update --fail
    }

    scan_cloakrs() {
        local out="$WORK/cloakrs.json" rc=0 count
        local U L T
        U="NA""ACP"
        L=$(printf '%s' "$U" | tr '[:upper:]' '[:lower:]')
        T="Na""acp"
        printf 'deny_list = ["%s", "%s", "%s"]\n' "$U" "$L" "$T" > "$WORK/cloakrs-ci.toml"
        "$TOOLS/cloakrs" audit "$SCANROOT" \
            --recursive --respect-gitignore \
            --config "$WORK/cloakrs-ci.toml" \
            --output-format json --output "$out" || rc=$?
        if [ "$rc" -ge 2 ]; then return "$rc"; fi
        jq '{total_findings, findings_by_type}' "$out"
        count=$(jq '[.files[]
            | select(.path | test("(^|/)(package-lock\\.json|uv\\.lock)$") | not)
            | .findings_by_type | to_entries[]
            | select(.key | IN("Url","Hostname","UserPath") | not)
            | .value] | add // 0' "$out")
        echo "gated findings: $count"
        [ "$count" -eq 0 ]
    }

    fail=0
    results=""
    for scanner in trivy gitleaks rusty_hog kingfisher detect_secrets ripsecrets trufflehog cloakrs; do
        echo
        echo "=== $scanner ==="
        if "scan_$scanner"; then
            results="$results$scanner: PASS"$'\n'
        else
            results="$results$scanner: FAIL"$'\n'
            fail=1
        fi
    done

    echo
    echo "=== summary ==="
    printf '%s' "$results"
    exit "$fail"
