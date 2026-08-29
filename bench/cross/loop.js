const fs = require('fs');
const b = fs.readFileSync(process.argv[2]);
const i = new WebAssembly.Instance(new WebAssembly.Module(b));
console.log(i.exports.bench(parseInt(process.argv[3])));
