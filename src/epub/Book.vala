/** The kinds of formatting kept from a book's content */
enum Spedread.StyleKind {
    HEADING,
    BOLD,
    ITALIC,
}

/** Formatting applied between two character offsets of a book's text */
struct Spedread.StyleSpan {
    public int start;
    public int end;
    public StyleKind kind;
}

/** A part of a book, delimited by character offsets of the book's text */
class Spedread.Chapter {
    public string title;
    public int start;
    public int end;

    public Chapter (string title, int start, int end) {
        this.title = title;
        this.start = start;
        this.end = end;
    }
}

/** A book flattened to a single text with its chapter table */
class Spedread.Book {
    public string title = "";
    public string author = "";
    public string language = "";
    public string text = "";
    public Chapter[] chapters = {};
    public StyleSpan[] styles = {};

    /** Offsets where a chapter starts, in order, without the first chapter */
    public int[] chapter_boundaries () {
        int[] boundaries = {};

        for (var i = 1; i < chapters.length; i++) {
            boundaries += chapters[i].start;
        }

        return boundaries;
    }
}
