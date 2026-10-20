// SPDX-License-Identifier: Apache-2.0

//! A server span's route and the health-probe rule, as rhobound-cli's reader (`route`, `noQuery`, `IsProbe`).

/// Whether a server span's route ("METHOD /path") is a health or readiness probe: Go's regular expression
/// `grpc\.health\.v1\.Health/|(^|\s)/(_?healthz?|readyz|livez|ready|ping)(\?|$)`, where `\s` is RE2's ASCII
/// class `[\t\n\f\r ]` and `$` is the end of the text.
pub fn is_probe(route: &str) -> bool {
    let r = route.as_bytes();
    if memchr::memmem::find(r, b"grpc.health.v1.Health/").is_some() {
        return true;
    }
    const ALTS: [&[u8]; 8] = [
        b"_healthz",
        b"_health",
        b"healthz",
        b"health",
        b"readyz",
        b"livez",
        b"ready",
        b"ping",
    ];
    for i in memchr::memchr_iter(b'/', r) {
        if i > 0 && !matches!(r[i - 1], b'\t' | b'\n' | 0x0C | b'\r' | b' ') {
            continue;
        }
        let rest = &r[i + 1..];
        for alt in ALTS {
            if let Some(after) = rest.strip_prefix(alt) {
                if after.is_empty() || after[0] == b'?' {
                    return true;
                }
            }
        }
    }
    false
}

/// noQuery: cut a path's query string and fragment, only when what comes before contains a '/'.
fn no_query(p: &str) -> &str {
    let q = p.find('?');
    let h = p.find('#');
    let cut = match (q, h) {
        (Some(a), Some(b)) => Some(a.min(b)),
        (a, b) => a.or(b),
    };
    match cut {
        Some(c) if c > 0 && p[..c].contains('/') => &p[..c],
        _ => p,
    }
}

/// The route of a server span, given the value of its first path attribute (in the reference's key order, the
/// empty string when it has none or it is empty), its name, and its first method attribute; written to `out`.
pub(crate) fn route_into(out: &mut String, path_attr: &str, name: &str, method: &str) {
    let mut path = if path_attr.is_empty() {
        name
    } else {
        path_attr
    };
    path = no_query(path);
    let mut owned_slash = false;
    if path.starts_with("http://") || path.starts_with("https://") {
        // strings.Count(path, "/") >= 3: keep "/" + everything after the third slash
        let mut slashes = path.match_indices('/');
        match slashes.nth(2) {
            Some((k, _)) => path = &path[k..],
            None => owned_slash = true,
        }
    }
    out.clear();
    out.push_str(method);
    out.push(' ');
    if owned_slash {
        out.push('/');
    } else {
        out.push_str(path);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn route(path: &str, name: &str, method: &str) -> String {
        let mut s = String::new();
        route_into(&mut s, path, name, method);
        crate::json::trim_space(&s).to_string()
    }

    #[test]
    fn routes() {
        assert_eq!(route("/a?b", "", "GET"), "GET /a");
        assert_eq!(
            route("", "UsersController#show", ""),
            "UsersController#show"
        );
        assert_eq!(route("http://10.0.0.1:8080/ready", "", ""), "/ready");
        assert_eq!(route("https://host/ping?probe", "", ""), "/ping");
        assert_eq!(route("http://host", "", ""), "/");
        assert_eq!(route("http://host/", "", ""), "/");
        assert_eq!(route("http://a/b/c", "", "POST"), "POST /b/c");
    }

    #[test]
    fn probes() {
        assert!(is_probe("GET /healthz"));
        assert!(is_probe("/health"));
        assert!(is_probe("x\t/livez?v"));
        assert!(!is_probe("x\u{b}/livez"));
        assert!(!is_probe("/healthy"));
        assert!(!is_probe("/api/health"));
        assert!(is_probe("a grpc.health.v1.Health/Check"));
        assert!(!is_probe("/ready/"));
        assert!(!is_probe("/HEALTHZ"));
    }
}
