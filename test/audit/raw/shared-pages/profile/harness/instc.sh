source /Users/benoitc/Projects/erlang_wasm-prof-harness/lib.sh
tag=$1
for g in qjs py; do
  echo "== $tag inst $g compiled $(uptime)" >> $O/inst_$tag.txt
  erlrun inst -run profreq main $g compiled $(cache inst) 100 $O/inst_$tag.terms >> $O/inst_$tag.txt 2>&1
done
echo INSTC_DONE >> $O/inst_$tag.txt
