# Plan for Updating Fork with Upstream Main Branch

## Overview

This document provides a detailed plan for bringing new features from the upstream main branch into our forked project while preserving our local optimizations for local models and resilience mode. Our fork has specific changes in the `rust/` directory (and optionally `scripts/`) that we must maintain, including:
- Removal of DashScope API references
- Resilience mode implementation (as planned in `Resiliance_mode_robustness_refactor_plan.md`)
- Local model optimizations

We only care about changes in the `rust/` directory (and optionally `scripts/`), as stated in the requirements. The primary source of truth for identifying upstream changes is: `git diff upstream/main -- rust/`

## Prerequisites

1. Git repository with configured remotes:
   - `origin`: Our fork (https://github.com/WadeBalsamo/claw-code.git)
   - `upstream`: Upstream repository (https://github.com/ultraworkers/claw-code.git)
2. Current working branch is `beta` (our development branch)
3. Clean working directory (or stash any temporary changes)
4. Familiarity with basic Git operations (fetch, merge, reset, checkout)

## Step-by-Step Procedure

### 1. Prepare and Verify Current State

First, ensure we are on the correct branch and understand our divergence from upstream.

```bash
# Confirm we are on beta branch
git checkout beta
git status

# Verify we have no uncommitted changes that we want to keep (stash if needed)
git status --porcelain

# Check our current position relative to upstream/main
echo "Merge base between beta and upstream/main:"
git merge-base beta upstream/main

# Show commits that are in beta but not in upstream/main (our unique commits)
echo "\nCommits in beta not in upstream/main:"
git log --oneline upstream/main..beta --

# Show commits that are in upstream/main but not in beta (upstream advances)
echo "\nCommits in upstream/main not in beta:"
git log --oneline beta..upstream/main --
```

### 2. Examine Upstream Changes in Rust Directory

Identify exactly what changes exist in upstream/main for the `rust/` directory that we might want to incorporate.

```bash
# Get detailed diff of upstream changes in rust/ since our fork
echo "\n=== Changes in upstream/main for rust/ directory ==="
git diff upstream/main -- rust/ | head -100   # Limit output for readability

# Get summary of file changes
echo "\n=== Summary of file changes in rust/ ==="
git diff --name-only upstream/main -- rust/ | sort

# Get commit statistics for rust/ changes
echo "\n=== Commit statistics for rust/ changes ==="
git log --oneline --rust/ beta..upstream/main | head -20
```

### 3. Identify Our Local Changes to Preserve

Confirm what local changes we have in the `rust/` directory that must be preserved.

```bash
# Show our local changes in rust/ that are not in upstream/main
echo "\n=== Our local changes in rust/ (beta vs upstream/main) ==="
git diff --name-only upstream/main beta -- rust/ || echo "No differences found (this is expected if we've already integrated)"

# If the above is empty, check our changes since the merge base
echo "\n=== Our local changes in rust/ since merge base ==="
git diff $(git merge-base beta upstream/main) beta -- rust/ | head -50

# List specific files we know we've modified
echo "\n=== Checking specific files we know we've modified ==="
for file in rust/crates/api/src/error.rs \
            rust/crates/api/src/lib.rs \
            rust/crates/api/src/resilience_config.rs \
            rust/crates/api/src/resilience_tests.rs; do
    if [ -f "$file" ]; then
        echo "$file exists in beta"
        git diff --name-only upstream/main beta -- "$file" && echo "  -> Has local changes" || echo "  -> Matches upstream/main"
    else
        echo "$file DELETED in beta (we removed it)"
    fi
done
```

### 4. Determine What Upstream Changes to Incorporate

Based on the project goals, we want to incorporate upstream changes that:
- Fix bugs or improve functionality unrelated to our local modifications
- Enhance provider support (OpenAI, Anthropic, etc.) that doesn't conflict with our local model focus
- Improve tooling, diagnostics, or infrastructure that benefits our resilience mode
- Update dependencies to newer, secure versions

We want to avoid or carefully handle upstream changes that:
- Modify provider integrations we've removed (DashScope, etc.)
- Conflict with our resilience mode implementation
- Modify files we've deliberately changed for local model optimization

### 5. Create Update Strategy

Given our requirements, the safest approach is to:
1. Take the latest `upstream/main` as our base
2. Replace the `rust/` directory with our version from the `beta` branch
3. Do the same for `scripts/` if we have local modifications there
4. Commit the result and update our `beta` branch

This ensures we get all upstream improvements outside `rust/` while preserving our local customizations.

```bash
# Fetch latest upstream changes
git fetch upstream

# Create a temporary branch from latest upstream/main
git checkout -b update_rust upstream/main

# Apply our rust/ and scripts/ directories from beta
# This overwrites upstream versions with our local versions
git checkout beta -- rust/ scripts/

# Verify what we're about to commit
echo "\n=== Changes to be committed ==="
git diff --cached --stat

# Check if we have any changes to commit
if git diff --cached --quiet; then
    echo "No changes detected - beta is already up to date with upstream/main for rust/ and scripts/"
    git checkout beta
    git branch -d update_rust
    exit 0
fi

# Commit the changes
git commit -m "Update rust/ and scripts/ to beta version while incorporating upstream/main advances

Preserving our local modifications for:
- Local model optimizations
- DashScope API removal
- Resilience mode implementation
- Any custom scripts/ enhancements

Based on upstream/main commit: $(git rev-parse --short HEAD^)"

# Verify the commit looks correct
echo "\n=== Commit preview ==="
git show --stat
```

### 6. Update Beta Branch

Now update our `beta` branch to incorporate the changes.

```bash
# Switch back to beta branch
git checkout beta

# Reset beta to point to our new update_rust commit
# This effectively makes beta = upstream/main + our rust/ + our scripts/
git reset --hard update_rust

# Verify the update
echo "\n=== Verification after update ==="
echo "Current commit: $(git rev-parse HEAD)"
echo "Should show our rust/ and scripts/ changes are preserved"

# Check that we have our local changes in rust/
echo "\n=== Confirming our rust/ changes are present ==="
git diff --name-only upstream/main beta -- rust/ || echo "Local rust/ changes are present (expected)"

# Check that we have upstream/main changes outside rust/
echo "\n=== Confirming we have upstream advances outside rust/ ==="
git diff --name-only beta upstream/main -- ':!rust/' ':!scripts/' | head -10

# Clean up temporary branch
git branch -d update_rust

# Optional: Push to origin (use with caution)
# git push origin beta --force-with-lease
```

### 7. Post-Update Verification

After updating, verify that our changes are preserved and upstream changes are integrated.

```bash
# Build verification (if applicable)
echo "\n=== Building to verify integrity ==="
cd rust
cargo build --release
cd ..

# Run tests if available
echo "\n=== Running tests ==="
cargo test --workspace --release

# Check specific resilience mode functionality
echo "\n=== Checking resilience mode files ==="
ls -la rust/crates/api/src/resilience_*
grep -r "resilience" rust/crates/api/src/ --include="*.rs" | head -5

# Verify DashScope removal
echo "\n=== Verifying DashScope removal ==="
if ! grep -r "dashscope\|DashScope" rust/ --include="*.rs" --include="*.toml"; then
    echo "DashScope references successfully removed"
else
    echo "WARNING: DashScope references found - check manually"
    grep -r "dashscope\|DashScope" rust/ --include="*.rs" --include="*.toml"
fi
```

### 8. Handling Conflicts and Special Cases

#### If Merge Conflicts Occur During Checkout
In our approach, conflicts during `git checkout beta -- rust/ scripts/` are unlikely because we're overwriting. However, if you encounter issues:

```bash
# If you see errors about local changes being overwritten, stash first:
git stash
# Then repeat the checkout
git checkout beta -- rust/ scripts/
git stash pop   # Reapply stashed changes if needed
```

#### If We Need to Preserve Specific Upstream Changes in Rust/
If we identify specific upstream changes in `rust/` that we want to keep (e.g., bug fixes), we would need a more sophisticated approach:

1. Identify specific commits or changes we want from upstream
2. Use `git cherry-pick` or `git patch` to apply them selectively
3. Resolve any conflicts by manually editing files

Example for cherry-picking a specific commit:
```bash
git checkout beta
git cherry-pick <upstream-commit-hash> -- rust/path/to/file.rs
# Resolve any conflicts manually
```

#### Upstream Changes to Documentation or Plans
If we want to keep upstream updates to documentation that don't conflict with our resilience plan:
```bash
# Example: updating resilience plan document
git checkout upstream/main -- Resiliance_mode_robustness_refactor_plan.md
# Then manually merge with our local version if we have modifications
```

## Decision Matrix for File Types

| File/Directory | Action | Reason |
|----------------|--------|--------|
| `rust/` | **REPLACE** with beta version | Preserve our local model optimizations, resilience mode, and provider removals |
| `scripts/` | **REPLACE** with beta version (if modified) | Preserve our custom scripts/local setup |
| `*/Cargo.toml` | **MERGE** carefully | Check for dependency updates; keep our feature flags/removals |
| `*.md` documentation | **UPSTREAM** with manual review | Accept upstream improvements but preserve our resilience plan |
| `.github/` workflows | **UPSTREAM** | Accept CI/CD improvements from upstream |
| `rust/.claw.json` | **UPSTREAM** | Accept upstream defaults; our custom permissions in `.claw/` |
| `.claw/` session files | **UPSTREAM** (or ignore) | These are runtime files; don't need to preserve specific versions |
| All other files | **UPSTREAM** | Accept upstream improvements outside our focus areas |

## Safety Checks and Recommendations

1. **Backup First**: Consider creating a backup branch before starting:
   ```bash
   git backup-beta: $(git rev-parse beta)
   ```

2. **Review Changes**: After the update, carefully review:
   - What upstream changes we gained outside `rust/`
   - That our critical `rust/` modifications remain intact
   - That no unwanted provider integrations were reintroduced

3. **Test Thoroughly**: Pay special attention to:
   - Resilience mode functionality
   - Local model provider connections
   - Error handling pathways we modified
   - Scripts that setup local models

4. **Document Deviations**: If we intentionally drop certain upstream changes, document why in our fork's documentation.

5. **Regular Updates**: Make this update process regular (e.g., weekly) to minimize divergence and conflict resolution.

## Troubleshooting

### Symptom: Missing our resilience mode changes after update
**Solution**: 
```bash
# Check if we accidentally overwrote rust/
git diff upstream/main beta -- rust/ | grep -i resilience
# If missing, restore from backup branch:
git checkout backup-beta -- rust/
```

### Symptom: Build fails after update
**Solution**:
1. Check if we missed updating a dependency in Cargo.toml
2. Verify our removed providers aren't being referenced elsewhere
3. Check for breaking changes in upstream API we need to adapt to

### Symptom: Unexpected provider references reappeared
**Solution**:
```bash
# Find where they came from
git grep -i "dashscope\|azure\|vertex" rust/
# Trace to specific commit and determine if we need to re-remove or if it's a false positive
```

## Conclusion

By following this plan, we will successfully integrate upstream advances while maintaining our critical local modifications for local model support and resilience mode. The key is being systematic about what we preserve (`rust/` and optionally `scripts/`) and what we accept from upstream (everything else).

Remember to adjust the specifics based on what you discover in Steps 2 and 3 - if you find that you have changes in additional directories that need preservation (like `docs/` for our resilience plan), extend the `git checkout beta --` line accordingly.

Last updated: $(date)
