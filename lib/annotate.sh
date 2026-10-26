# shellcheck shell=bash
# Output helpers shared by the actions' scripts (#8). Sourced, never run: each
# script sources it from its own directory's ../lib, which every caller's
# `uses: FaultMaven/ci-actions/<action>@<sha>` fetch holds, since that fetch is
# the whole repository at <sha>. The runner reads workflow commands from a
# step's stdout and stderr alike, after trimming a line's leading blanks, so
# no line a script prints may begin `::` unless the script means it to.

# A value printed into a :: command's message is escaped as GitHub decodes it:
# `%` as %25, CR as %0D and LF as %0A. No value can start a line of its own,
# and none is shown altered.
escape() {
  local s="$1"
  s="${s//%/%25}"
  s="${s//$'\r'/%0D}"
  s="${s//$'\n'/%0A}"
  printf '%s' "$s"
}

annotate() { # level, message
  printf '::%s::%s\n' "$1" "$(escape "$2")"
}

# A value printed anywhere else, a plain log line or the step summary (which
# is markdown, not a workflow command), goes through flat(): CR, LF and tab
# become spaces, so it stays on its line and is shown as written.
flat() {
  local s="$1"
  s="${s//$'\r'/ }"
  s="${s//$'\n'/ }"
  s="${s//$'\t'/ }"
  printf '%s' "$s"
}

# The first non-blank line of a file of a tool's stderr, without gh's "gh: "
# prefix: gh's later lines are hints, not the error. Trailing blanks and CRs
# are cut before a line is judged blank, so a CRLF line of spaces counts as
# blank; git pads a "remote: " line with spaces.
first_err() { # file
  awk '{ sub(/[ \t\r]+$/, "") } NF { sub(/^gh: /, ""); print; exit }' "$1"
}

# The last non-blank line of a file of a tool's stderr: imagetools prints its
# progress before its error.
last_err() { # file
  awk '{ sub(/[ \t\r]+$/, "") } NF { l = $0 } END { print l }' "$1"
}

# Replays a tool's captured stderr into the log with every line prefixed by
# the tool's name, so that no line of it, whatever the tool or a server sent,
# begins `::` and is run as a workflow command.
log_tool_output() { # tool name, file
  sed "s/^/$1: /" "$2" >&2
}
