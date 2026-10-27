use std::path::Path;
use std::time::Duration;

use tokio::sync::mpsc;
use tokio::time::Instant;

use iap2_csm::CsmMessage;
use iap2_csm::messages::authentication::*;
use iap2_csm::messages::car_play::*;
use iap2_csm::messages::communications::*;
use iap2_csm::messages::identification::*;
use iap2_csm::messages::location::*;
use iap2_csm::messages::now_playing::*;
use iap2_csm::messages::power::*;
use iap2_csm::messages::route_guidance::*;
use iap2_csm::messages::vehicle_status::*;
use iap2_csm::messages::wifi::*;

use crate::framing::frame_msg_id;
use crate::ident::{DROPPABLE, Identity, Transport, build_identification};
use crate::vehicle::{LocationTypes, VehicleFeed, VehicleStatus};
use crate::{AsyncAuth, ControlChannel, net};

/// Wireless CarPlay parameters handed to the phone: the AP and the AirPlay receiver.
#[derive(Debug, Clone)]
pub struct CpConfig {
    pub wifi_iface: String,
    pub ssid: String,
    pub passphrase: String,
    pub channel: u8,
    pub security_type: SecurityType,
    pub airplay_port: u32,
    pub source_version: String,
    pub public_key: String,
    pub transport: Transport,
    /// Wired only: the USB network interface carrying the AV stream, whose link-local
    /// address the phone connects back to.
    pub av_iface: Option<String>,
    pub available_current_ma: u16,
    /// The access point's MAC when it is not this host's, so the phone is told the right one.
    pub ap_mac: Option<String>,
    /// Asks an access point that is not this host's for the SSID and channel it is on air with.
    pub ap_on_air: Option<AskOnAir>,
    /// Mac wireless receiver addresses and cancellation shared with the control socket.
    pub wireless_handoff: Option<crate::wireless_handoff::WirelessHandoff>,
}

pub type AskOnAir = fn() -> Option<(String, u8)>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BringupEvent {
    Identified,
    Authenticated,
    Subscribed,
    WifiConfigSent,
    CarPlayStartSent,
    Incoming { msg_id: u16, frame: Vec<u8> },
    Failed(String),
    Closed,
    SeekResult { request_id: String, position_ms: u32, sent: bool },
}

#[derive(Debug)]
pub enum BringupError {
    Channel,
    Identification(String),
    Auth(String),
}

impl core::fmt::Display for BringupError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            BringupError::Channel => write!(f, "control channel closed during bring-up"),
            BringupError::Identification(e) => write!(f, "identification failed: {e}"),
            BringupError::Auth(e) => write!(f, "authentication failed: {e}"),
        }
    }
}

impl std::error::Error for BringupError {}

fn subscriptions() -> Vec<Vec<u8>> {
    vec![
        StartNowPlayingUpdates {
            media_item_attributes: Some(StartMediaItemAttributes {
                persistent_id: true,
                title: true,
                duration_ms: true,
                album: true,
                artist: true,
                album_artist: false,
                genre: false,
                artwork: true,
            }),
            playback_attributes: Some(StartPlaybackAttributes {
                status: true,
                elapsed_ms: true,
                app_name: true,
                playback_speed: true,
                set_elapsed_available: true,
                app_bundle_id: true,
            }),
        }
        .encode(),
        StartRouteGuidanceUpdates {
            display_component_id: None,
        }
        .encode(),
        StartPowerUpdates {
            maximum_current_drawn_from_accessory: false,
            device_battery_will_charge_if_power_is_present: false,
            accessory_power_mode: false,
            is_external_charger_connected: true,
            battery_charging_state: true,
            battery_charge_level: true,
        }
        .encode(),
        StartCommunicationsUpdates {
            signal_strength: true,
            registration_status: false,
            airplane_mode_status: false,
            carrier_name: true,
            cellular_supported: true,
        }
        .encode(),
        StartCallStateUpdates {
            remote_id: true,
            display_name: true,
            status: true,
            direction: true,
            call_uuid: true,
            address_book_id: false,
            label: false,
            service: false,
            is_conferenced: false,
            conference_group: false,
            disconnect_reason: true,
            start_timestamp: false,
        }
        .encode(),
    ]
}

async fn recv<C: ControlChannel>(ch: &mut C) -> Result<Vec<u8>, BringupError> {
    ch.recv().await.ok_or(BringupError::Channel)
}

async fn run_identification<C: ControlChannel>(
    ch: &mut C,
    id: &Identity,
    transport: Transport,
) -> Result<(), BringupError> {
    let mut exclude: Vec<&str> = Vec::new();
    loop {
        let frame = recv(ch).await?;
        match frame_msg_id(&frame) {
            Some(0x1D00) => {
                let ident = build_identification(id, transport, &exclude);
                ch.send(ident.encode())
                    .await
                    .map_err(|_| BringupError::Channel)?;
            }
            Some(0x1D02) => return Ok(()),
            Some(0x1D03) => {
                let rejected = IdentificationRejected::decode(&frame)
                    .map_err(|e| BringupError::Identification(e.to_string()))?;
                let flagged = flagged_fields(&rejected);
                let drop: Vec<&str> = DROPPABLE
                    .iter()
                    .copied()
                    .filter(|f| flagged.contains(f) && !exclude.contains(f))
                    .collect();
                if drop.is_empty() {
                    return Err(BringupError::Identification(format!(
                        "rejected fields not droppable: {flagged:?}"
                    )));
                }
                exclude.extend(drop);
                let ident = build_identification(id, transport, &exclude);
                ch.send(ident.encode())
                    .await
                    .map_err(|_| BringupError::Channel)?;
            }
            other => {
                return Err(BringupError::Identification(format!(
                    "unexpected message during identification: {other:?}"
                )));
            }
        }
    }
}

fn flagged_fields(r: &IdentificationRejected) -> Vec<&'static str> {
    let mut out = Vec::new();
    let mut push = |on: bool, name| {
        if on {
            out.push(name)
        }
    };
    push(
        r.location_information_component,
        "location_information_component",
    );
    push(
        r.vehicle_information_component,
        "vehicle_information_component",
    );
    push(r.vehicle_status_component, "vehicle_status_component");
    out
}

async fn run_auth<C: ControlChannel, A: AsyncAuth>(
    ch: &mut C,
    auth: &mut A,
) -> Result<(), BringupError> {
    let cert = auth.read_certificate().await.map_err(BringupError::Auth)?;
    loop {
        let frame = recv(ch).await?;
        match frame_msg_id(&frame) {
            Some(0xAA00) => {
                ch.send(
                    AuthenticationCertificate {
                        certificate: cert.clone(),
                    }
                    .encode(),
                )
                .await
                .map_err(|_| BringupError::Channel)?;
            }
            Some(0xAA02) => {
                let req = RequestAuthenticationChallengeResponse::decode(&frame)
                    .map_err(|e| BringupError::Auth(e.to_string()))?;
                let sig = auth.sign(req.challenge).await.map_err(BringupError::Auth)?;
                ch.send(AuthenticationResponse { response: sig }.encode())
                    .await
                    .map_err(|_| BringupError::Channel)?;
            }
            Some(0xAA05) => return Ok(()),
            Some(0xAA04) => {
                return Err(BringupError::Auth(
                    "device sent AuthenticationFailed".into(),
                ));
            }
            other => {
                return Err(BringupError::Auth(format!(
                    "unexpected message during auth: {other:?}"
                )));
            }
        }
    }
}

fn wifi_config(cp: &CpConfig) -> AccessoryWiFiConfigurationInformation {
    AccessoryWiFiConfigurationInformation {
        ssid: Some(cp.ssid.clone()),
        passphrase: Some(cp.passphrase.clone()),
        security_type: cp.security_type,
        channel: cp.channel,
    }
}

struct StartSessionGate {
    bootstrap: bool,
    sent: bool,
}

fn carplay_available(transport: Transport, offer: &CarPlayAvailability) -> bool {
    (match transport {
        Transport::Wired => offer.wired_attributes.as_ref().and_then(|a| a.available),
        Transport::Wireless => offer.wireless_attributes.as_ref().and_then(|a| a.available),
    }) == Some(true)
}

impl StartSessionGate {
    fn claim(&mut self, cp: &CpConfig, offer: &CarPlayAvailability) -> bool {
        if !self.bootstrap || self.sent || !carplay_available(cp.transport, offer) { return false; }
        if cp.transport == Transport::Wireless && cp.wireless_handoff.as_ref().is_some_and(|h| !h.claim_start()) { return false; }
        self.sent = true;
        true
    }
}

fn carplay_start_session(cp: &CpConfig, live: OnAir) -> Option<CarPlayStartSession> {
    if cp.transport == Transport::Wired {
        // The link-local the phone connects to: the A/V interface's.
        let fe80 = net::wlan_link_local(cp.av_iface.as_deref()?)?;
        return Some(CarPlayStartSession {
            wired_attributes: Some(CarPlayStartSessionWiredAttributes {
                ip_address: vec![fe80],
            }),
            wireless_attributes: None,
            port: Some(cp.airplay_port),
            // No AP interface: the A/V interface stands in.
            device_identifier: net::wlan_mac(&cp.wifi_iface)
                .or_else(|| cp.av_iface.as_deref().and_then(net::wlan_mac)),
            public_key: Some(cp.public_key.clone()),
            source_version: Some(cp.source_version.clone()),
        });
    }
    let receiver = cp.wireless_handoff.as_ref().map(|handoff| handoff.receiver_host())
        .or_else(|| net::wlan_link_local(&cp.wifi_iface))?;
    let (live_ssid, live_channel) = live;
    let ssid = live_ssid
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| cp.ssid.clone());
    let channel = live_channel.filter(|c| *c != 0).unwrap_or(cp.channel);
    Some(CarPlayStartSession {
        wired_attributes: None,
        wireless_attributes: Some(CarPlayStartSessionWirelessAttributes {
            wifi_ssid: Some(ssid),
            passphrase: Some(cp.passphrase.clone()),
            channel: Some(channel),
            ip_address: vec![receiver],
            security_type: Some(cp.security_type as u8),
        }),
        port: Some(cp.airplay_port),
        device_identifier: cp.ap_mac.clone().or_else(|| net::wlan_mac(&cp.wifi_iface)),
        public_key: Some(cp.public_key.clone()),
        source_version: Some(cp.source_version.clone()),
    })
}

/// How long the access point is given to come back before the phone is answered anyway.
// Covers the AP service's own readiness budget plus the wait for the regulatory domain.
const AP_WAIT: Duration = Duration::from_secs(30);
const AP_POLL: Duration = Duration::from_millis(250);

/// The SSID and channel the access point is on air with.
type OnAir = (Option<String>, Option<u8>);

async fn on_air(cp: &CpConfig) -> OnAir {
    match cp.ap_on_air {
        Some(ask) => match tokio::task::spawn_blocking(ask).await {
            Ok(Some((ssid, channel))) => (Some(ssid), Some(channel)),
            _ => (None, None),
        },
        None => net::ap_ssid_channel(&cp.wifi_iface),
    }
}

/// The answer names an SSID and a channel, so it waits until they are on air and returns them.
async fn wait_for_ap(cp: &CpConfig) -> OnAir {
    let iface = &cp.wifi_iface;
    let remote = cp.ap_on_air.is_some();
    if !remote && (iface.is_empty() || !Path::new(&format!("/sys/class/net/{iface}")).exists()) {
        return (None, None);
    }
    // A remote access point may still run what it had before ours was set.
    let up = |live: &OnAir| match live {
        (Some(ssid), Some(_)) => !remote || *ssid == cp.ssid,
        _ => false,
    };
    let mut live = on_air(cp).await;
    if up(&live) {
        return live;
    }
    let what = if remote {
        "the dongle's access point".to_string()
    } else {
        format!("the access point on {iface}")
    };
    println!("[cp] waiting for {what}");
    let deadline = Instant::now() + AP_WAIT;
    while Instant::now() < deadline {
        tokio::time::sleep(AP_POLL).await;
        live = on_air(cp).await;
        if up(&live) {
            if let (Some(ssid), Some(channel)) = &live {
                println!("[cp] access point up: {ssid} on channel {channel}");
            }
            return live;
        }
    }
    println!("[cp] {what} stayed down, answering anyway");
    live
}

/// Runs the accessory side of a wireless CarPlay session: identification, MFi auth,
/// subscriptions, then the request/response phase (Wi-Fi config, CarPlayStartSession),
/// emitting progress and every subsequent incoming message id over `events`.
pub async fn run_accessory<C: ControlChannel, A: AsyncAuth>(
    ch: C, auth: A, id: Identity, cp: CpConfig,
    events: mpsc::Sender<BringupEvent>, vehicle: VehicleFeed,
) {
    run_accessory_session(ch, auth, id, cp, events, vehicle, true).await;
}

/// iAP2 over an established CarPlay network session carries metadata and controls;
/// it must never ask the phone to replace that session with another one.
pub async fn run_accessory_tunnel<C: ControlChannel, A: AsyncAuth>(
    ch: C, auth: A, id: Identity, cp: CpConfig,
    events: mpsc::Sender<BringupEvent>, vehicle: VehicleFeed,
) {
    run_accessory_session(ch, auth, id, cp, events, vehicle, false).await;
}

async fn run_accessory_session<C: ControlChannel, A: AsyncAuth>(
    mut ch: C,
    mut auth: A,
    id: Identity,
    cp: CpConfig,
    events: mpsc::Sender<BringupEvent>,
    mut vehicle: VehicleFeed,
    bootstrap: bool,
) {
    if let Err(e) = run_identification(&mut ch, &id, cp.transport).await {
        let _ = events.send(BringupEvent::Failed(e.to_string())).await;
        return;
    }
    let _ = events.send(BringupEvent::Identified).await;

    if let Err(e) = run_auth(&mut ch, &mut auth).await {
        let _ = events.send(BringupEvent::Failed(e.to_string())).await;
        return;
    }
    let _ = events.send(BringupEvent::Authenticated).await;

    if cp.transport == Transport::Wired {
        let power = PowerSourceUpdate {
            available_current_for_device: Some(cp.available_current_ma),
            device_battery_should_charge_if_power_is_present: Some(true),
        };
        if ch.send(power.encode()).await.is_err() {
            let _ = events.send(BringupEvent::Closed).await;
            return;
        }
    }

    for sub in subscriptions() {
        if ch.send(sub).await.is_err() {
            let _ = events.send(BringupEvent::Closed).await;
            return;
        }
    }
    let _ = events.send(BringupEvent::Subscribed).await;

    let mut phone_tag=crate::events::EventTag::default();
    let mut seek_feed_open=true;
    let mut location_feed_open=true;
    let mut status_feed_open=true;
    let mut can_seek=false;
    let mut track_id: Option<String>=None;
    let mut duration: Option<u32>=None;
    let mut location_types = LocationTypes::default();
    let mut status_wanted = false;
    let handoff = (cp.transport == Transport::Wireless).then(|| cp.wireless_handoff.clone()).flatten();
    let mut connection_updates = handoff.as_ref().map(|h| h.connection_updates())
        .unwrap_or_else(|| tokio::sync::watch::channel(false).1);
    let mut connection_feed_open = handoff.is_some();
    let mut fallback_deadline: Option<Instant> = None;
    let mut fallback_message: Option<CarPlayStartSession> = None;
    let mut start_gate = StartSessionGate { bootstrap, sent: false };
    loop {
        let frame = tokio::select! {
            changed = connection_updates.changed(), if connection_feed_open => {
                if changed.is_err() { connection_feed_open = false; }
                if *connection_updates.borrow_and_update() {
                    fallback_deadline = None;
                    fallback_message = None;
                }
                continue;
            }
            _ = tokio::time::sleep_until(fallback_deadline.unwrap_or_else(|| Instant::now() + Duration::from_secs(3600))), if fallback_deadline.is_some() => {
                fallback_deadline = None;
                if let (Some(mut start), Some(address)) = (fallback_message.take(), handoff.as_ref().and_then(|h| h.take_alternate())) {
                    if let Some(wireless) = &mut start.wireless_attributes { wireless.ip_address = vec![address]; }
                    if ch.send(start.encode()).await.is_err() { break; }
                    println!("[cp] CarPlayStartSession alternate address sent (IPv6)");
                }
                continue;
            }
            frame = ch.recv() => match frame {
                Some(frame) => frame,
                None => break,
            },
            changed = vehicle.seek.changed(), if seek_feed_open => {
                if changed.is_err() { seek_feed_open=false; continue; }
                let seek=vehicle.seek.borrow_and_update().clone();
                if let Some(seek)=seek {
                    if !phone_tag.phone_id.as_ref().is_some_and(|id| id.replace('-', ":").eq_ignore_ascii_case(&seek.phone_id.replace('-', ":"))) {continue;}
                    let valid=can_seek && duration.is_some_and(|d| d>0) && (seek.track_id.is_none() || seek.track_id==track_id);
                    let position=seek.position_ms.min(duration.unwrap_or(0));
                    let sent=valid && ch.send(SetNowPlayingInformation{elapsed_ms:Some(position)}.encode()).await.is_ok();
                    let _=events.send(BringupEvent::SeekResult{request_id:seek.request_id,position_ms:position,sent}).await;
                }
                continue;
            }
            changed = vehicle.location.changed(), if location_feed_open => {
                if changed.is_err() {
                    location_feed_open = false;
                    continue;
                }
                let nmea = vehicle.location.borrow_and_update().1.clone();
                if !send_location(&mut ch, &location_types, &nmea).await {
                    break;
                }
                continue;
            }
            changed = vehicle.status.changed(), if status_feed_open => {
                if changed.is_err() {
                    status_feed_open = false;
                    continue;
                }
                let status = vehicle.status.borrow_and_update().clone();
                if status_wanted && !send_status(&mut ch, &status).await {
                    break;
                }
                continue;
            }
        };
        let Some(msg_id) = frame_msg_id(&frame) else {
            continue;
        };
        phone_tag.learn(&frame);
        if let Ok(update)=NowPlayingUpdate::decode(&frame) {
            if let Some(media)=&update.media_item_attributes {
                if let Some(id)=media.persistent_id {
                    let next=Some(id.to_string());
                    if next!=track_id {duration=None;track_id=next;}
                }
                if let Some(ms)=media.duration_ms {duration=Some(ms);}
            }
            if let Some(playback)=update.playback_attributes {
                if let Some(available)=playback.can_seek() {can_seek=available;}
            }
        }
        match msg_id {
            0xFFFA => {
                location_types = StartLocationInformation::decode(&frame)
                    .map(|req| LocationTypes::from_request(&req))
                    .unwrap_or_default();
                println!("[cp] location: subscribed {:?}", location_types.names());
                // Only fixes from now on, not the one from before the phone asked.
                vehicle.location.mark_unchanged();
            }
            0xFFFC => {
                location_types = LocationTypes::default();
                println!("[cp] location: stopped");
            }
            0xA100 => {
                status_wanted = true;
                println!("[cp] vehicle status: subscribed");
                let status = vehicle.status.borrow_and_update().clone();
                if !send_status(&mut ch, &status).await {
                    break;
                }
            }
            0xA102 => {
                status_wanted = false;
                println!("[cp] vehicle status: stopped");
            }
            0x5702 => {
                if ch.send(wifi_config(&cp).encode()).await.is_err() {
                    break;
                }
                let _ = events.send(BringupEvent::WifiConfigSent).await;
            }
            0x4300 => {
                let offer = match CarPlayAvailability::decode(&frame) {
                    Ok(offer) => offer,
                    Err(e) => {
                        fallback_deadline = None;
                        fallback_message = None;
                        println!("[cp] CarPlayAvailability undecodable: {e}");
                        continue;
                    }
                };
                println!("[cp] CarPlayAvailability wired={:?} wireless={:?}", offer.wired_attributes, offer.wireless_attributes);
                if !carplay_available(cp.transport, &offer) {
                    fallback_deadline = None;
                    fallback_message = None;
                    continue;
                }
                if !start_gate.bootstrap || start_gate.sent { continue; }
                let live = if cp.transport == Transport::Wired {
                    (None, None)
                } else {
                    wait_for_ap(&cp).await
                };
                match carplay_start_session(&cp, live) {
                    Some(start) => {
                        // Recheck shared state after awaiting network parameters.
                        if !start_gate.claim(&cp, &offer) { continue; }
                        let ip = start
                            .wireless_attributes
                            .as_ref()
                            .map(|w| &w.ip_address)
                            .or_else(|| start.wired_attributes.as_ref().map(|w| &w.ip_address))
                            .map(|a| a.join(","))
                            .unwrap_or_default();
                        println!(
                            "[cp] CarPlayStartSession ip={ip} port={} device_id={} pk_len={}",
                            start.port.unwrap_or(0),
                            start.device_identifier.as_deref().unwrap_or("-"),
                            start.public_key.as_deref().unwrap_or("").len()
                        );
                        if ch.send(start.encode()).await.is_err() {
                            break;
                        }
                        if fallback_deadline.is_none() {
                            fallback_deadline = handoff.as_ref().and_then(|h| h.retry_deadline());
                            if fallback_deadline.is_some() { fallback_message = Some(start); }
                        }
                        let _ = events.send(BringupEvent::CarPlayStartSent).await;
                    }
                    None => {
                        let iface = if cp.transport == Transport::Wired { cp.av_iface.as_deref().unwrap_or("<missing USB interface>") } else { &cp.wifi_iface };
                        let why = format!("no usable receiver address on {iface:?}");
                        println!("[cp] CarPlayStartSession not sent: {why}");
                        let _ = events.send(BringupEvent::Failed(why)).await;
                    }
                }
            }
            _ => {}
        }
        if events
            .send(BringupEvent::Incoming { msg_id, frame })
            .await
            .is_err()
        {
            return;
        }
    }
    let _ = events.send(BringupEvent::Closed).await;
}

/// Each sentence the phone asked for as its own message. False once the channel is gone.
async fn send_location<C: ControlChannel>(ch: &mut C, types: &LocationTypes, nmea: &str) -> bool {
    for line in types.wanted(nmea) {
        let msg = LocationInformation { nmea_sentence: line.to_string() };
        if ch.send(msg.encode()).await.is_err() {
            return false;
        }
    }
    true
}

async fn send_status<C: ControlChannel>(ch: &mut C, status: &VehicleStatus) -> bool {
    if status.is_empty() {
        return true;
    }
    println!(
        "[cp] vehicle status → range={:?} temp={:?} warn={:?}",
        status.range, status.outside_temperature, status.range_warning
    );
    let msg = VehicleStatusUpdate {
        range: status.range,
        outside_temperature: status.outside_temperature,
        range_warning: status.range_warning,
    };
    ch.send(msg.encode()).await.is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dongle_ap(ask: AskOnAir) -> CpConfig {
        CpConfig {
            wifi_iface: "usb0".into(),
            ssid: "LIVI".into(),
            passphrase: "12345678".into(),
            channel: 36,
            security_type: SecurityType::WpaWpa2,
            airplay_port: 7000,
            source_version: "950.7.1".into(),
            public_key: String::new(),
            transport: Transport::Wireless,
            av_iface: None,
            available_current_ma: 500,
            ap_mac: None,
            ap_on_air: Some(ask),
            wireless_handoff: None,
        }
    }

    fn offer(wired: Option<bool>, wireless: Option<bool>) -> CarPlayAvailability {
        CarPlayAvailability {
            wired_attributes: Some(CarPlayAvailabilityWiredAttributes { available: wired, usb_transport_identifier: None }),
            wireless_attributes: Some(CarPlayAvailabilityWirelessAttributes { available: wireless, bluetooth_transport_identifier: None }),
        }
    }

    #[test]
    fn starts_only_when_the_current_transport_is_available() {
        let mut cp = dongle_ap(|| None);
        let mut gate = StartSessionGate { bootstrap: true, sent: false };
        for advertised in [offer(Some(true), Some(false)), offer(Some(true), None)] {
            let decoded = CarPlayAvailability::decode(&advertised.encode()).unwrap();
            assert!(!gate.claim(&cp, &decoded));
        }
        assert!(gate.claim(&cp, &offer(Some(false), Some(true))));
        assert!(!gate.claim(&cp, &offer(Some(false), Some(true))));
        cp.transport = Transport::Wired;
        let mut wired = StartSessionGate { bootstrap: true, sent: false };
        assert!(!wired.claim(&cp, &offer(Some(false), Some(true))));
        assert!(wired.claim(&cp, &offer(Some(true), Some(false))));
    }

    #[test]
    fn metadata_tunnel_never_restarts_carplay_even_when_advertised_available() {
        let mut cp = dongle_ap(|| None);
        for transport in [Transport::Wireless, Transport::Wired] {
            cp.transport = transport;
            let mut gate = StartSessionGate { bootstrap: false, sent: false };
            assert!(!gate.claim(&cp, &offer(Some(true), Some(true))));
            assert!(!gate.claim(&cp, &offer(Some(false), Some(false))));
        }
    }

    #[test]
    fn new_bluetooth_channel_cannot_restart_an_existing_wireless_session() {
        let mut cp = dongle_ap(|| None);
        cp.wireless_handoff = crate::wireless_handoff::WirelessHandoff::new("192.0.2.10", "fe80::10");
        let mut first = StartSessionGate { bootstrap: true, sent: false };
        assert!(first.claim(&cp, &offer(None, Some(true))));
        let mut refreshed = StartSessionGate { bootstrap: true, sent: false };
        assert!(!refreshed.claim(&cp.clone(), &offer(None, Some(true))));
        cp.wireless_handoff.as_ref().unwrap().network_connected();
        assert!(!refreshed.claim(&cp, &offer(None, Some(true))));
        cp.transport = Transport::Wired;
        assert!(refreshed.claim(&cp, &offer(Some(true), None)));
    }

    #[test]
    fn wireless_handoff_uses_selected_primary_but_never_overrides_wired_usb() {
        let mut cp = dongle_ap(|| None);
        cp.wifi_iface = "missing-test-interface".into();
        cp.wireless_handoff = crate::wireless_handoff::WirelessHandoff::new("192.0.2.10", "fe80::10");
        let start = carplay_start_session(&cp, (None, None)).unwrap();
        assert_eq!(start.wireless_attributes.unwrap().ip_address, vec!["192.0.2.10"]);
        assert!(start.wired_attributes.is_none());
        cp.transport = Transport::Wired;
        // USB interface is absent: the wireless address must not substitute for it.
        assert!(carplay_start_session(&cp, (None, None)).is_none());
    }

    #[tokio::test]
    async fn a_dongle_carrying_our_ssid_is_not_waited_for() {
        let live = wait_for_ap(&dongle_ap(|| Some(("LIVI".into(), 6)))).await;
        assert_eq!(live, (Some("LIVI".into()), Some(6)));
    }

    #[tokio::test(start_paused = true)]
    async fn a_dongle_on_another_ssid_is_answered_with_what_it_carries() {
        let live = wait_for_ap(&dongle_ap(|| Some(("old".into(), 36)))).await;
        assert_eq!(live, (Some("old".into()), Some(36)));
    }

    #[tokio::test(start_paused = true)]
    async fn a_silent_dongle_leaves_our_own_values() {
        let live = wait_for_ap(&dongle_ap(|| None)).await;
        assert_eq!(live, (None, None));
    }
}
