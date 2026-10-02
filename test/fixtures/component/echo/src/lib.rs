wit_bindgen::generate!({ world: "echo" });

struct Component;

impl Guest for Component {
    fn run(input: Vec<u8>) -> Result<Vec<u8>, String> {
        if input.is_empty() {
            Err("empty input".to_string())
        } else {
            Ok(input.iter().map(|b| b.to_ascii_uppercase()).collect())
        }
    }
}

export!(Component);
