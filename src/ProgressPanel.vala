/** Shows how far the reader is in the current chapter or in the whole text */
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

    /** When the user chooses what progress is measured against */
    public signal void scope_changed ();

    /** Whether progress is currently measured against the chapter */
    public bool uses_chapter_scope {
        get { return _chapter_button.sensitive && _chapter_button.active; }
    }

    /** Whether the text has chapters at all */
    public bool has_chapters {
        set { _chapter_button.sensitive = value; }
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

        append (scope_box);
        append (_title);
        append (_bar);
        append (_percent);
        append (_position);
        append (_time_left);

        var settings = AppSettings.settings;
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

    /** Show `done` steps out of `total` */
    public void update (
        string title,
        int done,
        int total,
        int words_at_a_time,
        string time_left
    ) {
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
        _title.label = "";
        _title.visible = false;
        _bar.fraction = 0;
        _percent.label = "—";
        _position.label = _ ("No text to read yet");
        _time_left.label = "";
    }
}
