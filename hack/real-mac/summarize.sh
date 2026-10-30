#!/bin/zsh
# summarize.sh RESULTS...: print a markdown PASS/FAIL table for hunt result files (plus their FAIL and
# XFAIL lines). Exits non-zero when any file has a FAIL line or lacks the DONE marker.
bad=0
echo "| script | PASS | FAIL | XFAIL | DONE |"
echo "|---|---|---|---|---|"
for f in "$@"; do
  p=$(grep -c '^PASS' $f 2>/dev/null); x=$(grep -c '^FAIL' $f 2>/dev/null); xf=$(grep -c '^XFAIL' $f 2>/dev/null)
  d=$(grep -qx DONE $f 2>/dev/null && echo yes || echo no)
  [[ ${x:-0} -gt 0 || $d == no ]] && bad=1
  echo "| ${${f:t}%-results.txt} | ${p:-0} | ${x:-0} | ${xf:-0} | $d |"
done
for f in "$@"; do
  grep -hE '^(FAIL|XFAIL)' $f 2>/dev/null | sed "s/^/- ${${f:t}%-results.txt}: /"
done
exit $bad
