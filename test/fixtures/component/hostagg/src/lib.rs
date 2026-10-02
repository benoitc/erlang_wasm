wit_bindgen::generate!({ world: "app" });

use example::agg::host::shout;

struct C;

impl Guest for C {
    fn announce(s: String) -> String {
        format!("<<{}>>", shout(&s))
    }
}

export!(C);
