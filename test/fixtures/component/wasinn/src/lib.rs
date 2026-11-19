wit_bindgen::generate!({ world: "app", generate_all });

use std::cell::RefCell;

use wasi::nn::errors::{Error, ErrorCode};
use wasi::nn::graph::{load, load_by_name, ExecutionTarget, GraphEncoding};
use wasi::nn::inference::GraphExecutionContext;
use wasi::nn::tensor::{Tensor, TensorType};

thread_local! {
    static HELD: RefCell<Vec<Tensor>> = RefCell::new(Vec::new());
}

fn code(c: ErrorCode) -> &'static str {
    match c {
        ErrorCode::InvalidArgument => "invalid-argument",
        ErrorCode::InvalidEncoding => "invalid-encoding",
        ErrorCode::Timeout => "timeout",
        ErrorCode::RuntimeError => "runtime-error",
        ErrorCode::UnsupportedOperation => "unsupported-operation",
        ErrorCode::TooLarge => "too-large",
        ErrorCode::NotFound => "not-found",
        ErrorCode::Security => "security",
        ErrorCode::Unknown => "unknown",
    }
}

fn ty(t: TensorType) -> &'static str {
    match t {
        TensorType::Fp16 => "FP16",
        TensorType::Fp32 => "FP32",
        TensorType::Fp64 => "FP64",
        TensorType::Bf16 => "BF16",
        TensorType::U8 => "U8",
        TensorType::I32 => "I32",
        TensorType::I64 => "I64",
    }
}

// The enums by position, in the order the interface declares them.
const TYPES: [TensorType; 7] = [
    TensorType::Fp16,
    TensorType::Fp32,
    TensorType::Fp64,
    TensorType::Bf16,
    TensorType::U8,
    TensorType::I32,
    TensorType::I64,
];
const ENCODINGS: [GraphEncoding; 7] = [
    GraphEncoding::Openvino,
    GraphEncoding::Onnx,
    GraphEncoding::Tensorflow,
    GraphEncoding::Pytorch,
    GraphEncoding::Tensorflowlite,
    GraphEncoding::Ggml,
    GraphEncoding::Autodetect,
];
const TARGETS: [ExecutionTarget; 3] = [
    ExecutionTarget::Cpu,
    ExecutionTarget::Gpu,
    ExecutionTarget::Tpu,
];

fn text(e: Error) -> String {
    format!("{}: {}", code(e.code()), e.data())
}

fn bytes(size: u32) -> Tensor {
    Tensor::new(&[size], TensorType::U8, &vec![7u8; size as usize])
}

fn answer(r: Result<Vec<(String, Tensor)>, Error>) -> String {
    match r {
        Ok(outs) => format!("ok: {}", outs.len()),
        Err(e) => text(e),
    }
}

struct C;

impl Guest for C {
    fn run(model: String, input: Vec<u8>) -> Result<Vec<Output>, String> {
        Self::run_with(model, vec![1], 4, input)
    }

    fn run_with(
        model: String,
        dimensions: Vec<u32>,
        ty_index: u32,
        input: Vec<u8>,
    ) -> Result<Vec<Output>, String> {
        let graph = load_by_name(&model).map_err(text)?;
        let ctx = graph.init_execution_context().map_err(text)?;
        let tensor = Tensor::new(&dimensions, TYPES[ty_index as usize], &input);
        let outs = ctx
            .compute(vec![("input".to_string(), tensor)])
            .map_err(text)?;
        Ok(outs
            .into_iter()
            .map(|(name, t)| Output {
                name,
                dimensions: t.dimensions(),
                ty: ty(t.ty()).to_string(),
                data: t.data(),
            })
            .collect())
    }

    fn hold(count: u32, size: u32) -> u32 {
        HELD.with(|held| {
            let mut held = held.borrow_mut();
            for _ in 0..count {
                held.push(bytes(size));
            }
            held.len() as u32
        })
    }

    fn release() {
        HELD.with(|held| held.borrow_mut().clear());
    }

    fn load_bytes() -> String {
        match load(&[vec![1u8, 2, 3]], GraphEncoding::Ggml, ExecutionTarget::Cpu) {
            Ok(_) => "ok".to_string(),
            Err(e) => text(e),
        }
    }

    fn load_with(parts: Vec<Vec<u8>>, encoding: u32, target: u32) -> String {
        match load(&parts, ENCODINGS[encoding as usize], TARGETS[target as usize]) {
            Ok(_) => "ok".to_string(),
            Err(e) => text(e),
        }
    }

    fn tensor_echo(dimensions: Vec<u32>, ty_index: u32, data: Vec<u8>) -> Output {
        let t = Tensor::new(&dimensions, TYPES[ty_index as usize], &data);
        Output {
            name: String::new(),
            dimensions: t.dimensions(),
            ty: ty(t.ty()).to_string(),
            data: t.data(),
        }
    }

    // Each kind forges a handle the bindings would never produce. A forged
    // value that the host does not take is forgotten, so the guest drops
    // each real handle exactly once.
    fn misuse(model: String, kind: u32, size: u32) -> String {
        let graph = match load_by_name(&model) {
            Ok(g) => g,
            Err(e) => return text(e),
        };
        let ctx = match graph.init_execution_context() {
            Ok(c) => c,
            Err(e) => return text(e),
        };
        match kind {
            // A tensor that was dropped.
            0 => {
                let t = bytes(size);
                let h = t.handle();
                drop(t);
                let stale = unsafe { Tensor::from_handle(h) };
                answer(ctx.compute(vec![("x".to_string(), stale)]))
            }
            // A graph in the place of a tensor.
            1 => {
                let fake = unsafe { Tensor::from_handle(graph.handle()) };
                answer(ctx.compute(vec![("x".to_string(), fake)]))
            }
            // One tensor passed twice.
            2 => {
                let t = bytes(size);
                let twin = unsafe { Tensor::from_handle(t.handle()) };
                answer(ctx.compute(vec![("a".to_string(), t), ("b".to_string(), twin)]))
            }
            // A tensor in the place of the execution context.
            3 => {
                let t = bytes(size);
                let fake = unsafe { GraphExecutionContext::from_handle(t.handle()) };
                let r = answer(fake.compute(vec![("x".to_string(), bytes(size))]));
                std::mem::forget(fake);
                r
            }
            _ => "unknown kind".to_string(),
        }
    }
}

export!(C);
