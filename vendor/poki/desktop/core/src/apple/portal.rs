//! The developer portal as Xcode uses it (developerservices2, protocol QH65B2). Request shapes
//! follow Sideloader's developersession.d (GPL-3.0) and AltSign (AGPL-3.0).
use super::gsa::{AppToken, Session};
use crate::{Error, Result};
use serde::{Deserialize, Serialize};

const BASE: &str = "https://developerservices2.apple.com/services/QH65B2";
const CLIENT_ID: &str = "XABBG36SBA";
/// The App ID feature key for app groups.
pub const FEATURE_APP_GROUPS: &str = "APG3427HIY";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Team {
    pub team_id: String,
    pub name: String,
    /// "Individual", "Company/Organization", "In-House"; a free Personal Team is `is_free`.
    pub kind: String,
    pub is_free: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Device {
    pub device_id: String,
    pub name: String,
    pub udid: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Certificate {
    pub certificate_id: String,
    pub serial_number: String,
    pub name: String,
    pub machine_name: String,
    #[serde(with = "serde_bytes_b64")]
    pub der: Vec<u8>,
}

mod serde_bytes_b64 {
    use base64::Engine;
    use serde::{Deserialize, Deserializer, Serializer};
    pub fn serialize<S: Serializer>(v: &Vec<u8>, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&base64::engine::general_purpose::STANDARD.encode(v))
    }
    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Vec<u8>, D::Error> {
        let s = String::deserialize(d)?;
        base64::engine::general_purpose::STANDARD.decode(s).map_err(serde::de::Error::custom)
    }
}

#[derive(Debug, Clone)]
pub struct AppId {
    pub app_id_id: String,
    pub identifier: String,
    pub name: String,
    pub features: plist::Dictionary,
}

#[derive(Debug, Clone)]
pub struct AppGroup {
    pub group_id: String,
    pub identifier: String,
    pub name: String,
}

#[derive(Debug, Clone)]
pub struct Profile {
    pub profile_id: String,
    pub name: String,
    pub data: Vec<u8>,
}

pub struct Portal<'a> {
    http: reqwest::Client,
    session: &'a Session,
    token: &'a AppToken,
    anisette: &'a mut super::anisette::Provider,
}

fn st<'a>(d: &'a plist::Dictionary, k: &str) -> String { d.get(k).and_then(|v| v.as_string()).unwrap_or("").to_string() }

impl<'a> Portal<'a> {
    pub fn new(session: &'a Session, token: &'a AppToken, anisette: &'a mut super::anisette::Provider) -> Result<Self> {
        Ok(Portal { http: super::http_client()?, session, token, anisette })
    }

    async fn call(&mut self, action: &str, params: plist::Dictionary) -> Result<plist::Dictionary> {
        let headers = self.anisette.headers().await?;
        let mut req = plist::Dictionary::new();
        req.insert("clientId".into(), CLIENT_ID.into());
        req.insert("protocolVersion".into(), "QH65B2".into());
        req.insert("requestId".into(), uuid::Uuid::new_v4().to_string().to_uppercase().into());
        req.insert("userLocale".into(), plist::Value::Array(vec!["en_US".into()]));
        for (k, v) in params {
            req.insert(k, v);
        }
        let mut body = Vec::new();
        plist::to_writer_xml(&mut body, &plist::Value::Dictionary(req))?;
        let mut rb = self
            .http
            .post(format!("{BASE}/{action}?clientId={CLIENT_ID}"))
            .header("Content-Type", "text/x-xml-plist")
            .header("Accept", "text/x-xml-plist")
            .header("Accept-Language", "en-us")
            .header("User-Agent", "Xcode")
            .header("X-Apple-I-Identity-Id", &self.session.adsid)
            .header("X-Apple-GS-Token", &self.token.token)
            .header("X-Xcode-Version", super::XCODE_VERSION)
            .header("X-Apple-App-Info", super::XCODE_APP_ID);
        for (k, v) in &headers.map {
            rb = rb.header(k.as_str(), v.as_str());
        }
        let res = rb.body(body).send().await?;
        let status = res.status();
        let bytes = res.bytes().await?;
        let v: plist::Dictionary = plist::from_bytes(&bytes).map_err(|_| {
            if status.as_u16() == 401 || status.as_u16() == 403 {
                Error::NeedsPerson("Apple no longer accepts this sign-in. Sign in again.".into())
            } else {
                Error::msg(format!("The developer portal gave an unexpected answer (HTTP {status})."))
            }
        })?;
        let code = v.get("resultCode").and_then(|c| c.as_signed_integer().or_else(|| c.as_unsigned_integer().map(|u| u as i64))).unwrap_or(0);
        if code != 0 {
            let text = v.get("userString").or_else(|| v.get("resultString")).and_then(|s| s.as_string()).unwrap_or("").to_string();
            return Err(portal_error(code, text));
        }
        Ok(v)
    }

    pub async fn teams(&mut self) -> Result<Vec<Team>> {
        let v = self.call("listTeams.action", plist::Dictionary::new()).await?;
        let mut out = vec![];
        for t in v.get("teams").and_then(|t| t.as_array()).into_iter().flatten() {
            let Some(t) = t.as_dictionary() else { continue };
            let kind = st(t, "type");
            let memberships = t.get("memberships").and_then(|m| m.as_array());
            let is_free = memberships.map(|m| m.len() == 1 && m[0].as_dictionary().map(|d| st(d, "name").to_lowercase().contains("free")).unwrap_or(false)).unwrap_or(false);
            out.push(Team { team_id: st(t, "teamId"), name: st(t, "name"), kind, is_free });
        }
        if out.is_empty() {
            return Err(Error::msg("This Apple ID has no developer team. Open Xcode or developer.apple.com once with it to accept Apple's agreement, then try again."));
        }
        Ok(out)
    }

    fn team_params(team: &str) -> plist::Dictionary {
        let mut d = plist::Dictionary::new();
        d.insert("teamId".into(), team.into());
        d
    }

    pub async fn devices(&mut self, team: &str) -> Result<Vec<Device>> {
        let v = self.call("ios/listDevices.action", Self::team_params(team)).await?;
        Ok(v.get("devices").and_then(|d| d.as_array()).into_iter().flatten().filter_map(|d| d.as_dictionary()).map(|d| Device { device_id: st(d, "deviceId"), name: st(d, "name"), udid: st(d, "deviceNumber") }).collect())
    }

    /// Registers the phone with the team if it is not there yet.
    pub async fn ensure_device(&mut self, team: &str, udid: &str, name: &str) -> Result<Device> {
        if let Some(d) = self.devices(team).await?.into_iter().find(|d| d.udid.eq_ignore_ascii_case(udid)) {
            return Ok(d);
        }
        let mut p = Self::team_params(team);
        p.insert("name".into(), name.into());
        p.insert("deviceNumber".into(), udid.into());
        let v = self.call("ios/addDevice.action", p).await?;
        let d = v.get("device").and_then(|d| d.as_dictionary()).ok_or_else(|| Error::msg("Apple registered the phone but sent no record"))?;
        Ok(Device { device_id: st(d, "deviceId"), name: st(d, "name"), udid: st(d, "deviceNumber") })
    }

    /// Every field Apple sends for the team's development certificates, certificate bytes left
    /// out (for support).
    pub async fn certificates_raw(&mut self, team: &str) -> Result<Vec<String>> {
        let v = self.call("ios/listAllDevelopmentCerts.action", Self::team_params(team)).await?;
        let mut out = vec![format!("top-level keys: {:?}", v.keys().collect::<Vec<_>>())];
        for d in v.get("certificates").or_else(|| v.get("certRequests")).and_then(|d| d.as_array()).into_iter().flatten().filter_map(|d| d.as_dictionary()) {
            let mut fields = vec![];
            for (k, val) in d {
                let shown = match val {
                    plist::Value::Data(b) => format!("<{} bytes>", b.len()),
                    plist::Value::String(s) => s.clone(),
                    plist::Value::Integer(i) => i.to_string(),
                    plist::Value::Boolean(b) => b.to_string(),
                    plist::Value::Date(d) => format!("{d:?}"),
                    plist::Value::Dictionary(d) => format!("{{{}}}", d.keys().cloned().collect::<Vec<_>>().join(",")),
                    plist::Value::Array(a) => format!("[{} items]", a.len()),
                    other => format!("{other:?}"),
                };
                fields.push(format!("{k}={shown}"));
            }
            out.push(fields.join("  "));
        }
        Ok(out)
    }

    pub async fn certificates(&mut self, team: &str) -> Result<Vec<Certificate>> {
        let v = self.call("ios/listAllDevelopmentCerts.action", Self::team_params(team)).await?;
        Ok(v.get("certificates").or_else(|| v.get("certRequests"))
            .and_then(|d| d.as_array())
            .into_iter()
            .flatten()
            .filter_map(|d| d.as_dictionary())
            .map(|d| Certificate {
                certificate_id: st(d, "certificateId"),
                serial_number: { let s = st(d, "serialNumber"); if s.is_empty() { st(d, "serialNum") } else { s } },
                name: st(d, "name"),
                machine_name: st(d, "machineName"),
                der: d.get("certContent").and_then(|c| c.as_data()).unwrap_or(&[]).to_vec(),
            })
            .collect())
    }

    /// Sends the CSR. Apple answers with the new certificate request (its id and serial number,
    /// sometimes the certificate itself), which is how the new certificate is found afterwards.
    pub async fn submit_csr(&mut self, team: &str, csr_pem: &str, machine_id: &str, machine_name: &str) -> Result<Certificate> {
        let mut p = Self::team_params(team);
        p.insert("machineId".into(), machine_id.into());
        p.insert("machineName".into(), machine_name.into());
        p.insert("csrContent".into(), csr_pem.into());
        let v = self.call("ios/submitDevelopmentCSR.action", p).await?;
        let d = v.get("certRequest").and_then(|d| d.as_dictionary());
        let get = |k: &str| d.map(|d| st(d, k)).unwrap_or_default();
        let serial = { let s = get("serialNumber"); if s.is_empty() { get("serialNum") } else { s } };
        tracing::info!(certificate_id = %get("certificateId"), cert_request_id = %get("certRequestId"), serial = %serial, "certificate request accepted");
        Ok(Certificate {
            certificate_id: get("certificateId"),
            serial_number: serial,
            name: get("name"),
            machine_name: get("machineName"),
            der: d.and_then(|d| d.get("certContent")).and_then(|c| c.as_data()).unwrap_or(&[]).to_vec(),
        })
    }

    pub async fn revoke_certificate(&mut self, team: &str, serial_number: &str) -> Result<()> {
        let mut p = Self::team_params(team);
        p.insert("serialNumber".into(), serial_number.into());
        self.call("ios/revokeDevelopmentCert.action", p).await?;
        Ok(())
    }

    pub async fn app_ids(&mut self, team: &str) -> Result<Vec<AppId>> {
        let v = self.call("ios/listAppIds.action", Self::team_params(team)).await?;
        Ok(v.get("appIds")
            .and_then(|d| d.as_array())
            .into_iter()
            .flatten()
            .filter_map(|d| d.as_dictionary())
            .map(|d| AppId { app_id_id: st(d, "appIdId"), identifier: st(d, "identifier"), name: st(d, "name"), features: d.get("features").and_then(|f| f.as_dictionary()).cloned().unwrap_or_default() })
            .collect())
    }

    pub async fn ensure_app_id(&mut self, team: &str, identifier: &str, name: &str) -> Result<AppId> {
        if let Some(a) = self.app_ids(team).await?.into_iter().find(|a| a.identifier == identifier) {
            return Ok(a);
        }
        let mut p = Self::team_params(team);
        p.insert("identifier".into(), identifier.into());
        p.insert("name".into(), name.into());
        self.call("ios/addAppId.action", p).await?;
        self.app_ids(team).await?.into_iter().find(|a| a.identifier == identifier).ok_or_else(|| Error::msg(format!("Apple did not create the App ID {identifier}")))
    }

    /// Turns a feature on (e.g. app groups) if it is off.
    pub async fn enable_feature(&mut self, team: &str, app_id: &AppId, feature: &str) -> Result<()> {
        if app_id.features.get(feature).and_then(|f| f.as_boolean()).unwrap_or(false) {
            return Ok(());
        }
        let mut p = Self::team_params(team);
        p.insert("appIdId".into(), app_id.app_id_id.clone().into());
        p.insert(feature.into(), true.into());
        self.call("ios/updateAppId.action", p).await?;
        Ok(())
    }

    pub async fn app_groups(&mut self, team: &str) -> Result<Vec<AppGroup>> {
        let v = self.call("ios/listApplicationGroups.action", Self::team_params(team)).await?;
        Ok(v.get("applicationGroupList")
            .and_then(|d| d.as_array())
            .into_iter()
            .flatten()
            .filter_map(|d| d.as_dictionary())
            .map(|d| AppGroup { group_id: st(d, "applicationGroup"), identifier: st(d, "identifier"), name: st(d, "name") })
            .collect())
    }

    pub async fn ensure_app_group(&mut self, team: &str, identifier: &str, name: &str) -> Result<AppGroup> {
        if let Some(g) = self.app_groups(team).await?.into_iter().find(|g| g.identifier == identifier) {
            return Ok(g);
        }
        let mut p = Self::team_params(team);
        p.insert("identifier".into(), identifier.into());
        p.insert("name".into(), name.into());
        let v = self.call("ios/addApplicationGroup.action", p).await?;
        let d = v.get("applicationGroup").and_then(|d| d.as_dictionary()).ok_or_else(|| Error::msg("Apple created the app group but sent no record"))?;
        Ok(AppGroup { group_id: st(d, "applicationGroup"), identifier: st(d, "identifier"), name: st(d, "name") })
    }

    pub async fn assign_app_group(&mut self, team: &str, app_id: &AppId, group: &AppGroup) -> Result<()> {
        let mut p = Self::team_params(team);
        p.insert("appIdId".into(), app_id.app_id_id.clone().into());
        p.insert("applicationGroups".into(), group.group_id.clone().into());
        self.call("ios/assignApplicationGroupToAppId.action", p).await?;
        Ok(())
    }

    pub async fn profile(&mut self, team: &str, app_id: &AppId) -> Result<Profile> {
        let mut p = Self::team_params(team);
        p.insert("appIdId".into(), app_id.app_id_id.clone().into());
        let v = self.call("ios/downloadTeamProvisioningProfile.action", p).await?;
        let d = v.get("provisioningProfile").and_then(|d| d.as_dictionary()).ok_or_else(|| Error::msg("Apple sent no provisioning profile"))?;
        Ok(Profile { profile_id: st(d, "provisioningProfileId"), name: st(d, "name"), data: d.get("encodedProfile").and_then(|c| c.as_data()).unwrap_or(&[]).to_vec() })
    }
}

fn portal_error(code: i64, text: String) -> Error {
    let t = match code {
        7460 => "This team has registered its limit of devices. Remove one at developer.apple.com, or use another Apple ID.".to_string(),
        3250 | 7250 => "A free Apple ID can only sign three apps at a time, and Apple counts Poki's extensions. Remove another sideloaded app from your developer account and try again.".to_string(),
        9100 | 7460_0 => text,
        35 => "Apple's developer agreement has changed. Open developer.apple.com once, accept it, then try again.".to_string(),
        _ if text.is_empty() => format!("The developer portal refused the request (code {code})."),
        _ => text,
    };
    Error::apple(code, t)
}
