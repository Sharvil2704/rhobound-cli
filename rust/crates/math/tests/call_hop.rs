// SPDX-License-Identifier: Apache-2.0

//! A topology written by the Go code after the first release can carry a `hop` on a call (the per-edge network
//! time). rbfast models the callee's hop only, so it must refuse such a file instead of ignoring the field and
//! printing numbers that differ from rhobound's (found on the AWS captures of the spec3 run: `rbfast model` on
//! the topology `rhobound infer` wrote gave different latencies with no sign of it).

use rbfast_math::parse_topology;

const PLAIN: &str = r#"{"name":"t","services":[
 {"name":"a","s":5,"servers":2,"children":["b",{"name":"c","p":0.5}]},
 {"name":"b","s":3,"servers":2,"hop":0.2},
 {"name":"c","s":4,"servers":2,"hop":0.3}],"entry":{"a":1}}"#;

fn with_call_hop(key: &str) -> String {
    PLAIN.replace(
        r#"{"name":"c","p":0.5}"#,
        &format!(r#"{{"name":"c","p":0.5,"{key}":0.25}}"#),
    )
}

#[test]
fn call_objects_without_hop_still_parse() {
    parse_topology(PLAIN.as_bytes()).expect("a name and a {name,p} call parse as before");
}

#[test]
fn a_call_with_its_own_hop_is_refused() {
    for key in ["hop", "Hop", "HOP"] {
        let e = parse_topology(with_call_hop(key).as_bytes())
            .err()
            .unwrap_or_else(|| panic!("call hop key {key:?} was read"));
        assert!(
            e.0.contains("a: a call with its own hop is not supported"),
            "{key}: {}",
            e.0
        );
    }
}

#[test]
fn a_service_hop_is_still_read() {
    let t = parse_topology(PLAIN.as_bytes()).unwrap();
    assert!(t.services.iter().any(|s| s.name == "b" && s.hop == 0.2));
}
