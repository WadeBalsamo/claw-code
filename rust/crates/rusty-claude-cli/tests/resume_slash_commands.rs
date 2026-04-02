use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use runtime::Session;

static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

#[test]
fn resumed_binary_accepts_slash_commands_with_arguments() {
    let temp_dir = unique_temp_dir("resume-slash-commands");
    fs::create_dir_all(&temp_dir).expect("temp dir should exist");

    let session_path = temp_dir.join("session.jsonl");
    let export_path = temp_dir.join("notes.txt");

    let mut session = Session::new();
    session
        .push_user_text("ship the slash command harness")
        .expect("session write should succeed");
    session
        .save_to_path(&session_path)
        .expect("session should persist");

    let output = Command::new(env!("CARGO_BIN_EXE_claw"))
        .current_dir(&temp_dir)
        .args([
            "--resume",
            session_path.to_str().expect("utf8 path"),
            "/export",
            export_path.to_str().expect("utf8 path"),
            "/clear",
            "--confirm",
        ])
        .output()
        .expect("claw should launch");

    assert!(
        output.status.success(),
        "stdout:\n{}\n\nstderr:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );

    let stdout = String::from_utf8(output.stdout).expect("stdout should be utf8");
    assert!(stdout.contains("Export"));
    assert!(stdout.contains("wrote transcript"));
    assert!(stdout.contains(export_path.to_str().expect("utf8 path")));
    assert!(stdout.contains("Cleared resumed session file"));

    let export = fs::read_to_string(&export_path).expect("export file should exist");
    assert!(export.contains("# Conversation Export"));
    assert!(export.contains("ship the slash command harness"));

    let restored = Session::load_from_path(&session_path).expect("cleared session should load");
    assert!(restored.messages.is_empty());
}

fn unique_temp_dir(label: &str) -> PathBuf {
    let millis = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock should be after epoch")
        .as_millis();
    let counter = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
    std::env::temp_dir().join(format!(
        "claw-{label}-{}-{millis}-{counter}",
        std::process::id()
    ))
}
