# WGM Plugin Protocol

This document specifies the contract for wgm plugins — extensible modules that integrate with wgm's lifecycle to add capabilities like knowledge validation, code analysis, or specialized testing.

## Overview

**Goal:** Enable third-party skills and tools to hook into wgm's lifecycle without modifying wgm itself.

**Core principle:** Plugins are **optional, composable, and fail-safe**. If a plugin is unavailable or errors, wgm continues normally.

## Plugin Discovery

### Registration File

Each plugin is a skill in `~/.copilot/skills/` that publishes a `plugin.toml` file at the root:

```
~/.copilot/skills/sofaking/plugin.toml
~/.copilot/skills/my-linter/plugin.toml
```

### Metadata Format

**plugin.toml** (TOML 1.0):

```toml
[plugin]
name = "sofaking"
version = "1.0.0"
description = "Stack Overflow for Agents knowledge integration"
author = "SchwartzKamel"
license = "MIT"

# Lifecycle hooks this plugin implements
lifecycle = ["plan", "validate"]

# Soft dependencies (non-blocking)
requires = ["sofa_api_key"]

# Hard dependencies (plugin cannot run without these)
depends_on = []

# Timeout for plugin.invoke() calls (seconds)
timeout = 10

# Project-level enablement flag (default: true if installed)
# Can be overridden in specs/CONSTITUTION.md
enabled_by_default = true
```

**Fields:**
- `name`: Unique identifier (must match skill directory name)
- `lifecycle`: List of hooks this plugin implements (`plan`, `validate`, `custom`)
- `requires`: Soft dependencies; plugin warns if missing but doesn't fail
- `depends_on`: Hard dependencies; plugin refuses to run if missing
- `timeout`: Max seconds for a single invocation (prevents hangs)
- `enabled_by_default`: Can be disabled per-project in CONSTITUTION.md

## Lifecycle Hooks

wgm invokes plugins at standard points in its lifecycle:

### `plan` Hook

**When:** After Plan phase writes `specs/*` files, before Preflight readiness scoring.

**Context:**
```python
{
    "phase": "plan",
    "spec_file": "specs/oauth-authentication.md",  # path to spec
    "spec_title": "OAuth Authentication",
    "spec_body": "...",  # full spec markdown
    "search_terms": ["oauth", "authentication", "oidc"],  # auto-derived or user-provided
    "tech_stack": ["python", "fastapi"],  # detected from codebase or spec
    "prior_searches": []  # results from previous plugin calls in this session
}
```

**Expected Output:**
```python
{
    "success": True,  # or False if plugin failed
    "posts": [
        {
            "id": "post-uuid-1",
            "title": "How to implement OAuth 2.0 with FastAPI",
            "url": "https://agents.stackoverflow.com/questions/post-uuid-1",
            "type": "question",  # question | til | blueprint
            "trust_score": 4.8,  # 0–5.0
            "view_count": 234,
            "claims": ["use authlib", "add rate limiting", "validate state param"],
            "summary": "Post discusses FastAPI OAuth implementation with authlib library"
        }
    ],
    "top_post_id": "post-uuid-1",  # most relevant post ID
    "summary": "Found 5 posts on OAuth with FastAPI; top match has 4.8/5 trust",
    "recommendation": "Consider using authlib library; user feedback confirms it works well",
    "error": None  # or error string if something went wrong
}
```

**Integration Point (wgm):**
After `specs/*` are written, wgm:
1. Calls `plugin.invoke("plan", context)` for each enabled plugin with `plan` hook
2. Collects results
3. Summarizes findings for user review
4. Records decision in `IMPLEMENTATION_PLAN.md`:
   ```
   ### Knowledge Base Review (Automated)
   - Searched via sofaking for: oauth, authentication, oidc
   - Top post (ID: post-uuid-1, trust: 4.8/5): "How to implement OAuth 2.0 with FastAPI"
   - Recommendation: Use authlib library with state param validation
   - User decision: [ACCEPTED | REJECTED | NEEDS_REVIEW]
   ```

---

### `validate` Hook

**When:** After a task completes validation (backpressure command exits 0), plugin may contribute to knowledge base.

**Context:**
```python
{
    "phase": "validate",
    "task_id": "task-001",
    "task_title": "Implement OAuth login endpoint",
    "outcome": "worked_as_written",  # or worked_with_changes | did_not_work
    "feedback": "Used authlib with rate limiting; added unit tests for state param validation",
    "related_post_id": None,  # optional: if this task was based on a prior post
    "code_snippet": None,  # optional: key code changes
    "time_spent_minutes": 45
}
```

**Expected Output:**
```python
{
    "success": True,
    "verified": True,  # or False if verification failed
    "post_id": "post-uuid-1",  # the post this verifies
    "reputation_change": 5,  # delta in agent reputation (may be 0)
    "visibility": "public",  # or private; affects where result appears
    "error": None
}
```

**Integration Point (wgm):**
After validation passes, wgm:
1. Asks user: "Publish this solution to the knowledge base?" (optional)
2. Calls `plugin.invoke("validate", context)`
3. Records verification in `IMPLEMENTATION_PLAN.md`:
   ```
   ### Verification (Automated)
   - Task: Implement OAuth login endpoint
   - Outcome: worked_as_written
   - Verified on: 2026-06-20
   - Reputation contribution: +5
   ```

---

### `custom` Hook

Reserved for future specialized plugins. Plugin defines when it fires and what inputs it expects.

---

## Plugin Invocation Interface

### sync `invoke(hook_name, context)`

**Input:**
- `hook_name`: `str` — "plan", "validate", or custom
- `context`: `dict` — hook-specific context (see above)

**Output:**
- `dict` — hook-specific result (see above)

**Error Handling:**
- Plugin must catch all exceptions and return `{ success: False, error: "<message>" }`
- wgm logs the error; does not crash
- If timeout is exceeded, wgm forcibly stops the plugin and returns timeout error

**Example (pseudocode):**

```python
# In sofaking plugin module:
def invoke(hook_name, context):
    try:
        if hook_name == "plan":
            return handle_plan_hook(context)
        elif hook_name == "validate":
            return handle_validate_hook(context)
        else:
            return { "success": False, "error": f"Unknown hook: {hook_name}" }
    except Exception as e:
        return { "success": False, "error": str(e) }

def handle_plan_hook(context):
    # 1. Extract spec and search terms
    search_terms = context["search_terms"]
    
    # 2. Call SOFA API
    posts = search_sofa(search_terms)
    
    # 3. Format and return results
    return {
        "success": True,
        "posts": posts,
        "top_post_id": posts[0]["id"] if posts else None,
        "summary": f"Found {len(posts)} relevant posts",
        "error": None
    }
```

---

## Configuration & Enablement

### Project-Level Control

Projects can enable/disable plugins in `specs/CONSTITUTION.md`:

```markdown
## Plugin Configuration

### Enabled Plugins
- sofaking (all phases)
- my-code-linter (validate phase only)

### Disabled Plugins
- *none*

### Plugin Tuning
sofaking.search_terms_override = ["oauth", "oidc", "sso"]
```

Or simply **omit a plugin to disable it**.

### Soft Dependencies (API Keys, etc.)

If a plugin declares `requires = ["sofa_api_key"]` and the key is missing:
- Plugin logs a helpful message to user
- Plugin returns `{ success: False, error: "SOFA API key not found; set SOFA_API_KEY environment variable" }`
- wgm continues without crashing

---

## Error Handling & Resilience

### Expected Errors

Plugin should handle and return gracefully:

| Error | Plugin Response | wgm Behavior |
|---|---|---|
| API key missing | `{ success: False, error: "..." }` | Log warning; continue |
| API timeout | `{ success: False, error: "Timeout" }` | Log warning; continue |
| Network unreachable | `{ success: False, error: "..." }` | Log warning; continue |
| Plugin crashed | `invoke()` throws | wgm catches; logs; continues |

### Plugin Validation at Discovery

wgm scans plugins at Triage and logs issues:

```
INFO: Plugin discovered: sofaking v1.0.0
WARN: sofaking requires sofa_api_key (not set); plugin will fail gracefully
INFO: Loaded plugins: sofaking(plan,validate)
```

---

## Plugin Development Checklist

Creating a new plugin? Follow these steps:

- [ ] Create skill directory: `~/.copilot/skills/my-plugin/`
- [ ] Add `plugin.toml` with metadata
- [ ] Add `PLUGIN.md` documenting your hooks and configuration
- [ ] Implement `invoke(hook_name, context)` → returns dict matching spec
- [ ] Test error cases: missing dependencies, timeouts, API failures
- [ ] Test integration with wgm: run `/wgm plan: ...` and verify your hook fires
- [ ] Document your plugin's lifecycle hooks (when they fire, what they do)

---

## Example: Minimal Plugin

**~/.copilot/skills/hello-plugin/plugin.toml:**
```toml
[plugin]
name = "hello-plugin"
version = "1.0.0"
lifecycle = ["plan"]
enabled_by_default = true
```

**~/.copilot/skills/hello-plugin/hello_plugin.py:**
```python
def invoke(hook_name, context):
    if hook_name == "plan":
        return {
            "success": True,
            "summary": f"Hello from Plan phase! Spec: {context['spec_title']}",
            "error": None
        }
    return { "success": False, "error": f"Unknown hook: {hook_name}" }
```

**Result:** During Plan, wgm logs:
```
INFO: Plugin hello-plugin (plan): "Hello from Plan phase! Spec: OAuth Authentication"
```

---

## Future Considerations

- **Plugin versioning:** Pins, compatibility checks (TBD)
- **Hot reloading:** Enable/disable plugins without restarting wgm (TBD)
- **Sandbox security:** Isolate plugin execution (TBD; assume trusted code for now)
- **Performance:** Parallel plugin invocation (TBD)
