wit_bindgen::generate!({ world: "app", generate_all });
use wasi::sockets::instance_network::instance_network;
use wasi::sockets::ip_name_lookup::resolve_addresses;
use wasi::sockets::network::IpAddress;
struct C;
impl Guest for C {
    fn lookup(name: String) -> Vec<String> {
        let net = instance_network();
        let mut out = Vec::new();
        if let Ok(stream) = resolve_addresses(&net, &name) {
            while let Ok(Some(a)) = stream.resolve_next_address() {
                out.push(match a {
                    IpAddress::Ipv4((a,b,c,d)) => format!("{}.{}.{}.{}", a,b,c,d),
                    IpAddress::Ipv6(_) => "v6".to_string(),
                });
            }
        }
        out
    }
}
export!(C);
