import glob,re,statistics as st
RAW='/Users/benoitc/Projects/erlang_wasm-shared-pages/test/audit/raw/shared-pages/restore'
d={}
for t in ['base','cand']:
  for f in sorted(glob.glob(f'{RAW}/{t}.r*.txt')):
    for l in open(f):
      p=l.split()
      if len(p)==5 and p[1] in('restore','load_snapshot'):
        d.setdefault((p[0],p[1],t),[]).append((float(p[3]),float(p[4])))
for g in ['py','qjs','lua','plain']:
  for op in ['restore','load_snapshot']:
    b=d[(g,op,'base')];c=d[(g,op,'cand')]
    bm=min(x[0] for x in b);cm=min(x[0] for x in c)
    bmed=st.median([x[1] for x in b]);cmed=st.median([x[1] for x in c])
    print(f"{g:6}{op:14} min base {bm:10.1f} cand {cm:10.1f} ratio {cm/bm:6.3f} | med-of-med base {bmed:10.1f} cand {cmed:10.1f} ratio {cmed/bmed:6.3f}")
