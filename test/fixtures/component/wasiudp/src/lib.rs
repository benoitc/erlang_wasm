wit_bindgen::generate!({ world: "app", generate_all });
use wasi::sockets::instance_network::instance_network;
use wasi::sockets::udp_create_socket::create_udp_socket;
use wasi::sockets::network::{IpAddressFamily, IpSocketAddress, Ipv4SocketAddress};
use wasi::sockets::udp::OutgoingDatagram;

struct C;

impl Guest for C {
    fn ping(a: u8, b: u8, c: u8, d: u8, port: u16, msg: Vec<u8>) -> Vec<u8> {
        let net = instance_network();
        let sock = create_udp_socket(IpAddressFamily::Ipv4).unwrap();
        let local = IpSocketAddress::Ipv4(Ipv4SocketAddress { port: 0, address: (127, 0, 0, 1) });
        sock.start_bind(&net, local).unwrap();
        sock.finish_bind().unwrap();
        let remote = IpSocketAddress::Ipv4(Ipv4SocketAddress { port, address: (a, b, c, d) });
        let (rx, tx) = match sock.stream(Some(remote)) {
            Ok(s) => s,
            Err(_) => return Vec::new(),
        };
        let _ = tx.send(&[OutgoingDatagram { data: msg, remote_address: None }]);
        match rx.receive(1) {
            Ok(ds) if !ds.is_empty() => ds[0].data.clone(),
            _ => Vec::new(),
        }
    }
}
export!(C);
