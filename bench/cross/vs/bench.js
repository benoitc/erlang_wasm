// 30,000 iterations of mixed arithmetic; prints one checksum.
let s = 0;
for (let i = 0; i < 30000; i++) { s = (s + (i * i) % 7) | 0; }
print(s);
