class Spedread.MainWindow : Gtk.ApplicationWindow {
    ReadTab _read;
    TextTab _text;

    Gtk.ShortcutController _shortcut_controller;
    Gtk.SpinButton _ms_per_word;
    Gtk.SpinButton _words_at_a_time;
    Gtk.Stack _stack;
    Gtk.Revealer _progress_revealer;
    ProgressPanel _progress;
    Gtk.Spinner _loading_spinner;
    Gtk.Button _open_button;
    Gtk.DropDown _theme_chooser;

#if GTK_4_10
    Gtk.FontDialogButton _font_chooser;
#else
    Gtk.FontButton _font_chooser;
#endif

    WordIndex _word_index = new WordIndex ();
    int _current_word = -1;
    uint _timeout_id = 0;

    /** How often the progress and position are refreshed while playing */
    const int64 PROGRESS_INTERVAL_US = 250 * 1000;
    const int64 SAVE_INTERVAL_US = 5 * 1000 * 1000;

    Book? _book = null;
    BookRecord? _record = null;
    int[] _chapter_first_words = {};
    bool _loading_book = false;
    bool _is_opening_file = false;
    int64 _last_progress_update = 0;
    int64 _last_position_save = 0;

    /** The type of lambdas that are passed to the `add_new_shortcut` method */
    delegate void ShortcutFunc ();

    /** Used by `add_new_shortcut` to determine if the shortcut should run */
    delegate bool ShouldRunFunc ();
    static bool should_always_run () { return true; }
    bool is_tab_read () { return _stack.visible_child == _read; }
    bool is_tab_text () { return _stack.visible_child == _text; }

    /** Whether keys should control reading rather than the focused widget */
    bool should_handle_reading_keys () {
        if (!is_tab_read ()) {
            return false;
        }

        var focused = get_focus ();
        return focused == null
            || (!focused.is_ancestor (_progress)
                && focused.get_ancestor (typeof (Gtk.Popover)) == null);
    }

    public MainWindow (Gtk.Application app) {
        Object (
            application: app,
            default_height: 520,
            default_width: 820,
            title: "Spedread"
        );

        _stack = build_main_stack ();
        _stack.notify["visible-child"].connect (view_switched);

        var progress_side = build_progress_side ();

        _text.input.buffer.changed.connect (text_changed);

        var switcher = new Gtk.StackSwitcher () {
            stack = _stack,
        };

        var titlebar = new Gtk.HeaderBar () {
            show_title_buttons = true,
            title_widget = switcher,
        };

        _loading_spinner = new Gtk.Spinner () {
            visible = false,
        };

        titlebar.pack_start (build_progress_button ());
        titlebar.pack_start (build_open_button ());
        titlebar.pack_start (build_recent_button ());
        titlebar.pack_start (_loading_spinner);
        titlebar.pack_start (build_new_window_button ());
        titlebar.pack_start (build_quick_paste_button ());
        titlebar.pack_end (build_menu_button ());

        _shortcut_controller = new Gtk.ShortcutController () {
            propagation_phase = Gtk.PropagationPhase.CAPTURE,
            scope = Gtk.ShortcutScope.GLOBAL,
        };

        _stack.add_controller (_shortcut_controller);
        define_shortcuts ();

        var content = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        content.append (progress_side);
        content.append (_stack);

        set_titlebar (titlebar);
        set_child (content);

        ((Gtk.Widget) this).add_controller (build_drop_target ());

        var theme = ThemeManager.get_default ();
        theme.changed.connect (apply_theme);
        apply_theme ();
    }

    public override bool close_request () {
        stop_reading ();
        return base.close_request ();
    }

    /** Use the colors of the current theme */
    void apply_theme () {
        var theme = ThemeManager.get_default ();

        if (theme.is_sepia) {
            add_css_class (ThemeManager.SEPIA_CLASS);
        } else {
            remove_css_class (ThemeManager.SEPIA_CLASS);
        }

        _read.pivot_color = theme.palette.pivot;
        _text.apply_palette (theme.palette);
    }

    protected override void dispose () {
        remove_timeout ();
        base.dispose ();
    }

    void add_new_shortcut (
        Gdk.ModifierType modifiers,
        uint keyval,
        owned ShortcutFunc action,
        owned ShouldRunFunc should_run = should_always_run
    ) {
        var shortcut_trigger = new Gtk.KeyvalTrigger (keyval, modifiers);
        var shortcut_action = new Gtk.CallbackAction (() => {
            var should_run_result = should_run ();
            if (should_run_result) {
                action ();
            }

            return should_run_result;
        });

        var shortcut = new Gtk.Shortcut (shortcut_trigger, shortcut_action);
        _shortcut_controller.add_shortcut (shortcut);
    }

    bool can_click_next_word () {
        return is_tab_read () && !_read.is_playing && _read.has_next_word;
    }

    bool can_click_previous_word () {
        return is_tab_read () && !_read.is_playing && _read.has_previous_word;
    }

    /** Stop iterating every word automatically */
    void remove_timeout () {
        if (_timeout_id != 0) {
            Source.remove (_timeout_id);
            _timeout_id = 0;
        }
    }

    /** Build the word index if needed. Return false when there is no text. */
    bool ensure_word_index () {
        if (!_word_index.is_valid) {
            if (_book != null) {
                _word_index.rebuild (
                    _book.text,
                    (int) _words_at_a_time.value,
                    BookLoader.language_of (_book),
                    _book.chapter_boundaries ()
                );
            } else {
                var buffer = _text.input.buffer;
                Gtk.TextIter start, end;
                buffer.get_bounds (out start, out end);

                _word_index.rebuild (
                    buffer.get_text (start, end, true),
                    (int) _words_at_a_time.value,
                    start.get_language ()
                );
            }

            update_chapter_words ();
        }

        return !_word_index.is_empty;
    }

    /** Reset the reading position to the start and show the first word */
    void refresh_read_tab () {
        if (!ensure_word_index ()) {
            _current_word = -1;
            _read.reset_text ();
            _read.allow_playing = false;
            _read.has_next_word = false;
            _read.has_previous_word = false;
            update_time_left ();
            return;
        }

        _current_word = 0;
        show_word (_current_word);
        _read.allow_playing = _word_index.length > 1;
        update_word_navigation ();
        update_time_left ();
    }

    /** Show the word at `index` in the "Read" tab */
    void show_word (int index) {
        var buffer = _text.input.buffer;
        Gtk.TextIter start, end;

        buffer.get_iter_at_offset (out start, _word_index.start (index));
        buffer.get_iter_at_offset (out end, _word_index.end (index));
        _read.word = buffer.get_text (start, end, false);
    }

    /** Update the "next"/"previous" button states */
    void update_word_navigation () {
        _read.has_next_word = _word_index.is_valid
            && _current_word + 1 < _word_index.length;
        _read.has_previous_word = _word_index.is_valid && _current_word > 0;
    }

    void view_switched () {
        var current_view = _stack.visible_child;
        var input_view = _text;

        if (current_view == input_view) {
            // "Text" view: focus on the text view
            stop_reading ();
            _text.input.grab_focus ();
        } else {
            // "Read" view: focus on the play/pause button
            if (!_word_index.is_valid)
                refresh_read_tab ();
            else
                update_time_left ();

            _read.focus_play_button ();
        }
    }

    /** The chapter containing the word at `word`, using the cached starts */
    int chapter_of_word (int word) {
        var low = 0;
        var high = _chapter_first_words.length;

        while (low + 1 < high) {
            var middle = low + (high - low) / 2;

            if (_chapter_first_words[middle] <= word) {
                low = middle;
            } else {
                high = middle;
            }
        }

        return low;
    }

    /** Cache which word each chapter starts with */
    void update_chapter_words () {
        _chapter_first_words = {};

        if (_book != null) {
            foreach (var chapter in _book.chapters) {
                _chapter_first_words += _word_index.first_word_from (chapter.start);
            }
        }
    }

    /** Describe a duration rounded up to the second */
    static string format_time_left (ulong time_left_in_ms) {
        var time_left_in_s = time_left_in_ms / 1000;

        // Always round up
        if (time_left_in_ms % 1000 != 0) {
            time_left_in_s++;
        }

        var seconds_left = (uint) (time_left_in_s % 60);
        var minutes_left = (uint) (time_left_in_s / 60 % 60);
        var hours_left = (uint) (time_left_in_s / 3600);

        if (hours_left > 0) {
            // TR: If plural is an issue, you can translate it as "Time left: %u h %u min"
            return _ ("%u h %u min left").printf (hours_left, minutes_left);
        }

        // TR: If plural is an issue, you can translate it as "Time left: %u min %u s"
        return _ ("%u min %u s left").printf (minutes_left, seconds_left);
    }

    /** Update the time left label and the progress panel */
    void update_time_left () {
        _last_progress_update = get_monotonic_time ();

        if (!_word_index.is_valid) {
            _progress.clear ();
            return;
        }

        if (_word_index.is_empty) {
            _read.time_left = "";
            _progress.clear ();
            return;
        }

        var word = int.max (_current_word, 0);
        var first = 0;
        var end = _word_index.length;
        var title = "";
        var chapter = -1;

        if (_book != null) {
            chapter = chapter_of_word (word);
            title = _book.chapters[chapter].title;

            if (_progress.uses_chapter_scope) {
                first = _chapter_first_words[chapter];

                if (chapter + 1 < _chapter_first_words.length) {
                    end = _chapter_first_words[chapter + 1];
                }
            }
        }

        int remaining_words = end - (word + 1);
        string time_left;

        if (remaining_words > 0) {
            var ms_per_word = (ulong) _ms_per_word.value;
            time_left = format_time_left (ms_per_word * (ulong) remaining_words);
        } else if (end == _word_index.length) {
            time_left = _ ("End reached");
        } else {
            time_left = _ ("End of chapter");
        }

        _read.time_left = time_left;
        _progress.update (
            title,
            chapter,
            word + 1 - first,
            end - first,
            (int) _words_at_a_time.value,
            time_left
        );
    }

    /** Keep the progress and the saved position current while playing */
    void reading_progressed () {
        var now = get_monotonic_time ();

        if (_progress_revealer.reveal_child
            && now - _last_progress_update >= PROGRESS_INTERVAL_US) {
            update_time_left ();
        }

        if (now - _last_position_save >= SAVE_INTERVAL_US) {
            save_position ();
        }
    }

    /** Remember where the reader is in the current book */
    void save_position () {
        _last_position_save = get_monotonic_time ();

        if (_record == null || !_word_index.is_valid || _current_word < 0
            || _word_index.is_empty) {
            return;
        }

        var offset = _word_index.start (_current_word);
        var percent = (int) ((_current_word + 1) * 100L / _word_index.length);

        if (offset != _record.offset || percent != _record.percent) {
            _record.offset = offset;
            _record.percent = percent;
            BookStore.save (_record);
        }
    }

    /** Stop treating the text as a book */
    void forget_book () {
        _book = null;
        _record = null;
        _chapter_first_words = {};
        _text.read_only = false;
        _progress.set_chapters ({});
        title = "Spedread";
    }

    /** React to the text being replaced or edited */
    void text_changed () {
        if (_loading_book) {
            return;
        }

        if (_book != null) {
            forget_book ();
        }

        reset_reading ();
    }

    /** Reset the reading position to the start and show the first word if any */
    void reset_reading () {
        _word_index.invalidate ();
        _current_word = -1;
        _read.allow_playing = false;
        _read.has_next_word = false;
        _read.has_previous_word = false;

        // The highlight may refer to a word that no longer exists
        _text.clear_word_highlight ();

        if (_stack.visible_child == _read) {
            refresh_read_tab ();
        } else {
            update_time_left ();
        }
    }

    /** Regroup the words while staying at the same place in the text */
    void words_at_a_time_changed () {
        if (!_word_index.is_valid || _current_word < 0) {
            reset_reading ();
            return;
        }

        var offset = _word_index.start (_current_word);
        _word_index.invalidate ();
        go_to_offset (offset);
    }

    /** Show the word found at the character `offset` of the text */
    void go_to_offset (int offset) {
        if (!ensure_word_index ()) {
            refresh_read_tab ();
            return;
        }

        go_to_word (_word_index.word_at_offset (offset));
    }

    /** Jump to the first word of a chapter */
    void go_to_chapter (int chapter) {
        if (_book == null || !ensure_word_index ()) {
            return;
        }

        // A chapter without any words leads to the next word available
        go_to_word (int.min (_chapter_first_words[chapter], _word_index.length - 1));
        save_position ();

        if (is_tab_read ()) {
            _read.focus_play_button ();
        }
    }

    /** Show the word at index `word` and update everything depending on it */
    void go_to_word (int word) {
        _current_word = word;
        show_word (_current_word);
        _read.allow_playing = _word_index.length > 1;
        update_word_navigation ();
        update_text_position ();
        update_time_left ();
    }

    /** When the main menu is shown */
    void popover_shown () {
        stop_reading ();
    }

    /** Shows the next word if any and update the UI, returning if there's a
        next word */
    bool tick () {
        if (!ensure_word_index ()) {
            // No text: update the UI and stop trying to read more
            _timeout_id = 0;
            _read.is_playing = false;
            _read.has_next_word = false;
            _read.has_previous_word = false;
            update_text_position ();
            update_time_left ();

            return false;
        }

        if (_current_word + 1 >= _word_index.length) {
            // Nothing left to read, update the UI and stop trying to read more
            _timeout_id = 0;
            _read.is_playing = false;
            _read.has_next_word = false;
            _read.has_previous_word = _current_word > 0;
            update_text_position ();
            update_time_left ();

            return false;
        }

        // A new word has been read! Update the UI to reflect that
        _current_word++;
        show_word (_current_word);
        reading_progressed ();

        // Keep ticking
        return true;
    }

    /** Scroll to the current word and highlight it inside the "Text" tab */
    void update_text_position () {
        // Only the visible Text tab needs to be scrolled and highlighted.
        // When switching to it, `stop_reading` calls this method again.
        if (!is_tab_text ()) {
            return;
        }

        if (!_word_index.is_valid || _current_word < 0
            || _current_word >= _word_index.length) {
            return;
        }

        var buffer = _text.input.buffer;
        Gtk.TextIter start, end;

        buffer.get_iter_at_offset (out start, _word_index.start (_current_word));
        buffer.get_iter_at_offset (out end, _word_index.end (_current_word));
        _text.scroll_to_position (end);
        _text.highlight_current_word (TextBounds (start, end));
    }

    void start_reading () {
        if (!_word_index.is_valid || _current_word < 0
            || _current_word + 1 >= _word_index.length) {
            refresh_read_tab ();
        }

        uint ms_per_word = (uint) _ms_per_word.value;

        _timeout_id = Timeout.add (ms_per_word, tick, Priority.HIGH);

        _read.is_playing = true;
    }

    void stop_reading () {
        remove_timeout ();

        if (_word_index.is_valid) {
            update_word_navigation ();
            update_text_position ();
            update_time_left ();
        } else {
            _read.has_next_word = false;
            _read.has_previous_word = false;
        }

        _read.is_playing = false;
        save_position ();
    }

    /** Open a book in this window, or in a new one if that would throw away
        text the user has entered */
    public void open_file (File file) {
        if (_book == null && _text.input.buffer.get_char_count () > 0) {
            var window = new MainWindow (application);
            window.present ();
            window.open_file (file);
            return;
        }

        load_file.begin (file);
    }

    void set_opening_file (bool is_opening) {
        _is_opening_file = is_opening;
        _open_button.sensitive = !is_opening;
        _loading_spinner.visible = is_opening;
        _loading_spinner.spinning = is_opening;
    }

    async void load_file (File file) {
        if (_is_opening_file) {
            return;
        }

        stop_reading ();
        set_opening_file (true);

        try {
            show_book (yield BookLoader.load (file, (int) _words_at_a_time.value));
        } catch (EpubError.DRM_PROTECTED error) {
            show_message (_ ("This book is protected by DRM and can't be opened."));
        } catch (EpubError.NO_TEXT error) {
            show_message (_ ("This book has no readable text. It may only contain images."));
        } catch (EpubError.TOO_LARGE error) {
            show_message (_ ("This book is too large to be opened."));
        } catch (Error error) {
            warning ("Can't open the book: %s", error.message);
            show_message (_ ("This file couldn't be read as an EPUB book."));
        }

        set_opening_file (false);
    }

    void show_book (LoadedBook loaded) {
        _loading_book = true;
        _book = loaded.book;
        _record = loaded.record;
        _text.show_book (loaded.book);
        _loading_book = false;

        _text.read_only = true;
        _text.clear_word_highlight ();
        _progress.set_chapters (loaded.book.chapters);
        title = loaded.book.title;

        _word_index = loaded.index;
        if (loaded.words_at_a_time != (int) _words_at_a_time.value) {
            _word_index.invalidate ();
        }

        ensure_word_index ();
        update_chapter_words ();
        go_to_offset (_record.offset);

        _stack.visible_child = _read;
    }

    /** Go back to an empty text */
    void close_book () {
        stop_reading ();
        _text.input.buffer.text = "";
    }

    void show_message (string message) {
#if GTK_4_10
        new Gtk.AlertDialog ("%s", message) {
            buttons = { _ ("_OK") },
        }.show (this);
#else
        var dialog = new Gtk.MessageDialog (
            this,
            Gtk.DialogFlags.MODAL,
            Gtk.MessageType.WARNING,
            Gtk.ButtonsType.OK,
            "%s",
            message);
        dialog.response.connect (() => {
            dialog.close ();
        });
        dialog.show ();
#endif
    }

    static Gtk.FileFilter build_epub_filter () {
        var filter = new Gtk.FileFilter () {
            name = _ ("EPUB Books"),
        };
        filter.add_mime_type ("application/epub+zip");
        filter.add_suffix ("epub");
        return filter;
    }

    void choose_file () {
#if GTK_4_10
        var dialog = new Gtk.FileDialog () {
            title = _ ("Open Book"),
            default_filter = build_epub_filter (),
        };

        dialog.open.begin (this, null, (_, result) => {
            try {
                open_file (dialog.open.end (result));
            } catch (Error error) {
                // Most likely cancelled by the user
                debug ("No file chosen: %s", error.message);
            }
        });
#else
        var dialog = new Gtk.FileChooserNative (
            _ ("Open Book"), this, Gtk.FileChooserAction.OPEN, null, null
        );
        dialog.add_filter (build_epub_filter ());
        dialog.response.connect (response => {
            if (response == Gtk.ResponseType.ACCEPT) {
                open_file (dialog.get_file ());
            }

            dialog.destroy ();
        });
        dialog.show ();
#endif
    }

    Gtk.DropTarget build_drop_target () {
        var target = new Gtk.DropTarget (typeof (Gdk.FileList), Gdk.DragAction.COPY) {
            propagation_phase = Gtk.PropagationPhase.CAPTURE,
        };

        target.drop.connect ((value, x, y) => {
            var files = ((Gdk.FileList) value.get_boxed ()).get_files ();

            if (files == null) {
                return false;
            }

            open_file (files.data);
            return true;
        });

        return target;
    }

    Gtk.Widget build_progress_side () {
        _progress = new ProgressPanel ();
        _progress.scope_changed.connect (update_time_left);
        _progress.chapter_activated.connect (go_to_chapter);

        var side = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        side.append (_progress);
        side.append (new Gtk.Separator (Gtk.Orientation.VERTICAL));

        _progress_revealer = new Gtk.Revealer () {
            child = side,
            transition_type = Gtk.RevealerTransitionType.SLIDE_RIGHT,
        };

        AppSettings.settings.bind (
            "progress-panel-visible",
            _progress_revealer, "reveal-child",
            SettingsBindFlags.GET
        );

        _progress_revealer.notify["reveal-child"].connect (update_time_left);

        return _progress_revealer;
    }

    Gtk.ToggleButton build_progress_button () {
        var button = new Gtk.ToggleButton () {
            icon_name = "sidebar-show-symbolic",
            tooltip_text = _ ("Show Side Panel (F9)"),
        };

        AppSettings.settings.bind (
            "progress-panel-visible",
            button, "active",
            SettingsBindFlags.DEFAULT
        );

        return button;
    }

    Gtk.Button build_open_button () {
        _open_button = new Gtk.Button () {
            icon_name = "document-open-symbolic",
            tooltip_text = _ ("Open Book (Ctrl+O)"),
        };

        _open_button.clicked.connect (choose_file);
        return _open_button;
    }

    Gtk.MenuButton build_recent_button () {
        var contents = new Gtk.Box (Gtk.Orientation.VERTICAL, App.MARGIN / 2);
        var popover = new Gtk.Popover () {
            child = contents,
        };

        popover.show.connect (() => {
            stop_reading ();
            fill_recent_books (contents, popover);
        });

        return new Gtk.MenuButton () {
            icon_name = "document-open-recent-symbolic",
            popover = popover,
            tooltip_text = _ ("Recent Books"),
        };
    }

    void fill_recent_books (Gtk.Box contents, Gtk.Popover popover) {
        for (var child = contents.get_first_child ();
             child != null;
             child = contents.get_first_child ()) {
            contents.remove (child);
        }

        if (_book != null) {
            var close_button = new Gtk.Button.with_label (_ ("Close Book"));
            close_button.clicked.connect (() => {
                popover.popdown ();
                close_book ();
            });
            contents.append (close_button);
        }

        var records = BookStore.recent ();

        if (records.length == 0) {
            contents.append (new Gtk.Label (_ ("No recent books")));
            return;
        }

        for (var i = 0; i < records.length; i++) {
            contents.append (build_recent_row (records[i], contents, popover));
        }
    }

    Gtk.Widget build_recent_row (
        BookRecord record,
        Gtk.Box contents,
        Gtk.Popover popover
    ) {
        var title_label = new Gtk.Label (record.title) {
            xalign = 0,
            max_width_chars = 32,
            ellipsize = Pango.EllipsizeMode.END,
        };

        // TR: Shown under a book's title. %d is how much of the book was read
        var progress_text = _ ("%d%% read").printf (record.percent);
        var details = record.author != ""
            ? "%s · %s".printf (record.author, progress_text)
            : progress_text;
        var details_label = new Gtk.Label (details) {
            xalign = 0,
            max_width_chars = 32,
            ellipsize = Pango.EllipsizeMode.END,
        };
        details_label.add_css_class ("dim-label");

        var labels = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        labels.append (title_label);
        labels.append (details_label);

        var open_button = new Gtk.Button () {
            child = labels,
            hexpand = true,
        };
        open_button.add_css_class ("flat");
        open_button.clicked.connect (() => {
            popover.popdown ();
            open_file (File.new_for_path (BookStore.epub_path (record.id)));
        });

        var remove_button = new Gtk.Button () {
            icon_name = "user-trash-symbolic",
            tooltip_text = _ ("Remove from Recent Books"),
            valign = Gtk.Align.CENTER,
            // The book being read can't lose its saved position
            sensitive = _record == null || _record.id != record.id,
        };
        remove_button.add_css_class ("flat");
        remove_button.clicked.connect (() => {
            BookStore.remove (record.id);
            fill_recent_books (contents, popover);
        });

        var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, App.MARGIN / 2);
        row.append (open_button);
        row.append (remove_button);
        return row;
    }

    Gtk.Stack build_main_stack () {
        var stack = new Gtk.Stack () {
            transition_type = Gtk.StackTransitionType.SLIDE_LEFT_RIGHT,
            margin_bottom = 18,
            margin_top = 18,
            margin_start = 18,
            margin_end = 18
        };

        build_text_tab ();
        build_read_tab ();

        stack.add_titled (_text, "Text", _ ("Text"));
        stack.add_titled (_read, "Read", _ ("Read"));

        return stack;
    }

    void build_read_tab () {
        _read = new ReadTab ();

        _read.start_reading.connect (start_reading);
        _read.stop_reading.connect (stop_reading);

        _read.previous_word.connect (() => {
            if (can_click_previous_word ()) {
                _current_word--;
                show_word (_current_word);
                update_word_navigation ();
                update_text_position ();
                update_time_left ();
            }
        });

        _read.next_word.connect (() => {
            if (can_click_next_word ()) {
                tick ();
                update_word_navigation ();
                update_text_position ();
                update_time_left ();
            }
        });
    }

    void build_text_tab () {
        _text = new TextTab ();
    }

    Gtk.Button build_new_window_button () {
        var button = new Gtk.Button () {
            icon_name = "window-new-symbolic",
            tooltip_text = _ ("New Window (Ctrl+N)"),
        };

        button.clicked.connect (() => {
            new MainWindow (application).present ();
        });

        return button;
    }

    Gtk.MenuButton build_menu_button () {
        var settings = AppSettings.settings;
        var is_using_libadwaita = AppSettings.is_using_libadwaita;

        var contents = new Gtk.Grid () {
            column_spacing = App.MARGIN,
            row_spacing = is_using_libadwaita ? App.MARGIN : 0,
            margin_start = App.MARGIN / 2,
            margin_end = App.MARGIN / 2,
            margin_top = is_using_libadwaita ? App.MARGIN / 2 : 0,
            margin_bottom = is_using_libadwaita ? App.MARGIN / 2 : 0,
        };

        var popover = new Gtk.Popover () {
            child = contents,
        };

        var button = new Gtk.MenuButton () {
            icon_name = "open-menu-symbolic",
            popover = popover,
            tooltip_text = _ ("Main Menu"),
        };

        _ms_per_word = new Gtk.SpinButton (null, 25, 0);
        _ms_per_word.set_increments (25, 50);
        _ms_per_word.set_range (25, 2000);
        _ms_per_word.value_changed.connect (() => {
            if (!_read.is_playing) {
                update_time_left ();
            }
        });
        settings.bind (
            "milliseconds-per-word",
            _ms_per_word, "value",
            SettingsBindFlags.DEFAULT
        );

        _words_at_a_time = new Gtk.SpinButton (null, 25, 0);
        _words_at_a_time.set_increments (1, 2);
        _words_at_a_time.set_range (1, 10);

        settings.bind (
            "words-at-a-time",
            _words_at_a_time, "value",
            SettingsBindFlags.DEFAULT
        );

        _words_at_a_time.value_changed.connect (words_at_a_time_changed);

#if GTK_4_10
        var font_dialog = new Gtk.FontDialog ();
        _font_chooser = new Gtk.FontDialogButton (font_dialog);
        settings.bind_with_mapping (
            "reading-font",
            _font_chooser, "font-desc",
            SettingsBindFlags.DEFAULT,
            (target, gotten) => { // get from settings
                var font_string = gotten.get_string ();
                var font = Pango.FontDescription.from_string (font_string);
                target.set_boxed (font);
                return true;
            },
            value => { // set to settings
                var font = (Pango.FontDescription) value;
                return font.to_string ();
            },
            null, null
        );
#else
        _font_chooser = new Gtk.FontButton ();
        settings.bind (
            "reading-font",
            _font_chooser, "font",
            SettingsBindFlags.DEFAULT
        );
#endif
        var font_chooser_button = (Gtk.Button) _font_chooser.get_first_child ();
        font_chooser_button.clicked.connect (() => {
            popover.popdown ();
        });

        settings.bind (
            "reading-font",
            _read, "font",
            SettingsBindFlags.GET
        );

        var pivot_enabled = new Gtk.Switch () {
            halign = Gtk.Align.END,
        };
        settings.bind (
            "pivot-enabled",
            pivot_enabled, "active",
            SettingsBindFlags.DEFAULT
        );
        pivot_enabled.state_set.connect (new_state => {
            _read.user_enabled_pivot = new_state;
            return false;
        });
        _read.user_enabled_pivot = settings.get_boolean ("pivot-enabled");

        var bionic_enabled = new Gtk.Switch () {
            halign = Gtk.Align.END,
        };
        settings.bind (
            "bionic-enabled",
            bionic_enabled, "active",
            SettingsBindFlags.DEFAULT
        );
        bionic_enabled.state_set.connect (new_state => {
            _read.user_enabled_bionic = new_state;
            return false;
        });
        _read.user_enabled_bionic = settings.get_boolean ("bionic-enabled");

        var use_libadwaita = new Gtk.Switch () {
            halign = Gtk.Align.END,
        };
        settings.bind (
            "use-libadwaita",
            use_libadwaita, "active",
            SettingsBindFlags.DEFAULT
        );
        use_libadwaita.state_set.connect (new_state => {
            // Warn the user that the change will only be applied after an app
            // restart. `is_active` is there to make sure only the focused
            // window displays the warning
            if (is_active && new_state != AppSettings.is_using_libadwaita) {
                popover.popdown ();

                show_message (_ (
                    "This change will only be applied after you restart Spedread"));
            }

            // Set the state (see `Gtk.Switch.state_set`)
            return false;
        });

        _theme_chooser = new Gtk.DropDown.from_strings ({
            // TR: Reading theme following the system's light or dark preference
            _ ("System"),
            _ ("Light"),
            _ ("Sepia"),
            _ ("Dark"),
        });

        select_current_theme ();
        settings.changed["reading-theme"].connect (select_current_theme);
        _theme_chooser.notify["selected"].connect (() => {
            var chosen = ThemeManager.THEMES[_theme_chooser.selected];

            if (settings.get_string ("reading-theme") != chosen) {
                settings.set_string ("reading-theme", chosen);
            }
        });

        var about_button = new Gtk.Button.with_label (_ ("About Spedread..."));
        about_button.clicked.connect (() => {
            popover.popdown ();

            // TR: "Name <email@domain.com>", "Name https://website.example" or "Name"
            var translator_credits = _ ("translator-credits");
            var catchphrase = _ ("Read like a speedrunner!");
            var authors = new string[] {
                "Naqua Darazaki <n.darazaki@gmail.com>",
            };

#if ADW_1_5
            if (AppSettings.is_using_libadwaita) {
                Adw.show_about_dialog_from_appdata (this,
                    application.resource_base_path + "/appdata.xml", VERSION,
                    "comments", catchphrase,
                    "translator-credits", translator_credits,
                    "developers", authors,
                    null
                );

                return;
            }
#elif ADW_1_2
            if (AppSettings.is_using_libadwaita) {
                var win = new Adw.AboutWindow () {
                    application_name = "Spedread",
                    application_icon = "com.github.Darazaki.Spedread",
                    version = VERSION,
                    comments = catchphrase,
                    translator_credits = translator_credits,
                    license_type = Gtk.License.GPL_3_0,
                    developers = authors,
                    website = "https://github.com/Darazaki/Spedread",
                };
                win.set_transient_for (this);
                win.show ();

                return;
            }
#endif

            Gtk.show_about_dialog (this,
                "program-name", "Spedread",
                "website", "https://github.com/Darazaki/Spedread",
                "license-type", Gtk.License.GPL_3_0,
                "logo-icon-name", "com.github.Darazaki.Spedread",
                "comments", catchphrase,
                "translator-credits", translator_credits,
                "version", VERSION,
                "authors", authors
            );
        });

        contents.attach (new Gtk.Label (_ ("Milliseconds per Word")), 0, 0, 1, 1);
        contents.attach (_ms_per_word, 1, 0, 1, 1);
        contents.attach (new Gtk.Label (_ ("Words at a Time")), 0, 1, 1, 1);
        contents.attach (_words_at_a_time, 1, 1, 1, 1);
        contents.attach (new Gtk.Label (_ ("Reading Font")), 0, 2, 1, 1);
        contents.attach (_font_chooser, 1, 2, 1, 1);
        contents.attach (new Gtk.Label (_ ("Fixed Pivot")), 0, 3, 1, 1);
        contents.attach (pivot_enabled, 1, 3, 1, 1);
        contents.attach (new Gtk.Label (_ ("Bionic Reading")), 0, 4, 1, 1);
        contents.attach (bionic_enabled, 1, 4, 1, 1);
        contents.attach (new Gtk.Label (_ ("Theme")), 0, 5, 1, 1);
        contents.attach (_theme_chooser, 1, 5, 1, 1);
        contents.attach (new Gtk.Label (_ ("Use libadwaita")), 0, 6, 1, 1);
        contents.attach (use_libadwaita, 1, 6, 1, 1);
        contents.attach (about_button, 0, 7, 2, 1);

        popover.show.connect (popover_shown);

        return button;
    }

    /** Show the saved theme in the main menu */
    void select_current_theme () {
        var current = AppSettings.settings.get_string ("reading-theme");

        for (var i = 0; i < ThemeManager.THEMES.length; i++) {
            if (ThemeManager.THEMES[i] == current) {
                _theme_chooser.selected = i;
            }
        }
    }

    /** Replaces the text to read with the clipboard's content */
    void quick_paste () {
        // Make sure pasting the text stops the current reading
        stop_reading ();

        var clipboard = Gdk.Display.get_default ().get_clipboard ();

        // Attempt reading text from the clipboard
        clipboard.read_text_async.begin (null, (_, result) => {
            // The clipboard's content may or may to be convertible into
            // text. If it isn't: return
            string? maybe_text;
            try {
                maybe_text = clipboard.read_text_async.end (result);
            } catch {
                return;
            }

            if (maybe_text != null) {
                // Update the text (all the annoying stuff should be automatic)
                _text.input.buffer.text = maybe_text;
            }
        });
    }

    Gtk.Button build_quick_paste_button () {
        var button = new Gtk.Button () {
            icon_name = "edit-paste-symbolic",
            tooltip_text = _ ("Paste (Ctrl+P)"),
        };

        button.clicked.connect (quick_paste);
        return button;
    }

    void switch_tab () {
        _stack.visible_child = _stack.visible_child == _read
            ? (Gtk.Widget) _text
            : (Gtk.Widget) _read;
    }

    void toggle_reading () {
        if (!_read.allow_playing)
            return;

        if (_read.is_playing)
            stop_reading ();
        else
            start_reading ();
    }

    void define_shortcuts () {
        const Gdk.ModifierType CTRL = Gdk.ModifierType.CONTROL_MASK;
        const Gdk.ModifierType CTRL_SHIFT = CTRL | Gdk.ModifierType.SHIFT_MASK;

        // Quick paste
        add_new_shortcut (CTRL, Gdk.Key.P, quick_paste);
        add_new_shortcut (CTRL_SHIFT, Gdk.Key.V, quick_paste);

        // Switch tabs
        add_new_shortcut (CTRL, Gdk.Key.Tab, switch_tab);
        add_new_shortcut (CTRL, Gdk.Key.KP_Tab, switch_tab);
        add_new_shortcut (CTRL_SHIFT, Gdk.Key.Tab, switch_tab);
        add_new_shortcut (CTRL_SHIFT, Gdk.Key.KP_Tab, switch_tab);

        // Open a book
        add_new_shortcut (CTRL, Gdk.Key.O, () => {
            if (!_is_opening_file) {
                choose_file ();
            }
        });

        // Show or hide the progress panel
        add_new_shortcut (0, Gdk.Key.F9, () => {
            var settings = AppSettings.settings;
            settings.set_boolean (
                "progress-panel-visible",
                !settings.get_boolean ("progress-panel-visible")
            );
        });

        // Search text
        add_new_shortcut (CTRL, Gdk.Key.F, () => {
            _text.search_bar.toggle_search_visible_focused ();
        }, is_tab_text);

        // New window
        add_new_shortcut (CTRL, Gdk.Key.N, () => {
            new MainWindow (application).present ();
        });

        // Previous word
        add_new_shortcut (0, Gdk.Key.Left, () => _read.previous_word (), should_handle_reading_keys);
        add_new_shortcut (0, Gdk.Key.KP_Left, () => _read.previous_word (), should_handle_reading_keys);

        // Next word
        add_new_shortcut (0, Gdk.Key.Right, () => _read.next_word (), should_handle_reading_keys);
        add_new_shortcut (0, Gdk.Key.KP_Right, () => _read.next_word (), should_handle_reading_keys);

        // Toggle reading
        add_new_shortcut (0, Gdk.Key.space, toggle_reading, should_handle_reading_keys);
        add_new_shortcut (0, Gdk.Key.Return, toggle_reading, should_handle_reading_keys);
        add_new_shortcut (0, Gdk.Key.KP_Space, toggle_reading, should_handle_reading_keys);
        add_new_shortcut (0, Gdk.Key.KP_Enter, toggle_reading, should_handle_reading_keys);
    }
}
