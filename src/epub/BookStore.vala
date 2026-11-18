/** What is remembered about a book that was opened */
class Spedread.BookRecord {
    public string id;
    public string title = "";
    public string author = "";
    public int offset = 0;
    public int percent = 0;
    public int64 last_opened = 0;

    public BookRecord (string id) {
        this.id = id;
    }
}

/** Keeps a private copy of opened books along with their reading positions.
    Each book has its own files so that separate windows can't overwrite each
    other's books. Access to the original file may not last inside a sandbox. */
namespace Spedread.BookStore {
    const int MAX_RECENT_BOOKS = 20;
    const string GROUP = "Book";

    string directory () {
        return Path.build_filename (Environment.get_user_data_dir (), "spedread", "books");
    }

    internal string epub_path (string id) {
        return Path.build_filename (directory (), id + ".epub");
    }

    string info_path (string id) {
        return Path.build_filename (directory (), id + ".ini");
    }

    internal BookRecord? load (string id) {
        var file = new KeyFile ();

        try {
            file.load_from_file (info_path (id), KeyFileFlags.NONE);

            var record = new BookRecord (id);
            record.title = file.get_string (GROUP, "title");
            record.author = file.get_string (GROUP, "author");
            record.offset = file.get_integer (GROUP, "offset");
            record.percent = file.get_integer (GROUP, "percent");
            record.last_opened = file.get_int64 (GROUP, "last-opened");
            return record;
        } catch (Error error) {
            return null;
        }
    }

    internal void save (BookRecord record) {
        var file = new KeyFile ();
        file.set_string (GROUP, "title", record.title);
        file.set_string (GROUP, "author", record.author);
        file.set_integer (GROUP, "offset", record.offset);
        file.set_integer (GROUP, "percent", record.percent);
        file.set_int64 (GROUP, "last-opened", record.last_opened);

        try {
            DirUtils.create_with_parents (directory (), 0700);
            FileUtils.set_contents (info_path (record.id), file.to_data ());
        } catch (Error error) {
            warning ("Can't save the reading position: %s", error.message);
        }
    }

    /** Keep a copy of the book unless there already is one */
    internal void store_file (string id, Bytes data) {
        var path = epub_path (id);

        if (FileUtils.test (path, FileTest.EXISTS)) {
            return;
        }

        try {
            DirUtils.create_with_parents (directory (), 0700);
            FileUtils.set_data (path, data.get_data ());
        } catch (Error error) {
            warning ("Can't keep a copy of the book: %s", error.message);
        }
    }

    /** Books that can be reopened, most recently opened first */
    internal GenericArray<BookRecord> recent () {
        var records = new GenericArray<BookRecord> ();

        try {
            var dir = Dir.open (directory ());
            string? name;

            while ((name = dir.read_name ()) != null) {
                if (!name.has_suffix (".ini")) {
                    continue;
                }

                var record = load (name[0:name.length - 4]);
                if (record != null && FileUtils.test (epub_path (record.id), FileTest.EXISTS)) {
                    records.add (record);
                }
            }
        } catch (Error error) {
            return records;
        }

        records.sort_with_data ((a, b) => {
            return a.last_opened > b.last_opened ? -1 : (a.last_opened < b.last_opened ? 1 : 0);
        });

        return records;
    }

    /** Delete the copies of the oldest books. Their positions are kept in case
        they get opened again. */
    internal void trim_recent () {
        var records = recent ();

        for (var i = MAX_RECENT_BOOKS; i < records.length; i++) {
            FileUtils.unlink (epub_path (records[i].id));
        }
    }

    internal void remove (string id) {
        FileUtils.unlink (epub_path (id));
        FileUtils.unlink (info_path (id));
    }
}
