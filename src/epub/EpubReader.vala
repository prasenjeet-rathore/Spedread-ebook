errordomain Spedread.EpubError {
    INVALID,
    DRM_PROTECTED,
    NO_TEXT,
    TOO_LARGE,
}

/** Extracts the readable text and structure of an EPUB held in memory.
    Nothing is ever written to disk and no network access is allowed. EPUB files
    are untrusted so every decompressed size is limited. */
class Spedread.EpubReader {
    const string[] FONT_OBFUSCATION_ALGORITHMS = {
        "http://www.idpf.org/2008/embedding",
        "http://ns.adobe.com/pdf/enc#RC",
    };

    const int XML_OPTIONS =
        Xml.ParserOption.NONET | Xml.ParserOption.NOERROR | Xml.ParserOption.NOWARNING;
    const int HTML_OPTIONS =
        Html.ParserOption.NONET | Html.ParserOption.NOERROR
        | Html.ParserOption.NOWARNING | Html.ParserOption.RECOVER;

    class ManifestItem {
        public string path;
        public string media_type;
        public bool is_nav;
    }

    class TocEntry {
        public string title;
        public string path;
        public string? fragment;
    }

    class SpineDocument {
        public string path;
        public int start;
        public string? heading;
    }

    /** Largest allowed size of one decompressed file */
    public int64 max_entry_size = 64 * 1024 * 1024;

    /** Largest allowed size of everything decompressed for one book */
    public int64 max_total_size = 512 * 1024 * 1024;

    /** Largest allowed number of files inside the archive */
    public int max_entries = 50000;

    Bytes _data;
    int64 _total_size = 0;

    string _opf_path = "";
    Book _book = new Book ();
    HashTable<string, ManifestItem> _manifest =
        new HashTable<string, ManifestItem> (str_hash, str_equal);
    GenericArray<ManifestItem> _spine = new GenericArray<ManifestItem> ();
    string? _ncx_id = null;

    StringBuilder _text = new StringBuilder ();
    int _char_count = 0;
    int _trailing_newlines = 0;
    bool _pending_space = false;
    int _heading_depth = 0;
    StringBuilder _heading = new StringBuilder ();
    StyleSpan[] _styles = {};

    string _current_path = "";
    GenericSet<string> _wanted_anchors = new GenericSet<string> (str_hash, str_equal);
    HashTable<string, int> _anchors = new HashTable<string, int> (str_hash, str_equal);

    delegate bool NameFilter (string name);

    public EpubReader (Bytes data) {
        _data = data;
    }

    /** Parse the whole book */
    public Book read () throws EpubError {
        var meta = read_entries (name => {
            return name == "META-INF/container.xml"
                || name == "META-INF/encryption.xml";
        });

        var container = meta["META-INF/container.xml"];
        if (container == null) {
            throw new EpubError.INVALID ("Missing META-INF/container.xml");
        }

        _opf_path = find_opf_path (container);
        var opf_name = _opf_path;
        var opf = read_entries (name => name == opf_name)[opf_name];
        if (opf == null) {
            throw new EpubError.INVALID ("Missing package document");
        }

        parse_opf (opf);
        check_encryption (meta["META-INF/encryption.xml"]);

        var wanted = new GenericSet<string> (str_hash, str_equal);
        _spine.foreach (item => wanted.add (item.path));

        ManifestItem? nav = null;
        ManifestItem? ncx = find_ncx ();
        _manifest.foreach ((id, item) => {
            if (item.is_nav) {
                nav = item;
            }
        });

        if (nav != null) {
            wanted.add (nav.path);
        }

        if (ncx != null) {
            wanted.add (ncx.path);
        }

        var files = read_entries (name => wanted.contains (name));

        var toc = new GenericArray<TocEntry> ();
        if (nav != null && files.contains (nav.path)) {
            toc = parse_nav (files[nav.path], nav.path);
        }

        if (toc.length == 0 && ncx != null && files.contains (ncx.path)) {
            toc = parse_ncx (files[ncx.path], ncx.path);
        }

        toc.foreach (entry => {
            if (entry.fragment != null) {
                _wanted_anchors.add (entry.path + "#" + entry.fragment);
            }
        });

        var documents = new GenericArray<SpineDocument> ();
        for (var i = 0; i < _spine.length; i++) {
            var item = _spine[i];
            var content = files[item.path];

            if (content != null) {
                documents.add (read_document (content, item.path));
            }
        }

        _book.text = _text.str.chomp ();
        _char_count = _book.text.char_count ();

        if (_book.text.strip () == "") {
            throw new EpubError.NO_TEXT ("The book has no readable text");
        }

        _book.styles = _styles;
        _book.chapters = build_chapters (toc, documents);

        if (_book.title == "") {
            _book.title = _ ("Untitled Book");
        }

        return _book;
    }

    /** Decompress the wanted files, each followed by a NUL byte */
    HashTable<string, Bytes> read_entries (NameFilter wanted) throws EpubError {
        var result = new HashTable<string, Bytes> (str_hash, str_equal);
        var archive = new Archive.Read ();
        archive.support_format_zip ();

        unowned uint8[] data = _data.get_data ();
        if (data == null || archive.open_memory (data) != Archive.Result.OK) {
            throw new EpubError.INVALID ("Not a ZIP archive");
        }

        var buffer = new uint8[64 * 1024];
        var entry_count = 0;

        for ( ;; ) {
            unowned Archive.Entry entry;
            var status = archive.next_header (out entry);

            if (status == Archive.Result.EOF) {
                break;
            } else if (status != Archive.Result.OK && status != Archive.Result.WARN) {
                throw new EpubError.INVALID ("Damaged archive");
            }

            if (++entry_count > max_entries) {
                throw new EpubError.TOO_LARGE ("Too many files in the archive");
            }

            unowned string? raw_name = entry.pathname ();
            var name = raw_name != null && raw_name.validate ()
                ? normalize_path ("", raw_name, false)
                : null;

            if (name == null || !wanted (name)) {
                continue;
            }

            var content = new ByteArray ();
            for ( ;; ) {
                var count = archive.read_data (buffer);

                if (count < 0) {
                    throw new EpubError.INVALID ("Damaged or encrypted archive entry");
                } else if (count == 0) {
                    break;
                }

                _total_size += count;
                if (content.len + count > max_entry_size || _total_size > max_total_size) {
                    throw new EpubError.TOO_LARGE ("The book is too large");
                }

                content.append (buffer[0:count]);
            }

            content.append ({ 0 });
            result[name] = ByteArray.free_to_bytes ((owned) content);
        }

        return result;
    }

    /** Resolve `href` against a directory, returning its path inside the
        archive or null when it points outside of the archive */
    static string? normalize_path (string directory, string href, bool decode = true) {
        var path = href;

        if (decode) {
            var cut = path.index_of_char ('#');
            if (cut >= 0) {
                path = path[0:cut];
            }

            cut = path.index_of_char ('?');
            if (cut >= 0) {
                path = path[0:cut];
            }

            if (Uri.parse_scheme (path) != null) {
                return null;
            }

            path = Uri.unescape_string (path) ?? path;
        }

        var full = path.has_prefix ("/") ? path : directory + path;
        var parts = new GenericArray<string> ();

        foreach (var part in full.split ("/")) {
            if (part == "" || part == ".") {
                continue;
            } else if (part == "..") {
                if (parts.length == 0) {
                    return null;
                }

                parts.remove_index (parts.length - 1);
            } else {
                parts.add (part);
            }
        }

        if (parts.length == 0) {
            return null;
        }

        var result = new StringBuilder (parts[0]);
        for (var i = 1; i < parts.length; i++) {
            result.append_c ('/');
            result.append (parts[i]);
        }

        return result.str;
    }

    static string directory_of (string path) {
        var slash = path.last_index_of_char ('/');
        return slash >= 0 ? path[0:slash + 1] : "";
    }

    static string? fragment_of (string href) {
        var hash = href.index_of_char ('#');
        if (hash < 0 || hash + 1 >= href.length) {
            return null;
        }

        var fragment = href[hash + 1:href.length];
        return Uri.unescape_string (fragment) ?? fragment;
    }

    static string collapse_whitespace (string text) {
        var result = new StringBuilder ();
        var pending_space = false;
        var index = 0;
        unichar character;

        while (text.get_next_char (ref index, out character)) {
            if (character.isspace ()) {
                pending_space = result.len > 0;
            } else {
                if (pending_space) {
                    result.append_c (' ');
                    pending_space = false;
                }

                result.append_unichar (character);
            }
        }

        return result.str;
    }

    static Xml.Doc* parse_xml (Bytes content, string name) throws EpubError {
        unowned uint8[] data = content.get_data ();
        unowned string text = (string) data;
        var document = Xml.Parser.read_memory (
            text, data.length - 1, name, null,
            XML_OPTIONS | Xml.ParserOption.RECOVER
        );

        if (document == null || document->get_root_element () == null) {
            delete document;
            throw new EpubError.INVALID ("Invalid XML in %s", name);
        }

        return document;
    }

    /** The encoding of an (X)HTML file, which the HTML parser can't detect */
    static string detect_encoding (uint8[] data) {
        if (data.length >= 2
            && ((data[0] == 0xFF && data[1] == 0xFE)
                || (data[0] == 0xFE && data[1] == 0xFF))) {
            return "UTF-16";
        }

        unowned string text = (string) data;
        var head_size = 0;
        while (head_size < 200 && head_size < data.length && data[head_size] != 0) {
            head_size++;
        }

        var head = text.substring (0, head_size);

        if (head.has_prefix ("<?xml")) {
            var start = head.index_of ("encoding=");
            if (start >= 0 && start + 10 < head.length) {
                start += 10;
                var end = head.index_of_char (head[start - 1], start);
                if (end > start) {
                    return head[start:end];
                }
            }
        }

        return "UTF-8";
    }

    /** Parse content as XHTML, falling back on the forgiving HTML parser for
        the many books that aren't valid XML */
    static Xml.Doc* parse_content (Bytes content, string name) {
        unowned uint8[] data = content.get_data ();
        unowned string text = (string) data;
        var size = data.length - 1;

        if (size <= 0) {
            return null;
        }

        Xml.Doc* document = Xml.Parser.read_memory (text, size, name, null, XML_OPTIONS);
        if (document != null) {
            var root = document->get_root_element ();
            if (root != null && root->name.ascii_casecmp ("html") == 0) {
                return document;
            }

            delete document;
        }

        return Html.Doc.read_memory (
            (char[]) data, size, name, detect_encoding (data), HTML_OPTIONS
        );
    }

    static bool is_element (Xml.Node* node, string name) {
        return node->type == Xml.ElementType.ELEMENT_NODE
            && node->name.ascii_casecmp (name) == 0;
    }

    static Xml.Node* find_element (Xml.Node* parent, string name) {
        for (var child = parent->children; child != null; child = child->next) {
            if (is_element (child, name)) {
                return child;
            }

            if (child->type == Xml.ElementType.ELEMENT_NODE) {
                var found = find_element (child, name);
                if (found != null) {
                    return found;
                }
            }
        }

        return null;
    }

    /** The value of an element's `epub:type` attribute. It is stored
        differently depending on which parser was used. */
    static string? epub_type_of (Xml.Node* node) {
        for (var attr = node->properties; attr != null; attr = attr->next) {
            var is_epub_type = attr->name == "epub:type"
                || (attr->name == "type" && attr->ns != null
                    && attr->ns->prefix == "epub");

            if (is_epub_type) {
                return attr->children != null ? attr->children->content : "";
            }
        }

        return null;
    }

    static bool has_token (string? tokens, string token) {
        if (tokens == null) {
            return false;
        }

        foreach (var candidate in tokens.split_set (" \t\r\n")) {
            if (candidate == token) {
                return true;
            }
        }

        return false;
    }

    string find_opf_path (Bytes container) throws EpubError {
        var document = parse_xml (container, "container.xml");
        string? path = null;

        var rootfile = find_element (document->get_root_element (), "rootfile");
        if (rootfile != null) {
            var full_path = rootfile->get_prop ("full-path");
            if (full_path != null) {
                path = normalize_path ("", full_path);
            }
        }

        delete document;

        if (path == null) {
            throw new EpubError.INVALID ("No package document declared");
        }

        return path;
    }

    void parse_opf (Bytes opf) throws EpubError {
        var document = parse_xml (opf, _opf_path);
        var root = document->get_root_element ();
        var directory = directory_of (_opf_path);

        var metadata = find_element (root, "metadata");
        if (metadata != null) {
            _book.title = metadata_value (metadata, "title");
            _book.author = metadata_value (metadata, "creator");
            _book.language = metadata_value (metadata, "language");
        }

        var manifest = find_element (root, "manifest");
        if (manifest != null) {
            for (var node = manifest->children; node != null; node = node->next) {
                if (is_element (node, "item")) {
                    add_manifest_item (node, directory);
                }
            }
        }

        var spine = find_element (root, "spine");
        if (spine != null) {
            _ncx_id = spine->get_prop ("toc");

            for (var node = spine->children; node != null; node = node->next) {
                if (is_element (node, "itemref")) {
                    add_spine_item (node);
                }
            }
        }

        delete document;

        if (_spine.length == 0) {
            throw new EpubError.NO_TEXT ("The book has no readable content");
        }
    }

    static string metadata_value (Xml.Node* metadata, string name) {
        var node = find_element (metadata, name);
        return node != null ? collapse_whitespace (node->get_content ()) : "";
    }

    void add_manifest_item (Xml.Node* node, string directory) {
        var id = node->get_prop ("id");
        var href = node->get_prop ("href");

        if (id == null || href == null) {
            return;
        }

        var path = normalize_path (directory, href);
        if (path == null) {
            return;
        }

        var item = new ManifestItem () {
            path = path,
            media_type = (node->get_prop ("media-type") ?? "").down (),
            is_nav = has_token (node->get_prop ("properties"), "nav"),
        };
        _manifest[id] = item;
    }

    void add_spine_item (Xml.Node* node) {
        var id = node->get_prop ("idref");
        var item = id != null ? _manifest[id] : null;

        // The navigation document only repeats the table of contents
        if (item == null || item.is_nav || node->get_prop ("linear") == "no") {
            return;
        }

        var lower_path = item.path.down ();
        var is_html = item.media_type.contains ("html")
            || lower_path.has_suffix (".xhtml")
            || lower_path.has_suffix (".html")
            || lower_path.has_suffix (".htm");

        if (is_html) {
            _spine.add (item);
        }
    }

    ManifestItem? find_ncx () {
        if (_ncx_id != null && _manifest.contains (_ncx_id)) {
            return _manifest[_ncx_id];
        }

        ManifestItem? found = null;
        _manifest.foreach ((id, item) => {
            if (item.media_type == "application/x-dtbncx+xml") {
                found = item;
            }
        });

        return found;
    }

    /** Refuse books whose content is encrypted. Obfuscated fonts are fine:
        they are listed there too but the text remains readable. */
    void check_encryption (Bytes? encryption) throws EpubError {
        if (encryption == null) {
            return;
        }

        var document = parse_xml (encryption, "encryption.xml");
        var encrypted = new GenericSet<string> (str_hash, str_equal);
        collect_encrypted (document->get_root_element (), encrypted);
        delete document;

        for (var i = 0; i < _spine.length; i++) {
            if (encrypted.contains (_spine[i].path)) {
                throw new EpubError.DRM_PROTECTED ("The book's content is encrypted");
            }
        }
    }

    static void collect_encrypted (Xml.Node* node, GenericSet<string> encrypted) {
        for (var child = node->children; child != null; child = child->next) {
            if (is_element (child, "EncryptedData")) {
                var method = find_element (child, "EncryptionMethod");
                var algorithm = method != null ? method->get_prop ("Algorithm") : null;
                var reference = find_element (child, "CipherReference");
                var uri = reference != null ? reference->get_prop ("URI") : null;
                var path = uri != null ? normalize_path ("", uri) : null;

                if (path != null && !(algorithm in FONT_OBFUSCATION_ALGORITHMS)) {
                    encrypted.add (path);
                }
            } else if (child->type == Xml.ElementType.ELEMENT_NODE) {
                collect_encrypted (child, encrypted);
            }
        }
    }

    TocEntry? new_toc_entry (string title, string href, string toc_path) {
        var path = normalize_path (directory_of (toc_path), href);
        if (path == null) {
            return null;
        }

        return new TocEntry () {
            title = collapse_whitespace (title),
            path = path,
            fragment = fragment_of (href),
        };
    }

    GenericArray<TocEntry> parse_nav (Bytes content, string path) {
        Xml.Doc* document = parse_content (content, path);
        var entries = new GenericArray<TocEntry> ();

        if (document == null) {
            return entries;
        }

        var root = document->get_root_element ();
        if (root != null) {
            var nav = find_toc_nav (root);
            if (nav != null) {
                collect_nav_links (nav, path, entries);
            }
        }

        delete document;
        return entries;
    }

    /** The `nav` element marked as the table of contents, or else the first */
    static Xml.Node* find_toc_nav (Xml.Node* root) {
        Xml.Node* first = null;
        var marked = find_marked_nav (root, ref first);
        return marked != null ? marked : first;
    }

    static Xml.Node* find_marked_nav (Xml.Node* parent, ref Xml.Node* first) {
        for (var child = parent->children; child != null; child = child->next) {
            if (child->type != Xml.ElementType.ELEMENT_NODE) {
                continue;
            }

            if (is_element (child, "nav")) {
                if (has_token (epub_type_of (child), "toc")) {
                    return child;
                }

                if (first == null) {
                    first = child;
                }
            } else {
                var found = find_marked_nav (child, ref first);
                if (found != null) {
                    return found;
                }
            }
        }

        return null;
    }

    void collect_nav_links (Xml.Node* parent, string path, GenericArray<TocEntry> entries) {
        for (var child = parent->children; child != null; child = child->next) {
            if (child->type != Xml.ElementType.ELEMENT_NODE) {
                continue;
            }

            var href = is_element (child, "a") ? child->get_prop ("href") : null;
            if (href != null) {
                var entry = new_toc_entry (child->get_content (), href, path);
                if (entry != null) {
                    entries.add (entry);
                }
            } else {
                collect_nav_links (child, path, entries);
            }
        }
    }

    GenericArray<TocEntry> parse_ncx (Bytes content, string path) throws EpubError {
        var document = parse_xml (content, path);
        var entries = new GenericArray<TocEntry> ();
        collect_nav_points (document->get_root_element (), path, entries);
        delete document;
        return entries;
    }

    void collect_nav_points (Xml.Node* parent, string path, GenericArray<TocEntry> entries) {
        for (var child = parent->children; child != null; child = child->next) {
            if (child->type != Xml.ElementType.ELEMENT_NODE) {
                continue;
            }

            if (is_element (child, "navPoint")) {
                add_nav_point (child, path, entries);
            }

            collect_nav_points (child, path, entries);
        }
    }

    void add_nav_point (Xml.Node* point, string path, GenericArray<TocEntry> entries) {
        Xml.Node* label = null;
        Xml.Node* target = null;

        for (var child = point->children; child != null; child = child->next) {
            if (label == null && is_element (child, "navLabel")) {
                label = child;
            } else if (target == null && is_element (child, "content")) {
                target = child;
            }
        }

        var href = target != null ? target->get_prop ("src") : null;
        if (href == null) {
            return;
        }

        var title = label != null ? label->get_content () : "";
        var entry = new_toc_entry (title, href, path);
        if (entry != null) {
            entries.add (entry);
        }
    }

    /** Append one spine document to the book's text */
    SpineDocument read_document (Bytes content, string path) {
        block_break (2);

        var result = new SpineDocument () {
            path = path,
            start = _char_count,
        };

        Xml.Doc* document = parse_content (content, path);
        if (document == null) {
            return result;
        }

        var root = document->get_root_element ();
        if (root != null) {
            _current_path = path;
            _heading.truncate (0);
            _first_heading = null;

            var body = find_element (root, "body");
            walk_children (body != null ? body : root);
            result.heading = _first_heading;
        }

        delete document;
        return result;
    }

    string? _first_heading = null;

    void walk_children (Xml.Node* parent) {
        for (var child = parent->children; child != null; child = child->next) {
            switch (child->type) {
                case Xml.ElementType.TEXT_NODE:
                case Xml.ElementType.CDATA_SECTION_NODE:
                    append_text (child->content);
                    break;
                case Xml.ElementType.ENTITY_REF_NODE:
                    // HTML entities such as `&nbsp;` when the DTD isn't loaded
                    var entity = Html.EntityDesc.lookup (child->name);
                    if (entity != null) {
                        append_text (((unichar) entity->value).to_string ());
                    }
                    break;
                case Xml.ElementType.ELEMENT_NODE:
                    walk_element (child);
                    break;
                default:
                    break;
            }
        }
    }

    static bool is_skipped_element (string name) {
        switch (name) {
            case "head":
            case "script":
            case "style":
            case "template":
            case "svg":
            case "math":
            case "img":
            case "image":
            case "audio":
            case "video":
            case "object":
            case "embed":
            case "iframe":
            case "canvas":
                return true;
            default:
                return false;
        }
    }

    /** How many line breaks separate this element from its surroundings */
    static int break_size_of (string name) {
        switch (name) {
            case "p":
            case "div":
            case "section":
            case "article":
            case "aside":
            case "header":
            case "footer":
            case "main":
            case "nav":
            case "figure":
            case "blockquote":
            case "pre":
            case "ul":
            case "ol":
            case "dl":
            case "table":
            case "hr":
            case "h1":
            case "h2":
            case "h3":
            case "h4":
            case "h5":
            case "h6":
                return 2;
            case "li":
            case "dt":
            case "dd":
            case "tr":
            case "caption":
            case "figcaption":
                return 1;
            default:
                return 0;
        }
    }

    static bool is_note_reference (Xml.Node* node) {
        return has_token (epub_type_of (node), "noteref")
            || has_token (node->get_prop ("role"), "doc-noteref");
    }

    void walk_element (Xml.Node* node) {
        var name = node->name.down ();

        if (is_skipped_element (name) || is_note_reference (node)) {
            return;
        }

        if (name == "br") {
            block_break (1);
            return;
        }

        var break_size = break_size_of (name);
        block_break (break_size);
        record_anchors (node);

        var is_heading = name.length == 2 && name[0] == 'h'
            && name[1] >= '1' && name[1] <= '6';
        var start = _char_count;

        if (is_heading) {
            _heading_depth++;
        }

        walk_children (node);

        if (is_heading) {
            _heading_depth--;
            add_style (start, StyleKind.HEADING);

            if (_heading_depth == 0) {
                if (_first_heading == null && _heading.len > 0) {
                    _first_heading = _heading.str;
                }

                _heading.truncate (0);
            }
        } else if (name == "b" || name == "strong") {
            add_style (start, StyleKind.BOLD);
        } else if (name == "i" || name == "em" || name == "cite") {
            add_style (start, StyleKind.ITALIC);
        }

        block_break (break_size);

        if (name == "td" || name == "th") {
            _pending_space = true;
        }
    }

    void add_style (int start, StyleKind kind) {
        if (_char_count > start) {
            _styles += StyleSpan () { start = start, end = _char_count, kind = kind };
        }
    }

    void record_anchors (Xml.Node* node) {
        record_anchor (node->get_prop ("id"));

        if (is_element (node, "a")) {
            record_anchor (node->get_prop ("name"));
        }
    }

    void record_anchor (string? id) {
        if (id == null) {
            return;
        }

        var key = _current_path + "#" + id;
        if (_wanted_anchors.contains (key) && !_anchors.contains (key)) {
            _anchors[key] = _char_count;
        }
    }

    void put_char (unichar character) {
        _text.append_unichar (character);
        _char_count++;

        if (_heading_depth > 0) {
            _heading.append_unichar (character);
        }
    }

    void append_text (string text) {
        var index = 0;
        unichar character;

        while (text.get_next_char (ref index, out character)) {
            // Soft hyphen, zero-width space and byte order mark
            if (character == 0xAD || character == 0x200B || character == 0xFEFF) {
                continue;
            }

            if (character.isspace ()) {
                _pending_space = true;
                continue;
            }

            if (_pending_space && _char_count > 0 && _trailing_newlines == 0) {
                put_char (' ');
            }

            _pending_space = false;
            _trailing_newlines = 0;
            put_char (character);
        }
    }

    /** Make sure the next text starts after `count` line breaks */
    void block_break (int count) {
        if (count == 0 || _char_count == 0) {
            return;
        }

        _pending_space = false;

        while (_trailing_newlines < count) {
            _text.append_c ('\n');
            _char_count++;
            _trailing_newlines++;
        }
    }

    bool has_text_before (int offset) {
        unowned string text = _book.text;
        var end = text.index_of_nth_char (offset);
        return text[0:end].strip () != "";
    }

    Chapter[] build_chapters (
        GenericArray<TocEntry> toc,
        GenericArray<SpineDocument> documents
    ) {
        var starts = new HashTable<string, SpineDocument> (str_hash, str_equal);
        documents.foreach (document => starts[document.path] = document);

        var chapters = new GenericArray<Chapter> ();
        for (var i = 0; i < toc.length; i++) {
            var entry = toc[i];
            var document = starts[entry.path];
            if (document == null) {
                continue;
            }

            var start = document.start;
            if (entry.fragment != null) {
                var key = entry.path + "#" + entry.fragment;
                if (_anchors.contains (key)) {
                    start = _anchors[key];
                }
            }

            if (start < _char_count) {
                chapters.add (new Chapter (entry.title, start, _char_count));
            }
        }

        if (chapters.length == 0) {
            documents.foreach (document => {
                if (document.start < _char_count) {
                    var title = document.heading ?? "";
                    chapters.add (new Chapter (title, document.start, _char_count));
                }
            });
        }

        return finish_chapters (chapters);
    }

    /** Order the chapters, drop duplicates and give each one its final range
        so that together they cover the whole text */
    Chapter[] finish_chapters (GenericArray<Chapter> found) {
        found.sort_with_data ((a, b) => a.start - b.start);

        Chapter[] chapters = {};
        for (var i = 0; i < found.length; i++) {
            var chapter = found[i];

            if (chapters.length == 0 || chapters[chapters.length - 1].start != chapter.start) {
                chapters += chapter;
            }
        }

        if (chapters.length == 0) {
            chapters += new Chapter (_book.title, 0, _char_count);
        } else if (chapters[0].start > 0) {
            if (has_text_before (chapters[0].start)) {
                Chapter[] with_front = { new Chapter (_ ("Front Matter"), 0, 0) };
                foreach (var chapter in chapters) {
                    with_front += chapter;
                }

                chapters = with_front;
            } else {
                chapters[0].start = 0;
            }
        }

        for (var i = 0; i < chapters.length; i++) {
            chapters[i].end = i + 1 < chapters.length
                ? chapters[i + 1].start
                : _char_count;

            if (chapters[i].title == "") {
                // TR: Used when a part of a book has no title. %d is its number
                chapters[i].title = _ ("Chapter %d").printf (i + 1);
            }
        }

        return chapters;
    }
}
