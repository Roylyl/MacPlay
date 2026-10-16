//! The CarPlay screen stream received in this process: livi-screen-stream frames and decrypts
//! it, the feed registry gates it and routes it to the planes.

use std::collections::HashMap;
use std::io::Read;
use std::net::TcpListener;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use livi_screen_stream::{ScreenSink, ScreenStream};
use livi_video_nal::CpCodec;
use socket2::{Domain, Protocol, Socket, Type};

use crate::feed;

/// Reports the stream's configuration record, which the main process needs to build the plane.
pub type ConfigCb = Box<dyn Fn(CpCodec, Vec<u8>) + Send + 'static>;

const IDLE: Duration = Duration::from_millis(20);

#[derive(Default)]
struct Receiver {
    stop: AtomicBool,
    connected: AtomicBool,
    frames: AtomicU64,
    bytes: AtomicU64,
    connections: AtomicU64,
    disconnects: AtomicU64,
    last_disconnect_frames: AtomicU64,
}

struct Sink {
    id: u32,
    /// Set once this receiver is retired; a replacement owns the plane from then on.
    receiver: Arc<Receiver>,
    on_config: ConfigCb,
    /// The config the main process has; the phone repeats it, the plane is built once.
    reported: Option<(CpCodec, Vec<u8>)>,
}

impl Sink {
    fn retired(&self) -> bool {
        self.receiver.stop.load(Ordering::Relaxed)
    }
}

impl ScreenSink for Sink {
    fn on_config(&mut self, codec: CpCodec, atom: &[u8]) {
        if self.retired() {
            return;
        }
        feed::note_receiver_codec(self.id, codec);
        // a keepalive config carries no record, the last one stays
        if atom.is_empty() {
            return;
        }
        if self.reported.as_ref().is_some_and(|(c, a)| *c == codec && a == atom) {
            return;
        }
        self.reported = Some((codec, atom.to_vec()));
        (self.on_config)(codec, atom.to_vec());
    }

    fn on_frame(&mut self, nal: &[u8]) {
        if self.retired() {
            return;
        }
        crate::VIDEO_ACTIVITY.fetch_add(1, Ordering::Relaxed);
        self.receiver.frames.fetch_add(1, Ordering::Relaxed);
        self.receiver.bytes.fetch_add(nal.len() as u64, Ordering::Relaxed);
        feed::push_video(self.id, nal);
    }

    fn on_started(&mut self) {}
}

static RECEIVERS: OnceLock<Mutex<HashMap<u32, Arc<Receiver>>>> = OnceLock::new();

fn receivers() -> &'static Mutex<HashMap<u32, Arc<Receiver>>> {
    RECEIVERS.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Per receiver, so a retired stream or second control connection cannot affect health checks.
pub fn statistics(id: u32) -> Vec<f64> {
    let receivers = receivers().lock().unwrap_or_else(|e| e.into_inner());
    let Some(r) = receivers.get(&id) else { return Vec::new() };
    vec![r.frames.load(Ordering::Relaxed) as f64, r.bytes.load(Ordering::Relaxed) as f64,
        u8::from(r.connected.load(Ordering::Relaxed)) as f64,
        r.connections.load(Ordering::Relaxed) as f64, r.disconnects.load(Ordering::Acquire) as f64,
        r.last_disconnect_frames.load(Ordering::Relaxed) as f64]
}

/// Dual stack: the phone may reach us over either family.
fn listen_any_port() -> std::io::Result<TcpListener> {
    let socket = Socket::new(Domain::IPV6, Type::STREAM, Some(Protocol::TCP))?;
    socket.set_only_v6(false)?;
    socket.set_reuse_address(true)?;
    socket.bind(&"[::]:0".parse::<std::net::SocketAddr>().unwrap().into())?;
    socket.listen(1)?;
    Ok(socket.into())
}

/// Binds a port for this plane's stream and serves it until `close`. Returns the port.
pub fn open(id: u32, key: [u8; 32], on_config: ConfigCb) -> std::io::Result<u16> {
    close(id);
    feed::forget_stream(id);
    let listener = listen_any_port()?;
    let port = listener.local_addr()?.port();
    listener.set_nonblocking(true)?;

    let receiver = Arc::new(Receiver::default());
    receivers().lock().unwrap_or_else(|e| e.into_inner()).insert(id, receiver.clone());

    std::thread::Builder::new().name(format!("livi-cp-screen-{id}")).spawn(move || {
        // Built here: the sink behind ScreenStream is not Send, so it stays on this thread.
        let mut stream =
            ScreenStream::new(key, Box::new(Sink { id, receiver: receiver.clone(), on_config, reported: None }));
        let mut chunk = vec![0u8; 65536];
        while !receiver.stop.load(Ordering::Relaxed) {
            let Ok((client, _)) = listener.accept() else {
                std::thread::sleep(IDLE);
                continue;
            };
            let _ = client.set_nodelay(true);
            // The accepted socket inherits the listener's nonblocking flag; the read blocks with a
            // timeout.
            let _ = client.set_nonblocking(false);
            let _ = client.set_read_timeout(Some(IDLE));
            stream.reset();
            receiver.connections.fetch_add(1, Ordering::Relaxed);
            receiver.connected.store(true, Ordering::Release);
            eprintln!("[cp_screen] video data connection accepted");
            let mut client = client;
            while !receiver.stop.load(Ordering::Relaxed) {
                match client.read(&mut chunk) {
                    Ok(0) => break,
                    Ok(n) => {
                        if stream.push(&chunk[..n]).is_err() {
                            break; // Fatal framing/authentication error: close TCP so recovery can restart it.
                        }
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => continue,
                    Err(e) if e.kind() == std::io::ErrorKind::TimedOut => continue,
                    Err(_) => break,
                }
            }
            receiver.connected.store(false, Ordering::Release);
            receiver.last_disconnect_frames.store(receiver.frames.load(Ordering::Relaxed), Ordering::Relaxed);
            receiver.disconnects.fetch_add(1, Ordering::Release);
            eprintln!("[cp_screen] video data connection closed");
        }
    })?;
    Ok(port)
}

pub fn close(id: u32) {
    if let Some(receiver) = receivers().lock().unwrap_or_else(|e| e.into_inner()).remove(&id) {
        receiver.stop.store(true, Ordering::Relaxed);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::net::TcpStream;
    use std::sync::mpsc;

    const KEY: [u8; 32] = [7u8; 32];
    const HEADER_LEN: usize = 128;
    const OP_VIDEO_CONFIG: u8 = 1;

    /// A config message as the phone sends it: 128-byte header, then four reserved bytes,
    /// the fourcc and the record itself.
    fn config_message(fourcc: &[u8; 4], atom: &[u8]) -> Vec<u8> {
        let mut body = vec![0u8; 4];
        body.extend_from_slice(fourcc);
        body.extend_from_slice(atom);
        let mut m = vec![0u8; HEADER_LEN];
        m[..4].copy_from_slice(&(body.len() as u32).to_le_bytes());
        m[4] = OP_VIDEO_CONFIG;
        m.extend_from_slice(&body);
        m
    }

    fn connect(port: u16) -> TcpStream {
        for _ in 0..50 {
            if let Ok(c) = TcpStream::connect(("127.0.0.1", port)) {
                return c;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        panic!("receiver did not accept on {port}");
    }

    #[test]
    fn a_connection_reports_the_streams_config() {
        let (tx, rx) = mpsc::channel();
        let port = open(0xdead_0001, KEY, Box::new(move |codec, atom| {
            let _ = tx.send((codec as u8, atom));
        }))
        .expect("receiver binds a port");
        assert!(port > 0);

        let mut client = connect(port);
        client.write_all(&config_message(b"hvcC", &[1, 2, 3])).unwrap();

        let (codec, atom) = rx.recv_timeout(Duration::from_secs(5)).expect("config reported");
        assert_eq!(codec, 1, "hvcC is H265");
        assert_eq!(atom, vec![1, 2, 3]);
        close(0xdead_0001);
    }

    #[test]
    fn a_keepalive_config_is_not_reported() {
        let (tx, rx) = mpsc::channel();
        let port = open(0xdead_0003, KEY, Box::new(move |_, atom| {
            let _ = tx.send(atom);
        }))
        .unwrap();

        let mut client = connect(port);
        client.write_all(&config_message(b"hvcC", &[9])).unwrap();
        client.write_all(&config_message(b"hvcC", &[])).unwrap();

        assert_eq!(rx.recv_timeout(Duration::from_secs(5)).unwrap(), vec![9]);
        assert!(rx.recv_timeout(Duration::from_millis(300)).is_err(), "keepalive reported");
        close(0xdead_0003);
    }

    #[test]
    fn a_repeated_config_is_reported_once_and_a_changed_one_again() {
        let (tx, rx) = mpsc::channel();
        let port = open(0xdead_0004, KEY, Box::new(move |_, atom| {
            let _ = tx.send(atom);
        }))
        .unwrap();

        let mut client = connect(port);
        client.write_all(&config_message(b"hvcC", &[1])).unwrap();
        client.write_all(&config_message(b"hvcC", &[1])).unwrap();
        client.write_all(&config_message(b"hvcC", &[2])).unwrap();

        assert_eq!(rx.recv_timeout(Duration::from_secs(5)).unwrap(), vec![1]);
        assert_eq!(rx.recv_timeout(Duration::from_secs(5)).unwrap(), vec![2]);
        assert!(rx.recv_timeout(Duration::from_millis(300)).is_err(), "repeat reported");
        close(0xdead_0004);
    }

    #[test]
    fn a_second_open_replaces_the_first_and_close_frees_the_id() {
        let first = open(0xdead_0002, KEY, Box::new(|_, _| {})).unwrap();
        let second = open(0xdead_0002, KEY, Box::new(|_, _| {})).unwrap();
        assert_ne!(first, second, "each open binds its own port");
        close(0xdead_0002);
    }

    #[test]
    fn transport_health_is_scoped_to_the_current_receiver() {
        let id = 0xdead_0005;
        let port = open(id, KEY, Box::new(|_, _| {})).unwrap();
        let client = connect(port);
        for _ in 0..100 {
            if statistics(id)[2] == 1.0 { break; }
            std::thread::sleep(IDLE);
        }
        assert_eq!(&statistics(id)[2..5], &[1.0, 1.0, 0.0]);
        drop(client);
        for _ in 0..100 {
            if statistics(id)[4] == 1.0 { break; }
            std::thread::sleep(IDLE);
        }
        assert_eq!(&statistics(id)[2..5], &[0.0, 1.0, 1.0]);
        let _replacement = open(id, KEY, Box::new(|_, _| {})).unwrap();
        assert_eq!(statistics(id), vec![0.0; 6]);
        close(id);
        assert!(statistics(id).is_empty());
    }
}
