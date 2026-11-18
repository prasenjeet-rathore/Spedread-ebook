namespace Spedread.EpubReaderTest {
    const string CONTAINER = """<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/book.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>""";

    const string XHTML_HEAD = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN"
  "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml"
      xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>Ignored title</title><style>p { color: red; }</style></head>""";

    string opf (string manifest, string spine, string spine_attrs = "") {
        return """<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Test  Book</dc:title>
    <dc:creator>Some Author</dc:creator>
    <dc:language>en</dc:language>
  </metadata>
  <manifest>%s</manifest>
  <spine %s>%s</spine>
</package>""".printf (manifest, spine_attrs, spine);
    }

    const string TWO_ITEMS = """
<item id="one" href="text/one.xhtml" media-type="application/xhtml+xml"/>
<item id="two" href="text/two%20b.xhtml" media-type="application/xhtml+xml"/>""";

    const string TWO_REFS = """<itemref idref="one"/><itemref idref="two"/>""";

    string page (string body) {
        return XHTML_HEAD + "<body>" + body + "</body></html>";
    }

    string page_one () {
        return page ("""<h1>First</h1>
<p>Alpha <b>bold</b> <em>soft</em>&nbsp;beta<a epub:type="noteref" href="#n">1</a>.</p>
<img src="x.png" alt="not read"/><script>hidden()</script>""");
    }

    string page_two () {
        return page ("""<h1 id="second">Second</h1><p>Gamma delta.</p>
<h2 id="third">Third</h2><p>Epsilon.</p>""");
    }

    /** Fixtures go through a temporary file: the binding of
        `Archive.Write.open_memory` can't report the size written */
    Bytes make_zip (string[] names, string[] contents) {
        try {
            string path;
            FileUtils.close (FileUtils.open_tmp ("spedread-test-XXXXXX.epub", out path));

            var archive = new Archive.Write ();
            archive.set_format_zip ();
            assert_true (archive.open_filename (path) == Archive.Result.OK);

            for (var i = 0; i < names.length; i++) {
                var entry = new Archive.Entry ();
                entry.set_pathname (names[i]);
                entry.set_filetype (Archive.FileType.IFREG);
                entry.set_perm ((Archive.FileMode) 0644);
                entry.set_size (contents[i].length);
                assert_true (archive.write_header (entry) == Archive.Result.OK);
                archive.write_data (contents[i].data);
            }

            archive.close ();

            uint8[] data;
            FileUtils.get_data (path, out data);
            FileUtils.unlink (path);
            return new Bytes (data);
        } catch (Error failure) {
            GLib.error ("Can't create fixture: %s", failure.message);
        }
    }

    Bytes make_book (string opf_text, string[] names = {}, string[] contents = {}) {
        string[] all_names = {
            "META-INF/container.xml", "OEBPS/book.opf",
            "OEBPS/text/one.xhtml", "OEBPS/text/two b.xhtml",
        };
        string[] all_contents = { CONTAINER, opf_text, page_one (), page_two () };

        for (var i = 0; i < names.length; i++) {
            all_names += names[i];
            all_contents += contents[i];
        }

        return make_zip (all_names, all_contents);
    }

    Book read (Bytes data) {
        try {
            return new EpubReader (data).read ();
        } catch (EpubError failure) {
            GLib.error ("Unexpected failure: %s", failure.message);
        }
    }

    string chapter_text (Book book, Chapter chapter) {
        var start = book.text.index_of_nth_char (chapter.start);
        var end = book.text.index_of_nth_char (chapter.end);
        return book.text[start:end].strip ();
    }

    void test_epub3_nav () {
        var nav = page ("""<nav epub:type="landmarks"><a href="one.xhtml">No</a></nav>
<nav epub:type="toc"><ol>
<li><a href="one.xhtml">Chapter One</a></li>
<li><a href="two%20b.xhtml#second">Chapter Two</a>
  <ol><li><a href="two%20b.xhtml#third">Nested</a></li></ol></li>
</ol></nav>""");
        var manifest = TWO_ITEMS
            + """<item id="nav" href="text/nav.xhtml" properties="nav"
                 media-type="application/xhtml+xml"/>""";
        var spine = """<itemref idref="nav"/>""" + TWO_REFS;
        var book = read (make_book (opf (manifest, spine), { "OEBPS/text/nav.xhtml" }, { nav }));

        assert_cmpstr (book.title, CompareOperator.EQ, "Test Book");
        assert_cmpstr (book.author, CompareOperator.EQ, "Some Author");
        assert_cmpint (book.chapters.length, CompareOperator.EQ, 3);
        assert_cmpstr (book.chapters[0].title, CompareOperator.EQ, "Chapter One");
        assert_cmpstr (book.chapters[2].title, CompareOperator.EQ, "Nested");
        assert_cmpint (book.chapters[0].start, CompareOperator.EQ, 0);
        assert_cmpstr (
            chapter_text (book, book.chapters[1]), CompareOperator.EQ,
            "Second\n\nGamma delta."
        );
        assert_cmpstr (chapter_text (book, book.chapters[2]), CompareOperator.EQ,
            "Third\n\nEpsilon.");
        assert_cmpint (
            book.chapters[2].end, CompareOperator.EQ, book.text.char_count ()
        );
    }

    void test_text_extraction () {
        var book = read (make_book (opf (TWO_ITEMS, TWO_REFS)));

        // Entities are decoded; notes, images, scripts and styles are dropped
        assert_true (book.text.has_prefix ("First\n\nAlpha bold soft beta."));
        assert_false (book.text.contains ("hidden"));
        assert_false (book.text.contains ("not read"));
        assert_false (book.text.contains ("Ignored"));

        var kinds = new int[3];
        foreach (var span in book.styles) {
            kinds[span.kind]++;
        }

        assert_cmpint (kinds[StyleKind.HEADING], CompareOperator.EQ, 3);
        assert_cmpint (kinds[StyleKind.BOLD], CompareOperator.EQ, 1);
        assert_cmpint (kinds[StyleKind.ITALIC], CompareOperator.EQ, 1);
    }

    void test_epub2_ncx () {
        var ncx = """<?xml version="1.0"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"><navMap>
<navPoint id="a"><navLabel><text>NCX One</text></navLabel>
  <content src="text/one.xhtml"/>
  <navPoint id="b"><navLabel><text>NCX Two</text></navLabel>
    <content src="text/two%20b.xhtml"/></navPoint>
</navPoint></navMap></ncx>""";
        var manifest = TWO_ITEMS
            + """<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>""";
        var book = read (make_book (
            opf (manifest, TWO_REFS, "toc=\"ncx\""), { "OEBPS/toc.ncx" }, { ncx }
        ));

        assert_cmpint (book.chapters.length, CompareOperator.EQ, 2);
        assert_cmpstr (book.chapters[0].title, CompareOperator.EQ, "NCX One");
        assert_cmpstr (book.chapters[1].title, CompareOperator.EQ, "NCX Two");
    }

    void test_no_toc_uses_spine () {
        var book = read (make_book (opf (TWO_ITEMS, TWO_REFS)));

        assert_cmpint (book.chapters.length, CompareOperator.EQ, 2);
        assert_cmpstr (book.chapters[0].title, CompareOperator.EQ, "First");
        assert_cmpstr (book.chapters[1].title, CompareOperator.EQ, "Second");
    }

    void test_linear_no_is_skipped () {
        var spine = """<itemref idref="one"/><itemref idref="two" linear="no"/>""";
        var book = read (make_book (opf (TWO_ITEMS, spine)));

        assert_false (book.text.contains ("Gamma"));
    }

    void test_malformed_xhtml () {
        var manifest = """<item id="one" href="bad.xhtml" media-type="application/xhtml+xml"/>""";
        var broken = """<html><head><title/></head><body><p>Café &eacute;tude<br>
<p>Unclosed &amp; broken</body>""";
        var book = read (make_book (
            opf (manifest, """<itemref idref="one"/>"""), { "OEBPS/bad.xhtml" }, { broken }
        ));

        assert_true (book.text.contains ("Café étude"));
        assert_true (book.text.contains ("Unclosed & broken"));
    }

    void assert_fails (Bytes data, EpubError expected, int64 max_entry = -1) {
        var reader = new EpubReader (data);
        if (max_entry >= 0) {
            reader.max_entry_size = max_entry;
        }

        try {
            reader.read ();
            assert_not_reached ();
        } catch (EpubError failure) {
            assert_cmpint (failure.code, CompareOperator.EQ, expected.code);
        }
    }

    string encryption (string algorithm, string uri) {
        return """<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
  xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
<enc:EncryptedData><enc:EncryptionMethod Algorithm="%s"/>
<enc:CipherData><enc:CipherReference URI="%s"/></enc:CipherData>
</enc:EncryptedData></encryption>""".printf (algorithm, uri);
    }

    void test_drm () {
        var names = new string[] { "META-INF/encryption.xml" };
        var drm = encryption (
            "http://www.w3.org/2001/04/xmlenc#aes256-cbc", "OEBPS/text/one.xhtml"
        );
        assert_fails (
            make_book (opf (TWO_ITEMS, TWO_REFS), names, { drm }),
            new EpubError.DRM_PROTECTED ("")
        );

        var fonts = encryption ("http://www.idpf.org/2008/embedding", "OEBPS/text/one.xhtml");
        read (make_book (opf (TWO_ITEMS, TWO_REFS), names, { fonts }));
    }

    void test_invalid_files () {
        assert_fails (new Bytes ("not a zip".data), new EpubError.INVALID (""));
        assert_fails (make_zip ({ "a.txt" }, { "text" }), new EpubError.INVALID (""));
    }

    void test_no_text () {
        var empty = page ("""<img src="cover.png"/>""");
        var manifest = """<item id="one" href="i.xhtml" media-type="application/xhtml+xml"/>""";
        assert_fails (
            make_book (opf (manifest, """<itemref idref="one"/>"""), { "OEBPS/i.xhtml" }, { empty }),
            new EpubError.NO_TEXT ("")
        );
    }

    void test_size_limit () {
        assert_fails (
            make_book (opf (TWO_ITEMS, TWO_REFS)), new EpubError.TOO_LARGE (""), 16
        );
    }

    void test_path_escape () {
        var manifest = """<item id="one" href="../../../etc/passwd"
            media-type="application/xhtml+xml"/>""";
        assert_fails (
            make_book (opf (manifest, """<itemref idref="one"/>""")),
            new EpubError.NO_TEXT ("")
        );
    }

    public static int main (string[] args) {
        Test.init (ref args);
        Xml.Parser.init ();
        Test.add_func ("/epub/epub3-nav", test_epub3_nav);
        Test.add_func ("/epub/text", test_text_extraction);
        Test.add_func ("/epub/epub2-ncx", test_epub2_ncx);
        Test.add_func ("/epub/no-toc", test_no_toc_uses_spine);
        Test.add_func ("/epub/linear-no", test_linear_no_is_skipped);
        Test.add_func ("/epub/malformed", test_malformed_xhtml);
        Test.add_func ("/epub/drm", test_drm);
        Test.add_func ("/epub/invalid", test_invalid_files);
        Test.add_func ("/epub/no-text", test_no_text);
        Test.add_func ("/epub/size-limit", test_size_limit);
        Test.add_func ("/epub/path-escape", test_path_escape);
        return Test.run ();
    }
}
