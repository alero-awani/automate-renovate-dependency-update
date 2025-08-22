# Breaking Changes Detection for Helm Updates

## Problem

Renovate provides valuable automation by:

- Detecting new Helm chart versions
- Creating PRs with version bumps
- Including upstream release notes
- Updating Chart.lock files

However, teams must still manually:

- Review release notes to identify breaking changes
- Cross-reference breaking changes with values.yaml configurations
- Determine if removed/deprecated keys affect our deployments before merging

The solution is to:

Enhance Renovate workflow with an automated breaking change analysis pipeline so that:

1. When Renovate creates a PR, automatically fetch and compare old and new values, identify breaking changes, deprecated features, and configuration
changes.
2. Compare identified breaking changes against our current values.yaml files to determine if any removed/deprecated keys, configuration format changes, or version requirements affect our specific setup.
3. Enhanced Release Notes: Augment Renovate's existing release notes using AI with the analysis, clearly flagging:
    - Breaking changes that affect the current configuration
    - Safe updates that can be auto-merged
4. Automated Decision Making: Based on the analysis, automatically categorize PRs and label as:
    - Safe for auto-merge (no breaking changes affecting our config)
    - Requires migration (breaking changes with clear migration path)
    - Needs manual review (complex changes or unclear impact)

## Pipeline Steps

### 1. Trigger Detection

- Workflow triggers on pull request events (opened, synchronize, reopened)
- Validates that changes exist in `k8s/charts/` directory structure
- Exits early if no chart-related files are modified

### 2. Chart and Dependency Detection

- **Chart Detection**: Analyzes git diff to identify which chart directory was modified
- **Dependency Analysis**: Compares Chart.yaml between base and head branches to identify which dependency version changed
- **Version Extraction**: Extracts old version from base branch Chart.yaml and new version from updated chart archive
- **Workspace Setup**: Creates working directories for template comparison and analysis

### 3. Chart Archive Processing

- **New Chart**: Extracts chart archive from `charts/` directory and retrieves default values.yaml
- **Old Chart**: Downloads old chart version from the configured repository (OCI or traditional Helm repo)
- **Values Extraction**: Saves both old and new chart default values for comparison

### 4. Template Rendering

- **Custom Values Processing**: Identifies all `values.*.yaml` files in the chart directory
- **Template Generation**: Renders Helm templates for both old and new chart versions using each custom values file
- **Validation Tracking**: Captures any template rendering failures or validation errors
- **Output Organization**: Saves rendered manifests in separate directories for comparison

### 5. Default Values Comparison

- **Chart Defaults Comparison**: Uses dyff to compare old vs new chart default values
- **Manifest Comparison**: Compares rendered Kubernetes manifests for each values file
- **Change Detection**: Identifies if any meaningful differences exist between versions

### 6. Early Exit Conditions

- **Template Failure Check**: If any templates fail to render, applies "needs-review" label and exits
- **No Changes Check**: If no chart defaults or manifest differences exist, applies "ready-to-merge" label and exits
- **Continuation Logic**: Only proceeds to AI analysis if actual changes are detected

### 7. AI-Powered Analysis

- **Prompt Construction**: Builds comprehensive prompt including:
  - Version context (old version → new version)
  - Chart default value changes (dyff output)
  - Custom values files (filtered to relevant dependency only)
  - Breaking change evaluation rules
- **API Call**: Sends analysis request to GitHub Models API with retry logic for rate limiting
- **Response Processing**: Extracts AI analysis and recommended label from response

### 8. Decision Making and Labeling

- **Pattern Matching**: Analyzes AI response for explicit label recommendations
- **Label Application**: Applies one of three labels based on analysis:
  - `breaking-changes`: Manual intervention required due to incompatible changes
  - `ready-to-merge`: Safe to merge automatically with no breaking changes
  - `needs-review`: Uncertain impact requiring human evaluation
- **Fallback Logic**: Defaults to "needs-review" if AI analysis fails or is unclear

### 9. Summary Report Generation

- **Comprehensive Report**: Creates detailed markdown summary including:
  - Version upgrade information
  - Rendered manifest changes with validation results
  - Chart default value differences
  - Complete AI analysis with recommendations
- **Structured Output**: Organizes information in collapsible sections for easy review

### 10. PR Comment and Output

- **Comment Posting**: Adds generated summary as PR comment for team visibility
- **GitHub Outputs**: Sets workflow outputs for downstream automation:
  - `breaking_changes`: Boolean indicating if breaking changes detected
  - `chart_name`, `dependency_name`: Identification information
  - Template validation results for each values file
- **Label Visibility**: Applied labels provide immediate visual indication of PR safety

### 11. Error Handling and Cleanup

- **Comprehensive Error Handling**: Captures and reports specific failure types:
  - Authentication/authorization failures
  - Rate limiting with exponential backoff
  - Payload size limitations
  - Network and server errors
- **Detailed Logging**: Provides step-by-step execution logs for debugging
- **Workspace Cleanup**: Removes temporary files and directories after analysis

## Technical Considerations

### AI Payload Size Limitations

The pipeline is designed around a critical constraint: **rendered Helm template diffs cannot be fed directly to AI models** due to payload size limitations.

**Why Template Diffs Are Too Large:**

- Modern Kubernetes applications generate extensive YAML manifests
- Template diffs between versions can easily exceed 100KB-1MB in size
- AI model context windows and API payload limits (typically 128KB-1MB) cannot accommodate full template comparisons
- Network timeouts and processing costs make large payload analysis impractical

**Pipeline Design Solutions:**

- **Chart Defaults Focus**: AI analyzes only the chart's default values.yaml changes (typically <10KB)
- **Values-Centric Analysis**: Evaluates how chart changes affect user's custom values files
- **Template Diffs for Humans**: Full template comparisons are generated and included in PR comments for manual review
- **Smart Filtering**: Only dependency-specific configurations are sent to AI, reducing noise

**What AI Analyzes:**

- Chart default value changes (dyff output)
- User's custom values files (filtered to relevant dependency)
- Version context and semantic versioning implications
- Breaking change patterns based on configuration compatibility

**What Humans Review:**
- Complete rendered manifest differences
- Template validation errors and warnings
- Full context of Kubernetes resource changes
- Complex migration scenarios requiring domain knowledge

This hybrid approach leverages AI for configuration compatibility analysis while preserving human oversight for complex deployment changes that require full context understanding.

### Enhanced Validation with Kind Cluster

The pipeline automatically sets up a kind (Kubernetes in Docker) cluster within the GitHub Actions workflow for comprehensive validation:

**Automated Kind Cluster:**
- Workflow creates ephemeral kind cluster for each PR analysis
- No manual cluster setup required - fully automated in CI/CD
- Provides production-like Kubernetes environment for validation

**Two-Level Validation Process:**
1. **Helm Template Validation** (`helm template --validate`):
   - Validates chart syntax and template rendering
   - Checks for basic Kubernetes resource format compliance
   - Fast initial validation layer

2. **kubectl Dry-run Validation** (`kubectl apply --dry-run=server`):
   - Validates against actual Kubernetes API server in kind cluster
   - Checks admission controllers, resource quotas, and RBAC policies
   - Validates CRD compatibility and API version availability
   - Catches deployment issues that template validation alone cannot detect

**Enhanced Error Analysis:**

- Both validation types captured separately for detailed troubleshooting
- Validation errors automatically fed to AI for contextual analysis and recommendations
- PR comments include comprehensive validation results with clear success/failure indicators
- Pipeline intelligently handles validation failures before proceeding to breaking change analysis





- Old chart: Just templated for diff comparison
- New chart: Templated AND validated against the kind cluster for deployment readiness

  1. `helm template (no dry-run)` → Always produces YAML for diffing
  2. `kubectl apply --dry-run=server` → Validates that YAML against cluster