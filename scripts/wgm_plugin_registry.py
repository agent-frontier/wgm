#!/usr/bin/env python3
"""
WGM Plugin Registry

Discovers and manages wgm plugins. Used by wgm at Triage to load available plugins.

Usage:
    from wgm_plugin_registry import discover_plugins, load_plugin
    
    plugins = discover_plugins()
    print(plugins)
    # Output: { "sofaking": {...}, "my-plugin": {...} }
    
    result = load_plugin("sofaking", "plan", context)
    print(result)
"""

import os
import sys
import json
from pathlib import Path
from typing import Dict, Any


def discover_plugins() -> Dict[str, Dict[str, Any]]:
    """
    Scan ~/.copilot/skills/ for plugin.toml files and load metadata.
    
    Returns:
        Dict mapping plugin name → metadata dict
    """
    plugins = {}
    skills_dir = Path.home() / ".copilot" / "skills"
    
    if not skills_dir.exists():
        return plugins
    
    for skill_dir in skills_dir.iterdir():
        if not skill_dir.is_dir():
            continue
        
        plugin_file = skill_dir / "plugin.toml"
        if not plugin_file.exists():
            continue
        
        try:
            metadata = _parse_plugin_toml(plugin_file)
            metadata["path"] = str(skill_dir)
            plugins[metadata["name"]] = metadata
        except Exception as e:
            print(f"WARN: Failed to load plugin {skill_dir.name}: {e}", file=sys.stderr)
    
    return plugins


def _parse_plugin_toml(toml_file: Path) -> Dict[str, Any]:
    """Parse a plugin.toml file."""
    try:
        import tomllib
    except ImportError:
        try:
            import tomli as tomllib
        except ImportError:
            import toml as tomllib
    
    with open(toml_file, "r") as f:
        if hasattr(tomllib, "loads"):
            data = tomllib.loads(f.read())
        else:
            data = tomllib.load(f)
    
    plugin = data.get("plugin", {})
    
    return {
        "name": plugin.get("name", "unknown"),
        "version": plugin.get("version", "0.0.0"),
        "description": plugin.get("description", ""),
        "lifecycle": plugin.get("lifecycle", []),
        "requires": plugin.get("requires", []),
        "depends_on": plugin.get("depends_on", []),
        "timeout": plugin.get("timeout", 10),
        "enabled_by_default": plugin.get("enabled_by_default", True)
    }


def check_soft_dependencies(plugin: Dict[str, Any]) -> Dict[str, bool]:
    """Check if plugin's soft dependencies are available."""
    status = {}
    for req in plugin.get("requires", []):
        status[req] = _check_dependency(req)
    return status


def _check_dependency(req: str) -> bool:
    """Check if a requirement is available."""
    if req == "sofa_api_key":
        return bool(os.environ.get("SOFA_API_KEY"))
    return True


def load_plugin(plugin_name: str, hook_name: str, context: Dict[str, Any]) -> Dict[str, Any]:
    """
    Load and invoke a plugin's hook.
    
    Returns:
        Hook result dict (success/error status + hook-specific data)
    """
    plugins = discover_plugins()
    
    if plugin_name not in plugins:
        return {
            "success": False,
            "error": f"Plugin not found: {plugin_name}"
        }
    
    plugin = plugins[plugin_name]
    
    # Check hard dependencies
    for dep in plugin.get("depends_on", []):
        if not _check_dependency(dep):
            return {
                "success": False,
                "error": f"Plugin dependency not met: {dep}"
            }
    
    # Warn about soft dependencies
    soft_deps = check_soft_dependencies(plugin)
    for req, status in soft_deps.items():
        if not status:
            print(
                f"WARN: Plugin {plugin_name} requires {req} (not found); "
                f"plugin may fail or degrade",
                file=sys.stderr
            )
    
    # Check if hook is supported
    if hook_name not in plugin.get("lifecycle", []):
        return {
            "success": False,
            "error": f"Plugin {plugin_name} does not support hook: {hook_name}"
        }
    
    # Load and invoke the plugin module
    try:
        module = _load_plugin_module(plugin)
        result = module.invoke(hook_name, context)
        return result
    except Exception as e:
        return {
            "success": False,
            "error": f"Plugin error: {str(e)}"
        }


def _load_plugin_module(plugin: Dict[str, Any]):
    """Dynamically load a plugin's Python module."""
    import importlib.util
    
    plugin_dir = Path(plugin["path"])
    
    # Try common naming patterns
    for pattern in [f"{plugin['name']}.py", f"{plugin['name']}_plugin.py"]:
        module_file = plugin_dir / pattern
        if module_file.exists():
            spec = importlib.util.spec_from_file_location(plugin["name"], module_file)
            if spec and spec.loader:
                module = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(module)
                return module
    
    raise FileNotFoundError(f"No module found for plugin: {plugin['name']}")


def list_plugins_cli():
    """CLI: List all available plugins."""
    plugins = discover_plugins()
    
    if not plugins:
        print("No plugins found in ~/.copilot/skills/")
        return
    
    print(f"\n{len(plugins)} plugin(s) available:\n")
    for name, meta in sorted(plugins.items()):
        print(f"  📦 {name} ({meta['version']})")
        print(f"     Lifecycle: {', '.join(meta['lifecycle'])}")
        if meta.get("requires"):
            deps = check_soft_dependencies(meta)
            missing = [req for req, status in deps.items() if not status]
            if missing:
                print(f"     ⚠️  Missing: {', '.join(missing)}")
        print()


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "list":
        list_plugins_cli()
    else:
        plugins = discover_plugins()
        print(json.dumps(plugins, indent=2))
