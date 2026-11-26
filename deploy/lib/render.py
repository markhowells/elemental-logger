#!/usr/bin/env python3
"""Render every managed config file from the versioned templates.

    render.py --env /etc/marine/marine.env --images deploy/images.env \
              --config config --out /var/lib/marine/rendered [--version 1.2.3]

* marine.env is parsed as DATA (KEY=VALUE lines), never executed by a shell.
* *.json templates are parsed, placeholders are substituted structurally (so
  special characters in passwords cannot break the JSON, and numbers/lists/
  booleans keep their type), and the result is re-serialised.
* Other templates get plain text substitution.
* Any unresolved *_PLACEHOLDER, any 'changeme' value, or a missing/too-short
  required value is a hard error and nothing is written.

Placeholders are NAME_PLACEHOLDER and resolve to the variable NAME.
"""
import argparse
import hashlib
import json
import os
import re
import sys

# Non-greedy so adjacent placeholders (SCHEME_PLACEHOLDERDOMAIN_PLACEHOLDER) and
# placeholders directly followed by text (URL_SCHEME_PLACEHOLDERsignalk.) both work.
PLACEHOLDER = re.compile(r"([A-Z][A-Z0-9]*(?:_[A-Z0-9]+)*?)_PLACEHOLDER")
DROP = object()  # sentinel: remove this key from the JSON object

# name: minimum length (None = optional)
REQUIRED = {
    "WIFI_SSID": 4,
    "WIFI_PASSWORD": 8,
    "PORTAINER_ADMIN_PASSWORD": 12,
    "INFLUXDB_USERNAME": 1,
    "INFLUXDB_PASSWORD": 8,
    "INFLUXDB_TOKEN": 32,
    "INFLUXDB_ORG": 1,
    "INFLUXDB_BUCKET": 1,
    "VESSEL_NAME": 1,
}

DEFAULTS = {
    "WIFI_COUNTRY": "GB",
    "VESSEL_MMSI": "",
    "DOMAIN": "elemental.internal",
    "CAN_INTERFACE": "can0",           # can0 in production; vcan0 for bench tests (tools/canswitch.sh)
    "TLS_MODE": "off",                 # off | internal
    "AUTO_APPLY": "no",                # yes | no (marine-update)
    "SIGNALK_ALLOW_READONLY": "false", # anonymous read access to SignalK
    # Plugin behaviour. Defaults reproduce what the live system does today.
    "INFLUX_PLUGIN_DEBUG": "true",
    "INFLUX_RESOLUTION_MS": "0",
    "INFLUX_IGNORED_PATHS": "",        # comma-separated, e.g. electrical.switches.bank.*
}


def parse_env(path):
    out = {}
    with open(path, encoding="utf-8") as fh:
        for n, raw in enumerate(fh, 1):
            line = raw.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            if "=" not in line:
                raise SystemExit(f"{path}:{n}: expected KEY=VALUE")
            key, _, val = line.partition("=")
            key = key.strip()
            val = val.strip()
            if len(val) >= 2 and val[0] == val[-1] and val[0] in "'\"":
                val = val[1:-1]
            if not re.fullmatch(r"[A-Z][A-Z0-9_]*", key):
                raise SystemExit(f"{path}:{n}: bad variable name {key!r}")
            out[key] = val
    return out


def as_bool(v):
    return str(v).strip().lower() in ("1", "true", "yes", "on")


def validate(env):
    errors = []
    for name, minlen in REQUIRED.items():
        v = env.get(name, "")
        if "changeme" in v.lower():
            errors.append(f"{name} still contains 'changeme'")
        elif len(v) < minlen:
            errors.append(f"{name} must be at least {minlen} characters" if v else f"{name} is not set")
    if len(env.get("WIFI_PASSWORD", "")) > 63:
        errors.append("WIFI_PASSWORD must be at most 63 characters")
    if env.get("TLS_MODE") not in ("off", "internal"):
        errors.append("TLS_MODE must be 'off' or 'internal'")
    if env.get("AUTO_APPLY") not in ("yes", "no"):
        errors.append("AUTO_APPLY must be 'yes' or 'no'")
    try:
        if int(env.get("INFLUX_RESOLUTION_MS", "0")) < 0:
            raise ValueError
    except ValueError:
        errors.append("INFLUX_RESOLUTION_MS must be a non-negative integer")
    if not re.fullmatch(r"(s?l?can|vcan)[0-9]+", env.get("CAN_INTERFACE", "")):
        errors.append("CAN_INTERFACE must look like can0 / vcan0")
    if not re.fullmatch(r"[a-z0-9]([a-z0-9.-]*[a-z0-9])?", env.get("DOMAIN", "")):
        errors.append("DOMAIN must be a lowercase hostname, e.g. elemental.internal")
    return errors


def typed_values(env):
    """Typed values for exact-match JSON placeholders (key = variable name)."""
    ignored = [p.strip() for p in env["INFLUX_IGNORED_PATHS"].split(",") if p.strip()]
    mmsi = env["VESSEL_MMSI"].strip()
    return {
        "INFLUX_PLUGIN_DEBUG": as_bool(env["INFLUX_PLUGIN_DEBUG"]),
        "INFLUX_RESOLUTION_MS": int(env["INFLUX_RESOLUTION_MS"]),
        "INFLUX_IGNORED_PATHS": ignored,
        # allow_readonly only when explicitly enabled; otherwise the key is dropped
        "SIGNALK_ALLOW_READONLY": True if as_bool(env["SIGNALK_ALLOW_READONLY"]) else DROP,
        "VESSEL_MMSI": mmsi if mmsi else DROP,
    }


def text_values(env):
    tls = env["TLS_MODE"]
    vals = dict(env)
    vals.update({
        "SCHEME": "http://" if tls == "off" else "",
        "URL_SCHEME": "http://" if tls == "off" else "https://",
        "GLOBAL_OPTIONS": "auto_https off" if tls == "off" else "local_certs",
        "TLS": "" if tls == "off" else "tls internal",
        "VERSION": env.get("VERSION", "dev"),
    })
    return vals


def subst_text(text, vals, where):
    def rep(m):
        name = m.group(1)
        if name not in vals:
            raise SystemExit(f"{where}: unresolved placeholder {name}_PLACEHOLDER")
        return str(vals[name])
    return PLACEHOLDER.sub(rep, text)


def subst_json(node, typed, vals, where):
    if isinstance(node, dict):
        out = {}
        for k, v in node.items():
            r = subst_json(v, typed, vals, where)
            if r is not DROP:
                out[k] = r
        return out
    if isinstance(node, list):
        return [r for r in (subst_json(v, typed, vals, where) for v in node) if r is not DROP]
    if isinstance(node, str):
        m = PLACEHOLDER.fullmatch(node)
        if m and m.group(1) in typed:
            return typed[m.group(1)]
        return subst_text(node, vals, where)
    return node


def write(path, data, mode=0o640, gid=None):
    """Write atomically. gid: group that must be able to read the file (the container user's group).

    As root the file is chgrp'd to gid and keeps `mode`. When not root (tests, CI) chgrp is not
    possible, so a group-restricted file is made world-readable instead; that is acceptable only
    because a non-root render is never a real deployment.
    """
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(data)
    if gid is not None:
        if os.geteuid() == 0:
            os.chown(tmp, 0, gid)
        else:
            mode |= 0o004
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--env", required=True)
    ap.add_argument("--images", required=True, help="images.env with pinned image references")
    ap.add_argument("--config", required=True, help="directory holding the templates")
    ap.add_argument("--out", help="output directory (required unless --check)")
    ap.add_argument("--container-gid", type=int, default=1000,
                    help="gid of the SignalK container user (node); signalk/* files are made readable by it")
    ap.add_argument("--version", default="dev")
    ap.add_argument("--check", action="store_true", help="validate and render in memory only")
    args = ap.parse_args()
    if not args.check and not args.out:
        ap.error("--out is required unless --check is given")

    env = dict(DEFAULTS)
    env.update(parse_env(args.env))
    errors = validate(env)
    if errors:
        print("marine.env problems:", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        raise SystemExit(1)

    images = parse_env(args.images)
    for need in ("SIGNALK_IMAGE", "INFLUXDB_IMAGE", "CADDY_IMAGE", "PORTAINER_IMAGE"):
        if need not in images:
            raise SystemExit(f"{args.images}: missing {need}")
    env["VERSION"] = args.version

    typed = typed_values(env)
    vals = text_values(env)

    def tpl(rel):
        with open(os.path.join(args.config, rel), encoding="utf-8") as fh:
            return fh.read()

    outputs = {}  # relative path -> (content, mode)

    plugin = subst_json(json.loads(tpl("signalk/signalk-to-influxdb2.json.template")), typed, vals, "plugin config")
    outputs["signalk/plugin-config-data/signalk-to-influxdb2.json"] = (json.dumps(plugin, indent=2) + "\n", 0o640)

    settings = subst_json(json.loads(tpl("signalk/settings.managed.json.template")), typed, vals, "settings")
    outputs["signalk/settings.managed.json"] = (json.dumps(settings, indent=2) + "\n", 0o640)

    for rel_in, rel_out in (
        ("hostapd.conf.template", "hostapd.conf"),
        ("dnsmasq.conf.template", "dnsmasq.conf"),
        ("Caddyfile.template", "caddy/Caddyfile"),
        ("landing/index.html.template", "landing/index.html"),
    ):
        mode = 0o600 if rel_out == "hostapd.conf" else 0o644
        outputs[rel_out] = (subst_text(tpl(rel_in), vals, rel_in), mode)

    # docker compose interpolation file (holds secrets: 0600)
    compose_env = {
        "MARINE_RENDERED": os.path.abspath(args.out) if args.out else "/var/lib/marine/rendered",
        "DOMAIN": env["DOMAIN"],
        "INFLUXDB_USERNAME": env["INFLUXDB_USERNAME"],
        "INFLUXDB_PASSWORD": env["INFLUXDB_PASSWORD"],
        "INFLUXDB_TOKEN": env["INFLUXDB_TOKEN"],
        "INFLUXDB_ORG": env["INFLUXDB_ORG"],
        "INFLUXDB_BUCKET": env["INFLUXDB_BUCKET"],
        **{k: images[k] for k in ("SIGNALK_IMAGE", "INFLUXDB_IMAGE", "CADDY_IMAGE", "PORTAINER_IMAGE")},
    }
    # docker compose parses env files itself: '$' interpolates, ' #' starts a comment,
    # and a leading quote changes how the value is read. Refuse values that would be mangled.
    for k, v in compose_env.items():
        if "\n" in v or "$" in v or " #" in v or v != v.strip() or v[:1] in "'\"":
            raise SystemExit(
                f"{k}: value must not contain newlines or '$', ' #', "
                "leading/trailing spaces or a leading quote (docker compose env-file rules)"
            )
    outputs["compose.env"] = ("".join(f"{k}={v}\n" for k, v in compose_env.items()), 0o600)

    if args.check:
        print("OK: marine.env is valid and all templates render.")
        return

    sums = []
    for rel, (content, mode) in sorted(outputs.items()):
        write(os.path.join(args.out, rel), content, mode,
              gid=args.container_gid if rel.startswith("signalk/") else None)
        sums.append(f"{hashlib.sha256(content.encode()).hexdigest()}  {rel}\n")
    write(os.path.join(args.out, "SHA256SUMS"), "".join(sums), 0o644)
    print(f"Rendered {len(outputs)} files to {args.out}")


if __name__ == "__main__":
    main()
