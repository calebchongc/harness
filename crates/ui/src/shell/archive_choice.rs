//! The one-time question the first ⌘W close asks: archive the session, or
//! just close it. The answer becomes the archive-on-close setting (Settings →
//! Archived sessions), which ⌘W and the ✕ buttons follow from then on. The
//! close-without-archiving shortcut (⌘⌥W) and the ✕ buttons never ask.

use super::*;

#[cfg(test)]
mod tests;

/// The dialog's copy, given the two shortcuts as displayed.
pub(super) fn archive_choice_copy(close: &str, close_only: &str) -> (String, String) {
    (
        format!("When you close a chat with {close}"),
        format!(
            "Archive it to move an idle session to the archived shelf, or just close it \
             and keep it in the sidebar. Running sessions are never archived. \
             {close_only} always just closes. You can change this in Settings \u{2192} \
             Archived sessions."
        ),
    )
}

impl Shell {
    /// ⌘W on a chat pane, tab or the last session. Archives the closed
    /// session when archive-on-close is on. Until that has been chosen once,
    /// a ⌘W that would close a session asks first and closes nothing yet.
    pub(crate) fn close_chat_view_by_shortcut(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if !settings::archive_on_close_chosen(cx) && self.state.read(cx).selected_chat.is_some() {
            self.archive_choice_prompt = true;
            cx.notify();
            return false;
        }
        self.close_chat_view_with_archive(true, window, cx)
    }

    /// The question's answer: save it as the archive-on-close setting, then
    /// do the close the ⌘W asked for.
    pub(crate) fn choose_close_archiving(
        &mut self,
        archive: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if !std::mem::take(&mut self.archive_choice_prompt) {
            return false;
        }
        settings::set_archive_sessions_on_close(archive, cx);
        self.sync_independent_settings(cx);
        self.close_chat_view_with_archive(true, window, cx)
    }

    /// Escape: nothing closes and nothing is saved; the next ⌘W asks again.
    pub(super) fn dismiss_archive_choice(&mut self, cx: &mut Context<Self>) -> bool {
        if !std::mem::take(&mut self.archive_choice_prompt) {
            return false;
        }
        cx.notify();
        true
    }

    pub(super) fn render_archive_choice_dialog(
        &self,
        viewport: gpui::Size<Pixels>,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        if !self.archive_choice_prompt {
            return None;
        }
        let (close, close_only) = settings::close_shortcut_badges(cx);
        let (title, body) = archive_choice_copy(&close, &close_only);
        let card = popover::dialog_card(theme)
            .child(popover::dialog_title(theme, &title))
            .child(div().mt(px(6.0)).child(popover::dialog_body(theme, body)))
            .child(
                div()
                    .mt(px(16.0))
                    .flex()
                    .flex_row()
                    .justify_end()
                    .gap(px(8.0))
                    .child(
                        popover::btn_ghost(theme, "Just close it", "archive-choice-close")
                            .id("archive-choice-close")
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.choose_close_archiving(false, window, cx);
                            })),
                    )
                    .child(
                        popover::btn_primary(theme, "Archive it")
                            .id("archive-choice-archive")
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.choose_close_archiving(true, window, cx);
                            })),
                    ),
            )
            .into_any_element();
        Some(popover::modal("archive-choice-dialog", viewport, card))
    }
}
