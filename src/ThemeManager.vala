/** Colors that can't come from the toolkit's stylesheet */
class Spedread.ThemePalette {
    public Gdk.RGBA pivot;
    public string word_background;
    public string word_foreground;
    public string match_background;
    public string match_foreground;
    public string selected_match_background;
    public string selected_match_foreground;

    public ThemePalette (
        string pivot,
        string word_background, string word_foreground,
        string match_background, string match_foreground,
        string selected_match_background, string selected_match_foreground
    ) {
        this.pivot = Gdk.RGBA ();
        this.pivot.parse (pivot);
        this.word_background = word_background;
        this.word_foreground = word_foreground;
        this.match_background = match_background;
        this.match_foreground = match_foreground;
        this.selected_match_background = selected_match_background;
        this.selected_match_foreground = selected_match_foreground;
    }
}

/** Applies the reading theme chosen by the user to the whole application */
class Spedread.ThemeManager : Object {
    public const string SEPIA_CLASS = "sepia";

    /** Values of the `reading-theme` setting */
    public const string[] THEMES = { "system", "light", "sepia", "dark" };

    const string SEPIA_CSS = """
window.sepia {
    --window-bg-color: #f4ecd8;
    --window-fg-color: #433422;
    --view-bg-color: #fbf5e6;
    --view-fg-color: #433422;
    --headerbar-bg-color: #eadfc6;
    --headerbar-fg-color: #433422;
    --headerbar-backdrop-color: #f4ecd8;
    --popover-bg-color: #fbf5e6;
    --popover-fg-color: #433422;
    --sidebar-bg-color: #eadfc6;
    --sidebar-fg-color: #433422;
    --accent-bg-color: #8a5a24;
    --accent-fg-color: #fff8e7;
    --accent-color: #7a4a1e;
    background-color: #f4ecd8;
    color: #433422;
}

window.sepia textview,
window.sepia textview > text {
    background-color: #fbf5e6;
    color: #433422;
}
""";

#if GTK_4_20
    const string COLOR_SCHEME_PROPERTY = "gtk-interface-color-scheme";
#else
    const string COLOR_SCHEME_PROPERTY = "gtk-application-prefer-dark-theme";
#endif

    static ThemeManager? _instance = null;

    ThemePalette _light = new ThemePalette (
        "#c01c28", "#613583", "#ffffff", "#f8e45c", "#000000", "#ff9f40", "#000000"
    );
    ThemePalette _dark = new ThemePalette (
        "#ff7b72", "#c9a7eb", "#1e1e1e", "#f5c211", "#000000", "#ffa348", "#000000"
    );
    ThemePalette _sepia = new ThemePalette (
        "#a51d2d", "#7a4a1e", "#fff8e7", "#e8c547", "#2b2113", "#d98e3a", "#2b2113"
    );

    /** When the colors to use may have changed */
    public signal void changed ();

    public string theme {
        owned get { return AppSettings.settings.get_string ("reading-theme"); }
    }

    public bool is_sepia {
        get { return theme == "sepia"; }
    }

    public ThemePalette palette {
        get {
            if (is_sepia) {
                return _sepia;
            }

            return is_dark () ? _dark : _light;
        }
    }

    public static ThemeManager get_default () {
        if (_instance == null) {
            _instance = new ThemeManager ();
        }

        return _instance;
    }

    /** Start applying the theme. The display must be available. */
    public void start () {
        var provider = new Gtk.CssProvider ();
        provider.load_from_data (SEPIA_CSS.data);
        Gtk.StyleContext.add_provider_for_display (
            Gdk.Display.get_default (),
            provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        );

        AppSettings.settings.changed["reading-theme"].connect (apply);

        if (AppSettings.is_using_libadwaita) {
            Adw.StyleManager.get_default ().notify["dark"].connect (() => changed ());
        } else {
            Gtk.Settings.get_default ().notify[COLOR_SCHEME_PROPERTY]
                .connect (() => changed ());
        }

        apply ();
    }

    bool is_dark () {
        if (AppSettings.is_using_libadwaita) {
            return Adw.StyleManager.get_default ().dark;
        }

#if GTK_4_20
        return Gtk.Settings.get_default ().gtk_interface_color_scheme
            == Gtk.InterfaceColorScheme.DARK;
#else
        return Gtk.Settings.get_default ().gtk_application_prefer_dark_theme;
#endif
    }

    void apply () {
        var current = theme;

        if (AppSettings.is_using_libadwaita) {
            var scheme = Adw.ColorScheme.DEFAULT;

            if (current == "dark") {
                scheme = Adw.ColorScheme.FORCE_DARK;
            } else if (current != "system") {
                scheme = Adw.ColorScheme.FORCE_LIGHT;
            }

            Adw.StyleManager.get_default ().color_scheme = scheme;
        } else {
            var settings = Gtk.Settings.get_default ();

            if (current == "system") {
                settings.reset_property (COLOR_SCHEME_PROPERTY);
            } else {
#if GTK_4_20
                settings.gtk_interface_color_scheme = current == "dark"
                    ? Gtk.InterfaceColorScheme.DARK
                    : Gtk.InterfaceColorScheme.LIGHT;
#else
                settings.gtk_application_prefer_dark_theme = current == "dark";
#endif
            }
        }

        changed ();
    }
}
