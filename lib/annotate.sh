# shellcheck shell=bash
# Annotation helpers shared by the actions' scripts (#8). Sourced, never run:
# each script sources it from its own directory's ../lib, which every caller's
# `uses: FaultMaven/ci-actions/<action>@<sha>` fetch holds, since that fetch
# is the whole repository at <sha>.

# A value printed into a :: command is escaped as GitHub decodes a command's
# message: `%` as %25, CR as %0D and LF as %0A. No value can start a line of
# its own, and none is shown altered.
escape() {
  local s="$1"
  s="${s//%/%25}"
  s="${s//$'\r'/%0D}"
  s="${s//$'\n'/%0A}"
  printf '%s' "$s"
}

annotate() {
  printf '::%s::%s\n' "$1" "$(escape "$2")"
}

# The first non-blank line of the stderr the caller captured in $ERR, without
# gh's "gh: " prefix: gh's later lines are hints, not the error. Trailing
# blanks are cut: git pads a "remote: " line with spaces.
first_err() {
  awk 'NF { sub(/^gh: /, ""); sub(/[ \t\r]+$/, ""); print; exit }' "$ERR"
}
