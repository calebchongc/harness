// Adapted from Zeron (MIT); see third_party/licenses/Zeron-MIT.txt.
//! In-memory documents are separate from website navigation and login profiles.
use crate::markdown::content_reference::{HtmlCompatibility, HtmlPreview};

pub(super) struct HtmlDocument {
    pub path: String,
    pub title: String,
    pub html: String,
}

fn escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

impl HtmlDocument {
    pub fn new(request: &HtmlPreview, content: &str) -> Result<Self, String> {
        let title = request
            .path
            .rsplit(['/', '\\'])
            .next()
            .unwrap_or("HTML preview")
            .to_owned();
        let runtime = match request.compatibility {
            HtmlCompatibility::None => "",
            HtmlCompatibility::CodexVisualize => include_str!("visualize.js"),
        };
        let controls = match request.compatibility {
            HtmlCompatibility::None => "",
            HtmlCompatibility::CodexVisualize => include_str!("visualize-controls.js"),
        };
        // The iframe has a unique origin, scripts only, no host API. The CSP
        // also applies to srcdoc: content cannot relax it with its own meta tag.
        let child = format!(
            "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><style>:root{{color-scheme:light dark}}body{{margin:16px;font:14px system-ui}}[hidden]{{display:none!important}}</style><script>{controls}</script><script>{runtime}</script></head><body>{content}</body></html>"
        );
        let width = if request.wide { "100%" } else { "960px" };
        #[allow(unused_mut)]
        let mut html = format!(
            "<!doctype html><html><head><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; frame-src about:; connect-src 'none'; base-uri 'none'; form-action 'none'\"><title>{}</title><style>:root{{color-scheme:light dark}}html,body{{margin:0;height:100%;overflow:hidden}}iframe{{display:block;width:100%;max-width:{width};height:100%;margin:auto;border:0}}</style></head><body><iframe title=\"{}\" sandbox=\"allow-scripts\" srcdoc=\"{}\"></iframe></body></html>",
            escape(&title),
            escape(&title),
            escape(&child)
        );
        // Fixture-only status relay. Production previews have no message
        // listener and no page-to-engine bridge of any kind.
        #[cfg(feature = "browser-fixture")]
        html.push_str("<script>window.addEventListener('message',e=>{if(e.source===document.querySelector('iframe').contentWindow&&typeof e.data==='string'&&e.data.startsWith('preview:'))document.title=e.data.slice(0,256)})</script>");
        // Bound the final encoded document, including attribute escaping,
        // consistently on every platform. Bound JSON escaping too: Linux
        // sends this through a framed command
        // pipe, and control characters can expand to six bytes each.
        let command_bytes = serde_json::to_string(&html)
            .map_err(|_| "Could not encode this HTML preview.".to_owned())?
            .len();
        if html.encode_utf16().count() > 900_000
            || html.len() > 950_000
            || command_bytes > 3_900_000
        {
            return Err("This HTML preview is too large. Open the source file instead.".into());
        }
        Ok(Self {
            path: request.path.clone(),
            title,
            html,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn policy_is_scripts_only_and_content_cannot_replace_it() {
        let request = HtmlPreview {
            path: "/work/design.html".into(),
            wide: false,
            compatibility: HtmlCompatibility::CodexVisualize,
        };
        let doc = HtmlDocument::new(&request, "<meta http-equiv=Content-Security-Policy content=\"default-src *\"><base href=\"https://example.com\"><script>fetch('/secret')</script>").unwrap();
        assert!(doc.html.contains("connect-src 'none'"));
        assert!(doc.html.contains("base-uri 'none'"));
        assert!(doc.html.contains("form-action 'none'"));
        assert!(doc.html.contains("default-src 'none'"));
        assert!(!doc.html.contains("allow-same-origin"));
        assert!(!doc.html.contains("allow-forms"));
        assert!(!doc.html.contains("allow-popups"));
        assert!(doc.html.contains("class Tweak"));
        assert!(doc.html.contains("max-width:960px"));
        for address in [
            "https://example.com",
            "file:///tmp/secret",
            "data:text/html,hi",
            "harness://open/chat/a",
            "graff-view://html/0123456789abcdef0123456789abcdef",
        ] {
            assert!(!super::super::model::allowed_document_navigation(address));
        }
        assert!(super::super::model::allowed_document_navigation(
            "about:blank"
        ));
        assert!(super::super::model::allowed_document_navigation(
            "about:srcdoc"
        ));
    }

    #[test]
    fn documents_escape_the_frame_boundary_and_bound_the_encoded_size() {
        let request = HtmlPreview {
            path: "/tmp/test.html".into(),
            wide: true,
            compatibility: HtmlCompatibility::None,
        };
        let doc = HtmlDocument::new(
            &request,
            "</iframe><script>parent.document.body.remove()</script>",
        )
        .unwrap();
        assert_eq!(doc.html.matches("<iframe ").count(), 1);
        assert!(doc.html.contains("&lt;/iframe&gt;"));
        assert!(doc.html.contains("sandbox=\"allow-scripts\""));
        assert!(HtmlDocument::new(&request, &"&".repeat(250_000)).is_err());
        assert!(HtmlDocument::new(&request, &"\0".repeat(700_000)).is_err());
    }
}
