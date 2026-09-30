#!/usr/bin/env python3
"""Install a verified local release bundle; never stop Hermes or run inference."""
import argparse
from collections.abc import Mapping
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import tempfile
import uuid

NAME = "fleet-liveops"
VERSION = "0.3.0"
RUNTIME_FILES = ("plugin.yaml", "__init__.py", "push_store.py", "push_payload.py",
                 "push_sender.py", "dashboard/manifest.json", "dashboard/plugin_api.py",
                 "dashboard/index.js")


class SetupError(Exception):
    pass


def verify_bundle(bundle):
    try:
        manifest = json.loads((bundle / "release.json").read_text())
        if manifest["version"] != VERSION or set(manifest["files"]) != set(RUNTIME_FILES):
            raise SetupError("This setup bundle has an incompatible manifest. Download it again.")
        plugin = bundle / "plugin"
        if plugin.is_symlink():
            raise SetupError("The plugin directory is a symlink. Download the complete ZIP again.")
        actual = {p.relative_to(plugin).as_posix() for p in plugin.rglob("*") if p.is_file()}
        if actual != set(RUNTIME_FILES) or any(p.is_symlink() for p in plugin.rglob("*")):
            raise SetupError("The plugin bundle contains unexpected files. Download it again.")
        for name in RUNTIME_FILES:
            if hashlib.sha256((plugin / name).read_bytes()).hexdigest() != manifest["files"][name]:
                raise SetupError("The plugin bundle failed its integrity check. Download it again.")
        return plugin
    except (OSError, KeyError, ValueError, TypeError) as exc:
        raise SetupError("Cannot verify this setup bundle. Download the complete ZIP again.") from exc


def regular_file(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or path.is_symlink():
        raise SetupError("A configuration file is not a regular file. No changes were made.")
    if hasattr(os, "getuid") and info.st_uid != os.getuid():
        raise SetupError("A configuration file belongs to another user. No changes were made.")
    return path.read_bytes(), stat.S_IMODE(info.st_mode)


def discover_profiles(root):
    if root.is_symlink() or not (root / "config.yaml").is_file():
        raise SetupError("Hermes configuration was not found. Install Hermes first or specify --hermes-root.")
    profiles = {"default": root / "config.yaml"}
    directory = root / "profiles"
    if directory.is_symlink():
        raise SetupError("The profiles directory is a symlink. Choose a physical Hermes root.")
    if directory.exists():
        for profile in sorted(directory.iterdir()):
            if profile.is_symlink():
                raise SetupError("A profile directory is a symlink. No changes were made.")
            if profile.is_dir() and (profile / "config.yaml").exists():
                if not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}", profile.name) or profile.name == "default":
                    raise SetupError("A profile name is unsupported. No changes were made.")
                profiles[profile.name] = profile / "config.yaml"
    return profiles


def enabled_config(raw, yaml_factory):
    yaml = yaml_factory()
    yaml.preserve_quotes = True
    try:
        config = yaml.load(raw.decode("utf-8"))
        if not isinstance(config, Mapping):
            raise ValueError()
        plugins = config.setdefault("plugins", {})
        if not isinstance(plugins, Mapping):
            raise ValueError()
        for field in ("enabled", "disabled"):
            values = plugins.get(field, [])
            if not isinstance(values, list) or any(not isinstance(value, str) for value in values):
                raise ValueError()
        if NAME in plugins.get("enabled", []) and NAME not in plugins.get("disabled", []):
            return raw
        if NAME not in plugins.get("enabled", []):
            plugins.setdefault("enabled", []).append(NAME)
        if NAME in plugins.get("disabled", []):
            plugins["disabled"].remove(NAME)
        output = io.StringIO()
        yaml.dump(config, output)
        return output.getvalue().encode("utf-8")
    except Exception as exc:
        raise SetupError("A profile configuration could not be safely updated. No changes were made.") from exc


def private_directory(path):
    if path.is_symlink():
        raise SetupError("An installation directory is a symlink. No changes were made.")
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not path.is_dir() or (hasattr(os, "getuid") and path.stat().st_uid != os.getuid()):
        raise SetupError("An installation directory is not owned by this user.")
    path.chmod(0o700)


def write_atomic(path, data, mode):
    fd, temp = tempfile.mkstemp(prefix=".fleet-setup-", dir=path.parent)
    temp = Path(temp)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        temp.chmod(mode)
        os.replace(temp, path)
    finally:
        temp.unlink(missing_ok=True)


def install(root, plugin, selected, yaml_factory, scanner):
    """Preflight everything, scan normally, then commit with private recovery copies."""
    if os.name != "posix":
        raise SetupError("Guided setup currently supports Mac and Linux. Use the manual installation instructions for other platforms.")
    profiles = discover_profiles(root)
    if not selected or any(name not in profiles for name in selected):
        raise SetupError("Select existing Hermes profiles.")
    selected = list(dict.fromkeys(selected))
    configs = {}
    for name in selected:
        raw, mode = regular_file(profiles[name])
        configs[name] = (raw, enabled_config(raw, yaml_factory), mode)
    # A shared-root plugin also serves the Fleet gateway; always enable default.
    if "default" not in configs:
        raw, mode = regular_file(profiles["default"])
        configs["default"] = (raw, enabled_config(raw, yaml_factory), mode)
    scanner(plugin)  # Must refuse a blocked scan or unavailable scanner.
    plugins = root / "plugins"
    private_directory(plugins)
    target = plugins / NAME
    if target.is_symlink() or (target.exists() and not target.is_dir()):
        raise SetupError("The installed plugin is not a regular directory.")
    if target.exists():
        try:
            yaml = yaml_factory()
            existing = str(yaml.load((target / "plugin.yaml").read_text())["version"])
            if tuple(map(int, existing.split("."))) > tuple(map(int, VERSION.split("."))):
                raise SetupError("A newer Fleet Live Reporting version is installed. Use its setup bundle.")
        except (OSError, KeyError, ValueError, TypeError) as exc:
            raise SetupError("Cannot identify the existing plugin. No changes were made.") from exc
    code_changed = not target.exists() or any(
        not (target / name).is_file() or (target / name).is_symlink()
        or (target / name).read_bytes() != (plugin / name).read_bytes() for name in RUNTIME_FILES)
    changed_configs = {name: values for name, values in configs.items() if values[0] != values[1]}
    if not code_changed and not changed_configs:
        return False
    backups = root / "backups"
    private_directory(backups)
    backup = backups / ("fleet-liveops-" + uuid.uuid4().hex)
    private_directory(backup)
    for name, (raw, _, _) in changed_configs.items():
        write_atomic(backup / (name + ".yaml"), raw, 0o600)
    # Avoid overwriting settings that changed while the setup review was open.
    if any(regular_file(profiles[name])[0] != values[0] for name, values in configs.items()):
        raise SetupError("Hermes settings changed during setup. Retry after closing Settings.")
    stage = Path(tempfile.mkdtemp(prefix=".fleet-liveops-", dir=plugins))
    installed_new = moved_old = False
    written = []
    try:
        for name in RUNTIME_FILES:
            destination = stage / name
            destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            write_atomic(destination, (plugin / name).read_bytes(), 0o600)
        if code_changed:
            if target.exists():
                os.replace(target, backup / "plugin")
                moved_old = True
            os.replace(stage, target)
            installed_new = True
        for name, (raw, updated, mode) in changed_configs.items():
            if regular_file(profiles[name])[0] != raw:
                raise SetupError("Hermes settings changed during setup. Retry after closing Settings.")
            write_atomic(profiles[name], updated, mode)
            written.append(name)
    except Exception as exc:
        for name in reversed(written):
            raw, updated, mode = configs[name]
            if regular_file(profiles[name])[0] == updated:
                write_atomic(profiles[name], raw, mode)
        if installed_new:
            shutil.rmtree(target)
        if moved_old:
            os.replace(backup / "plugin", target)
        raise SetupError("Setup did not finish. Changes were rolled back; private backups are retained.") from exc
    finally:
        if stage.exists():
            shutil.rmtree(stage)
    return True


def runtime_scanner(plugin):
    from tools.plugin_guard import scan_plugin, should_allow_plugin_install
    result = scan_plugin(plugin, source="Fleet Live Reporting " + VERSION)
    allowed, _ = should_allow_plugin_install(result, force=False)
    if allowed is not True:
        raise SetupError("Hermes's security scanner did not approve this plugin. Update Hermes or review the plugin in Hermes before retrying. No changes were made.")


def main():
    parser = argparse.ArgumentParser(description="Set up Fleet Live Reporting on the Hermes computer.")
    parser.add_argument("--hermes-root", type=Path)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--profiles", nargs="+")
    group.add_argument("--all-profiles", action="store_true")
    parser.add_argument("--yes", action="store_true", help="Apply the reviewed selection without prompting")
    parser.add_argument("--bundle", type=Path, default=Path(__file__).resolve().parent)
    args = parser.parse_args()
    try:
        from ruamel.yaml import YAML
        from hermes_constants import get_default_hermes_root
        from tools.plugin_guard import scan_plugin  # Require scanner before any write.
        root = args.hermes_root or get_default_hermes_root()
        plugin = verify_bundle(args.bundle)
        profiles = discover_profiles(root)
        names = list(profiles)
        print("Fleet Live Reporting " + VERSION)
        print("Available profiles: " + ", ".join(names))
        if args.all_profiles:
            selected = names
        elif args.profiles:
            selected = args.profiles
        else:
            if args.yes or not sys.stdin.isatty():
                raise SetupError("Specify --profiles or --all-profiles for non-interactive setup.")
            answer = input("Profiles to observe (comma separated, or all): ").strip()
            selected = names if answer.lower() == "all" else [x.strip() for x in answer.split(",") if x.strip()]
        if not selected or any(name not in profiles for name in selected):
            raise SetupError("Select existing profiles from the list above.")
        selected = list(dict.fromkeys(selected))
        print("Selected profiles: " + ", ".join(selected))
        print("The default gateway backend will also be enabled. Existing settings are preserved.")
        print("This installs reporting code and saves private recovery copies. It does not restart Hermes.")
        if not args.yes and input("Install? [y/N]: ").strip().lower() not in ("y", "yes"):
            print("Cancelled. No changes were made.")
            return 0
        changed = install(root, plugin, selected, YAML, runtime_scanner)
        print("Setup complete." if changed else "This version is already installed and the selected profiles are enabled.")
        print("When running work finishes, quit and reopen Hermes Desktop. Restart a separate Fleet gateway service too.")
        print("Then open Fleet > Live Operations setup > Check reporting. Each selected Desktop profile must be opened to start its backend.")
        return 0
    except ImportError:
        print("Setup needs the Hermes Python environment with its YAML library and security scanner. Follow README.txt in this download; no changes were made.", file=sys.stderr)
        return 1
    except SetupError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    except Exception:
        print("Setup could not finish. Private recovery copies, if created, remain in Hermes's backups directory. Check file permissions and retry.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
