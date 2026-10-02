wit_bindgen::generate!({ world: "app", generate_all });
use wasi::sockets::instance_network::instance_network;
use wasi::sockets::tcp_create_socket::create_tcp_socket;
use wasi::sockets::network::{IpAddressFamily, IpSocketAddress, Ipv4SocketAddress};

struct C;

impl Guest for C {
    fn echo_to(a: u8, b: u8, c: u8, d: u8, port: u16, msg: Vec<u8>) -> Vec<u8> {
        let net = instance_network();
        let sock = create_tcp_socket(IpAddressFamily::Ipv4).unwrap();
        let addr = IpSocketAddress::Ipv4(Ipv4SocketAddress { port, address: (a, b, c, d) });
        if sock.start_connect(&net, addr).is_err() {
            return Vec::new();
        }
        let (rx, tx) = sock.finish_connect().unwrap();
        tx.blocking_write_and_flush(&msg).unwrap();
        let mut out = Vec::new();
        while out.len() < msg.len() {
            match rx.blocking_read((msg.len() - out.len()) as u64) {
                Ok(chunk) => out.extend_from_slice(&chunk),
                Err(_) => break,
            }
        }
        out
    }

    // Bind to 127.0.0.1:port, listen, accept one connection, echo one read.
    fn serve_on(port: u16) -> Vec<u8> {
        let net = instance_network();
        let sock = create_tcp_socket(IpAddressFamily::Ipv4).unwrap();
        let addr = IpSocketAddress::Ipv4(Ipv4SocketAddress { port, address: (127, 0, 0, 1) });
        if sock.start_bind(&net, addr).is_err() {
            return Vec::new();
        }
        sock.finish_bind().unwrap();
        sock.start_listen().unwrap();
        sock.finish_listen().unwrap();
        let (_client, rx, tx) = sock.accept().unwrap();
        let data = rx.blocking_read(64).unwrap_or_default();
        let _ = tx.blocking_write_and_flush(&data);
        data
    }
}
export!(C);
