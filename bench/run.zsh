#!/usr/bin/env zsh
# Macro benchmark suite: runs every bench/*.lua on moonquakes and a
# reference lua5.4, verifies the outputs match, and reports user time.
#
# usage: bench/run.zsh [moonquakes-binary] [reference-lua]

set -u

typeset mq=${1:-./zig-out/bin/moonquakes}
typeset ref=${2:-lua5.4}
typeset dir=${0:a:h}
typeset -i fails=0

printf '%-16s %10s %10s %8s  %s\n' BENCH MOONQUAKES REFERENCE RATIO CHECK
for f in $dir/*.lua; do
  name=${f:t:r}
  out_mq=$(command time -f '%U' $mq $f 2>/tmp/mq_time.$$)
  t_mq=$(cat /tmp/mq_time.$$)
  out_ref=$(command time -f '%U' $ref $f 2>/tmp/ref_time.$$)
  t_ref=$(cat /tmp/ref_time.$$)
  if [[ "$out_mq" == "$out_ref" ]]; then
    check=ok
  else
    check=MISMATCH
    (( fails += 1 ))
  fi
  ratio=$(awk -v a=$t_mq -v b=$t_ref 'BEGIN { if (b > 0) printf("%.2fx", a / b); else print "-" }')
  printf '%-16s %9ss %9ss %8s  %s\n' $name $t_mq $t_ref $ratio $check
done
rm -f /tmp/mq_time.$$ /tmp/ref_time.$$
exit $fails
