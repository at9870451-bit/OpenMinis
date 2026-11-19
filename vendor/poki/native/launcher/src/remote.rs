//! The RemotePairing network transport: TCP to the phone's remote pairing service, pair-verify with a
//! saved RPPairing file, a TLS-PSK CDTunnel, and the RSD handshake inside that tunnel.
//!
//! On the phone itself the address is the loopback 10.7.0.1 (Poki's packet tunnel or the user's proxy
//! app reflects it). This path needs no usbmuxd and no lockdown pairing record.

use idevice::{
    IdeviceError,
    remote_pairing::{
        RemotePairingClient, RpPairingFile, RpPairingSocket, RpPairingSocketProvider,
        connect_tls_psk_tunnel_native,
    },
    rsd::RsdHandshake,
    tcp::handle::AdapterHandle,
};
use std::{
    fmt,
    future::Future,
    net::{IpAddr, SocketAddr},
    path::Path,
    pin::Pin,
    sync::atomic::{AtomicBool, AtomicU16, Ordering},
    time::{Duration, Instant},
};
use tokio::{
    io::AsyncReadExt,
    net::TcpStream,
};

/// The port iOS serves `_remotepairing._tcp` on after a restart of the phone. It is not fixed: iOS
/// gives the service the next free port when it starts it, and names the port only in its Bonjour
/// record, so a phone that started the service again listens somewhere else and refuses 49152.
pub const REMOTE_PAIRING_PORT: u16 = 49152;
static PORT: AtomicU16 = AtomicU16::new(REMOTE_PAIRING_PORT);

/// The port every remote pairing connection of this process goes to.
pub fn port() -> u16 {
    PORT.load(Ordering::Relaxed)
}

/// The app found the phone's remote pairing port in Bonjour. 0 goes back to 49152.
pub fn set_port(port: u16) {
    PORT.store(if port == 0 { REMOTE_PAIRING_PORT } else { port }, Ordering::Relaxed);
}

/// Whether the app is looking for a moved remote pairing port in Bonjour. Only then does a refused
/// connection mean the port moved. Otherwise it keeps its earlier meaning: on cellular iOS refuses
/// the developer services' loopback itself (GitHub issue 35), and a mounted disk image goes to
/// Poki's own session. The app never searches on cellular alone, and stops after a few looks.
static SEARCHING: AtomicBool = AtomicBool::new(false);

pub fn searching() -> bool {
    SEARCHING.load(Ordering::Relaxed)
}

pub fn set_searching(on: bool) {
    SEARCHING.store(on, Ordering::Relaxed);
}
/// The optional plist key that records the host name used when the RPPairing file was made.
pub const SENDING_HOST_KEY: &str = "sending_host";
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);

pub type Control = RemotePairingClient<RpPairingSocket<TcpStream>>;

/// The step that failed. Pair-verify failures mean the RPPairing file is not accepted and must be
/// remade; every later step means the file is good and the tunnel itself failed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Stage {
    Connect,
    /// The address refused the port while the app looks for a moved one (`searching`): the
    /// loopback works, and the remote pairing service does not listen on this port.
    NotListening,
    Handshake,
    PairVerify,
    Listener,
    Tunnel,
    Rsd,
}

#[derive(Debug)]
pub struct RemoteError {
    pub stage: Stage,
    pub detail: String,
}

impl fmt::Display for RemoteError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let detail = &self.detail;
        match self.stage {
            Stage::Connect => write!(
                f,
                "remote pairing connect failed: cannot reach the phone's remote pairing service ({detail}). Is the loopback on (Poki's tunnel, or the 10.7.0.1 setting in your proxy app)?"
            ),
            Stage::NotListening => write!(
                f,
                "remote pairing connect failed: the loopback reached the phone, and nothing there listens on this port ({detail}). iOS moves its remote pairing service to another port when it starts the service again; Poki looks the port up in Bonjour and tries again by itself."
            ),
            Stage::Handshake => write!(
                f,
                "remote pairing handshake failed: the phone's remote pairing service did not answer ({detail})."
            ),
            Stage::PairVerify => write!(
                f,
                "pair-verify failed: the phone does not accept this RPPairing file ({detail}). Pair again in Poki's setup."
            ),
            Stage::Listener => write!(
                f,
                "tunnel failed after pair-verify: the phone refused to open a tunnel listener ({detail})."
            ),
            Stage::Tunnel => write!(
                f,
                "tunnel failed after pair-verify: the TLS-PSK CDTunnel did not come up ({detail})."
            ),
            Stage::Rsd => write!(
                f,
                "tunnel failed after pair-verify: the RSD handshake inside the tunnel failed ({detail})."
            ),
        }
    }
}

impl std::error::Error for RemoteError {}

fn fail(stage: Stage) -> impl FnOnce(IdeviceError) -> RemoteError {
    move |error| RemoteError {
        stage,
        detail: describe(&error),
    }
}

/// idevice's socket error reads only "device socket io failed"; the I/O error under it tells an
/// end of stream from a reset.
fn describe(error: &IdeviceError) -> String {
    match error {
        IdeviceError::Socket(io) => format!("{error}: {io}"),
        _ => error.to_string(),
    }
}

/// Reads an RPPairing file and the host name to send with it: the file's `sending_host` key, then
/// `override_name`, then this machine's host name. Pair-verify itself signs with the file's
/// `identifier`; the name only matters to requests that send `sendingHost`.
pub fn read_pairing_file(
    path: &Path,
    override_name: Option<&str>,
) -> Result<(RpPairingFile, String), String> {
    let bytes = std::fs::read(path)
        .map_err(|error| format!("Cannot read RPPairing file {}: {error}", path.display()))?;
    let file = RpPairingFile::from_bytes(&bytes).map_err(|error| {
        format!(
            "{} is not a valid RPPairing file ({error}). It needs public_key, private_key and identifier; pair again in Poki's setup.",
            path.display()
        )
    })?;
    let name = sending_host(&bytes)
        .or_else(|| override_name.map(String::from))
        .unwrap_or_else(|| "Poki".into());
    Ok((file, name))
}

pub fn sending_host(bytes: &[u8]) -> Option<String> {
    let dict: plist::Dictionary = plist::from_bytes(bytes).ok()?;
    dict.get(SENDING_HOST_KEY)
        .and_then(plist::Value::as_string)
        .filter(|name| !name.is_empty())
        .map(String::from)
}

async fn connect_tcp(addr: SocketAddr) -> Result<TcpStream, RemoteError> {
    match tokio::time::timeout(CONNECT_TIMEOUT, TcpStream::connect(addr)).await {
        Ok(Ok(stream)) => Ok(stream),
        Ok(Err(error)) => Err(RemoteError {
            stage: if error.kind() == std::io::ErrorKind::ConnectionRefused && searching() {
                Stage::NotListening
            } else {
                Stage::Connect
            },
            detail: format!("{addr}: {error}"),
        }),
        Err(_) => Err(RemoteError {
            stage: Stage::Connect,
            detail: format!("{addr}: no answer within {}s", CONNECT_TIMEOUT.as_secs()),
        }),
    }
}

/// A reachability diagnostic, not authentication: `handshake_ok` only means the
/// service answered the initial RPPairing handshake. No device identity is returned.
#[derive(Debug, serde::Serialize)]
pub struct HandshakeProbe {
    pub tcp_connected: bool,
    pub handshake_ok: bool,
    pub stage: &'static str,
    pub code: &'static str,
    pub detail: String,
    pub port: u16,
    pub elapsed_ms: u64,
    pub host: IpAddr,
}

/// The pinned RpPairingSocket decoder consumes, but does not check, the magic.
/// Check it for this diagnostic so an unrelated length-prefixed JSON service
/// cannot be reported as RPPairing. Decode without its raw-payload trace log;
/// the client still constructs the request and validates the handshake path.
#[derive(Debug)]
struct ProbeSocket(RpPairingSocket<TcpStream>);

impl RpPairingSocketProvider for ProbeSocket {
    fn send_plain(
        &mut self,
        value: impl serde::Serialize,
        seq: usize,
    ) -> Pin<Box<dyn Future<Output = Result<(), IdeviceError>> + Send + '_>> {
        self.0.send_plain(value, seq)
    }

    fn send_encrypted(
        &mut self,
        ciphertext: Vec<u8>,
        seq: usize,
    ) -> Pin<Box<dyn Future<Output = Result<(), IdeviceError>> + Send + '_>> {
        self.0.send_encrypted(ciphertext, seq)
    }

    fn recv_plain<'a>(
        &'a mut self,
    ) -> Pin<Box<dyn Future<Output = Result<plist::Value, IdeviceError>> + Send + 'a>> {
        Box::pin(async move {
            let mut header = [0u8; 11];
            self.0.inner.read_exact(&mut header).await?;
            if &header[..9] != b"RPPairing" {
                return Err(IdeviceError::UnexpectedResponse(
                    "invalid RPPairing frame magic".into(),
                ));
            }
            let length = u16::from_be_bytes([header[9], header[10]]) as usize;
            // A single frame is bounded by the protocol's u16 length (no raw
            // response escapes this scope, including on a parse failure).
            let mut frame = header.to_vec();
            frame.resize(header.len() + length, 0);
            self.0.inner.read_exact(&mut frame[header.len()..]).await?;
            // Do not replay through idevice's decoder: its trace log dumps the
            // raw reply and its plist conversion unwraps untrusted JSON. Keep
            // those bytes private and let attempt_pair_verify check the path.
            let value: serde_json::Value = serde_json::from_slice(&frame[header.len()..])?;
            let plain = value.get("message").and_then(|v| v.get("plain"))
                .and_then(|v| v.get("_0")).filter(|v| v.is_object())
                .ok_or_else(|| IdeviceError::UnexpectedResponse("missing plain envelope".into()))?;
            Ok(plist::to_value(plain)?)
        })
    }

    fn serialize_bytes(bytes: &[u8]) -> plist::Value {
        RpPairingSocket::<TcpStream>::serialize_bytes(bytes)
    }

    fn deserialize_bytes(value: plist::Value) -> Option<Vec<u8>> {
        RpPairingSocket::<TcpStream>::deserialize_bytes(value)
    }
}

/// Only I/O messages are allowed through: protocol errors can embed peer data.
fn probe_error(error: &IdeviceError) -> (&'static str, String) {
    match error {
        IdeviceError::Socket(io) => (
            "io",
            format!(
                "device socket io failed: {io} (kind={:?}, os_code={:?})",
                io.kind(),
                io.raw_os_error()
            ),
        ),
        IdeviceError::Json(_) => ("invalid_json", "invalid RPPairing JSON response".into()),
        IdeviceError::UnexpectedResponse(_) => (
            "invalid_response",
            "invalid RPPairing frame or missing handshake response".into(),
        ),
        _ => ("protocol", "RPPairing handshake protocol error".into()),
    }
}

/// Connects to an explicit port and sends only `attempt_pair_verify`'s initial
/// handshake, under ONE deadline (at most 6 seconds, including TCP connect).
/// This never reads pairing files, validates a pairing, opens a listener/TLS
/// tunnel, requests consent, or consults/mutates PORT/SEARCHING. Dropping the
/// deadline future drops the owned socket; no work is spawned or retried.
/// Network/protocol failures are Ok diagnostics; port zero is a caller error.
pub async fn probe_handshake(
    host: IpAddr,
    port: u16,
    timeout: Duration,
) -> Result<HandshakeProbe, RemoteError> {
    if port == 0 {
        return Err(RemoteError {
            stage: Stage::Connect,
            detail: "probe port must be 1..65535".into(),
        });
    }
    let started = Instant::now();
    let timeout = timeout.min(Duration::from_secs(6));
    let mut probe = HandshakeProbe {
        tcp_connected: false,
        handshake_ok: false,
        stage: "connect",
        code: "timeout",
        detail: String::new(),
        port,
        elapsed_ms: 0,
        host,
    };
    let work = async {
        let stream = TcpStream::connect(SocketAddr::new(host, port)).await?;
        probe.tcp_connected = true;
        probe.stage = "handshake";
        // Latency hint only; an unsupported socket option is not a handshake failure.
        let _ = stream.set_nodelay(true);
        let mut control =
            RemotePairingClient::new(ProbeSocket(RpPairingSocket::new(stream)), "Poki probe");
        let response = control.attempt_pair_verify().await?;
        // idevice checks response._1.handshake._0 exists; also reject a scalar
        // or empty body rather than treating arbitrary JSON as a handshake.
        let valid = response
            .as_dictionary()
            .and_then(|body| body.get("wireProtocolVersion"))
            .and_then(plist::Value::as_unsigned_integer)
            .is_some_and(|version| version > 0);
        if !valid {
            return Err(IdeviceError::UnexpectedResponse(
                "invalid handshake body".into(),
            ));
        }
        Ok::<(), IdeviceError>(())
    };
    match tokio::time::timeout(timeout, work).await {
        Ok(Ok(())) => {
            probe.handshake_ok = true;
            probe.stage = "ready";
            probe.code = "ok";
            probe.detail = "RPPairing handshake response received; pairing not verified".into();
        }
        Ok(Err(error)) => {
            let (code, detail) = probe_error(&error);
            probe.code = code;
            probe.detail = detail;
        }
        Err(_) => {
            probe.detail = format!(
                "{} timed out (one {} ms total deadline)",
                probe.stage,
                timeout.as_millis()
            )
        }
    }
    probe.elapsed_ms = started.elapsed().as_millis().min(u64::MAX as u128) as u64;
    // Keep machine-readable codes internally and in the public Rust diagnostic;
    // the signer's fixed seven-field JSON carries the code in detail as well.
    probe.detail = format!(
        "[{}] {}; after {} ms",
        probe.code, probe.detail, probe.elapsed_ms
    );
    Ok(probe)
}

/// Opens the tunnel and returns its TCP adapter, the RSD handshake and the remote pairing control
/// connection. Keep the control connection alive for as long as the tunnel is in use.
pub async fn connect(
    host: IpAddr,
    pairing_file: &mut RpPairingFile,
    sending_host: &str,
    trace: impl Fn(&str),
) -> Result<(AdapterHandle, RsdHandshake, Control), RemoteError> {
    let addr = SocketAddr::new(host, port());
    trace("remote pairing connect");
    let stream = connect_tcp(addr).await?;
    let mut control = RemotePairingClient::new(RpPairingSocket::new(stream), sending_host);
    trace("remote pairing handshake");
    let asked = Instant::now();
    control
        .attempt_pair_verify()
        .await
        .map_err(|error| RemoteError {
            stage: Stage::Handshake,
            // How long the other side held the connection before it ended tells the phone's own
            // refusal (at once) from a proxy app that gave up reaching the phone (its dial timeout).
            detail: format!("{}, after {:.1} s", describe(&error), asked.elapsed().as_secs_f64()),
        })?;
    trace("pair-verify");
    // No fallback to pair-setup: the bridge never prompts, and a rejected file needs a new pairing.
    control
        .validate_pairing(pairing_file)
        .await
        .map_err(fail(Stage::PairVerify))?;
    trace("tunnel listener");
    let port = control
        .create_tcp_listener()
        .await
        .map_err(fail(Stage::Listener))?;
    let tunnel_stream = connect_tcp(SocketAddr::new(host, port))
        .await
        .map_err(|error| RemoteError {
            stage: Stage::Tunnel,
            detail: error.detail,
        })?;
    trace("tls-psk tunnel");
    let tunnel = connect_tls_psk_tunnel_native(tunnel_stream, control.encryption_key())
        .await
        .map_err(fail(Stage::Tunnel))?;
    let parse = |value: &str| {
        value.parse::<IpAddr>().map_err(|error| RemoteError {
            stage: Stage::Tunnel,
            detail: format!("bad tunnel address {value}: {error}"),
        })
    };
    let client_ip = parse(&tunnel.info.client_address)?;
    let server_ip = parse(&tunnel.info.server_address)?;
    let mtu = tunnel.info.mtu as usize;
    let rsd_port = tunnel.info.server_rsd_port;
    let mut adapter =
        idevice::tcp::adapter::Adapter::new(Box::new(tunnel.into_inner()), client_ip, server_ip);
    adapter.set_mss(mtu.clamp(1280, 8192) - 60);
    let mut adapter = adapter.to_async_handle();
    trace("rsd handshake");
    let rsd_stream = adapter
        .connect(rsd_port)
        .await
        .map_err(|error| RemoteError {
            stage: Stage::Rsd,
            detail: error.to_string(),
        })?;
    let rsd = RsdHandshake::new(rsd_stream)
        .await
        .map_err(fail(Stage::Rsd))?;
    Ok((adapter, rsd, control))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};
    use tokio::{io::AsyncWriteExt, net::TcpListener};

    async fn probe_listener() -> TcpListener {
        let listener = TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0)).await.unwrap();
        // Never set/restore global PORT just to test an explicit probe port.
        if listener.local_addr().unwrap().port() == port() {
            TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0)).await.unwrap()
        } else {
            listener
        }
    }

    async fn read_probe_request(stream: &mut TcpStream) {
        let mut header = [0u8; 11];
        stream.read_exact(&mut header).await.unwrap();
        assert_eq!(&header[..9], b"RPPairing");
        let mut body = vec![0; u16::from_be_bytes([header[9], header[10]]) as usize];
        stream.read_exact(&mut body).await.unwrap();
        let request: Value = serde_json::from_slice(&body).unwrap();
        let handshake = &request["message"]["plain"]["_0"]["request"]["_0"]["handshake"]["_0"];
        assert_eq!(handshake["hostOptions"]["attemptPairVerify"], true);
        assert_eq!(handshake["wireProtocolVersion"], 19);
        assert_eq!(request["originatedBy"], "host");
        assert_eq!(request["sequenceNumber"], 0);
    }

    fn probe_frame(payload: &[u8]) -> Vec<u8> {
        let mut frame = b"RPPairing".to_vec();
        frame.extend_from_slice(&(u16::try_from(payload.len()).unwrap()).to_be_bytes());
        frame.extend_from_slice(payload);
        frame
    }

    fn probe_handshake_reply() -> Value {
        json!({
            "message": {"plain": {"_0": {"response": {
                "forRequestIdentifier": 0,
                "_1": {"handshake": {"_0": {
                    "wireProtocolVersion": 19,
                    "minimumSupportedWireProtocolVersion": 8,
                    "deviceOptions": {"allowsPairSetup": true},
                    "peerDeviceInfo": {"identifier": "MOCK_PRIVATE_DEVICE_ID", "name": "MOCK_PRIVATE_NAME"}
                }}}
            }}}},
            "originatedBy": "device",
            "sequenceNumber": 0
        })
    }

    async fn assert_probe_socket_closed(stream: &mut TcpStream) {
        let mut extra = [0];
        match stream.read(&mut extra).await {
            Ok(0) => {},
            // Rejected magic can leave an unread body, causing TCP RST on drop.
            Err(error) if error.kind() == std::io::ErrorKind::ConnectionReset => {},
            other => panic!("probe must close without pair-verify/consent/TLS bytes: {other:?}"),
        }
    }

    async fn probe_mock_reply(frame: Vec<u8>) -> HandshakeProbe {
        let listener = probe_listener().await;
        let addr = listener.local_addr().unwrap();
        let server = async {
            let (mut stream, _) = listener.accept().await.unwrap();
            read_probe_request(&mut stream).await;
            stream.write_all(&frame).await.unwrap();
            stream.shutdown().await.unwrap();
            // The probe must drop its socket, never send pair-verify/consent/TLS.
            assert_probe_socket_closed(&mut stream).await;
        };
        let client = probe_handshake(addr.ip(), addr.port(), Duration::from_secs(1));
        let (_, probe) = tokio::time::timeout(Duration::from_secs(2), async {
            tokio::join!(server, client)
        }).await.unwrap();
        probe.unwrap()
    }

    #[tokio::test]
    async fn probe_tcp_then_eof_is_not_a_handshake() {
        let listener = probe_listener().await;
        let addr = listener.local_addr().unwrap();
        let server = async {
            let (mut stream, _) = listener.accept().await.unwrap();
            read_probe_request(&mut stream).await;
            // Preserve a measurable early EOF, not an artificial timeout.
            tokio::time::sleep(Duration::from_millis(60)).await;
        };
        let client = probe_handshake(addr.ip(), addr.port(), Duration::from_secs(1));
        let (_, probe) = tokio::time::timeout(Duration::from_secs(2), async {
            tokio::join!(server, client)
        }).await.unwrap();
        let probe = probe.unwrap();
        assert!(probe.tcp_connected);
        assert!(!probe.handshake_ok);
        assert_eq!(probe.stage, "handshake");
        assert_eq!(probe.code, "io");
        assert!(probe.detail.contains("UnexpectedEof"), "{}", probe.detail);
        assert!(probe.detail.contains("after "));
        assert!((40..1500).contains(&probe.elapsed_ms), "{}", probe.elapsed_ms);
        assert_eq!(probe.port, addr.port());
    }

    #[tokio::test]
    async fn probe_valid_handshake_is_ready_without_real_pairing_or_global_writes() {
        // Read-only snapshots: no test calls set_port/set_searching, avoiding a
        // reset-to-default race with other tests running in parallel.
        let before_port = port();
        let before_searching = searching();
        let frame = probe_frame(&serde_json::to_vec(&probe_handshake_reply()).unwrap());
        let probe = probe_mock_reply(frame).await;
        assert!(probe.tcp_connected && probe.handshake_ok);
        assert_eq!(probe.stage, "ready");
        assert_eq!(probe.code, "ok");
        assert_ne!(probe.port, before_port);
        assert_eq!(port(), before_port);
        assert_eq!(searching(), before_searching);
        let output = serde_json::to_string(&probe).unwrap();
        assert!(!output.contains("MOCK_PRIVATE"));
        assert!(!output.contains("peerDeviceInfo"));
        assert!(probe.detail.contains("pairing not verified"));
    }

    #[tokio::test]
    async fn probe_rejects_non_handshake_json_and_redacts_payloads() {
        let mut scalar_body = probe_handshake_reply();
        scalar_body["message"]["plain"]["_0"]["response"]["_1"]["handshake"]["_0"] = json!("MOCK_PRIVATE_KEY");
        let mut empty_body = probe_handshake_reply();
        empty_body["message"]["plain"]["_0"]["response"]["_1"]["handshake"]["_0"] = json!({});
        let mut bad_magic = probe_frame(&serde_json::to_vec(&probe_handshake_reply()).unwrap());
        bad_magic[0] = b'X';
        let frames = [
            probe_frame(br#"{"ok":true,"identifier":"MOCK_PRIVATE_ID"}"#),
            probe_frame(&serde_json::to_vec(&scalar_body).unwrap()),
            probe_frame(&serde_json::to_vec(&empty_body).unwrap()),
            probe_frame(br#"{"invalid":MOCK_PRIVATE_KEY}"#),
            bad_magic,
        ];
        for frame in frames {
            let probe = probe_mock_reply(frame).await;
            assert!(probe.tcp_connected);
            assert!(!probe.handshake_ok);
            assert_eq!(probe.stage, "handshake");
            assert!(matches!(probe.code, "invalid_response" | "invalid_json"));
            let output = serde_json::to_string(&probe).unwrap();
            assert!(!output.contains("MOCK_PRIVATE"), "{output}");
        }
    }

    #[tokio::test]
    async fn probe_silent_or_partial_handshake_times_out_and_closes_socket() {
        for partial in [&b""[..], &b"RPP"[..], &b"RPPairing\x00\x20{"[..]] {
            let listener = probe_listener().await;
            let addr = listener.local_addr().unwrap();
            let server = async {
                let (mut stream, _) = listener.accept().await.unwrap();
                read_probe_request(&mut stream).await;
                stream.write_all(partial).await.unwrap();
                let mut extra = [0];
                assert_eq!(stream.read(&mut extra).await.unwrap(), 0, "deadline must close the socket");
            };
            let client = probe_handshake(addr.ip(), addr.port(), Duration::from_millis(120));
            let (_, probe) = tokio::time::timeout(Duration::from_secs(2), async {
                tokio::join!(server, client)
            }).await.unwrap();
            let probe = probe.unwrap();
            assert!(probe.tcp_connected);
            assert!(!probe.handshake_ok);
            assert_eq!(probe.stage, "handshake");
            assert_eq!(probe.code, "timeout");
            assert!((100..1500).contains(&probe.elapsed_ms), "{}", probe.elapsed_ms);
            assert!(probe.detail.contains("one 120 ms total deadline"));
        }
    }

    #[tokio::test]
    async fn probe_connection_refused_is_a_connect_diagnostic() {
        // macOS can silently hold a bound-but-not-listening socket instead of
        // replying with RST. Close a temporary listener to create a refused port.
        let listener = probe_listener().await;
        let addr = listener.local_addr().unwrap();
        drop(listener);
        let probe = probe_handshake(addr.ip(), addr.port(), Duration::from_secs(1)).await.unwrap();
        assert!(!probe.tcp_connected && !probe.handshake_ok);
        assert_eq!(probe.stage, "connect");
        assert_eq!(probe.code, "io");
        assert!(probe.detail.contains("ConnectionRefused"), "{}", probe.detail);
        assert_eq!(probe.port, addr.port());
    }

    #[tokio::test]
    async fn probe_port_zero_is_a_caller_error() {
        let error = probe_handshake(std::net::Ipv4Addr::LOCALHOST.into(), 0, Duration::from_secs(1)).await.unwrap_err();
        assert_eq!(error.stage, Stage::Connect);
    }

    #[test]
    fn pair_verify_and_tunnel_failures_read_differently() {
        let message = |stage| {
            RemoteError {
                stage,
                detail: "x".into(),
            }
            .to_string()
        };
        assert!(message(Stage::PairVerify).starts_with("pair-verify failed:"));
        for stage in [Stage::Listener, Stage::Tunnel, Stage::Rsd] {
            assert!(message(stage).starts_with("tunnel failed after pair-verify:"));
        }
        assert!(message(Stage::Connect).starts_with("remote pairing connect failed:"));
        assert!(message(Stage::Handshake).starts_with("remote pairing handshake failed:"));
    }

    #[test]
    fn sending_host_comes_from_the_file_when_present() {
        let mut file = RpPairingFile::generate("pairing-mac").to_bytes();
        assert_eq!(sending_host(&file), None);
        let mut dict: plist::Dictionary = plist::from_bytes(&file).unwrap();
        dict.insert(SENDING_HOST_KEY.into(), "pairing-mac".into());
        file.clear();
        plist::to_writer_xml(&mut file, &dict).unwrap();
        assert_eq!(sending_host(&file).as_deref(), Some("pairing-mac"));

        let path = std::env::temp_dir().join(format!("poki-rp-{}.plist", std::process::id()));
        std::fs::write(&path, &file).unwrap();
        let (_, name) = read_pairing_file(&path, Some("flag-name")).unwrap();
        assert_eq!(name, "pairing-mac");
        std::fs::write(&path, RpPairingFile::generate("h").to_bytes()).unwrap();
        let (_, name) = read_pairing_file(&path, Some("flag-name")).unwrap();
        assert_eq!(name, "flag-name");
        std::fs::write(&path, b"not a plist").unwrap();
        assert!(read_pairing_file(&path, None).is_err());
        std::fs::remove_file(&path).unwrap();
    }
}
