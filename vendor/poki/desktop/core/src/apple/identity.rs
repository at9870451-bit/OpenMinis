//! The signing identity: an RSA-2048 key this computer makes and keeps, and the development
//! certificate Apple issues for it. The private key never leaves this computer.
use super::portal::{Certificate, Portal};
use crate::{Error, Result, paths};
use rsa::pkcs8::{DecodePrivateKey, EncodePrivateKey, EncodePublicKey};
use rsa::RsaPrivateKey;
use serde::{Deserialize, Serialize};

/// A key and the matching certificate, both DER.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Identity {
    pub team_id: String,
    pub certificate: Certificate,
    #[serde(skip)]
    pub key_pkcs8: Vec<u8>,
}

fn key_path(team: &str) -> Result<std::path::PathBuf> { Ok(paths::keys_dir()?.join(format!("{team}.p8"))) }

/// The key for a team: read from disk, or made and saved.
pub fn key_for(team: &str) -> Result<(Vec<u8>, bool)> {
    if let Some(v) = crate::vault::installed() {
        let name = format!("key-{team}");
        if let Some(pem) = v.get(&name)? {
            if let Ok(k) = RsaPrivateKey::from_pkcs8_pem(&String::from_utf8_lossy(&pem)) {
                return Ok((k.to_pkcs8_der().map_err(|e| Error::msg(e.to_string()))?.as_bytes().to_vec(), false));
            }
        }
        let mut rng = rand::thread_rng();
        let key = RsaPrivateKey::new(&mut rng, 2048).map_err(|e| Error::msg(format!("could not make a key: {e}")))?;
        let pem = key.to_pkcs8_pem(rsa::pkcs8::LineEnding::LF).map_err(|e| Error::msg(e.to_string()))?;
        v.set(&name, pem.as_bytes())?;
        return Ok((key.to_pkcs8_der().map_err(|e| Error::msg(e.to_string()))?.as_bytes().to_vec(), true));
    }
    let path = key_path(team)?;
    if let Ok(pem) = std::fs::read_to_string(&path) {
        if let Ok(k) = RsaPrivateKey::from_pkcs8_pem(&pem) {
            return Ok((k.to_pkcs8_der().map_err(|e| Error::msg(e.to_string()))?.as_bytes().to_vec(), false));
        }
    }
    let mut rng = rand::thread_rng();
    let key = RsaPrivateKey::new(&mut rng, 2048).map_err(|e| Error::msg(format!("could not make a key: {e}")))?;
    let pem = key.to_pkcs8_pem(rsa::pkcs8::LineEnding::LF).map_err(|e| Error::msg(e.to_string()))?;
    write_private(&path, pem.as_bytes())?;
    Ok((key.to_pkcs8_der().map_err(|e| Error::msg(e.to_string()))?.as_bytes().to_vec(), true))
}

/// Takes a team key another app made (Poki Setup hands its key to Poki on the iPhone), so both
/// sign with the one development certificate a free team allows. Replaces any key kept for the team.
pub fn import_key(team: &str, key_pkcs8_pem: &str) -> Result<()> {
    let key = RsaPrivateKey::from_pkcs8_pem(key_pkcs8_pem.trim()).map_err(|e| Error::msg(format!("the signing key is not a PKCS#8 RSA key: {e}")))?;
    let pem = key.to_pkcs8_pem(rsa::pkcs8::LineEnding::LF).map_err(|e| Error::msg(e.to_string()))?;
    match crate::vault::installed() {
        Some(v) => v.set(&format!("key-{team}"), pem.as_bytes()),
        None => write_private(&key_path(team)?, pem.as_bytes()),
    }
}

/// Whether a key is kept for the team.
pub fn has_key(team: &str) -> Result<bool> {
    match crate::vault::installed() {
        Some(v) => Ok(v.get(&format!("key-{team}"))?.is_some()),
        None => Ok(key_path(team)?.is_file()),
    }
}

/// Reuses the exact installed certificate without creating keys or replacing certificates.
#[cfg(feature = "device")]
pub(crate) async fn existing_for_update(portal: &mut Portal<'_>, team: &str, fingerprint: &str) -> Result<Identity> {
    let certificate = update_certificate(portal, team, fingerprint).await?;
    let pem = match crate::vault::installed() {
        Some(v) => v.get(&format!("key-{team}"))?.ok_or_else(|| Error::msg("The original signing key is unavailable; use the original signing computer."))?,
        None => std::fs::read(key_path(team)?).map_err(|_| Error::msg("The original signing key is unavailable; use the original signing computer."))?,
    };
    let key = RsaPrivateKey::from_pkcs8_pem(&String::from_utf8_lossy(&pem)).map_err(|_| Error::msg("The saved signing identity is unusable; use the original signing computer."))?;
    let key_pkcs8 = key.to_pkcs8_der().map_err(|e| Error::msg(e.to_string()))?.as_bytes().to_vec();
    if !certificate_matches(&key_pkcs8, &certificate.der) {
        return Err(Error::msg("The saved signing key does not match the original certificate; use the original signing computer."));
    }
    Ok(Identity { team_id: team.into(), certificate, key_pkcs8 })
}

#[cfg(feature = "device")]
pub(crate) async fn update_certificate(portal: &mut Portal<'_>, team: &str, fingerprint: &str) -> Result<Certificate> {
    select_update_certificate(portal.certificates(team).await?, fingerprint)
}

#[cfg(feature = "device")]
fn select_update_certificate(certificates: Vec<Certificate>, fingerprint: &str) -> Result<Certificate> {
    use sha2::{Digest, Sha256};
    certificates.into_iter().find(|c| hex::encode(Sha256::digest(&c.der)) == fingerprint && days_left(&c.der).unwrap_or(-1) > 1)
        .ok_or_else(|| Error::UpdateCheck("The original signing certificate is unavailable or expiring; keep Poki installed and renew it with its original signing identity."))
}

/// A throwaway identity with a self-signed "Apple Development" certificate, for checking the
/// signing pipeline without an Apple Account (`poki-setup selftest-sign`). iOS won't trust it.
pub fn self_signed(team: &str) -> Result<Identity> {
    let mut rng = rand::thread_rng();
    let key = RsaPrivateKey::new(&mut rng, 2048).map_err(|e| Error::msg(format!("could not make a key: {e}")))?;
    let der = key.to_pkcs8_der().map_err(|e| Error::msg(e.to_string()))?.as_bytes().to_vec();
    let kp = rcgen_key(&der)?;
    let mut params = rcgen::CertificateParams::new(Vec::<String>::new()).map_err(|e| Error::msg(e.to_string()))?;
    let mut dn = rcgen::DistinguishedName::new();
    dn.push(rcgen::DnType::CommonName, format!("Apple Development: Poki Setup Self-Test ({team})"));
    dn.push(rcgen::DnType::OrganizationalUnitName, team);
    dn.push(rcgen::DnType::OrganizationName, "Poki Setup Self-Test");
    dn.push(rcgen::DnType::CountryName, "US");
    params.distinguished_name = dn;
    params.extended_key_usages = vec![rcgen::ExtendedKeyUsagePurpose::CodeSigning];
    // As Apple's development certificates: codesign rejects a leaf without digitalSignature.
    params.key_usages = vec![rcgen::KeyUsagePurpose::DigitalSignature];
    params.is_ca = rcgen::IsCa::ExplicitNoCa;
    let cert = params.self_signed(&kp).map_err(|e| Error::msg(e.to_string()))?;
    Ok(Identity {
        team_id: team.to_string(),
        certificate: crate::apple::portal::Certificate { certificate_id: "selftest".into(), serial_number: "01".into(), name: "Poki Setup Self-Test".into(), machine_name: "selftest".into(), der: cert.der().to_vec() },
        key_pkcs8: der,
    })
}

fn write_private(path: &std::path::Path, bytes: &[u8]) -> Result<()> {
    std::fs::write(path, bytes)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    }
    Ok(())
}

/// The SubjectPublicKeyInfo of a key, to match Apple's certificate to it.
pub fn spki_of_key(pkcs8: &[u8]) -> Result<Vec<u8>> {
    let key = RsaPrivateKey::from_pkcs8_der(pkcs8).map_err(|e| Error::msg(e.to_string()))?;
    Ok(key.to_public_key().to_public_key_der().map_err(|e| Error::msg(e.to_string()))?.as_bytes().to_vec())
}

pub fn spki_of_cert(der: &[u8]) -> Option<Vec<u8>> {
    use der::{Decode, Encode};
    let cert = x509_cert::Certificate::from_der(der).ok()?;
    cert.tbs_certificate.subject_public_key_info.to_der().ok()
}

/// Whether a certificate carries this key. Compares the public key info, and falls back to finding
/// the key's modulus in the certificate's bytes, so a certificate the X.509 parser rejects still
/// matches.
pub fn certificate_matches(key_pkcs8: &[u8], cert_der: &[u8]) -> bool {
    if cert_der.is_empty() {
        return false;
    }
    if let (Ok(a), Some(b)) = (spki_of_key(key_pkcs8), spki_of_cert(cert_der)) {
        if a == b {
            return true;
        }
    }
    use rsa::traits::PublicKeyParts;
    match RsaPrivateKey::from_pkcs8_der(key_pkcs8) {
        Ok(k) => {
            let n = k.n().to_bytes_be();
            n.len() >= 128 && cert_der.windows(n.len()).any(|w| w == n.as_slice())
        }
        Err(_) => false,
    }
}

/// For support: what Apple lists for the team, and whether each certificate matches this
/// computer's key.
pub async fn diagnose(portal: &mut Portal<'_>, team: &str) -> Result<Vec<String>> {
    let (key, fresh) = key_for(team)?;
    let mut out = vec![format!("team {team}; this computer's key {}", if fresh { "was just made (none was saved)" } else { "is saved" })];
    out.extend(portal.certificates_raw(team).await?);
    for c in portal.certificates(team).await? {
        out.push(format!(
            "cert id={} serial={} machine={:?} name={:?} bytes={} parses={} matches_key={} days_left={:?}",
            c.certificate_id, c.serial_number, c.machine_name, c.name, c.der.len(), spki_of_cert(&c.der).is_some(), certificate_matches(&key, &c.der), days_left(&c.der)
        ));
    }
    Ok(out)
}

fn same_serial(a: &str, b: &str) -> bool {
    let norm = |s: &str| s.trim().trim_start_matches('0').to_ascii_uppercase();
    !a.trim().is_empty() && norm(a) == norm(b)
}

/// Days until the certificate expires, negative if it has.
pub fn days_left(cert_der: &[u8]) -> Option<i64> {
    use der::Decode;
    let cert = x509_cert::Certificate::from_der(cert_der).ok()?;
    let not_after = cert.tbs_certificate.validity.not_after.to_unix_duration().as_secs() as i64;
    Some((not_after - time::OffsetDateTime::now_utc().unix_timestamp()) / 86_400)
}

pub fn csr_pem(key_pkcs8: &[u8], common_name: &str) -> Result<String> {
    let key_pair = rcgen_key(key_pkcs8)?;
    let mut params = rcgen::CertificateParams::new(Vec::<String>::new()).map_err(|e| Error::msg(e.to_string()))?;
    let mut dn = rcgen::DistinguishedName::new();
    dn.push(rcgen::DnType::CommonName, common_name);
    dn.push(rcgen::DnType::CountryName, "US");
    params.distinguished_name = dn;
    let csr = params.serialize_request(&key_pair).map_err(|e| Error::msg(format!("CSR: {e}")))?;
    csr.pem().map_err(|e| Error::msg(e.to_string()))
}

/// The certificate Poki Setup would replace when the team is at Apple's limit: one made by Poki
/// Setup or Poki, the soonest to expire first.
fn replacement_candidate(certs: &[Certificate]) -> Option<&Certificate> {
    certs
        .iter()
        .filter(|c| c.machine_name.starts_with("Poki Setup") || c.machine_name.starts_with("Poki on") || c.name.contains("Poki"))
        .min_by_key(|c| days_left(&c.der).unwrap_or(i64::MIN))
}

/// A replacement the person was asked about, and whether they said yes. One file per team.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
struct Replacement {
    serial: String,
    #[serde(default)]
    approved: bool,
}

fn replacement_path(team: &str) -> Result<std::path::PathBuf> { Ok(paths::state_dir()?.join(format!("certificate-replacement-{team}.json"))) }

fn replacement(team: &str) -> Option<Replacement> { std::fs::read(replacement_path(team).ok()?).ok().and_then(|b| serde_json::from_slice(&b).ok()) }

fn set_replacement(team: &str, r: Option<&Replacement>) -> Result<()> {
    let path = replacement_path(team)?;
    match r {
        Some(r) => std::fs::write(path, serde_json::to_vec(r)?)?,
        None => {
            let _ = std::fs::remove_file(path);
        }
    }
    Ok(())
}

/// The person agreed to replace the certificate Poki Setup last asked about (on every team it
/// asked for). The next install or renewal revokes exactly that certificate, and only that one.
/// Returns how many it approved; 0 means nothing was waiting.
pub fn approve_replacement() -> Result<usize> {
    let mut n = 0;
    for entry in std::fs::read_dir(paths::state_dir()?)? {
        let path = entry?.path();
        let Some(team) = path.file_name().and_then(|f| f.to_str()).and_then(|f| f.strip_prefix("certificate-replacement-")).and_then(|f| f.strip_suffix(".json")) else { continue };
        if let Some(mut r) = replacement(team) {
            r.approved = true;
            set_replacement(team, Some(&r))?;
            n += 1;
        }
    }
    Ok(n)
}

/// What to tell the person when the team is at its limit and `old` would be replaced.
fn limit_message(old: &Certificate) -> String {
    let made_by = if old.machine_name.trim().is_empty() { String::new() } else { format!(" made by “{}”", old.machine_name.trim()) };
    let ends = match days_left(&old.der) {
        Some(d) if d < 0 => "it has already expired".to_string(),
        Some(0) => "it expires today".to_string(),
        Some(1) => "it expires tomorrow".to_string(),
        Some(d) => format!("it expires in {d} days"),
        None => "its end date could not be read".to_string(),
    };
    format!(
        "Your Apple Account already has its development certificate: “{}”{made_by}, serial {}; {ends}. Poki Setup on this computer cannot use it, because its key is on the computer or app that made it. Replacing it lets this computer sign Poki, but every app that certificate signed stops opening, on every iPhone and iPad, until it is installed again from here. If another computer still signs Poki for you, sign with that one instead. Choose Replace Certificate to go ahead.",
        old.name.trim(),
        old.serial_number.trim()
    )
}

/// A certificate on the team that matches this computer's key, or a new one. When Apple's limit
/// is in the way, nothing is revoked unless the person approved replacing that exact certificate
/// (see [`approve_replacement`]); otherwise this stops with [`Error::CertificateLimit`].
pub async fn ensure(portal: &mut Portal<'_>, team: &str, reporter: &crate::Reporter) -> Result<Identity> {
    let (key, fresh) = key_for(team)?;
    let certs = portal.certificates(team).await?;
    if !fresh {
        if let Some(c) = certs.iter().find(|c| certificate_matches(&key, &c.der) && days_left(&c.der).unwrap_or(-1) > 1) {
            set_replacement(team, None)?;
            return Ok(Identity { team_id: team.into(), certificate: c.clone(), key_pkcs8: key });
        }
    }
    reporter.note("identity", "Asking Apple for a signing certificate for this computer");
    let machine_id = machine_id()?;
    let machine_name = if crate::vault::installed().is_some() { format!("Poki on {}", hostname()) } else { format!("Poki Setup on {}", hostname()) };
    let csr = csr_pem(&key, "Poki Setup")?;
    let submitted = match portal.submit_csr(team, &csr, &machine_id, &machine_name).await {
        Ok(c) => {
            set_replacement(team, None)?;
            c
        }
        Err(Error::Apple { code, .. }) if code == 3250 || code == 7250 || code == 9100 => {
            let Some(old) = replacement_candidate(&certs) else {
                return Err(Error::apple(code, "This team already has its development certificate, made by another computer or app. Revoke it at developer.apple.com (Certificates) or in that app, then try again."));
            };
            let approved = replacement(team).map(|r| r.approved && same_serial(&r.serial, &old.serial_number)).unwrap_or(false);
            if !approved {
                // Remember which certificate the person is asked about, so a yes covers only it.
                set_replacement(team, Some(&Replacement { serial: old.serial_number.clone(), approved: false }))?;
                return Err(Error::CertificateLimit(limit_message(old)));
            }
            set_replacement(team, None)?;
            reporter.note("identity", format!("Replacing the certificate “{}” (serial {}), as you chose", old.name.trim(), old.serial_number.trim()));
            tracing::warn!(serial = %old.serial_number, machine = %old.machine_name, "revoking a certificate the person approved replacing");
            portal.revoke_certificate(team, &old.serial_number).await?;
            portal.submit_csr(team, &csr, &machine_id, &machine_name).await?
        }
        Err(e) => return Err(e),
    };
    if certificate_matches(&key, &submitted.der) {
        return Ok(Identity { team_id: team.into(), certificate: submitted, key_pkcs8: key });
    }
    // Apple can take a little while to list the new certificate. Find it by its id or serial
    // number (it was made from this computer's key), or by the key itself.
    let mut last: Vec<Certificate> = Vec::new();
    for attempt in 0..20 {
        if attempt > 0 {
            tokio::time::sleep(std::time::Duration::from_secs(3)).await;
        }
        let certs = portal.certificates(team).await?;
        let found = certs.iter().find(|c| certificate_matches(&key, &c.der)).or_else(|| {
            certs.iter().find(|c| {
                !c.der.is_empty()
                    && ((!submitted.certificate_id.is_empty() && c.certificate_id == submitted.certificate_id) || same_serial(&submitted.serial_number, &c.serial_number))
            })
        });
        if let Some(c) = found {
            return Ok(Identity { team_id: team.into(), certificate: c.clone(), key_pkcs8: key });
        }
        last = certs;
    }
    for c in &last {
        tracing::warn!(id = %c.certificate_id, serial = %c.serial_number, machine = %c.machine_name, bytes = c.der.len(), parses = spki_of_cert(&c.der).is_some(), "certificate on the team");
    }
    tracing::warn!(id = %submitted.certificate_id, serial = %submitted.serial_number, "the requested certificate was not found");
    if let Ok(lines) = portal.certificates_raw(team).await {
        for l in lines {
            tracing::warn!("listed: {l}");
        }
    }
    Err(Error::msg("Apple accepted the certificate request but has not listed the certificate yet. Try again in a minute; if it keeps happening, save a Support Bundle from Diagnostics."))
}

fn rcgen_key(key_pkcs8: &[u8]) -> Result<rcgen::KeyPair> {
    let pem = RsaPrivateKey::from_pkcs8_der(key_pkcs8).map_err(|e| Error::msg(e.to_string()))?.to_pkcs8_pem(rsa::pkcs8::LineEnding::LF).map_err(|e| Error::msg(e.to_string()))?;
    rcgen::KeyPair::from_pem_and_sign_algo(&pem, &rcgen::PKCS_RSA_SHA256).map_err(|e| Error::msg(format!("CSR key: {e}")))
}

fn machine_id() -> Result<String> {
    let path = paths::state_dir()?.join("machine-id");
    if let Ok(s) = std::fs::read_to_string(&path) {
        if s.trim().len() == 36 {
            return Ok(s.trim().to_string());
        }
    }
    let id = uuid::Uuid::new_v4().to_string().to_uppercase();
    std::fs::write(&path, &id)?;
    Ok(id)
}

pub fn hostname() -> String {
    if let Ok(name) = std::env::var("POKI_DEVICE_NAME") {
        if !name.trim().is_empty() {
            return name;
        }
    }
    #[cfg(target_os = "macos")]
    if let Ok(o) = std::process::Command::new("/usr/sbin/scutil").args(["--get", "ComputerName"]).output() {
        let name = String::from_utf8_lossy(&o.stdout).trim().to_string();
        if o.status.success() && !name.is_empty() {
            return name;
        }
    }
    std::env::var("COMPUTERNAME").ok().or_else(|| std::env::var("HOSTNAME").ok()).or_else(|| std::fs::read_to_string("/etc/hostname").ok().map(|s| s.trim().to_string())).filter(|s| !s.is_empty()).unwrap_or_else(|| "this computer".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn key_csr_and_match() {
        let (_lock, _dir) = crate::paths::test_home();
        let (key, fresh) = key_for("TESTTEAM").unwrap();
        assert!(fresh);
        let (again, fresh2) = key_for("TESTTEAM").unwrap();
        assert!(!fresh2);
        assert_eq!(key, again);
        let pem = csr_pem(&key, "Poki Setup").unwrap();
        assert!(pem.contains("BEGIN CERTIFICATE REQUEST"));
        // A self-signed cert from the same key matches; another key's does not.
        let kp = rcgen_key(&key).unwrap();
        let cert = rcgen::CertificateParams::new(Vec::<String>::new()).unwrap().self_signed(&kp).unwrap();
        assert!(certificate_matches(&key, cert.der()));
        assert!(days_left(cert.der()).unwrap() > 300);
        let (other, _) = key_for("OTHER").unwrap();
        assert!(!certificate_matches(&other, cert.der()));
    }
}

#[cfg(test)]
mod replacement_tests {
    use super::*;

    fn cert(serial: &str, machine: &str, name: &str) -> Certificate {
        Certificate { certificate_id: serial.into(), serial_number: serial.into(), name: name.into(), machine_name: machine.into(), der: vec![] }
    }

    #[test]
    fn only_poki_certificates_are_candidates() {
        assert!(replacement_candidate(&[cert("1", "Xcode on Mac", "Apple Development: Jane")]).is_none());
        let list = [cert("1", "Xcode on Mac", "Apple Development: Jane"), cert("2", "Poki Setup on Mac", "Apple Development: Jane")];
        assert_eq!(replacement_candidate(&list).unwrap().serial_number, "2");
        assert_eq!(replacement_candidate(&[cert("3", "Poki on iPhone", "x")]).unwrap().serial_number, "3");
    }

    #[test]
    fn a_yes_covers_only_the_certificate_asked_about() {
        let (_g, _d) = paths::test_home();
        set_replacement("T1", Some(&Replacement { serial: "0ABC".into(), approved: false })).unwrap();
        assert!(!replacement("T1").unwrap().approved);
        assert_eq!(approve_replacement().unwrap(), 1);
        let r = replacement("T1").unwrap();
        assert!(r.approved && same_serial(&r.serial, "ABC") && !same_serial(&r.serial, "ABD"));
        set_replacement("T1", None).unwrap();
        assert!(replacement("T1").is_none());
        assert_eq!(approve_replacement().unwrap(), 0);
    }

    #[test]
    fn the_question_names_the_certificate_and_what_stops() {
        let m = limit_message(&cert("5F00", "Poki Setup on Old Mac", "Apple Development: Jane"));
        assert!(m.contains("Poki Setup on Old Mac") && m.contains("5F00") && m.contains("stops opening") && m.contains("Replace Certificate"));
    }
}

#[cfg(all(test, feature = "device"))]
mod update_tests {
    #[test]
    fn update_certificate_requires_the_installed_certificate() {
        use sha2::{Digest, Sha256};
        let identity = super::self_signed("TESTTEAM").unwrap();
        let fingerprint = hex::encode(Sha256::digest(&identity.certificate.der));
        assert!(super::select_update_certificate(vec![identity.certificate.clone()], &fingerprint).is_ok());
        assert!(super::select_update_certificate(vec![identity.certificate], &"0".repeat(64)).is_err());
        assert!(super::select_update_certificate(vec![], &fingerprint).is_err());
    }
}
