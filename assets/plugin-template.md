# Plugin Template: Minimal wgm Plugin Structure

This template shows the minimal structure for a wgm plugin. Copy this and adapt for your skill.

## File Structure

```
~/.copilot/skills/my-plugin/
  ├── plugin.toml              # Plugin metadata (required)
  ├── PLUGIN.md                # Plugin documentation
  ├── SKILL.md                 # Copilot skill definition
  ├── my_plugin.py             # Implementation
  ├── requirements.txt         # Dependencies (if any)
  └── README.md                # For users
```

## plugin.toml (Required)

```toml
[plugin]
name = "my-plugin"
version = "1.0.0"
description = "Brief description of what this plugin does"
author = "Your Name"
license = "MIT"

# Which lifecycle hooks this plugin implements
lifecycle = ["plan"]  # or ["validate"] or ["plan", "validate"] or ["custom"]

# Soft dependencies (warn if missing, but don't fail)
requires = []  # e.g., ["my_api_key"]

# Hard dependencies (fail if missing)
depends_on = []  # e.g., ["python:3.10", "curl"]

# Timeout in seconds (max time for invoke() call)
timeout = 10

# Default enablement (can be overridden per-project)
enabled_by_default = true
```

## PLUGIN.md (Recommended)

```markdown
# My Plugin for wgm

Brief description. What problem does this solve? When should wgm invoke it?

## Hooks Implemented

### plan

**When:** After Plan phase writes specs.

**What it does:** [Your description]

**Example output:**
\`\`\`json
{
  "success": true,
  "summary": "...",
  "error": null
}
\`\`\`

## Configuration

Optional environment variables or project-level settings:

- `MY_PLUGIN_API_KEY`: API key for external service

## Error Handling

This plugin handles:
- Missing API key → returns helpful error
- Network timeout → returns timeout error
- [Other specific errors]

## Testing

To test locally:

\`\`\`bash
cd ~/.copilot/skills/my-plugin
python3 -c "from my_plugin import invoke; result = invoke('plan', {...}); print(result)"
\`\`\`
```

## my_plugin.py (Implementation)

```python
"""My wgm Plugin

Implements the plugin protocol for wgm lifecycle hooks.
"""

import os
import json
from typing import Dict, Any


def invoke(hook_name: str, context: Dict[str, Any]) -> Dict[str, Any]:
    """
    Main plugin entry point.
    
    Args:
        hook_name: "plan", "validate", or custom hook name
        context: Hook-specific context dict (see PLUGIN_PROTOCOL.md)
    
    Returns:
        Hook-specific result dict with success/error status
    """
    try:
        if hook_name == "plan":
            return handle_plan(context)
        elif hook_name == "validate":
            return handle_validate(context)
        else:
            return {
                "success": False,
                "error": f"Unknown hook: {hook_name}"
            }
    except Exception as e:
        # Always catch and return error dict; never raise
        return {
            "success": False,
            "error": f"Plugin error: {str(e)}"
        }


def handle_plan(context: Dict[str, Any]) -> Dict[str, Any]:
    """Handle plan phase hook."""
    
    # TODO: Implement your plan-phase logic
    # Example: search for relevant prior art, validate architecture choices, etc.
    
    spec_title = context.get("spec_title", "")
    search_terms = context.get("search_terms", [])
    
    # Your logic here...
    # result = your_api_call(search_terms)
    
    return {
        "success": True,
        "summary": f"Plan hook: processed spec '{spec_title}'",
        "error": None
    }


def handle_validate(context: Dict[str, Any]) -> Dict[str, Any]:
    """Handle validate phase hook."""
    
    # TODO: Implement your validate-phase logic
    # Example: verify solution against prior knowledge, publish learnings, etc.
    
    task_title = context.get("task_title", "")
    outcome = context.get("outcome", "")
    
    # Your logic here...
    # verified = your_verify_logic(task_title, outcome)
    
    return {
        "success": True,
        "verified": True,
        "error": None
    }


# Optional: Helper functions for your plugin's logic

def check_dependencies() -> Dict[str, bool]:
    """Check if required dependencies are available."""
    return {
        "api_key": bool(os.environ.get("MY_PLUGIN_API_KEY")),
        # Add other checks
    }


# Optional: If your plugin needs initialization, you can do it here
if __name__ == "__main__":
    # Test invocation
    test_context = {
        "phase": "plan",
        "spec_title": "Test Spec",
        "search_terms": ["test"]
    }
    result = invoke("plan", test_context)
    print(json.dumps(result, indent=2))
```

## requirements.txt (If Needed)

```
# Add external dependencies here
# requests>=2.28.0
# click>=8.0.0
```

## Integration Checklist

- [ ] `plugin.toml` has correct `name` (matches skill directory)
- [ ] `invoke()` is implemented and handles errors
- [ ] Both supported hooks (`plan` and/or `validate`) are handled
- [ ] Plugin returns dict (never raises exceptions)
- [ ] Test with: `python3 -c "from my_plugin import invoke; invoke('plan', {...})"`
- [ ] Plugin can be discovered: `ls ~/.copilot/skills/my-plugin/plugin.toml`
- [ ] wgm can load it: `/wgm grill` → check logs for plugin discovery

## Example Invocation (from wgm)

When wgm loads your plugin during Triage, it will:

```python
import importlib.util
spec = importlib.util.spec_from_file_location("my_plugin", "/path/to/my_plugin.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

# During Plan phase:
result = module.invoke("plan", context)
print(result)
# Output: { "success": True, "summary": "...", ... }
```

## Testing Your Plugin

```bash
# 1. Create a test project
mkdir ~/test-my-plugin && cd ~/test-my-plugin
git init

# 2. Run wgm with your plugin
/wgm plan: test feature

# 3. Check logs for plugin invocation
grep "my-plugin" ~/.copilot/skills/wgm/session.log

# 4. Verify your hook was called
grep "my-plugin" .wgm/IMPLEMENTATION_PLAN.md
```

---

**Next Steps:**
1. Fill in `plugin.toml` with your metadata
2. Implement `handle_plan()` and/or `handle_validate()`
3. Test with `/wgm`
4. Document in `PLUGIN.md`
