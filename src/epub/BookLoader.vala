/** A book ready to be displayed */
class Spedread.LoadedBook {
    public Book book;
    public BookRecord record;
    public WordIndex index;
    public int words_at_a_time;
}

/** Does all the slow work of opening a book outside of the main thread */
namespace Spedread.BookLoader {
    const int64 MAX_FILE_SIZE = 512 * 1024 * 1024;

    internal Pango.Language? language_of (Book book) {
        return book.language != "" ? Pango.Language.from_string (book.language) : null;
    }

    LoadedBook parse (Bytes data, int words_at_a_time) throws EpubError {
        var id = Checksum.compute_for_bytes (ChecksumType.SHA256, data);
        var book = new EpubReader (data).read ();

        BookStore.store_file (id, data);

        var record = BookStore.load (id) ?? new BookRecord (id);
        record.title = book.title;
        record.author = book.author;
        record.last_opened = new DateTime.now_utc ().to_unix ();
        BookStore.save (record);
        BookStore.trim_recent ();

        var index = new WordIndex ();
        index.rebuild (
            book.text,
            words_at_a_time,
            language_of (book),
            book.chapter_boundaries ()
        );

        return new LoadedBook () {
            book = book,
            record = record,
            index = index,
            words_at_a_time = words_at_a_time,
        };
    }

    internal async LoadedBook load (File file, int words_at_a_time) throws Error {
        var info = yield file.query_info_async (
            FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE
        );

        if (info.get_size () > MAX_FILE_SIZE) {
            throw new EpubError.TOO_LARGE ("The file is too large");
        }

        var data = yield file.load_bytes_async (null, null);

        LoadedBook? result = null;
        Error? failure = null;
        SourceFunc callback = load.callback;

        new Thread<void*> ("book-loader", () => {
            try {
                result = parse (data, words_at_a_time);
            } catch (Error error) {
                failure = error.copy ();
            }

            Idle.add ((owned) callback);
            return null;
        });

        yield;

        if (failure != null) {
            throw failure;
        }

        return result;
    }
}
