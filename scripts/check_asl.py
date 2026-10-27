"""Contrôles structurels de la définition ASL (hors ligne, sans appel AWS).

Usage : python -I check_asl.py stt-pipeline.asl.json
"""
import json
import sys

TERMINAL_TYPES = {"Succeed", "Fail"}
KNOWN_TYPES = {"Task", "Pass", "Choice", "Wait", "Succeed", "Fail", "Parallel", "Map"}


def targets(state):
    found = []
    if "Next" in state:
        found.append(state["Next"])
    for catch in state.get("Catch", []):
        found.append(catch["Next"])
    for choice in state.get("Choices", []):
        found.append(choice["Next"])
    if "Default" in state:
        found.append(state["Default"])
    return found


def check(definition):
    errors = []
    states = definition["States"]
    start = definition["StartAt"]
    if start not in states:
        errors.append(f"StartAt '{start}' does not exist")

    for name, state in states.items():
        kind = state.get("Type")
        if kind not in KNOWN_TYPES:
            errors.append(f"{name}: unknown type {kind!r}")
        for target in targets(state):
            if target not in states:
                errors.append(f"{name}: unknown target '{target}'")
        if kind not in TERMINAL_TYPES and kind != "Choice" and "Next" not in state and not state.get("End"):
            errors.append(f"{name}: no Next and not terminal")
        for catch in state.get("Catch", []):
            if "ErrorEquals" not in catch or "Next" not in catch:
                errors.append(f"{name}: malformed Catch")
        for retry in state.get("Retry", []):
            if "ErrorEquals" not in retry:
                errors.append(f"{name}: malformed Retry")
        if kind == "Task" and state.get("Resource", "").endswith(".waitForTaskToken") and "TimeoutSeconds" not in state:
            errors.append(f"{name}: waitForTaskToken without TimeoutSeconds")

    reachable, queue = set(), [start]
    while queue:
        current = queue.pop()
        if current in reachable or current not in states:
            continue
        reachable.add(current)
        queue.extend(targets(states[current]))
    for name in sorted(set(states) - reachable):
        errors.append(f"{name}: unreachable")

    return errors, reachable


def main(path):
    with open(path, encoding="utf-8") as handle:
        definition = json.load(handle)
    errors, reachable = check(definition)
    print(f"{len(definition['States'])} states, {len(reachable)} reachable")
    for error in errors:
        print("ERROR:", error)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
