//! Minimal WebDAV multistatus parser. Keeps only properties from 200-OK propstats, keyed by local name.

use quick_xml::events::Event;
use quick_xml::Reader;
use std::collections::HashMap;

#[derive(Debug, Default, Clone)]
pub struct DavResponse {
    pub href: String,
    pub props: HashMap<String, String>,
    pub is_collection: bool,
}

pub fn parse_multistatus(data: &[u8]) -> Vec<DavResponse> {
    let mut reader = Reader::from_reader(data);
    reader.config_mut().trim_text(true);
    let mut out = Vec::new();
    let mut buf = Vec::new();

    let mut current: Option<DavResponse> = None;
    let mut pending: HashMap<String, String> = HashMap::new();
    let mut pending_collection = false;
    let mut status = String::new();
    let mut in_prop = false;
    let mut in_resourcetype = false;
    let mut stack: Vec<String> = Vec::new();
    let mut text = String::new();

    loop {
        match reader.read_event_into(&mut buf) {
            Ok(Event::Start(e)) => {
                let name = String::from_utf8_lossy(e.local_name().as_ref()).to_string();
                text.clear();
                match name.as_str() {
                    "response" => current = Some(DavResponse::default()),
                    "propstat" => {
                        pending.clear();
                        pending_collection = false;
                        status.clear();
                    }
                    "prop" => in_prop = true,
                    "resourcetype" => in_resourcetype = true,
                    "collection" if in_resourcetype => pending_collection = true,
                    _ => {}
                }
                stack.push(name);
            }
            Ok(Event::Empty(e)) => {
                let name = String::from_utf8_lossy(e.local_name().as_ref()).to_string();
                if name == "collection" && in_resourcetype {
                    pending_collection = true;
                } else if in_prop && !in_resourcetype && name != "resourcetype" {
                    pending.insert(name, String::new());
                }
            }
            Ok(Event::Text(t)) => {
                if let Ok(s) = t.unescape() {
                    text.push_str(&s);
                }
            }
            Ok(Event::CData(t)) => text.push_str(&String::from_utf8_lossy(&t)),
            Ok(Event::End(e)) => {
                let name = String::from_utf8_lossy(e.local_name().as_ref()).to_string();
                stack.pop();
                match name.as_str() {
                    "href" if !in_prop => {
                        if let Some(c) = current.as_mut() {
                            c.href = text.trim().to_string();
                        }
                    }
                    "status" => status = text.clone(),
                    "resourcetype" => in_resourcetype = false,
                    "prop" => in_prop = false,
                    "propstat" => {
                        if status.contains(" 200") {
                            if let Some(c) = current.as_mut() {
                                c.props.extend(pending.drain());
                                if pending_collection {
                                    c.is_collection = true;
                                }
                            }
                        }
                    }
                    "response" => {
                        if let Some(c) = current.take() {
                            out.push(c);
                        }
                    }
                    _ => {
                        if in_prop && !in_resourcetype {
                            pending.insert(name, text.trim().to_string());
                        }
                    }
                }
                text.clear();
            }
            Ok(Event::Eof) | Err(_) => break,
            _ => {}
        }
        buf.clear();
    }
    out
}

pub fn escape(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}
