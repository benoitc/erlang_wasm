// A wasi:cli/command that uses wasi:nn: run the model named `echo` on stdin
// and write its first output to stdout. Built for wasm32-wasip2, so its core
// modules are linked and a drop goes through `canon resource.drop`.
//
// It loads the model a second time and never drops that graph, so the host
// has one graph left to close when the instance is destroyed.
wit_bindgen::generate!({ world: "nn", generate_all });

use std::io::{Read, Write};

use wasi::nn::graph::load_by_name;
use wasi::nn::tensor::{Tensor, TensorType};

fn main() {
    let mut input = Vec::new();
    std::io::stdin().read_to_end(&mut input).ok();

    let graph = load_by_name("echo").ok().expect("load");
    let ctx = graph.init_execution_context().ok().expect("context");
    let tensor = Tensor::new(&[1], TensorType::U8, &input);
    let outs = ctx
        .compute(vec![("input".to_string(), tensor)])
        .ok()
        .expect("compute");
    std::io::stdout().write_all(&outs[0].1.data()).ok();

    let kept = load_by_name("echo").ok().expect("load");
    std::mem::forget(kept);
}
