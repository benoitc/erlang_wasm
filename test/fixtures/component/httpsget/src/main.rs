// A real wasm32-wasip2 CLI that makes an outbound HTTPS GET to the authority named
// in HTTPS_SERVER, then prints "status=<code>" and the response body. It exercises
// the full guest path: wasi:http/outgoing-handler with scheme=https, so the runtime
// performs TLS underneath.
use wasi::http::types::{Fields, Method, OutgoingRequest, Scheme};
use wasi::http::outgoing_handler;

fn main() {
    let authority = std::env::var("HTTPS_SERVER").expect("HTTPS_SERVER");
    let req = OutgoingRequest::new(Fields::new());
    req.set_method(&Method::Get).unwrap();
    req.set_scheme(Some(&Scheme::Https)).unwrap();
    req.set_authority(Some(&authority)).unwrap();
    req.set_path_with_query(Some("/get?q=1")).unwrap();

    let fut = outgoing_handler::handle(req, None).expect("handle");
    let pollable = fut.subscribe();
    pollable.block();
    let resp = fut.get().unwrap().unwrap().expect("response");
    let status = resp.status();

    let body = resp.consume().unwrap();
    let stream = body.stream().unwrap();
    let mut out = Vec::new();
    loop {
        match stream.blocking_read(4096) {
            Ok(chunk) if chunk.is_empty() => break,
            Ok(chunk) => out.extend_from_slice(&chunk),
            Err(_) => break,
        }
    }
    println!("status={}", status);
    print!("{}", String::from_utf8_lossy(&out));
}
