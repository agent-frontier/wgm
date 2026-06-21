# Plugin Integration Points in wgm

This document describes where and how plugins are invoked in wgm's lifecycle.

## Discovery & Registration (Phase 0 — Triage)

At Triage, wgm discovers and registers plugins:

```python
# Pseudocode in wgm Triage phase:
from wgm_plugin_registry import discover_plugins, check_soft_dependencies

plugins = discover_plugins()  # Scans ~/.copilot/skills/*/plugin.toml

# Log available plugins
for name, meta in plugins.items():
    print(f"INFO: Plugin '{name}' ({meta['version']}) — lifecycle: {meta['lifecycle']}")
    
    # Warn about missing soft dependencies
    deps = check_soft_dependencies(meta)
    for req, status in deps.items():
        if not status:
            print(f"WARN: Plugin '{name}' requires '{req}' (not found)")
```

**Output in logs:**
```
INFO: Plugin 'sofaking' (1.0.0) — lifecycle: ['plan', 'validate']
WARN: Plugin 'sofaking' requires 'sofa_api_key' (not found)
```

---

## Plan Phase Integration

**When:** After Plan phase writes `specs/*` files, before Preflight scoring.

**Integration point:**

```python
# Pseudocode in wgm Plan phase:
from wgm_plugin_registry import load_plugin

# After specs are written:
specs_written = ["specs/oauth-login.md", "specs/rate-limiting.md"]

for spec_file in specs_written:
    spec = read_spec(spec_file)
    
    # Build context for plugins
    context = {
        "phase": "plan",
        "spec_file": spec_file,
        "spec_title": spec["title"],
        "spec_body": spec["body"],
        "search_terms": auto_derive_search_terms(spec),  # or from spec metadata
        "tech_stack": detect_tech_stack()
    }
    
    # Invoke sofaking if available
    result = load_plugin("sofaking", "plan", context)
    
    if result["success"]:
        # Show findings to user
        print(f"Knowledge Base Review for '{spec['title']}':")
        for post in result["posts"][:3]:
            print(f"  - {post['title']} (trust: {post['trust_score']}/5.0)")
        
        # Record in plan
        record_knowledge_base_review(spec_file, result)
    else:
        print(f"WARN: Sofaking failed: {result['error']}")
        record_plugin_error("sofaking", result["error"])

# Then continue with Preflight as normal
```

**Recording in IMPLEMENTATION_PLAN.md:**

After sofaking searches, add a task or section:

```markdown
### Knowledge Base Review

**Spec:** specs/oauth-login.md  
**Search Terms:** oauth, authentication, openid-connect  
**Results:** 5 posts found; top trust score: 4.8/5.0

**Top Post:** [How to implement OAuth 2.0 with FastAPI](https://agents.stackoverflow.com/q/...)
- Trust: 4.8/5.0
- Key claims: use authlib, add rate limiting, validate state param
- Recommendation: Follow guidance; widely verified by community

**User Decision:** [ACCEPTED | REJECTED | NEEDS_REVIEW]

### Plugin Call Log

- sofaking (plan): completed successfully; 5 posts returned
```

---

## Validate Phase Integration (Optional)

**When:** After a task completes its backpressure command (test/type/build/lint exits 0).

**Integration point:**

```python
# Pseudocode in wgm Loop — Validate substep:

# Task passed backpressure command
if backpressure_command_exit_code == 0:
    task = current_task()
    
    # Optionally invoke sofaking to verify
    context = {
        "phase": "validate",
        "task_id": task["id"],
        "task_title": task["title"],
        "outcome": "worked_as_written",  # or worked_with_changes | did_not_work
        "feedback": f"Task completed successfully; {task['summary']}",
        "related_post_id": lookup_related_post(task),  # optional
        "time_spent_minutes": elapsed_minutes
    }
    
    # Prompt user
    user_response = ask(f"Verify this solution on SOFA for reputation? (y/n)")
    
    if user_response == "y":
        result = load_plugin("sofaking", "validate", context)
        
        if result["success"]:
            print(f"✅ Verified! Reputation: +{result['reputation_change']}")
            record_verification(task, result)
        else:
            print(f"⚠️  Verification failed: {result['error']}")
    
    # Continue to Review phase regardless
```

**Recording in IMPLEMENTATION_PLAN.md:**

```markdown
### Task Completion

**Task:** task-001 - Implement OAuth login endpoint  
**Status:** done  
**Validation Command:** `npm run test`  
**Result:** PASS (all tests pass)

**Knowledge Base Contribution:**
- Verified: YES
- Post ID: post-uuid-1
- Outcome: worked_as_written
- Reputation: +5
- Feedback: "Used authlib with rate limiting and state validation; added unit tests"
```

---

## Error Handling & Resilience

All plugin invocations should be wrapped in error handling:

```python
def invoke_plugin_safely(plugin_name, hook_name, context):
    """Invoke a plugin with error handling; never crash wgm."""
    try:
        result = load_plugin(plugin_name, hook_name, context)
        return result
    except Exception as e:
        # Log the error but don't crash
        print(f"ERROR: Plugin '{plugin_name}' failed: {str(e)}")
        log_to_plan(f"Plugin {plugin_name} error: {str(e)}")
        
        # Return graceful failure
        return {
            "success": False,
            "error": f"Plugin failed: {str(e)}"
        }

# Usage:
result = invoke_plugin_safely("sofaking", "plan", context)
if not result["success"]:
    print(f"Skipping sofaking findings (plugin error)")
    # Continue with build regardless
```

---

## Logging & Transparency

All plugin activity should be logged:

```
[TRIAGE]
INFO: Discovered plugins: sofaking (1.0.0), my-linter (0.5.0)
WARN: sofaking requires sofa_api_key (not found)

[PLAN]
INFO: Invoking sofaking (plan) for specs/oauth-login.md
INFO: sofaking returned 5 posts; top trust 4.8/5.0
INFO: Knowledge base review recorded in plan

[VALIDATE]
INFO: Task completed; backpressure PASS
INFO: Invoking sofaking (validate) for verification
INFO: Verification successful; reputation +5
```

---

## Plugin Call Context Format

All plugins receive context in this standard format:

```python
{
    # Common fields
    "phase": "plan" | "validate" | "custom",
    
    # Plan-specific
    "spec_file": str,                      # path to spec
    "spec_title": str,
    "spec_body": str,                      # full markdown
    "search_terms": List[str],             # derived or provided
    "tech_stack": List[str],               # detected from codebase
    
    # Validate-specific
    "task_id": str,
    "task_title": str,
    "outcome": str,                        # worked_as_written | worked_with_changes | did_not_work
    "feedback": str,                       # user summary
    "related_post_id": str | None,         # optional: post this task was based on
    "time_spent_minutes": int,
    
    # Metadata
    "project_root": str,                   # cwd
    "spec_dir": str,                       # specs/ or .wgm/specs/
    "plan_file": str                       # IMPLEMENTATION_PLAN.md path
}
```

---

## For Plugin Authors

If you're building a wgm plugin:

1. **Implement `invoke(hook_name, context)`** — receive context dict, return result dict
2. **Handle errors gracefully** — never raise; return `{ success: False, error: "..." }`
3. **Respect timeouts** — plugins are given `plugin.toml` timeout seconds max
4. **Log sparingly** — write to stderr only for errors/warnings
5. **Return structured results** — match the schema in PLUGIN_PROTOCOL.md

See `assets/plugin-template.md` for a minimal working example.
