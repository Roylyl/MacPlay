//! One bounded address fallback for a wireless connection attempt.
use std::net::IpAddr;
use std::sync::{Arc, Mutex, atomic::{AtomicBool, Ordering}};
use std::time::Duration;
use tokio::{sync::watch, time::Instant};

#[derive(Clone, Debug)]
pub struct WirelessHandoff {
    primary: String,
    alternate: Option<String>,
    connected: watch::Sender<bool>,
    deadline: Arc<Mutex<Option<Instant>>>,
    retried: Arc<AtomicBool>,
    started: Arc<AtomicBool>,
}

impl WirelessHandoff {
    pub fn new(primary: &str, alternate: &str) -> Option<Self> {
        let primary = primary.parse::<IpAddr>().ok()?.to_string();
        let alternate = alternate.parse::<std::net::Ipv6Addr>().ok()
            .filter(|ip| ip.is_unicast_link_local())
            .map(|ip| ip.to_string())
            .filter(|ip| *ip != primary);
        let (connected, _) = watch::channel(false);
        Some(Self { primary, alternate, connected, deadline: Arc::new(Mutex::new(None)), retried: Arc::new(AtomicBool::new(false)), started: Arc::new(AtomicBool::new(false)) })
    }

    pub fn receiver_host(&self) -> String {
        if self.retried.load(Ordering::SeqCst) {
            if let Some(alternate) = &self.alternate { return alternate.clone(); }
        }
        self.primary.clone()
    }

    pub fn connection_updates(&self) -> watch::Receiver<bool> { self.connected.subscribe() }
    pub fn network_connected(&self) { self.connected.send_replace(true); }

    /// A refreshed Bluetooth channel must not start a second CarPlay session.
    pub fn claim_start(&self) -> bool {
        if *self.connected.borrow() { return false; }
        self.started.compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst).is_ok()
    }

    /// Repeated availability messages and overlapping Bluetooth sessions cannot reset the deadline.
    pub fn retry_deadline(&self) -> Option<Instant> {
        if self.alternate.is_none() || *self.connected.borrow() || self.retried.load(Ordering::SeqCst) { return None; }
        Some(*self.deadline.lock().unwrap().get_or_insert_with(|| Instant::now() + Duration::from_secs(12)))
    }

    pub fn take_alternate(&self) -> Option<String> {
        if *self.connected.borrow() { return None; }
        let alternate = self.alternate.clone()?;
        self.retried.compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst).ok()?;
        Some(alternate)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test(start_paused = true)]
    async fn availability_does_not_extend_the_single_retry_deadline() {
        let handoff = WirelessHandoff::new("192.0.2.10", "fe80::10").unwrap();
        let deadline = handoff.retry_deadline().unwrap();
        assert_eq!(deadline, Instant::now() + Duration::from_secs(12));
        tokio::time::advance(Duration::from_secs(5)).await;
        assert_eq!(handoff.clone().retry_deadline(), Some(deadline));
        assert_eq!(handoff.receiver_host(), "192.0.2.10");
        assert_eq!(handoff.take_alternate().as_deref(), Some("fe80::10"));
        assert_eq!(handoff.receiver_host(), "fe80::10");
        assert!(handoff.clone().take_alternate().is_none());
        assert!(handoff.retry_deadline().is_none());
    }

    #[tokio::test]
    async fn confirmed_session_cancels_all_bootstrap_waiters() {
        let handoff = WirelessHandoff::new("192.0.2.10", "fe80::10").unwrap();
        let mut updates = handoff.connection_updates();
        handoff.clone().network_connected();
        updates.changed().await.unwrap();
        assert!(*updates.borrow());
        assert!(handoff.retry_deadline().is_none());
        assert!(handoff.take_alternate().is_none());
        assert!(!handoff.claim_start());
    }

    #[test]
    fn refreshed_bluetooth_sessions_share_one_initial_request() {
        let handoff = WirelessHandoff::new("192.0.2.10", "fe80::10").unwrap();
        assert!(handoff.claim_start());
        assert!(!handoff.clone().claim_start());
        assert!(handoff.take_alternate().is_some());
        assert!(!handoff.clone().claim_start());
        handoff.network_connected();
        assert!(!handoff.claim_start());
        assert!(handoff.take_alternate().is_none());
    }

    #[test]
    fn no_duplicate_global_or_invalid_alternate_address() {
        assert!(WirelessHandoff::new("invalid", "fe80::10").is_none());
        for (primary, alternate) in [("fe80::10", "fe80::10"), ("192.0.2.10", "2001:db8::1"), ("192.0.2.10", "")] {
            let handoff = WirelessHandoff::new(primary, alternate).unwrap();
            assert!(handoff.take_alternate().is_none());
        }
    }
}
