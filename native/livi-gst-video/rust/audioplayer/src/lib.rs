//! One CarPlay audio stream from its RTP packets to the sink.
//!
//! The packets arrive decrypted from the receiver and go into an appsrc. The
//! jitter buffer paces them, the decoder turns them into PCM, and clocksync
//! releases each buffer at its running time, which the phone's burst delivery
//! needs.

pub mod uplink;

use gstreamer as gst;
use gstreamer_app as gst_app;
use gstreamer_audio as gst_audio;
use gstreamer_controller as gst_controller;
use gstreamer_controller::prelude::*;

use livi_audio_stream::{reframe_aac, rtp_caps, Codec, RTP_HEADER_LEN};
use std::str::FromStr;
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Once};

/// What a stream needs to build its pipeline.
pub struct Config {
    pub codec: Codec,
    pub payload_type: u8,
    pub clock_rate: u32,
    pub channels: u8,
    /// Jitter buffer depth. The phone ships buffered media that far ahead.
    pub latency_ms: u32,
    /// Voice and call streams take the short path to the sink.
    pub realtime: bool,
    pub device: Option<String>,
    pub label: String,
}

/// What turns the packets into raw samples. LPCM is already raw, so it goes
/// straight on.
fn decoder_chain(codec: Codec) -> Option<&'static str> {
    match codec {
        Codec::Lpcm | Codec::PcmLe => None,
        Codec::Opus => Some("rtpjitterbuffer latency={latency} name=jitter ! rtpopusdepay ! opusdec"),
        #[cfg(target_os = "linux")]
        Codec::AacLc => Some("rtpjitterbuffer latency={latency} name=jitter ! rtpmp4gdepay ! aacparse ! faad"),
        #[cfg(not(target_os = "linux"))]
        Codec::AacLc => {
            Some("rtpjitterbuffer latency={latency} name=jitter ! rtpmp4gdepay ! aacparse ! avdec_aac")
        }
    }
}

/// The only thing about audio output that differs between the systems: which sink carries it,
/// and what that sink calls a device.
const fn audio_sink() -> (&'static str, &'static str) {
    if cfg!(target_os = "macos") {
        ("osxaudiosink", "unique-id")
    } else {
        ("pulsesink", "device")
    }
}

const SINK_NAME: &str = "audio-sink";

fn sink_chain(cfg: &Config) -> String {
    let (element, _device_property) = audio_sink();
    if cfg.realtime {
        format!("{element} name={SINK_NAME} sync=false")
    } else {
        format!("{element} name={SINK_NAME} sync=false buffer-time=300000 latency-time=30000")
    }
}

/// The whole pipeline for `cfg`. The caps go onto the appsrc afterwards, so the
/// RFC 3640 fields keep their string types.
pub fn pipeline_desc(cfg: &Config) -> String {
    let head = match decoder_chain(cfg.codec) {
        Some(chain) => format!("{} ! ", chain.replace("{latency}", &cfg.latency_ms.max(100).to_string())),
        None => String::new(),
    };
    format!(
        "appsrc name=src is-live=true format=time do-timestamp=true ! \
         {head}audioconvert ! clocksync name=playout-clock sync=true ! volume name=vol ! \
         audioconvert ! audioresample ! audio/x-raw,format=S16LE,rate=48000,channels=2 ! \
         queue name=output-queue ! {sink}",
        sink = sink_chain(cfg),
    )
}

/// Pre-fader mono samples the probe mixed down, with their rate.
#[derive(Default)]
struct VizAcc {
    samples: Vec<i16>,
    rate: u32,
}

/// Statistics read from the pipeline; missing fields stay unknown, not zero.
#[derive(Default)]
pub struct Statistics {
    pub decoded_buffers: u64,
    pub pipeline_errors: u64,
    pub jitter_lost: Option<u64>,
    pub jitter_late: Option<u64>,
    pub jitter_duplicates: Option<u64>,
    pub average_jitter_ns: Option<u64>,
    pub queue_buffer_ns: Option<u64>,
    pub playout_lead_ns: Option<i64>,
    pub clock_latency_ns: Option<u64>,
    pub late_buffers: u64,
    pub device_restarts: u64,
}

pub struct Player {
    decoded: Arc<AtomicU64>,
    errors: Arc<AtomicU64>,
    playout_lead_ns: Arc<AtomicI64>,
    clock_latency_ns: Arc<AtomicU64>,
    late_buffers: Arc<AtomicU64>,
    device_restarts: AtomicU64,
    pipeline: gst::Pipeline,
    appsrc: gst_app::AppSrc,
    volume: gst::Element,
    /// GStreamer glides the level along this on the pipeline clock.
    level: gst_controller::InterpolationControlSource,
    visualizer_enabled: Arc<AtomicBool>,
    visualizer: Arc<Mutex<VizAcc>>,
    codec: Codec,
    payload_type: u8,
}

impl Player {
    pub fn new(cfg: &Config) -> Option<Self> {
        ensure_init();

        let desc = pipeline_desc(cfg);
        let pipeline = match gst::parse::launch(&desc) {
            Ok(p) => p.downcast::<gst::Pipeline>().ok()?,
            Err(e) => {
                eprintln!("[cp_audio:{}] pipeline failed: {e}", cfg.label);
                return None;
            }
        };

        if let Some(device) = &cfg.device {
            let (_, device_property) = audio_sink();
            let sink = pipeline.by_name(SINK_NAME)?;
            sink.set_property(device_property, device.as_str());
        }

        let appsrc = pipeline.by_name("src")?.downcast::<gst_app::AppSrc>().ok()?;
        let caps = gst::Caps::from_str(&rtp_caps(
            cfg.codec,
            cfg.payload_type,
            cfg.clock_rate,
            cfg.channels,
        ))
        .ok()?;
        appsrc.set_caps(Some(&caps));

        let volume = pipeline.by_name("vol")?;
        let level = gst_controller::InterpolationControlSource::new();
        level.set_mode(gst_controller::InterpolationMode::Linear);
        let binding = gst_controller::DirectControlBinding::new_absolute(&volume, "volume", &level);
        volume.add_control_binding(&binding).ok()?;
        volume.set_control_binding_disabled("volume", true);

        let decoded=Arc::new(AtomicU64::new(0));
        let errors=Arc::new(AtomicU64::new(0));
        let playout_lead_ns=Arc::new(AtomicI64::new(i64::MIN));
        let late_buffers=Arc::new(AtomicU64::new(0));
        let clock_latency_ns=Arc::new(AtomicU64::new(u64::MAX));
        // Segment running time + the queried upstream latency - current time.
        // This follows clocksync scheduling, not acoustic or network latency.
        if let Some(pad)=pipeline.by_name("playout-clock").and_then(|e|e.static_pad("sink")) {
            let weak=pipeline.downgrade();
            let lead=playout_lead_ns.clone();
            let late=late_buffers.clone();
            let latency=clock_latency_ns.clone();
            pad.add_probe(gst::PadProbeType::BUFFER,move |pad,info|{
                let latency=latency.load(Ordering::Relaxed);
                if latency!=u64::MAX
                    && let Some(pts)=info.buffer().and_then(|b|b.pts())
                    && let Some(event)=pad.sticky_event::<gst::event::Segment>(0)
                    && let Some(segment)=event.segment().downcast_ref::<gst::ClockTime>()
                    && let Some(running)=segment.to_running_time(pts)
                    && let Some(now)=weak.upgrade().and_then(|p|p.current_running_time()) {
                    let delta=(i128::from(running.nseconds())+i128::from(latency)-i128::from(now.nseconds()))
                        .clamp(i128::from(i64::MIN)+1,i128::from(i64::MAX)) as i64;
                    lead.store(delta,Ordering::Relaxed);
                    if delta < -20_000_000 {late.fetch_add(1,Ordering::Relaxed);}
                }
                gst::PadProbeReturn::Ok
            });
        }
        let visualizer_enabled = Arc::new(AtomicBool::new(false));
        let visualizer: Arc<Mutex<VizAcc>> = Default::default();
        // Pre-fader tap: mix each buffer to mono, hold ~200ms.
        if let Some(sink_pad) = volume.static_pad("sink") {
            let decoded=decoded.clone();
            let enabled = visualizer_enabled.clone();
            let acc = visualizer.clone();
            sink_pad.add_probe(gst::PadProbeType::BUFFER, move |pad, info| {
                if info.buffer().is_some(){decoded.fetch_add(1,Ordering::Relaxed);}
                if enabled.load(Ordering::Relaxed)
                    && let Some(buffer) = info.buffer()
                    && let Some(caps) = pad.current_caps()
                    && let Ok(ainfo) = gst_audio::AudioInfo::from_caps(&caps)
                    && let Ok(map) = buffer.map_readable()
                {
                    let ch = ainfo.channels().max(1) as usize;
                    let mono: Vec<i16> = match ainfo.format() {
                        gst_audio::AudioFormat::S16le => map
                            .as_slice()
                            .as_chunks::<2>()
                            .0
                            .chunks(ch)
                            .map(|f| (f.iter().map(|b| i16::from_le_bytes(*b) as i32).sum::<i32>() / ch as i32) as i16)
                            .collect(),
                        gst_audio::AudioFormat::F32le => map
                            .as_slice()
                            .as_chunks::<4>()
                            .0
                            .chunks(ch)
                            .map(|f| {
                                let avg = f.iter().map(|b| f32::from_le_bytes(*b)).sum::<f32>() / ch as f32;
                                (avg.clamp(-1.0, 1.0) * 32767.0) as i16
                            })
                            .collect(),
                        _ => return gst::PadProbeReturn::Ok,
                    };
                    if let Ok(mut a) = acc.lock() {
                        a.rate = ainfo.rate();
                        a.samples.extend_from_slice(&mono);
                        let cap = a.rate as usize / 5;
                        if cap > 0 && a.samples.len() > cap {
                            let overflow = a.samples.len() - cap;
                            a.samples.drain(..overflow);
                        }
                    }
                }
                gst::PadProbeReturn::Ok
            });
        }

        if let Some(bus) = pipeline.bus() {
            let errors=errors.clone();
            let label = cfg.label.clone();
            bus.set_sync_handler(move |_, msg| {
                if let gst::MessageView::Error(e) = msg.view() {
                    errors.fetch_add(1,Ordering::Relaxed);
                    eprintln!("[cp_audio:{label}] {} | {}", e.error(), e.debug().unwrap_or_default());
                }
                gst::BusSyncReply::Drop
            });
        }

        Some(Self {
            decoded,errors,playout_lead_ns,clock_latency_ns,late_buffers,device_restarts:AtomicU64::new(0),
            pipeline,
            appsrc,
            volume,
            level,
            visualizer_enabled,
            visualizer,
            codec: cfg.codec,
            payload_type: cfg.payload_type,
        })
    }

    pub fn statistics(&self) -> Statistics {
        // Query on the low-frequency statistics tick, never on the audio thread.
        if let Some(pad)=self.pipeline.by_name("playout-clock").and_then(|e|e.static_pad("sink")) {
            let mut query=gst::query::Latency::new();
            if pad.peer_query(&mut query) {
                let (live,min,_)=query.result();
                self.clock_latency_ns.store(if live {min.nseconds()}else{0},Ordering::Relaxed);
            }
        }
        let jitter=self.pipeline.by_name("jitter").map(|e|e.property::<gst::Structure>("stats"));
        let field=|name:&str|jitter.as_ref().and_then(|s|s.get::<u64>(name).ok());
        let lead=self.playout_lead_ns.load(Ordering::Relaxed);
        let latency=self.clock_latency_ns.load(Ordering::Relaxed);
        Statistics {
            decoded_buffers:self.decoded.load(Ordering::Relaxed),
            pipeline_errors:self.errors.load(Ordering::Relaxed),
            jitter_lost:field("num-lost"), jitter_late:field("num-late"),
            jitter_duplicates:field("num-duplicates"), average_jitter_ns:field("avg-jitter"),
            queue_buffer_ns:self.pipeline.by_name("output-queue").map(|e|e.property::<u64>("current-level-time")),
            playout_lead_ns:(lead!=i64::MIN).then_some(lead),
            clock_latency_ns:(latency!=u64::MAX).then_some(latency),
            late_buffers:self.late_buffers.load(Ordering::Relaxed),
            device_restarts:self.device_restarts.load(Ordering::Relaxed),
        }
    }

    /// Restart only the output pipeline; the receiver, ports and stream ID stay.
    pub fn set_device(&self,device:Option<&str>)->bool {
        if self.pipeline.set_state(gst::State::Null).is_err(){return false}
        let Some(sink)=self.pipeline.by_name(SINK_NAME) else{return false};
        let (_,property)=audio_sink();
        sink.set_property(property,device.filter(|d|!d.is_empty()));
        self.playout_lead_ns.store(i64::MIN,Ordering::Relaxed);
        self.clock_latency_ns.store(u64::MAX,Ordering::Relaxed);
        // Remove an in-flight volume ramp from the old pipeline clock.
        self.volume.set_control_binding_disabled("volume",true);
        if self.pipeline.set_state(gst::State::Playing).is_err(){return false}
        self.device_restarts.fetch_add(1,Ordering::Relaxed);
        true
    }

    /// Toggles the tap; off clears what was held.
    pub fn set_visualizer_enabled(&self, on: bool) {
        self.visualizer_enabled.store(on, Ordering::Relaxed);
        if !on && let Ok(mut a) = self.visualizer.lock() {
            a.samples.clear();
        }
    }

    /// Drains the mono samples read since the last call, with their rate.
    pub fn take_visualizer(&self) -> Option<(Vec<u8>, u32)> {
        let mut a = self.visualizer.lock().ok()?;
        if a.samples.is_empty() {
            return None;
        }
        let bytes = core::mem::take(&mut a.samples).iter().flat_map(|s| s.to_le_bytes()).collect();
        Some((bytes, a.rate))
    }

    pub fn start(&self) {
        let _ = self.pipeline.set_state(gst::State::Playing);
    }

    pub fn stop(&self) {
        let _ = self.pipeline.set_state(gst::State::Null);
    }

    /// Feeds one decrypted RTP packet. False when the source no longer takes it.
    pub fn push_rtp(&self, rtp: &[u8]) -> bool {
        let packet = match self.codec {
            Codec::AacLc => reframe_aac(rtp, self.payload_type),
            Codec::Opus => rtp.to_vec(),
            // LPCM arrives without a header the pipeline needs
            Codec::Lpcm | Codec::PcmLe => rtp[RTP_HEADER_LEN.min(rtp.len())..].to_vec(),
        };
        self.appsrc.push_buffer(gst::Buffer::from_slice(packet)).is_ok()
    }

    /// Feeds samples the main process handed over, without an RTP header.
    pub fn push_samples(&self, samples: &[u8]) -> bool {
        self.appsrc.push_buffer(gst::Buffer::from_slice(samples.to_vec())).is_ok()
    }

    /// Sets the level at once, or glides to it over `ms` on the pipeline clock.
    pub fn set_volume(&self, level: f64, ms: u64) {
        let target = level.clamp(0.0, 10.0);
        let now = self.pipeline.current_running_time();

        if ms == 0 || now.is_none() {
            self.volume.set_control_binding_disabled("volume", true);
            self.volume.set_property("volume", target);
            return;
        }

        let now = now.unwrap();
        self.level.set(now, self.volume.property::<f64>("volume"));
        self.level.set(now + gst::ClockTime::from_mseconds(ms), target);
        self.volume.set_control_binding_disabled("volume", false);
    }
}

impl Drop for Player {
    fn drop(&mut self) {
        let _ = self.pipeline.set_state(gst::State::Null);
    }
}

/// Initialises GStreamer once for this process.
pub fn ensure_init() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        let _ = gst::init();
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg(codec: Codec, realtime: bool) -> Config {
        Config {
            codec,
            payload_type: 96,
            clock_rate: 44100,
            channels: 2,
            latency_ms: 1000,
            realtime,
            device: None,
            label: "music".into(),
        }
    }

    /// The elements in order, as the parser sees them.
    fn elements(desc: &str) -> Vec<String> {
        desc.split('!').map(|p| p.split_whitespace().next().unwrap_or("").to_string()).collect()
    }

    #[test]
    fn the_aac_chain_runs_from_appsrc_to_the_sink() {
        let desc = pipeline_desc(&cfg(Codec::AacLc, false));

        assert_eq!(
            elements(&desc),
            vec![
                "appsrc",
                "rtpjitterbuffer",
                "rtpmp4gdepay",
                "aacparse",
                if cfg!(target_os = "linux") { "faad" } else { "avdec_aac" },
                "audioconvert",
                "clocksync",
                "volume",
                "audioconvert",
                "audioresample",
                "audio/x-raw,format=S16LE,rate=48000,channels=2",
                "queue",
                audio_sink().0,
            ]
        );
    }

    #[test]
    fn the_sink_is_fed_the_same_way_on_both_systems() {
        // Only the element differs; the buffered stream gets its reserve and nothing below
        // clocksync paces a second time.
        let buffered = sink_chain(&cfg(Codec::AacLc, false));
        assert!(buffered.contains("sync=false"), "{buffered}");
        assert!(buffered.contains("buffer-time=300000"), "{buffered}");
        assert!(buffered.contains("latency-time=30000"), "{buffered}");
        let realtime = sink_chain(&cfg(Codec::Opus, true));
        assert!(realtime.contains("sync=false"), "{realtime}");
        assert!(!realtime.contains("buffer-time"), "{realtime}");
    }

    #[test]
    fn opus_depays_and_decodes_as_opus() {
        let desc = pipeline_desc(&cfg(Codec::Opus, false));
        let e = elements(&desc);

        assert!(e.contains(&"rtpopusdepay".to_string()));
        assert!(e.contains(&"opusdec".to_string()));
    }

    #[test]
    fn lpcm_goes_straight_from_the_source_to_the_converter() {
        let desc = pipeline_desc(&cfg(Codec::Lpcm, false));
        let e = elements(&desc);

        assert_eq!(e[0], "appsrc");
        assert_eq!(e[1], "audioconvert");
        assert!(!desc.contains("rtpjitterbuffer"));
        assert!(!desc.contains("depay"));
    }

    #[test]
    fn the_jitter_buffer_takes_the_negotiated_depth() {
        let desc = pipeline_desc(&cfg(Codec::AacLc, false));

        assert!(desc.contains("rtpjitterbuffer latency=1000"));
    }

    #[test]
    fn a_depth_below_the_floor_is_raised() {
        let mut c = cfg(Codec::Opus, false);
        c.latency_ms = 10;

        assert!(pipeline_desc(&c).contains("rtpjitterbuffer latency=100"));
    }

    #[cfg(not(target_os = "macos"))]
    #[test]
    fn a_music_sink_gets_the_ring_and_period_a_realtime_one_does_not() {
        assert!(pipeline_desc(&cfg(Codec::AacLc, false)).contains("buffer-time=300000"));
        assert!(!pipeline_desc(&cfg(Codec::AacLc, true)).contains("buffer-time"));
    }

    #[test]
    fn the_desc_never_carries_the_device_string() {
        let mut c = cfg(Codec::Opus, false);
        c.device = Some("AppleUSBAudioEngine:Unknown Manufacturer:USB PnP Audio Device:131200:1".into());

        let desc = pipeline_desc(&c);
        assert!(desc.contains(&format!("name={SINK_NAME}")), "desc = {desc}");
        assert!(!desc.contains("unique-id="), "desc = {desc}");
        assert!(!desc.contains(" device="), "desc = {desc}");
        assert!(!desc.contains("USB PnP"), "device string leaked into desc: {desc}");
    }

    #[test]
    fn every_link_carries_a_space_on_both_sides() {
        let desc = pipeline_desc(&cfg(Codec::AacLc, false));

        assert_eq!(desc.matches(" ! ").count(), desc.matches('!').count());
    }
}
