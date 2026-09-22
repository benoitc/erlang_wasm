wit_bindgen::generate!({ world: "vectors" });

struct C;

impl Guest for C {
    fn echo_u8(v: u8) -> u8 { v }
    fn echo_u16(v: u16) -> u16 { v }
    fn echo_u32(v: u32) -> u32 { v }
    fn echo_u64(v: u64) -> u64 { v }
    fn echo_s8(v: i8) -> i8 { v }
    fn echo_s16(v: i16) -> i16 { v }
    fn echo_s32(v: i32) -> i32 { v }
    fn echo_s64(v: i64) -> i64 { v }
    fn echo_f32(v: f32) -> f32 { v }
    fn echo_f64(v: f64) -> f64 { v }
    fn echo_bool(v: bool) -> bool { v }
    fn echo_char(v: char) -> char { v }
    fn echo_string(v: String) -> String { v }
    fn echo_list_u32(v: Vec<u32>) -> Vec<u32> { v }
    fn echo_list_string(v: Vec<String>) -> Vec<String> { v }
    fn echo_point(v: Point) -> Point { v }
    fn echo_shape(v: Shape) -> Shape { v }
    fn echo_color(v: Color) -> Color { v }
    fn echo_option(v: Option<u32>) -> Option<u32> { v }
    fn echo_result(v: Result<u32, String>) -> Result<u32, String> { v }
    fn echo_perms(v: Perms) -> Perms { v }
    fn echo_tuple(v: (u8, String, bool)) -> (u8, String, bool) { v }
}

export!(C);
