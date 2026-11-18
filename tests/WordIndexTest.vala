namespace Spedread.WordIndexTest {
    string[] words_of (string text, WordIndex index) {
        string[] words = {};

        for (var i = 0; i < index.length; i++) {
            var start = text.index_of_nth_char (index.start (i));
            var end = text.index_of_nth_char (index.end (i));
            words += text.substring (start, end - start);
        }

        return words;
    }

    void assert_words (string text, WordIndex index, string[] expected) {
        var words = words_of (text, index);
        assert_cmpstrv (words, expected);
    }

    void test_single_words () {
        var text = "Hello, big world.\nNext line";
        var index = new WordIndex ();
        index.rebuild (text, 1);

        assert_true (index.is_valid);
        assert_words (text, index, { "Hello,", "big", "world.", "Next", "line" });
    }

    void test_numbers_and_acronyms () {
        var text = "About 1,000.5 at U.S.A. today";
        var index = new WordIndex ();
        index.rebuild (text, 1);

        assert_words (text, index, { "About", "1,000.5", "at", "U.S.A.", "today" });
    }

    void test_empty_text () {
        var index = new WordIndex ();
        index.rebuild (" \n ", 1);

        assert_true (index.is_valid);
        assert_true (index.is_empty);
        assert_cmpint (index.word_at_offset (0), CompareOperator.EQ, -1);
    }

    void test_groups_stop_at_boundaries () {
        var text = "one two three\n\nfour five six";
        var boundary = text.char_count () - "four five six".char_count ();
        var index = new WordIndex ();

        index.rebuild (text, 2, null, { boundary });
        assert_words (text, index, { "one two", "three", "four five", "six" });

        index.rebuild (text, 2);
        assert_words (text, index, { "one two", "three\n\nfour", "five six" });
    }

    void test_offset_lookup () {
        var text = "aa bb cc";
        var index = new WordIndex ();
        index.rebuild (text, 1);

        assert_cmpint (index.word_at_offset (0), CompareOperator.EQ, 0);
        assert_cmpint (index.word_at_offset (2), CompareOperator.EQ, 0);
        assert_cmpint (index.word_at_offset (3), CompareOperator.EQ, 1);
        assert_cmpint (index.word_at_offset (100), CompareOperator.EQ, 2);
        assert_cmpint (index.first_word_from (1), CompareOperator.EQ, 1);
        assert_cmpint (index.first_word_from (7), CompareOperator.EQ, 3);
    }

    void test_non_ascii_offsets () {
        var text = "été naïve 日本";
        var index = new WordIndex ();
        index.rebuild (text, 1);

        assert_cmpint (index.start (1), CompareOperator.EQ, 4);
        assert_cmpint (index.end (1), CompareOperator.EQ, 9);
    }

    public static int main (string[] args) {
        Test.init (ref args);
        Test.add_func ("/word-index/single-words", test_single_words);
        Test.add_func ("/word-index/numbers-acronyms", test_numbers_and_acronyms);
        Test.add_func ("/word-index/empty", test_empty_text);
        Test.add_func ("/word-index/boundaries", test_groups_stop_at_boundaries);
        Test.add_func ("/word-index/offset-lookup", test_offset_lookup);
        Test.add_func ("/word-index/non-ascii", test_non_ascii_offsets);
        return Test.run ();
    }
}
