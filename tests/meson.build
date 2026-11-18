word_index_test = executable(
    'word-index-test',
    'WordIndexTest.vala',
    word_index_source,
    dependencies: [
        dependency('glib-2.0'),
        dependency('gobject-2.0'),
        dependency('pango'),
    ],
)

test('word-index', word_index_test)

epub_reader_test = executable(
    'epub-reader-test',
    'EpubReaderTest.vala',
    epub_sources,
    dependencies: [
        dependency('glib-2.0'),
        dependency('gobject-2.0'),
        dependency('libxml-2.0'),
        dependency('libarchive'),
    ],
)

test('epub-reader', epub_reader_test)
