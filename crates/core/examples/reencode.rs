use funddesk_core::Board;

fn main() {
    let path = std::env::args()
        .nth(1)
        .expect("用法: reencode <board.json>");
    let data = std::fs::read(&path).expect("读取看板");
    let board: Board = serde_json::from_slice(&data).expect("解码看板");
    std::fs::write(
        "/tmp/funddesk-reencoded.json",
        serde_json::to_vec(&board).expect("编码看板"),
    )
    .expect("写入结果");
    println!("已写入 /tmp/funddesk-reencoded.json");
}
