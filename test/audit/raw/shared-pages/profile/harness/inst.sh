source /Users/benoitc/Projects/erlang_wasm-prof-harness/lib.sh
tag=$1
for g in lua qjs py; do for tier in interp compiled; do
  if [ $tier = compiled ]; then c=$(cache inst); else c=none; fi
  echo "== $tag inst $g $tier $(uptime)" >> $O/inst_$tag.txt
  erlrun inst -run profreq main $g $tier $c 100 $O/inst_$tag.terms >> $O/inst_$tag.txt 2>&1
done; done
echo INST_DONE >> $O/inst_$tag.txt
