class Spedread.TextTab : Gtk.Box {
    /** Contains the text the user wants to read */
    public Gtk.TextView input;
    public SearchBar search_bar;

    const string BIGGER_TEXT_TAG_NAME = "bigger-text";
    const int TEXT_SIZE = 12;
    const int HEADING_SIZE = 18;

    TagManager _tag_manager;
    Gtk.TextTag _heading_tag;
    Gtk.TextTag _bold_tag;
    Gtk.TextTag _italic_tag;

    /** Whether the text can only be read, which is the case for books */
    public bool read_only {
        set {
            input.editable = !value;
            input.cursor_visible = !value;
        }
    }

    /** Manages tags that are applied to portions the main text view */
    public class TagManager {
        public Gtk.TextTag next_word;
        public Gtk.TextTag needle;
        public Gtk.TextTag selected_needle;

        public TagManager (Gtk.TextBuffer buffer) {
            // Priority order is in reversed definition order
            next_word = new_tag (buffer, "next-word", "purple", "white");
            needle = new_tag (buffer, "needle", "yellow", "black");
            selected_needle = new_tag (buffer, "selected-needle", "orange", "black");
        }

        /** Add tag to highlight text to the buffer */
        static Gtk.TextTag new_tag (
            Gtk.TextBuffer buffer,
            string tag_name,
            string background,
            string foreground
        ) {
            var tag = buffer.create_tag (tag_name);
            tag.background = background;
            tag.background_set = true;
            tag.foreground = foreground;
            tag.foreground_set = true;
            return tag;
        }

        static void set_colors (Gtk.TextTag tag, string background, string foreground) {
            tag.background = background;
            tag.foreground = foreground;
        }

        /** Use colors that are readable with the current theme */
        public void apply_palette (ThemePalette palette) {
            set_colors (next_word, palette.word_background, palette.word_foreground);
            set_colors (needle, palette.match_background, palette.match_foreground);
            set_colors (
                selected_needle,
                palette.selected_match_background,
                palette.selected_match_foreground
            );
        }
    }

    public TextTab () {
        Object (
            orientation: Gtk.Orientation.VERTICAL,
            hexpand: true,
            vexpand: true,
            spacing: App.MARGIN
        );

        input = new Gtk.TextView () {
            wrap_mode = Gtk.WrapMode.WORD,
            bottom_margin = App.MARGIN,
            top_margin = App.MARGIN,
            right_margin = App.MARGIN,
            left_margin = App.MARGIN,
        };

        var buffer = input.buffer;
        _tag_manager = new TagManager (buffer);

        var scrolled = new Gtk.ScrolledWindow () {
            child = input,
            hexpand = true,
            vexpand = true,
        };

        search_bar = new SearchBar (input, _tag_manager) {
            visible = false,
        };

        var bigger_text = buffer.create_tag (BIGGER_TEXT_TAG_NAME, "size", TEXT_SIZE * Pango.SCALE);
        buffer.changed.connect (buffer => {
            // Reapply the tag to make sure that it covers the whole text
            var bounds = TextBounds.of (buffer);
            bounds.remove_tag (bigger_text);
            bounds.apply_tag (bigger_text);
        });

        // Tags created later take priority over the text size set above
        _heading_tag = buffer.create_tag (
            "book-heading",
            "size", HEADING_SIZE * Pango.SCALE,
            "weight", Pango.Weight.BOLD
        );
        _bold_tag = buffer.create_tag ("book-bold", "weight", Pango.Weight.BOLD);
        _italic_tag = buffer.create_tag ("book-italic", "style", Pango.Style.ITALIC);

        append (scrolled);
        append (search_bar);
    }

    /** Use colors that are readable with the current theme */
    public void apply_palette (ThemePalette palette) {
        _tag_manager.apply_palette (palette);
    }

    /** Replace the text with a formatted book */
    public void show_book (Book book) {
        var buffer = input.buffer;
        buffer.text = book.text;

        foreach (var style in book.styles) {
            Gtk.TextIter start, end;
            buffer.get_iter_at_offset (out start, style.start);
            buffer.get_iter_at_offset (out end, style.end);
            buffer.apply_tag (tag_for (style.kind), start, end);
        }

        Gtk.TextIter beginning;
        buffer.get_start_iter (out beginning);
        buffer.place_cursor (beginning);
    }

    Gtk.TextTag tag_for (StyleKind kind) {
        switch (kind) {
            case StyleKind.HEADING:
                return _heading_tag;
            case StyleKind.BOLD:
                return _bold_tag;
            default:
                return _italic_tag;
        }
    }

    /** Highlight the text between `bounds`, removing any other highlight */
    public void highlight_current_word (TextBounds bounds) {
        var buffer = input.buffer;
        var absolute_bounds = TextBounds.of (buffer);
        var tag = _tag_manager.next_word;
        absolute_bounds.remove_tag (tag);
        bounds.apply_tag (tag);
    }

    /** Remove the highlight around the word being read */
    public void clear_word_highlight () {
        TextBounds.of (input.buffer).remove_tag (_tag_manager.next_word);
    }

    /** Scroll the text so that the `position` is as close to the center as
        possible */
    public void scroll_to_position (Gtk.TextIter position) {
        input.scroll_to_iter (position, 0, true, 0, 0.5);
    }
}
