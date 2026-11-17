//! Apple's SRP-6a variant for GSA, as corecrypto does it with `noUsernameInX`: the username is in
//! M1 but not in x. Group: RFC 5054 2048-bit, hash SHA-256. Written from the protocol as
//! implemented in Sideloader (applesrpsession.d, GPL-3.0) and AltSign's corecrypto bridge.
use num_bigint::BigUint;
use num_traits::{One, Zero};
use sha2::{Digest, Sha256};

const N_HEX: &str = "AC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC3192943DB56050A37329CBB4A099ED8193E0757767A13DD52312AB4B03310DCD7F48A9DA04FD50E8083969EDB767B0CF6095179A163AB3661A05FBD5FAAAE82918A9962F0B93B855F97993EC975EEAA80D740ADBF4FF747359D041D5C33EA71D281E446B14773BCA97B43A23FB801676BD207A436C6481F1D2B9078717461A5B9D32E688F87748544523B524B0D57D5EA77A2775D2ECFA032CFBDBF52FB3786160279004E57AE6AF874E7303CE53299CCC041C7BC308D82A5698F3A8D0C38271AE35F8E9DBFBB694B5C803D89F7AE435DE236D525F54759B65E372FCD68EF20FA7111F9E4AFF73";
const PAD: usize = 256;

fn n() -> BigUint { BigUint::parse_bytes(N_HEX.as_bytes(), 16).unwrap() }
fn g() -> BigUint { BigUint::from(2u32) }

fn pad(x: &BigUint) -> Vec<u8> {
    let b = x.to_bytes_be();
    let mut out = vec![0u8; PAD.saturating_sub(b.len())];
    out.extend_from_slice(&b);
    out
}
fn h(parts: &[&[u8]]) -> Vec<u8> {
    let mut d = Sha256::new();
    for p in parts {
        d.update(p);
    }
    d.finalize().to_vec()
}
fn from_bytes(b: &[u8]) -> BigUint { BigUint::from_bytes_be(b) }

pub struct Client {
    a: BigUint,
    pub a_pub: Vec<u8>,
    k: Vec<u8>,
    m1: Vec<u8>,
    b_pub: Vec<u8>,
}

impl Client {
    pub fn new() -> Self {
        use rand::RngCore;
        let mut raw = [0u8; 32];
        rand::thread_rng().fill_bytes(&mut raw);
        let a = from_bytes(&raw);
        let a_pub = g().modpow(&a, &n()).to_bytes_be();
        Client { a, a_pub, k: vec![], m1: vec![], b_pub: vec![] }
    }

    /// The password as Apple's "s2k" wants it: SHA-256 of the password, then PBKDF2-HMAC-SHA256
    /// with the server's salt and iterations; "s2k_fo" feeds the hex of the hash instead.
    pub fn derive_password(password: &str, salt: &[u8], iterations: u32, s2k_fo: bool) -> [u8; 32] {
        let hashed = Sha256::digest(password.as_bytes());
        let input: Vec<u8> = if s2k_fo { hex::encode(hashed).into_bytes() } else { hashed.to_vec() };
        let mut out = [0u8; 32];
        pbkdf2::pbkdf2_hmac::<Sha256>(&input, salt, iterations, &mut out);
        out
    }

    /// Processes the server's B and salt; returns M1.
    pub fn process(&mut self, username: &str, derived_password: &[u8], salt: &[u8], b_pub: &[u8]) -> Result<Vec<u8>, &'static str> {
        let n = n();
        let g = g();
        let b = from_bytes(b_pub);
        if b.is_zero() || (&b % &n).is_zero() {
            return Err("bad server public value");
        }
        let a_num = from_bytes(&self.a_pub);
        let k = from_bytes(&h(&[&pad(&n), &pad(&g)]));
        let u = from_bytes(&h(&[&pad(&a_num), &pad(&b)]));
        if u.is_zero() {
            return Err("bad u");
        }
        // x = H(salt | H(":" | P)), with no username (corecrypto noUsernameInX).
        let inner = h(&[b":", derived_password]);
        let x = from_bytes(&h(&[salt, &inner]));
        let gx = g.modpow(&x, &n);
        let kgx = (&k * &gx) % &n;
        let base = (&b + &n - kgx) % &n;
        let exp = &self.a + &u * &x;
        let s = base.modpow(&exp, &n);
        let key = h(&[&s.to_bytes_be()]);
        let hn = h(&[&n.to_bytes_be()]);
        let hg = h(&[&pad(&g)]);
        let xor: Vec<u8> = hn.iter().zip(hg.iter()).map(|(a, b)| a ^ b).collect();
        let hi = h(&[username.as_bytes()]);
        let m1 = h(&[&xor, &hi, salt, &self.a_pub, b_pub, &key]);
        self.k = key;
        self.m1 = m1.clone();
        self.b_pub = b_pub.to_vec();
        let _ = BigUint::one();
        Ok(m1)
    }

    pub fn verify_server(&self, m2: &[u8]) -> bool {
        !self.k.is_empty() && h(&[&self.a_pub, &self.m1, &self.k]) == m2
    }

    /// The session key K, for the spd decryption and the app-token checksum.
    pub fn key(&self) -> &[u8] { &self.k }
}

impl Default for Client {
    fn default() -> Self { Self::new() }
}

#[cfg(test)]
mod tests {
    use super::*;
    use num_bigint::BigUint;

    /// A server written from the same maths proves the client against itself: M1 matches on both
    /// sides and M2 verifies. (Apple's servers cannot be reached from tests.)
    #[test]
    fn round_trip_with_reference_server() {
        let username = "someone@example.com";
        let password = "correct horse";
        let salt = b"0123456789abcdef";
        let derived = Client::derive_password(password, salt, 1000, false);
        let n = n();
        let g = g();
        let inner = h(&[b":", &derived]);
        let x = from_bytes(&h(&[salt, &inner]));
        let v = g.modpow(&x, &n);
        let b_priv = BigUint::from(123456789u64);
        let k = from_bytes(&h(&[&pad(&n), &pad(&g)]));
        let b_pub = (&k * &v + g.modpow(&b_priv, &n)) % &n;
        let b_bytes = b_pub.to_bytes_be();

        let mut client = Client::new();
        let m1 = client.process(username, &derived, salt, &b_bytes).unwrap();

        let a_num = from_bytes(&client.a_pub);
        let u = from_bytes(&h(&[&pad(&a_num), &pad(&b_pub)]));
        let s = (&a_num * v.modpow(&u, &n)).modpow(&b_priv, &n);
        let key = h(&[&s.to_bytes_be()]);
        assert_eq!(key, client.key());
        let hn = h(&[&n.to_bytes_be()]);
        let hg = h(&[&pad(&g)]);
        let xor: Vec<u8> = hn.iter().zip(hg.iter()).map(|(a, b)| a ^ b).collect();
        let expected_m1 = h(&[&xor, &h(&[username.as_bytes()]), salt, &client.a_pub, &b_bytes, &key]);
        assert_eq!(m1, expected_m1);
        let m2 = h(&[&client.a_pub, &m1, &key]);
        assert!(client.verify_server(&m2));
        assert!(!client.verify_server(b"nope"));
    }
}
