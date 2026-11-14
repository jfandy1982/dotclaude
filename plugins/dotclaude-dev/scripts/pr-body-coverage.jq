# Adds "uncovered" to the result of pr-body-parse.jq: the changed paths of the file table that no entry of the File risk section names.
# Usage: jq -c --argjson table "$(cat file-table.json)" -f pr-body-coverage.jq < parsed.json   ($table is the file table)
# An entry names a path in one of three forms (references/pr-body.md): the path itself, a directory ending in "/"
# (everything below it) or a pattern with one {a,b} group (the expansions). Entries for unchanged files are ignored.
# jq 1.6 compatible.

def entry_path: capture("^`(?<p>[^`]+)`").p;

def covers($entry; $path):
  if ($entry | endswith("/")) then ($path | startswith($entry))
  elif ($entry | test("\\{[^{}]*\\}")) then
    ($entry | capture("^(?<pre>[^{]*)\\{(?<alts>[^{}]*)\\}(?<post>.*)$")) as $c
    | any($c.alts | split(",")[]; $c.pre + . + $c.post == $path)
  else $entry == $path end;

([.fileRisk.Critical[], .fileRisk.Medium[], .fileRisk.Low[]] | map(entry_path)) as $entries
| . + {uncovered: [$table[].path | . as $p | select(any($entries[]; covers(.; $p)) | not)]}
