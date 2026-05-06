#!/usr/bin/env bats
# CLI-Verhaltenstests für pve8to9_upgrade.sh
# Tests laufen ohne root und triggern bewusst den Argument-Parser
# bevor das Skript Preflight-Checks startet.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../pve8to9_upgrade.sh"
  [[ -f "$SCRIPT" ]] || skip "Skript nicht gefunden: $SCRIPT"
}

@test "--help exit 0" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
}

@test "--help enthaelt Usage-Zeile" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "--help nennt alle dokumentierten Flags" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--repo"* ]]
  [[ "$output" == *"--reboot"* ]]
  [[ "$output" == *"--allow-ceph"* ]]
  [[ "$output" == *"--remove-systemd-boot"* ]]
  [[ "$output" == *"--yes"* ]]
}

@test "-h ist Aequivalent zu --help" {
  run bash "$SCRIPT" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "unbekannte Option exit 2" {
  run bash "$SCRIPT" --no-such-flag
  [ "$status" -eq 2 ]
}

@test "unbekannte Option meldet sie auf stderr" {
  run bash "$SCRIPT" --bogus-flag-xyz
  [ "$status" -eq 2 ]
  [[ "$output" == *"--bogus-flag-xyz"* ]]
}

@test "Skript hat shebang" {
  run head -n1 "$SCRIPT"
  [[ "$output" == "#!/usr/bin/env bash" ]]
}

@test "Skript ist syntaktisch valide (bash -n)" {
  run bash -n "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "Skript verwendet set -Eeuo pipefail" {
  run grep -E '^set -Eeuo pipefail' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "Help-Text dokumentiert no-subscription als Default" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Default"* ]] || [[ "$output" == *"default"* ]]
  [[ "$output" == *"no-subscription"* ]]
}
