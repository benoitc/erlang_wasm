wit_bindgen::generate!({ world: "app" });

use wasi::cli::environment;

struct C;

impl Guest for C {
    fn env() -> Vec<(String, String)> { environment::get_environment() }
    fn args() -> Vec<String> { environment::get_arguments() }
    fn cwd() -> Option<String> { environment::initial_cwd() }
}

export!(C);
