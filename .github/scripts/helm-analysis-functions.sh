#!/bin/bash

# Helm Chart Upgrade Analysis Functions
# Common functions for helm chart upgrade analysis workflow

set -euo pipefail

# Global variables
declare -g CHART_NAME=""
declare -g DEPENDENCY_NAME=""
declare -g OLD_VERSION=""
declare -g NEW_VERSION=""
declare -g CHART_ARCHIVE=""
declare -g WORKING_DIR=""

# Label management
declare -a ANALYSIS_LABELS=("breaking-changes" "ready-to-merge" "needs-review")

# =============================================================================
# Utility Functions
# =============================================================================

log_info() {
    echo "INFO: $*"
}

log_error() {
    echo "ERROR: $*" >&2
}

log_debug() {
    echo "DEBUG: $*"
}

get_error_message_for_status() {
    local status="$1"
    case "$status" in
        429) echo "AI service temporarily unavailable (rate limit)" ;;
        413) echo "AI service unavailable (request too large)" ;;
        401|403) echo "AI service unavailable (authentication error)" ;;
        500|502|503|504) echo "AI service temporarily unavailable (server error)" ;;
        *) echo "AI service unavailable" ;;
    esac
}

# Remove all analysis labels to avoid conflicts
remove_analysis_labels() {
    for label in "${ANALYSIS_LABELS[@]}"; do
        gh pr edit --remove-label "$label" 2>/dev/null || true
    done
}

# Apply a label with description and color
apply_label() {
    local label="$1"
    local description="$2"
    local color="$3"
    
    gh label create "$label" --color "$color" --description "$description" 2>/dev/null || true
    gh pr edit --add-label "$label"
    log_info "Applied label: $label"
}


# =============================================================================
# Chart Detection and Setup
# =============================================================================

# Helper function to set up context from step outputs
setup_context_from_outputs() {
    local chart_name="$1"
    local dependency_name="$2"
    local old_version="${3:-}"
    local new_version="${4:-}"
    
    CHART_NAME="$chart_name"
    DEPENDENCY_NAME="$dependency_name"
    WORKING_DIR="k8s/charts/$CHART_NAME"
    
    if [[ -n "$old_version" ]]; then
        OLD_VERSION="$old_version"
    fi
    
    if [[ -n "$new_version" ]]; then
        NEW_VERSION="$new_version"
    fi
    
    # Ensure working directory and subdirectories exist
    if [[ -d "$WORKING_DIR" ]]; then
        cd "$WORKING_DIR"
        mkdir -p {new_templates,old_templates,diff_outputs}
    else
        log_error "Working directory does not exist: $WORKING_DIR"
        exit 1
    fi
    
    log_info "Context set: CHART_NAME=$CHART_NAME, DEPENDENCY_NAME=$DEPENDENCY_NAME"
    [[ -n "${OLD_VERSION:-}" ]] && log_info "OLD_VERSION=$OLD_VERSION"
    [[ -n "${NEW_VERSION:-}" ]] && log_info "NEW_VERSION=$NEW_VERSION"
}

detect_changed_chart() {
    local base_sha="$1"
    local head_sha="$2"
    
    log_info "Detecting changed chart from PR files..."
    
    local changed_charts
    changed_charts=$(git diff --name-only "${base_sha}..${head_sha}" | grep "k8s/charts/" | cut -d'/' -f3 | sort -u)
    
    if [[ -z "$changed_charts" ]]; then
        log_error "No chart changes detected"
        exit 1
    fi
    
    CHART_NAME=$(echo "$changed_charts" | head -1)
    log_info "Processing chart: $CHART_NAME"
    echo "chart_name=$CHART_NAME" >> "$GITHUB_OUTPUT"
}

setup_workspace() {
    WORKING_DIR="k8s/charts/$CHART_NAME"
    cd "$WORKING_DIR"
    
    # Create necessary directories
    mkdir -p {new_templates,old_templates,diff_outputs}
    
    log_info "Workspace set up in: $WORKING_DIR"
}

# =============================================================================
# Dependency Version Detection
# =============================================================================

extract_dependency_versions() {
    local base_sha="$1"
    local chart_name="$2"
    
    CHART_NAME="$chart_name"
    WORKING_DIR="k8s/charts/$CHART_NAME"
    cd "$WORKING_DIR"
    
    log_info "Extracting dependency versions from git diff..."
    
    # Get old and new Chart.yaml content
    git show "${base_sha}:k8s/charts/$CHART_NAME/Chart.yaml" > old_chart.yaml
    
    # Find which dependency version changed
    while IFS= read -r dep; do
        local old_ver new_ver
        old_ver=$(yq eval ".dependencies[] | select(.name == \"$dep\") | .version" old_chart.yaml 2>/dev/null || echo "")
        new_ver=$(yq eval ".dependencies[] | select(.name == \"$dep\") | .version" Chart.yaml 2>/dev/null || echo "")
        
        log_debug "Checking $dep: $old_ver → $new_ver"
        
        if [[ "$old_ver" != "$new_ver" && -n "$new_ver" ]]; then
            DEPENDENCY_NAME="$dep"
            OLD_VERSION="$old_ver"
            NEW_VERSION="$new_ver"
            log_info "Found version change: $dep ($old_ver → $new_ver)"
            echo "dependency_name=$DEPENDENCY_NAME" >> "$GITHUB_OUTPUT"
            echo "old_version=$OLD_VERSION" >> "$GITHUB_OUTPUT"
            echo "new_version=$NEW_VERSION" >> "$GITHUB_OUTPUT"
            return 0
        fi
    done < <(yq eval '.dependencies[].name' Chart.yaml)
    
    # No changes detected - this shouldn't happen with Renovate
    log_error "No dependency version changes detected in Chart.yaml"
    exit 1
}

# =============================================================================
# Chart Extraction
# =============================================================================

extract_new_chart_from_archive() {
    log_info "Extracting new chart from archive..."
    
    # Navigate to charts directory and find archive
    cd "./charts" || {
        log_error "Charts directory not found"
        exit 1
    }
    
    local chart_archive
    chart_archive=$(ls "${DEPENDENCY_NAME}"-*.tgz 2>/dev/null | head -1)
    
    # Fallback: try with chart directory name
    if [[ -z "$chart_archive" ]]; then
        log_info "Archive not found with dependency name, trying chart directory name..."
        chart_archive=$(ls "${CHART_NAME}"-*.tgz 2>/dev/null | head -1)
    fi
    
    if [[ -z "$chart_archive" ]]; then
        log_error "No chart archive found for $CHART_NAME"
        exit 1
    fi
    
    CHART_ARCHIVE="$chart_archive"
    log_info "Found chart archive: $CHART_ARCHIVE"
    echo "chart_archive=$CHART_ARCHIVE" >> "$GITHUB_OUTPUT"
    
    # Extract chart archive and get default values
    tar -xzf "$CHART_ARCHIVE"
    
    if [[ -f "${DEPENDENCY_NAME}/values.yaml" ]]; then
        cp "${DEPENDENCY_NAME}/values.yaml" "../chart_default_values.yaml"
        log_info "Extracted default values from new $DEPENDENCY_NAME chart"
    else
        log_error "No values.yaml found in $DEPENDENCY_NAME chart archive"
        exit 1
    fi
    
    # Return to working directory (parent of charts/)
    cd ".."
}

download_old_chart() {
    log_info "Downloading old chart version: $OLD_VERSION"
    
    # Get repository URL from current Chart.yaml
    local repository
    repository=$(yq eval ".dependencies[] | select(.name == \"$DEPENDENCY_NAME\") | .repository" Chart.yaml)
    log_info "Chart repository: $repository"
    
    # Download old chart based on repository type
    if [[ "$repository" == oci://* ]]; then
        log_info "Downloading from OCI repository: $repository"
        if helm pull "$repository/$DEPENDENCY_NAME" --version "$OLD_VERSION" --untar; then
            log_info "Successfully downloaded old chart from OCI repository"
        else
            log_error "Failed to download old chart from OCI repository"
            return 1
        fi
    else
        log_info "Downloading from Helm repository: $repository"
        if helm repo add temp-old-repo "$repository" && \
           helm pull "temp-old-repo/$DEPENDENCY_NAME" --version "$OLD_VERSION" --untar; then
            helm repo remove temp-old-repo 2>/dev/null || true
            log_info "Successfully downloaded old chart from Helm repository"
        else
            helm repo remove temp-old-repo 2>/dev/null || true
            log_error "Failed to download old chart from Helm repository"
            return 1
        fi
    fi
    
    # Extract old values.yaml
    if [[ -f "${DEPENDENCY_NAME}/values.yaml" ]]; then
        cp "${DEPENDENCY_NAME}/values.yaml" "old_chart_values.yaml"
        log_info "Extracted old chart values from $DEPENDENCY_NAME"
        return 0
    else
        log_error "No values.yaml found in downloaded $DEPENDENCY_NAME chart"
        return 1
    fi
}

# =============================================================================
# Chart Templating
# =============================================================================

template_chart_with_values() {
    local chart_path="$1"
    local release_name="$2"
    local output_dir="$3"
    local prefix="$4"
    
    log_info "Templating $release_name chart with custom values files..."
    
    local values_files
    mapfile -t values_files < <(ls values.*.yaml 2>/dev/null || true)
    
    if [[ ${#values_files[@]} -eq 0 ]]; then
        log_info "No custom values files found"
        return 0
    fi
    
    for values_file in "${values_files[@]}"; do
        local values_name
        values_name=$(basename "$values_file" .yaml)
        
        log_info "Templating chart with $values_file..."
        
        local output_file="${output_dir}/${prefix}-${values_name}.yaml"
        
        # Template and validate the chart
        local helm_validation_file="${output_dir}/${prefix}-${values_name}-helm-validation.txt"
        
        # Step 1: Helm template with validation
        if helm template "$release_name" "$chart_path" -f "$values_file" --validate --dry-run=server > "$output_file" 2> "$helm_validation_file"; then
            log_info "Helm template validation passed for $values_file"
            
            log_info "Successfully templated chart with $values_file"
        else
            log_error "Helm template validation failed for $values_file"
        fi
        
        
        # Show validation error results
        log_info "Helm template results for $values_file:"
        echo "--- START VALIDATION OUTPUT ---"
        if [[ -s "$helm_validation_file" ]]; then
            cat "$helm_validation_file"
        else
            echo "No validation error output"
        fi
        echo "--- END VALIDATION OUTPUT ---"
    done
}

template_new_charts() {
    template_chart_with_values "./charts/$DEPENDENCY_NAME" "new-release" "new_templates" "new-template"
}

template_old_charts() {
    template_chart_with_values "./$DEPENDENCY_NAME" "old-release" "old_templates" "old-template"    
    # Cleanup extracted old chart directory
    rm -rf "$DEPENDENCY_NAME"
}

# =============================================================================
# Comparison Functions
# =============================================================================

compare_template_manifests() {
    log_info "Comparing rendered manifests..."
    
    local template_diffs_exist=false
    local values_files
    mapfile -t values_files < <(ls values.*.yaml 2>/dev/null || true)
    
    for values_file in "${values_files[@]}"; do
        local values_name
        values_name=$(basename "$values_file" .yaml)
        
        local old_template="old_templates/old-template-${values_name}.yaml"
        local new_template="new_templates/new-template-${values_name}.yaml"
        
        log_info "Comparing rendered manifests for $values_file..."
        
        # Check if both template files exist and have content
        if [[ -s "$old_template" ]] && [[ -s "$new_template" ]]; then
            log_info "Both templates exist, comparing manifests..."
            
            # Show debug info
            log_debug "First 10 lines of OLD template:"
            head -10 "$old_template" || echo "Cannot read old template"
            log_debug "First 10 lines of NEW template:"
            head -10 "$new_template" || echo "Cannot read new template"
            
            # Compare manifests
            local diff_file="diff_outputs/template_diff_${values_name}.txt"
            dyff between "$old_template" "$new_template" --color=off > "$diff_file" || true
            
            if [[ -s "$diff_file" ]]; then
                log_info "Found manifest differences for $values_file"
                template_diffs_exist=true
                echo "template_diff_${values_name}_exists=true" >> "$GITHUB_OUTPUT"
            else
                log_info "No manifest differences for $values_file"
                echo "template_diff_${values_name}_exists=false" >> "$GITHUB_OUTPUT"
            fi
        else
            log_info "Skipping manifest diff for $values_file - template files missing or empty"
            echo "template_diff_${values_name}_exists=false" >> "$GITHUB_OUTPUT"
        fi
    done
    
    
    echo "template_diffs_exist=$template_diffs_exist" >> "$GITHUB_OUTPUT"
    log_info "Template manifest comparison completed"
}

compare_chart_default_values() {
    log_info "Comparing chart default values..."
    
    # Compare old chart defaults with new chart defaults
    dyff between old_chart_values.yaml chart_default_values.yaml --color=off > diff_outputs/chart_diff.txt || true
    
    # Check if differences exist
    local chart_has_diff
    chart_has_diff=$([[ -s diff_outputs/chart_diff.txt ]] && echo "true" || echo "false")
    echo "chart_has_diff=$chart_has_diff" >> "$GITHUB_OUTPUT"
    
    log_info "Chart default values comparison completed"
}

# =============================================================================
# Early Exit Conditions
# =============================================================================


check_early_exit_conditions() {
    local template_diffs_exist="$1"
    
    # Check if no changes detected - early exit for safe merges
    if [[ ! -s diff_outputs/chart_diff.txt && "$template_diffs_exist" != "true" ]]; then
        log_info "No chart default differences detected - this is a safe version bump"
        
        apply_label "ready-to-merge" "Safe to merge - no breaking changes" "0e8a16"
        
        create_safe_merge_summary
        post_pr_comment "$PR_NUMBER"
        
        echo "skip_ai=true" >> "$GITHUB_OUTPUT"
        exit 0
    fi
    
    log_info "Chart differences detected - proceeding with AI analysis"
    echo "skip_ai=false" >> "$GITHUB_OUTPUT"
}

# =============================================================================
# AI Analysis
# =============================================================================

apply_ai_fallback_label() {
    local reason="$1"
    
    # Fallback logic: Check helm validation files directly (same as PR comment logic)
    local helm_validation_failed=false
    
    for validation_file in new_templates/*-helm-validation.txt; do
        if [[ -f "$validation_file" ]] && [[ -s "$validation_file" ]]; then
            helm_validation_failed=true
            break
        fi
    done
    
    if [[ "$helm_validation_failed" == "false" ]]; then
        log_info "AI unavailable but helm template validation passed - applying ready-to-merge label"
        remove_analysis_labels
        apply_label "ready-to-merge" "Helm validation passed - safe to merge" "0e8a16"
        
        # Create AI analysis file indicating fallback was used, but don't create error summary
        # This allows the workflow to continue and generate the full report
        echo "AI analysis unavailable - falling back to helm template validation results. Helm validation passed successfully." > ai_analysis.md
    else
        log_info "AI unavailable and helm template failures detected - requires manual review"
        remove_analysis_labels
        apply_label "needs-review" "Helm template failures detected - requires manual review" "fbca04"
        create_ai_error_analysis "$reason - helm template failures detected"
    fi
}


build_ai_prompt() {
    log_info "Building AI prompt..."
    
    # Collect validation errors from new template validation files
    local validation_errors=""
    local values_files
    mapfile -t values_files < <(ls values.*.yaml 2>/dev/null || true)
    
    for values_file in "${values_files[@]}"; do
        local values_name
        values_name=$(basename "$values_file" .yaml)
        
        local helm_validation_file="new_templates/new-template-${values_name}-helm-validation.txt"
        if [[ -s "$helm_validation_file" ]]; then
            validation_errors+="
### Helm Template Validation Error (${values_file}):
\`\`\`
$(cat "$helm_validation_file")
\`\`\`
"
        fi
    done
    
    if [[ -z "$validation_errors" ]]; then
        validation_errors="No helm template validation errors detected."
    fi
    
    cat > full_prompt.txt << EOF
You are a Helm chart upgrade expert. Analyze the following:

IMPORTANT: This analysis is for the '$DEPENDENCY_NAME' dependency within the '$CHART_NAME' chart.
Only focus on configurations related to '$DEPENDENCY_NAME' - ignore any other dependencies in the values files.

1. CHART CHANGES (dyff output between old and new '$DEPENDENCY_NAME' chart default values):
\`\`\`
EOF
    
    # Add chart diff content
    if [[ -s "diff_outputs/chart_diff.txt" ]]; then
        cat diff_outputs/chart_diff.txt >> full_prompt.txt
    else
        echo "No changes detected in chart default values" >> full_prompt.txt
    fi
    
    cat >> full_prompt.txt << EOF
\`\`\`

2. CUSTOM VALUES FILES (focus only on '$DEPENDENCY_NAME' configurations):
\`\`\`yaml
EOF
    
    # Process values files
    add_values_files_to_prompt
    
    cat >> full_prompt.txt << EOF
\`\`\`

3. VALIDATION ERRORS:
$validation_errors

VERSION CONTEXT: $OLD_VERSION → $NEW_VERSION

BREAKING CHANGE RULES:
- ONLY flag as BREAKING if user's custom values will become INVALID
- Removed value paths that user overrides = BREAKING
- Changed value types (string→number) that user overrides = BREAKING
- New REQUIRED values without defaults = BREAKING

NOT BREAKING:
- Version bumps in image tags
- New optional values with defaults
- Added configuration options
- Patch version updates (x.y.Z changes)
- Removed chart defaults that user does NOT override in their values files
- Changes to unused chart features

CRITICAL: Require ACTUAL evidence of user impact, not hypothetical scenarios.
- If user's values files don't reference a removed configuration → NOT breaking
- Don't flag as breaking based on "could be" or "might affect" - only flag when there's direct evidence
- Focus on what the user is actually using in their custom values files

VERSION ANALYSIS:
- If patch version (Z changed): Assume safe unless proven otherwise
- If minor version (Y changed): Check for deprecations
- If major version (X changed): Expect breaking changes

ANALYSIS APPROACH:
1. Check if user's custom values still work with new defaults
2. Verify no required values were added
3. Confirm no used value paths were removed
4. Validate no type changes affect user config

TASK: Analyze the '$DEPENDENCY_NAME' chart upgrade impact by examining chart default changes and custom value overrides.

IGNORE any configurations not related to '$DEPENDENCY_NAME' - they are not relevant to this analysis.

Format your response as:
## AI Analysis Results

### Version Analysis
[Analyze version change type and expected impact level]

### Impact Summary
- BREAKING: X issues found
- WARNING: Y issues found  
- INFO: Z issues found

### Chart Changes Analysis
[Analyze what changed in the chart defaults and how it affects custom configurations]

### Values Configuration Analysis
[Analyze custom value overrides and their compatibility with chart changes]

### Helm Template Validation Analysis
[Analyze any validation errors from helm template validation:
- Assess if validation errors indicate breaking changes or configuration issues
- Distinguish between errors that indicate breaking changes vs environment/infrastructure issues
- Provide specific recommendations for resolving validation issues]

### Recommendations
[Overall recommendations for this upgrade, including validation error resolution]

### Final Decision
Based on the analysis above, provide one of these labels:
- LABEL: breaking-changes (if there are breaking changes that require manual intervention)
- LABEL: ready-to-merge (if changes are safe and can be automatically merged)
- LABEL: needs-review (if uncertain or requires manual verification)
EOF
}

add_values_files_to_prompt() {
    local values_files
    mapfile -t values_files < <(ls values.*.yaml 2>/dev/null || true)
    
    if [[ ${#values_files[@]} -eq 0 ]]; then
        echo "# No custom values files found" >> full_prompt.txt
        return
    fi
    
    local counter=2
    for values_file in "${values_files[@]}"; do
        if [[ -f "$values_file" ]]; then
            local has_dependency
            has_dependency=$(yq eval "has(\"$DEPENDENCY_NAME\")" "$values_file" 2>/dev/null || echo "false")
            
            echo "" >> full_prompt.txt
            echo "$counter. CUSTOM VALUES FILE ($values_file)$([ "$has_dependency" = "true" ] && echo " - $DEPENDENCY_NAME section" || echo ""):" >> full_prompt.txt
            echo '```yaml' >> full_prompt.txt
            
            if [[ "$has_dependency" = "true" ]]; then
                echo "# Only showing $DEPENDENCY_NAME related configurations:" >> full_prompt.txt
                yq eval ".$DEPENDENCY_NAME" "$values_file" >> full_prompt.txt 2>/dev/null || echo "# No $DEPENDENCY_NAME section found" >> full_prompt.txt
            else
                echo "# No $DEPENDENCY_NAME configurations found in this file" >> full_prompt.txt
                echo "# This values file does not contain configurations for the changed dependency ($DEPENDENCY_NAME)" >> full_prompt.txt
            fi
            echo '```' >> full_prompt.txt
        else
            echo "" >> full_prompt.txt
            echo "$counter. CUSTOM VALUES FILE ($values_file):" >> full_prompt.txt
            echo '```yaml' >> full_prompt.txt
            echo "# File not found: $values_file" >> full_prompt.txt
            echo '```' >> full_prompt.txt
        fi
        ((counter++))
    done
}

call_ai_api() {
    log_info "Calling AI API..."
    
    # Create JSON payload
    cat > ai_payload.json << 'EOF'
{
  "model": "openai/gpt-4o",
  "messages": [
    {
      "role": "user",
      "content": ""
    }
  ]
}
EOF
    
    # Insert prompt content safely
    jq --rawfile content full_prompt.txt '.messages[0].content = $content' ai_payload.json > final_payload.json
    
    # Call API with retry logic
    local max_retries=3
    local retry_count=0
    local success=false
    
    while [[ $retry_count -lt $max_retries && "$success" = false ]]; do
        ((retry_count++))
        log_info "API attempt $retry_count of $max_retries..."
        
        local http_status
        http_status=$(curl -w "%{http_code}" -X POST \
            -H "Authorization: Bearer $GH_TOKEN" \
            -H "Content-Type: application/json" \
            -d @final_payload.json \
            "https://models.github.ai/inference/chat/completions" \
            -o ai_response.json)
        
        log_info "HTTP Status: $http_status"
        
        local error_message=$(get_error_message_for_status "$http_status")
        
        case "$http_status" in
            200)
                success=true
                log_info "API call successful"
                break
                ;;
            429)
                if [[ $retry_count -lt $max_retries ]]; then
                    local wait_time=$((retry_count * 30))
                    log_info "$error_message - waiting $wait_time seconds before retry..."
                    sleep "$wait_time"
                else
                    log_error "$error_message after $max_retries attempts"
                fi
                ;;
            413)
                log_error "$error_message. Cannot retry - need to reduce payload size."
                break
                ;;
            *)
                if [[ $retry_count -lt $max_retries ]]; then
                    local wait_time=$((retry_count * 10))
                    log_info "$error_message - waiting $wait_time seconds before retry..."
                    sleep "$wait_time"
                else
                    log_error "$error_message after $max_retries attempts"
                fi
                ;;
        esac
    done
    
    return $([ "$success" = true ] && echo 0 || echo 1)
}
apply_ai_label() {
    local ai_analysis="$1"
    
    remove_analysis_labels
    
    if echo "$ai_analysis" | grep -qi "LABEL.*breaking-changes\|Label.*breaking-changes"; then
        log_info "AI detected breaking changes!"
        echo "breaking_changes=true" >> "$GITHUB_OUTPUT"
        apply_label "breaking-changes" "Breaking changes detected" "d73a49"
    elif echo "$ai_analysis" | grep -qi "LABEL.*ready-to-merge\|Label.*ready-to-merge"; then
        log_info "AI detected no breaking changes - safe to merge"
        echo "breaking_changes=false" >> "$GITHUB_OUTPUT"
        apply_label "ready-to-merge" "Safe to merge" "0e8a16"
    else
        log_info "AI recommends manual review"
        echo "breaking_changes=unknown" >> "$GITHUB_OUTPUT"
        apply_label "needs-review" "Requires manual review" "fbca04"
    fi
}

process_ai_response() {
    if [[ -f ai_response.json && -s ai_response.json ]]; then
        # Check if we got a proper response
        if jq -e '.choices[0].message.content' ai_response.json > /dev/null 2>&1; then
            local ai_analysis
            ai_analysis=$(jq -r '.choices[0].message.content' ai_response.json)
            echo "$ai_analysis" > ai_analysis.md
            log_info "AI analysis completed successfully"
            
            # Extract and apply label from AI response
            apply_ai_label "$ai_analysis"
        else
            log_error "AI response format invalid"
            apply_ai_fallback_label "AI response invalid"
        fi
    else
        log_error "AI analysis failed - no response file"
        apply_ai_fallback_label "AI analysis unavailable"
    fi
}

perform_ai_analysis() {
    build_ai_prompt
    
    if call_ai_api; then
        process_ai_response
    else
        log_error "AI API call failed"
        apply_ai_fallback_label "AI analysis unavailable"
    fi
}

# =============================================================================
# Summary Generation
# =============================================================================

create_failure_summary() {
    local title="$1"
    local description="$2"
    
    cat > diff_summary.md << EOF
## $DEPENDENCY_NAME Chart Version Upgrade Analysis

**Version Upgrade:** $OLD_VERSION → $NEW_VERSION

### $title

**Status:** $description

### AI Analysis

**Result:** **NEEDS MANUAL REVIEW**

Template rendering failures were detected, indicating potential compatibility issues with your values files and the new chart version. Please review the template errors and update your configurations accordingly.

**Label Applied:** \`needs-review\`
EOF
}

create_safe_merge_summary() {
    cat > diff_summary.md << EOF
## $DEPENDENCY_NAME Chart Version Upgrade Analysis

**Version Upgrade:** $OLD_VERSION → $NEW_VERSION

### Chart Default Values Changes

**Status:** No changes in chart default values

### AI Analysis

**Result:** **SAFE TO MERGE**

No changes detected in chart default values, indicating this is a safe version bump with no breaking changes. This update can be automatically merged.

**Label Applied:** \`ready-to-merge\`
EOF
}

create_ai_error_analysis() {
    local error_message="$1"
    
    cat > ai_analysis.md << EOF
## AI Analysis

**Status:** AI analysis unavailable

The automated analysis could not be completed at this time. Please review the changes manually.

**Recommendation:** Review the chart changes and validation results above to determine if this upgrade is safe to merge.
EOF
}

generate_summary_report() {
    local template_diffs_exist="$1"
    
    log_info "Generating comprehensive summary report..."
    
    cat > diff_summary.md << EOF
## $DEPENDENCY_NAME Chart Version Upgrade Analysis

**Version Upgrade:** $OLD_VERSION → $NEW_VERSION

### Rendered Manifest Changes

EOF
    
    add_manifest_changes_to_summary "$template_diffs_exist"
    add_chart_defaults_to_summary
    add_ai_analysis_to_summary
}

add_manifest_changes_to_summary() {
    local template_diffs_exist="$1"
    
    if [[ "$template_diffs_exist" = "true" ]]; then
        echo "**Status:** Rendered manifests have changed" >> diff_summary.md
        echo "" >> diff_summary.md
        
        local values_files
        mapfile -t values_files < <(ls values.*.yaml 2>/dev/null || true)
        
        for values_file in "${values_files[@]}"; do
            local values_name
            values_name=$(basename "$values_file" .yaml)
            
            add_values_file_details "$values_file" "$values_name"
        done
    else
        echo "**Status:** No changes in rendered manifests" >> diff_summary.md
        echo "" >> diff_summary.md
    fi
}

add_values_file_details() {
    local values_file="$1"
    local values_name="$2"
    
    cat >> diff_summary.md << EOF
<details>
<summary>$values_file - Manifest Changes and Validation</summary>

**Validation Results (New Chart):**

<details>
<summary>Helm Template Validation</summary>

\`\`\`
EOF
    
    local new_helm_validation="new_templates/new-template-${values_name}-helm-validation.txt"
    if [[ -s "$new_helm_validation" ]]; then
        cat "$new_helm_validation" >> diff_summary.md
    else
        echo "✅ Helm template validation passed" >> diff_summary.md
    fi
    
    cat >> diff_summary.md << EOF
\`\`\`
</details>

<details>
<summary>kubectl Dry-run Validation</summary>

\`\`\`
EOF
    
    local new_kubectl_validation="new_templates/new-template-${values_name}-kubectl-validation.txt"
    if [[ -s "$new_kubectl_validation" ]]; then
        cat "$new_kubectl_validation" >> diff_summary.md
    else
        echo "✅ kubectl dry-run validation passed" >> diff_summary.md
    fi
    
    cat >> diff_summary.md << EOF
\`\`\`
</details>

EOF
    
    # Add template differences if they exist
    local diff_file="diff_outputs/template_diff_${values_name}.txt"
    if [[ -s "$diff_file" ]]; then
        cat >> diff_summary.md << EOF
**Manifest Changes:**
\`\`\`yaml
# Changes in rendered Kubernetes manifests
EOF
        cat "$diff_file" >> diff_summary.md
        echo '```' >> diff_summary.md
    else
        echo "**Manifest Changes:** No differences detected" >> diff_summary.md
    fi
    
    echo "</details>" >> diff_summary.md
    echo "" >> diff_summary.md
}

add_chart_defaults_to_summary() {
    echo "### Chart Default Values Changes" >> diff_summary.md
    echo "" >> diff_summary.md
    
    if [[ -s "diff_outputs/chart_diff.txt" ]]; then
        cat >> diff_summary.md << EOF
**Status:** Chart defaults have changed

<details>
<summary>View Chart Default Changes</summary>

\`\`\`yaml
# Changes in chart default values
EOF
        cat diff_outputs/chart_diff.txt >> diff_summary.md
        cat >> diff_summary.md << EOF
\`\`\`
</details>
EOF
    else
        echo "**Status:** No changes in chart default values" >> diff_summary.md
    fi
    
    echo "" >> diff_summary.md
}

add_ai_analysis_to_summary() {
    if [[ -f "ai_analysis.md" ]]; then
        cat ai_analysis.md >> diff_summary.md
    else
        cat >> diff_summary.md << EOF
## AI Analysis

AI analysis was not available for this run.
EOF
    fi
}

post_pr_comment() {
    local pr_number="$1"
    
    log_info "Posting PR comment..."
    gh pr comment "$pr_number" --body-file diff_summary.md
}

# =============================================================================
# Cleanup
# =============================================================================

cleanup_workspace() {
    log_info "Cleaning up workspace..."
    # Add any cleanup operations here if needed
}

# =============================================================================
# Export functions for use in workflow
# =============================================================================

# This allows the workflow to source this file and use all functions
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Script is being executed directly, not sourced
    log_error "This script should be sourced, not executed directly"
    exit 1
fi