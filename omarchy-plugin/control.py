#!/usr/bin/env python3
"""Small JSON bridge between the Omarchy shell plugin and an Elgato Key Light."""

import argparse
import json
import shutil
import subprocess
import sys
from typing import Any

SCENES = {
    "night": {"on": 1, "brightness": 10, "kelvin": 2900},
    "warm": {"on": 1, "brightness": 35, "kelvin": 3200},
    "studio": {"on": 1, "brightness": 65, "kelvin": 4300},
    "daylight": {"on": 1, "brightness": 80, "kelvin": 5600},
}


def output(value: dict[str, Any]) -> None:
    print(json.dumps(value, separators=(",", ":")))


def request(args: argparse.Namespace, method: str, path: str, payload: dict[str, Any] | None = None) -> Any:
    command = [
        "curl",
        "--fail",
        "--silent",
        "--show-error",
        "--connect-timeout",
        "2",
        "--max-time",
        "4",
        "--request",
        method,
        "--header",
        "Content-Type: application/json",
    ]
    if payload is not None:
        command += ["--data-binary", json.dumps(payload, separators=(",", ":"))]
    command.append(f"http://{args.host}:{args.port}{path}")
    result = subprocess.run(command, capture_output=True, text=True, timeout=6, check=False)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "Light is unreachable")
    return json.loads(result.stdout) if result.stdout.strip() else {}


def kelvin_to_mired(kelvin: int) -> int:
    return max(143, min(344, round(1_000_000 / kelvin)))


def mired_to_kelvin(mired: int) -> int:
    return max(2900, min(7000, round(1_000_000 / mired)))


def snapshot(args: argparse.Namespace) -> dict[str, Any]:
    state = request(args, "GET", "/elgato/lights")
    lights = state.get("lights") or []
    if not lights:
        raise RuntimeError("No light was reported by the device")
    light = lights[0]

    name = "Key Light"
    try:
        info = request(args, "GET", "/elgato/accessory-info")
        name = info.get("displayName") or info.get("productName") or name
    except Exception:
        pass

    return {
        "available": True,
        "on": int(light.get("on", 0)) == 1,
        "brightness": int(light.get("brightness", 0)),
        "kelvin": mired_to_kelvin(int(light.get("temperature", 233))),
        "name": name,
    }


def update(args: argparse.Namespace, values: dict[str, Any]) -> dict[str, Any]:
    light: dict[str, Any] = {}
    if "on" in values:
        light["on"] = int(values["on"])
    if "brightness" in values:
        light["brightness"] = max(3, min(100, int(values["brightness"])))
    if "kelvin" in values:
        light["temperature"] = kelvin_to_mired(max(2900, min(7000, int(values["kelvin"]))))
    request(args, "PUT", "/elgato/lights", {"numberOfLights": 1, "lights": [light]})
    return snapshot(args)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("snapshot", "toggle", "set", "scene", "identify", "launch"))
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, default=9123)
    parser.add_argument("--brightness", type=int)
    parser.add_argument("--kelvin", type=int)
    parser.add_argument("--name", choices=tuple(SCENES))
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if args.action == "snapshot":
            output(snapshot(args))
        elif args.action == "toggle":
            current = snapshot(args)
            output(update(args, {"on": 0 if current["on"] else 1}))
        elif args.action == "set":
            values = {}
            if args.brightness is not None:
                values["brightness"] = args.brightness
            if args.kelvin is not None:
                values["kelvin"] = args.kelvin
            if not values:
                raise RuntimeError("No setting was provided")
            output(update(args, values))
        elif args.action == "scene":
            if args.name is None:
                raise RuntimeError("No scene was provided")
            output(update(args, SCENES[args.name]))
        elif args.action == "identify":
            request(args, "POST", "/elgato/identify")
            result = snapshot(args)
            result["message"] = "Identify command sent"
            output(result)
        elif args.action == "launch":
            executable = shutil.which("luma")
            if executable is None:
                raise RuntimeError("The luma binary is not installed")
            subprocess.Popen(
                [executable, "--host", args.host, "--device-port", str(args.port)],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            output({"message": "Luma opened"})
        return 0
    except Exception as error:
        output({"available": False, "error": str(error)})
        return 1


if __name__ == "__main__":
    sys.exit(main())
