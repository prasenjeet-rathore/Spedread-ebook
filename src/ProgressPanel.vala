/** Shows the reading progress and the table of contents */
class Spedread.ProgressPanel : Gtk.Box {
    const string SCOPE_KEY = "progress-scope";
    const int PANEL_WIDTH = 200;

    Gtk.ToggleButton _chapter_button;
    Gtk.ToggleButton _book_button;
    Gtk.Label _title;
    Gtk.ProgressBar _bar;
    Gtk.Label _percent;
    Gtk.Label _position;
    Gtk.Label _time_left;
    Gtk.Stack _pages;
    Gtk.ListBox _chapters;
    Gtk.ScrolledWindow _chapters_scroll;
    int _current_chapter = -1;

    /** When the user picks a chapter in the table of contents */
    public signal void chapter_activated (int index);

    /** When the user chooses what progress is measured against */
    public signal void scope_changed ();

    /** Whether progress is currently measured against the chapter */
    public bool uses_chapter_scope {
        get { return _chapter_button.sensitive && _chapter_button.active; }
    }

    public ProgressPanel () {
        Object (
            orientation: Gtk.Orientation.VERTICAL,
            spacing: App.MARGIN,
            width_request: PANEL_WIDTH,
            hexpand: false,
            margin_start: 18,
            margin_end: 18,
            margin_top: 18,
            margin_bottom: 18
        );

        _chapter_button = new Gtk.ToggleButton.with_label (_ ("Chapter")) {
            hexpand = true,
            sensitive = false,
        };
        _book_button = new Gtk.ToggleButton.with_label (_ ("Whole Book")) {
            hexpand = true,
            group = _chapter_button,
        };

        var scope_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        scope_box.add_css_class ("linked");
        scope_box.append (_chapter_button);
        scope_box.append (_book_button);

        _title = new_label ();
        _title.wrap = true;
        _title.wrap_mode = Pango.WrapMode.WORD_CHAR;
        _title.max_width_chars = 20;
        _title.add_css_class ("heading");

        _bar = new Gtk.ProgressBar ();

        _percent = new_label ();
        _percent.add_css_class ("title-1");
        _position = new_label ();
        _time_left = new_label ();

        var progress_page = new Gtk.Box (Gtk.Orientation.VERTICAL, App.MARGIN);
        progress_page.append (scope_box);
        progress_page.append (_title);
        progress_page.append (_bar);
        progress_page.append (_percent);
        progress_page.append (_position);
        progress_page.append (_time_left);

        _chapters = new Gtk.ListBox () {
            selection_mode = Gtk.SelectionMode.SINGLE,
        };
        _chapters.add_css_class ("navigation-sidebar");
        _chapters.set_placeholder (new Gtk.Label (_ ("No chapters")) {
            margin_top = App.MARGIN,
        });
        _chapters.row_activated.connect (row => chapter_activated (row.get_index ()));

        _chapters_scroll = new Gtk.ScrolledWindow () {
            child = _chapters,
            hscrollbar_policy = Gtk.PolicyType.NEVER,
            vexpand = true,
        };

        _pages = new Gtk.Stack () {
            vexpand = true,
        };
        _pages.add_titled (progress_page, "progress", _ ("Progress"));
        _pages.add_titled (_chapters_scroll, "contents", _ ("Contents"));

        append (new Gtk.StackSwitcher () {
            stack = _pages,
        });
        append (_pages);

        var settings = AppSettings.settings;
        settings.bind (
            "side-panel-view",
            _pages, "visible-child-name",
            SettingsBindFlags.DEFAULT
        );
        _pages.notify["visible-child"].connect (() => {
            // The rows only have a position once they've been laid out
            Idle.add (() => {
                reveal_current_chapter ();
                return false;
            });
        });

        settings.changed[SCOPE_KEY].connect (load_scope);
        load_scope ();

        _chapter_button.toggled.connect (save_scope);
        clear ();
    }

    static Gtk.Label new_label () {
        return new Gtk.Label (null) {
            xalign = 0,
        };
    }

    void load_scope () {
        var use_chapter = AppSettings.settings.get_string (SCOPE_KEY) == "chapter";
        _chapter_button.active = use_chapter;
        _book_button.active = !use_chapter;
    }

    void save_scope () {
        var scope = _chapter_button.active ? "chapter" : "book";

        if (AppSettings.settings.get_string (SCOPE_KEY) != scope) {
            AppSettings.settings.set_string (SCOPE_KEY, scope);
        }

        scope_changed ();
    }

    /** Replace the table of contents. No chapters means plain text. */
    public void set_chapters (Chapter[] chapters) {
        _chapter_button.sensitive = chapters.length > 0;
        _current_chapter = -1;

        Gtk.ListBoxRow? row;
        while ((row = _chapters.get_row_at_index (0)) != null) {
            _chapters.remove (row);
        }

        foreach (var chapter in chapters) {
            _chapters.append (new Gtk.Label (chapter.title) {
                xalign = 0,
                wrap = true,
                wrap_mode = Pango.WrapMode.WORD_CHAR,
                max_width_chars = 20,
            });
        }
    }

    void select_chapter (int index) {
        if (index == _current_chapter) {
            return;
        }

        _current_chapter = index;
        _chapters.select_row (index >= 0 ? _chapters.get_row_at_index (index) : null);
        reveal_current_chapter ();
    }

    /** Scroll the table of contents to the current chapter */
    void reveal_current_chapter () {
        var row = _chapters.get_selected_row ();

        if (row == null || _pages.visible_child != _chapters_scroll) {
            return;
        }

        var origin = Graphene.Point ();
        origin.x = 0;
        origin.y = 0;

        Graphene.Point position;
        if (row.compute_point (_chapters, origin, out position)) {
            _chapters_scroll.vadjustment.clamp_page (
                position.y,
                position.y + row.get_height ()
            );
        }
    }

    /** Show `done` steps out of `total` inside chapter `chapter`, if any */
    public void update (
        string title,
        int chapter,
        int done,
        int total,
        int words_at_a_time,
        string time_left
    ) {
        select_chapter (chapter);

        var fraction = total > 0 ? (double) done / total : 0.0;

        _title.label = title;
        _title.visible = title != "";
        _bar.fraction = fraction.clamp (0.0, 1.0);
        // TR: Reading progress, for example "42%"
        _percent.label = _ ("%d%%").printf ((int) (fraction * 100));
        _position.label = words_at_a_time == 1
            ? _ ("Word %d of %d").printf (done, total)
            : _ ("Group %d of %d").printf (done, total);
        _time_left.label = time_left;
    }

    /** Show that there's nothing to measure */
    public void clear () {
        select_chapter (-1);
        _title.label = "";
        _title.visible = false;
        _bar.fraction = 0;
        _percent.label = "—";
        _position.label = _ ("No text to read yet");
        _time_left.label = "";
    }
}
