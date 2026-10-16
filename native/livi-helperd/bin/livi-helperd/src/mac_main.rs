// macOS direct receiver: system usbmuxd, local authentication and IOBluetooth.
use std::process::ExitCode;
use std::sync::Arc;
use std::time::Duration;

use iap2_csm::messages::wifi::SecurityType;
use iap2_link::LinkConfig;
use iap2_mfi::local::LocalCoprocessor;
use livi_runtime::bonjour::Bonjour;
use livi_runtime::bringup::{CpConfig, run_accessory};
use livi_runtime::driver::spawn_link_stream;
use livi_runtime::ident::{Identity, Transport};
use livi_runtime::livi_sock::{
    self, Broadcaster, LiviSockConfig, SharedTag, pump_artwork, pump_events_for,
};
use livi_runtime::mfi_async::SharedCoprocessor;
use livi_runtime::state::HelperState;

use crate::link::LinkPresence;

/// The published service, kept so nothing drops it while the helper runs.
static BONJOUR: std::sync::OnceLock<Bonjour> = std::sync::OnceLock::new();

fn env_s(key: &str, default: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default.to_string())
}

/// 6-byte accessory id: LIVI_CP_BT_MAC if set, else derived from the host pairing id.
fn accessory_mac(pi: &str) -> [u8; 6] {
    if let Ok(s) = std::env::var("LIVI_CP_BT_MAC") {
        let bytes: Vec<u8> = s
            .split(':')
            .filter_map(|h| u8::from_str_radix(h, 16).ok())
            .collect();
        if bytes.len() == 6 {
            return [bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5]];
        }
    }
    let mut m = [0x02u8, 0, 0, 0, 0, 0]; // locally-administered
    for (i, b) in pi.bytes().enumerate() {
        m[1 + (i % 5)] ^= b;
    }
    m
}

fn cp_config() -> (CpConfig, Identity) {
    let name = env_s("LIVI_CP_NAME", "LIVI");
    let pi = env_s("LIVI_CP_PI", "");
    let cp = CpConfig {
        ap_mac: Some(env_s("LIVI_CP_AP_MAC", "")).filter(|value|!value.is_empty()),
        ap_on_air: None,
        wireless_handoff: if env_s("LIVI_CP_WIRELESS", "") == "1" {
            livi_runtime::wireless_handoff::WirelessHandoff::new(&env_s("MACPLAY_RECEIVER_HOST", ""), &env_s("MACPLAY_RECEIVER_ALTERNATE_HOST", ""))
        } else { None },
        wifi_iface: env_s("LIVI_WIFI_IFACE", "en0"),
        ssid: name.clone(),
        passphrase: env_s("LIVI_PASSPHRASE", ""),
        channel: env_s("LIVI_CHANNEL", "36").parse().unwrap_or(36),
        security_type: SecurityType::WpaWpa2,
        airplay_port: env_s("LIVI_CP_AIRPLAY_PORT", "17000")
            .parse()
            .unwrap_or(17000),
        source_version: env_s("LIVI_CP_SOURCE_VERSION", "950.7.1"),
        public_key: pi.clone(),
        transport: Transport::Wired,
        av_iface: None, // resolved per session from the iPhone USB interface
        available_current_ma: 500,
    };
    let identity = Identity {
        name: name.clone(),
        ssid: name,
        bt_mac: accessory_mac(&pi),
    };
    (cp, identity)
}

async fn direct_bluetooth(auth: SharedCoprocessor, identity: Identity, mut cp: CpConfig,
    bcast: Broadcaster, state: Arc<HelperState>) {
    use tokio::io::AsyncReadExt;
    use std::os::unix::fs::PermissionsExt;
    let dir = std::env::var("MACPLAY_AUTH_DIR").unwrap_or_default();
    let path = std::path::Path::new(&dir).join("bluetooth.sock");
    let _ = std::fs::remove_file(&path);
    let listener = match tokio::net::UnixListener::bind(&path) {
        Ok(v) => v, Err(e) => { eprintln!("[MacPlay] Bluetooth socket: {e}"); return; }
    };
    let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
    cp.transport = Transport::Wireless;
    cp.wifi_iface = env_s("LIVI_WIFI_IFACE", "en0");
    cp.ssid = env_s("MACPLAY_WIFI_SSID", "");
    cp.av_iface = Some(cp.wifi_iface.clone());
    if cp.ssid.is_empty() { eprintln!("[MacPlay] Wireless setup needs the shared Wi-Fi SSID; Bluetooth discovery remains enabled"); }
    let bin = std::env::current_exe().unwrap().with_file_name("macplay-bluetooth");
    let mut child = match tokio::process::Command::new(bin).arg(&path).kill_on_drop(true).spawn() {
        Ok(v) => v, Err(e) => { eprintln!("[MacPlay] Bluetooth bridge: {e}"); return; }
    };
    loop {
        let accepted = tokio::select! {
            result = listener.accept() => result,
            result = child.wait() => { eprintln!("[MacPlay] Bluetooth bridge ended: {result:?}"); break; }
        };
        let Ok((mut stream, _)) = accepted else { break };
        if cp.ssid.is_empty() { eprintln!("[MacPlay] wireless connection refused: configure Wi-Fi first"); continue; }
        let mut header = Vec::new();
        while header.len() < 80 {
            match tokio::time::timeout(Duration::from_secs(3), stream.read_u8()).await {
                Ok(Ok(b'\n')) => break,
                Ok(Ok(b)) => header.push(b),
                _ => break,
            }
        }
        let value = String::from_utf8_lossy(&header);
        let local = value.split('|').next().unwrap_or("").replace('-', ":");
        let bytes: Vec<u8> = local.split(':').filter_map(|v| u8::from_str_radix(v,16).ok()).collect();
        if bytes.len()!=6 { continue; }
        let mut id = identity.clone(); id.bt_mac.copy_from_slice(&bytes); id.ssid=cp.ssid.clone();
        let (channel, art_rx) = spawn_link_stream(stream, LinkConfig { max_outgoing:4, control_version:2, ..LinkConfig::default() }, false);
        let (tx,rx) = tokio::sync::mpsc::channel(64);
        tokio::spawn(run_accessory(channel, auth.clone(), id, cp.clone(), tx, state.vehicle_feed()));
        let ident: SharedTag = Default::default();
        tokio::spawn(pump_events_for(rx,bcast.clone(),"bt",None,ident.clone()));
        tokio::spawn(pump_artwork(art_rx,bcast.clone(),ident));
    }
    let _ = std::fs::remove_file(&path);
}


fn start_carplay() -> Result<(), String> {
    let (cp, identity) = cp_config();
    let dir = std::env::var("MACPLAY_AUTH_DIR").map_err(|_| "缺少认证目录".to_string())?;
    let auth = LocalCoprocessor::load(std::path::Path::new(&dir)).map_err(|e|e.to_string())?;
    let auth = SharedCoprocessor::new(Box::new(auth));
    let bcast = Broadcaster::default();
    let state = Arc::new(HelperState::default());
    let wireless = env_s("LIVI_CP_WIRELESS", "") == "1";
    let tunnel_cp = if wireless { CpConfig {
        transport: Transport::Wireless,
        wifi_iface: env_s("LIVI_WIFI_IFACE", "en0"),
        ssid: env_s("MACPLAY_WIFI_SSID", ""), ..cp.clone()
    }} else {cp.clone()};
    let sock_cfg = LiviSockConfig { path:livi_sock::SOCK_PATH.into(),adapter:String::new(),identity:identity.clone(),cp:tunnel_cp,disconnect:None,targets:None,cp_live:None };
    let (a,bc,st)=(auth.clone(),bcast.clone(),state.clone());
    tokio::spawn(async move { if let Err(e)=livi_sock::serve(sock_cfg,a,None,bc,st).await {eprintln!("[MacPlay] control socket failed: {e}");} });
    if wireless {
        tokio::spawn(direct_bluetooth(auth,identity,cp.clone(),bcast.clone(),state));
    } else {
        tokio::spawn(crate::wired::watch_usbmuxd(auth,identity,cp.clone(),bcast.clone(),state,LinkPresence::always()));
    }
    if env_s("MACPLAY_EXTERNAL_DISCOVERY", "") != "1" {
    let b=Bonjour::start(env_s("LIVI_CP_DEVICE_ID","02:4d:50:00:00:01"),cp.airplay_port as u16,cp.source_version,env_s("LIVI_CP_PK",""),env_s("LIVI_CP_PI",""),bcast).map_err(|e|e.to_string())?;
    let _=BONJOUR.set(b);
    }
    println!("[MacPlay] {} receiver ready on port {}",if wireless {"wireless"} else {"wired USB"},cp.airplay_port);
    Ok(())
}
pub fn run() -> ExitCode {
    let rt=tokio::runtime::Runtime::new().expect("runtime");
    rt.block_on(async {
        if let Err(e)=start_carplay(){eprintln!("[MacPlay] startup failed: {e}");return ExitCode::FAILURE;}
        crate::shutdown_signal().await;
        livi_runtime::bonjour::stop();ExitCode::SUCCESS
    })
}
