//! `epdfinfo`: the PDF backend server for pdf-tools, written in Rust.

mod commands;
mod document;
mod image;
mod options;
mod pdf;
mod png;
mod protocol;
mod recolor;
mod region;
mod session;
mod synctex;
mod tempfile;
mod word;

use std::ffi::CString;
use std::io::{BufRead, Write};

use commands::Flow;
use protocol::ParsedLine;
use session::Session;

fn redirect_stderr(path: &str) -> bool {
    let Ok(c) = CString::new(path) else {
        return false;
    };
    // SAFETY: `c` is a valid NUL terminated path.
    let fd = unsafe {
        libc::open(
            c.as_ptr(),
            libc::O_WRONLY | libc::O_APPEND | libc::O_CREAT,
            0o666,
        )
    };
    if fd < 0 {
        return false;
    }
    // SAFETY: both descriptors are valid; the duplication replaces stderr.
    let ok = unsafe { libc::dup2(fd, libc::STDERR_FILENO) } >= 0;
    // SAFETY: `fd` was opened above and is no longer needed once duplicated.
    unsafe { libc::close(fd) };
    ok
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() > 2 {
        eprintln!("usage: epdfinfo [ERROR-LOGFILE]");
        std::process::exit(1);
    }
    let error_log = args.get(1).map(String::as_str).unwrap_or("/dev/null");
    if !redirect_stderr(error_log) {
        eprintln!("epdfinfo: Unable to redirect stderr");
        std::process::exit(2);
    }

    let mut session = Session::new();
    let stdin = std::io::stdin();
    let mut reader = std::io::BufReader::new(stdin.lock());
    let stdout = std::io::stdout();
    let mut writer = stdout.lock();

    loop {
        let mut line: Vec<u8> = Vec::new();
        match reader.read_until(b'\n', &mut line) {
            Ok(0) => break,
            Ok(n) => {
                if n <= 1 || line.last() != Some(&b'\n') {
                    eprintln!(
                        "Skipped parts of a line: `{}'",
                        String::from_utf8_lossy(&line)
                    );
                    continue;
                }
                line.pop();
                let text = String::from_utf8_lossy(&line).into_owned();
                let Some(parsed) = ParsedLine::parse(&text) else {
                    continue;
                };
                match commands::run(&mut session, &parsed.name, &parsed.args) {
                    Ok((response, flow)) => {
                        let _ = writer.write_all(&response.buf);
                        let _ = writer.flush();
                        if matches!(flow, Flow::Quit) {
                            std::process::exit(0);
                        }
                    }
                    Err(message) => {
                        let mut response = protocol::encode::Response::new();
                        response.err(&message);
                        let _ = writer.write_all(&response.buf);
                        let _ = writer.flush();
                    }
                }
            }
            Err(_) => std::process::exit(2),
        }
    }
    std::process::exit(0);
}
