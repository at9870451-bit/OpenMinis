//! One error type for the whole core. Every variant carries words a person can act on; the shell
//! shows `to_string()` as is, so the text says what happened and what to do next.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("{0}")]
    ReleaseUnavailable(&'static str),
    #[error("{0}")]
    UpdateCheck(&'static str),
    /// A plain sentence for the person.
    #[error("{0}")]
    Message(String),
    /// The phone or usbmuxd said no.
    #[error("{0}")]
    Device(String),
    /// Apple's servers said no (GSA or the developer portal), with Apple's code when it gave one.
    #[error("{message}")]
    Apple { code: i64, message: String },
    /// The person has to act (Trust This Computer, a 2FA code, a passcode) before this can go on.
    #[error("{0}")]
    NeedsPerson(String),
    /// Could not read or unlock the OS keychain (access denied or locked).
    #[error("{0}")]
    Keychain(String),
    /// Apple asked for a 2FA code while renewing an existing session with the saved password.
    #[error("Apple sent a verification code. Enter the 6-digit code to continue.")]
    NeedsCode(Box<crate::apple::gsa::Pending>),
    #[error("signing failed: {0}")]
    Sign(String),
    /// The team is at Apple's certificate limit. Replacing a certificate stops every app it signed
    /// from opening, so only the person decides: they approve it ([`crate::apple::identity::approve_replacement`])
    /// and try again.
    #[error("{0}")]
    CertificateLimit(String),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error("network: {0}")]
    Http(#[from] reqwest::Error),
    #[error("property list: {0}")]
    Plist(#[from] plist::Error),
    #[error("JSON: {0}")]
    Json(#[from] serde_json::Error),
}

pub type Result<T> = std::result::Result<T, Error>;

impl Error {
    pub fn msg(text: impl Into<String>) -> Self {
        Error::Message(text.into())
    }
    pub fn device(text: impl Into<String>) -> Self {
        Error::Device(text.into())
    }
    pub fn apple(code: i64, message: impl Into<String>) -> Self {
        Error::Apple { code, message: message.into() }
    }
    /// A short machine-readable kind for the UI to branch on.
    pub fn kind(&self) -> &'static str {
        match self {
            Error::Message(_) => "message",
            Error::ReleaseUnavailable(_) => "release_unavailable",
            Error::UpdateCheck(_) => "update_preflight",
            Error::Device(_) => "device",
            Error::Apple { .. } => "apple",
            Error::NeedsPerson(_) => "needs_person",
            Error::Keychain(_) => "keychain",
            Error::NeedsCode(_) => "needs_code",
            Error::Sign(_) => "sign",
            Error::CertificateLimit(_) => "certificate_limit",
            Error::Io(_) => "io",
            Error::Http(_) => "http",
            Error::Plist(_) => "plist",
            Error::Json(_) => "json",
        }
    }
}

#[cfg(feature = "device")]
impl From<idevice::IdeviceError> for Error {
    fn from(e: idevice::IdeviceError) -> Self {
        use idevice::IdeviceError as E;
        match e {
            E::PairingDialogResponsePending => Error::NeedsPerson("Tap Trust on the iPhone, then enter its passcode.".into()),
            E::UserDeniedPairing => Error::NeedsPerson("The iPhone said Don't Trust. Unplug it, plug it in again and tap Trust.".into()),
            E::PasswordProtected | E::DeviceLocked => Error::NeedsPerson("Unlock the iPhone and try again.".into()),
            E::DeviceNotFound => Error::Device("The iPhone is no longer connected.".into()),
            E::InvalidHostID => Error::Device("This computer is not paired with the iPhone any more. Pair it again.".into()),
            E::Usbmuxd(_) => Error::Device(usbmuxd_missing()),
            E::Socket(ref io) if matches!(io.kind(), std::io::ErrorKind::NotFound | std::io::ErrorKind::ConnectionRefused | std::io::ErrorKind::PermissionDenied) => Error::Device(usbmuxd_missing()),
            other => Error::Device(other.to_string()),
        }
    }
}

#[cfg(feature = "device")]
fn usbmuxd_missing() -> String {
    if cfg!(target_os = "windows") {
        "Poki Setup cannot reach the iPhone service. Install Apple Devices from the Microsoft Store (or iTunes from apple.com), then plug the iPhone in again.".into()
    } else if cfg!(target_os = "macos") {
        "Poki Setup cannot reach usbmuxd, which macOS starts when an iPhone is plugged in. Plug the iPhone in with a data cable and unlock it.".into()
    } else {
        "Poki Setup cannot reach usbmuxd. Install and start usbmuxd, then plug the iPhone in.".into()
    }
}
