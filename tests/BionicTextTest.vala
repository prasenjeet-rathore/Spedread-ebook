namespace Spedread.BionicTextTest {
    /** The emphasized parts of `text`, joined with "|" */
    string bold_parts (string text) {
        var ranges = BionicText.bold_ranges (text);
        string[] parts = {};

        for (var i = 0; i + 1 < ranges.length; i += 2) {
            parts += text[ranges[i]:ranges[i + 1]];
        }

        return string.joinv ("|", parts);
    }

    void check (string text, string expected) {
        assert_cmpstr (bold_parts (text), CompareOperator.EQ, expected);
    }

    void test_word_lengths () {
        check ("a", "");
        check ("to", "to");
        check ("the", "th");
        check ("read", "rea");
        check ("reading", "read");
    }

    void test_several_words_and_punctuation () {
        check ("Hello, big world.", "Hel|bi|wor");
        check ("well-known", "wel|kno");
        check ("(reading)", "read");
        check ("", "");
        check ("...", "");
    }

    void test_apostrophes () {
        check ("don't", "don");
        check ("don’t", "don");
        check ("dogs'", "dog");
    }

    void test_non_ascii () {
        check ("été", "ét");
        check ("été", "ét");
        check ("слово", "сло");
    }

    public static int main (string[] args) {
        Test.init (ref args);
        Test.add_func ("/bionic/word-lengths", test_word_lengths);
        Test.add_func ("/bionic/words-punctuation", test_several_words_and_punctuation);
        Test.add_func ("/bionic/apostrophes", test_apostrophes);
        Test.add_func ("/bionic/non-ascii", test_non_ascii);
        return Test.run ();
    }
}
