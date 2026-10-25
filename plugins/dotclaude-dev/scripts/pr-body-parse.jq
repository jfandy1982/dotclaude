# Parses a PR body written by create-pr. Contract: references/pr-body.md.
# Input: the body as raw text (jq -Rs); CRLF is normalized first. Output: one JSON object (see contract).
# shortcut: a heading inside a fenced code block is matched like any other, upgrade when a real body trips it.
# jq 1.6 compatible: every `if` has an `else`, no builtin newer than 1.6 (own `strip`, not `trim`).

def strip: sub("^\\s+"; "") | sub("\\s+$"; "");

# Text of a "## <name>" section, up to the next "## " heading or the end; null when absent.
def section($name):
  (capture("(?ims)^##[ \\t]+" + $name + "[ \\t]*(?:\\n|\\z)(?<t>.*?)(?=^##[ \\t]|\\z)") | .t) // null;

def bucket_re: "^###[ \\t]+(?:🔴|🟡|🟢)?[ \\t]*(?<b>critical|medium|low)[ \\t]*$";

# Bullets of the File risk section per bucket, canonical bucket names.
def buckets:
  reduce split("\n")[] as $l ({cur: null, out: {Critical: [], Medium: [], Low: []}};
    if ($l | test(bucket_re; "i")) then
      .cur = ($l | capture(bucket_re; "i") | .b | ascii_downcase | {critical: "Critical", medium: "Medium", low: "Low"}[.])
    elif ($l | test("^#{1,6}[ \\t]")) then
      .cur = null
    elif .cur != null and ($l | test("^- `[^`]+` — ")) then
      .out[.cur] += [$l | sub("^- "; "")]
    else
      .
    end)
  | .out;

gsub("\\r\\n"; "\n")
| section("File risk") as $risk
| ($risk // "" | buckets) as $b
| ([$b.Critical, $b.Medium, $b.Low] | add | length) as $entries
| (section("Closes") // "") as $closes
| ([$closes | scan("(?im)^[ \\t]*closes #([0-9]+)")] | map(.[0] | tonumber)) as $numbers
| {
    fileRisk: ({state: (if $risk == null then "missing" elif $entries == 0 then "empty" else "ok" end)} + $b),
    mergeDanger: (section("Merge danger") | if . == null then null else strip end),
    closes: {
      state: (if ($closes | strip) == "" then "missing" elif ($numbers | length) > 0 then "ok" else "unparsed" end),
      numbers: $numbers
    }
  }
  + (if $risk != null and $entries == 0 then {fileRiskRaw: ($risk | strip)} else {} end)
