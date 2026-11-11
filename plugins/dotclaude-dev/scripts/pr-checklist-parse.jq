# The PR merge checklist table of a CLAUDE.md. Usage: jq -Rs -f pr-checklist-parse.jq CLAUDE.md
# Prints {state, rows}: state "none" (no heading), "unusable" (no table, or a column is missing) or "ok";
# rows [{patterns, item}] in table order. The table format is described in pr-checklist.sh.

def trim_end: sub("\\s+$"; "");
def trim: sub("^\\s+"; "") | trim_end;
# cells of a table line: outer pipes dropped, split on unescaped pipes, trimmed
def cells: trim | ltrimstr("|") | sub("(?<!\\\\)\\|$"; "") | split("(?<!\\\\)\\|"; null) | map(trim);
# one pattern piece: trimmed, a leading and a trailing backtick removed (also when one pair wraps a comma list), one leading ./ removed
def clean: trim | sub("^`"; "") | sub("`$"; "") | trim | ltrimstr("./");
# the lines outside fenced code blocks (``` or ~~~): a heading or table shown as an example is not the checklist
# a fence is closed only by a bare line of the same character that is at least as long as the opening one
def outside_fences:
  reduce .[] as $line ({fence: null, out: []};
    ([$line | capture("^\\s*(?<m>`{3,}|~{3,})(?<rest>.*)$")] | first) as $f
    | if .fence == null then
        if $f != null then .fence = $f.m else .out += [$line] end
      elif $f != null and ($f.rest | test("^\\s*$")) and $f.m[:1] == .fence[:1] and ($f.m | length) >= (.fence | length) then .fence = null
      else . end)
  | .out;

(split("\n") | map(rtrimstr("\r")) | outside_fences) as $lines
| ($lines | map(trim_end == "### PR merge checklist") | index(true)) as $heading
| if $heading == null then {state: "none", rows: []}
  else
    ($lines[$heading + 1:]) as $after
    | ($after | map(test("^#{1,3}( |$)")) | index(true)) as $end
    | (if $end == null then $after else $after[:$end] end) as $section
    | ($section | map(test("^\\s*\\|")) | index(true)) as $start
    | if $start == null then {state: "unusable", rows: []}
      else
        ($section[$start:] | (map(test("^\\s*\\|")) | index(false)) as $n | if $n == null then . else .[:$n] end) as $table
        | ($table[0] | cells) as $header
        | ($header | index("File pattern")) as $p
        | ($header | index("Checklist item")) as $i
        | if $p == null or $i == null then {state: "unusable", rows: []}
          else
            {state: "ok",
             rows: [$table[1:][] | cells
                    | select(all(.[]; test("^:?-+:?$")) | not)
                    | {patterns: [(.[$p] // "") | split(",")[] | clean | select(length > 0)], item: (.[$i] // "")}
                    | select((.patterns | length) > 0 and (.item | length) > 0)]}
          end
      end
  end
