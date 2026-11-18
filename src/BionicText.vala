/** Finds which parts of a text get emphasized by bionic reading */
namespace Spedread.BionicText {
    /** Byte ranges to emphasize, as consecutive start and end offsets. The
        first half of each word plus one letter is emphasized, and words of a
        single letter are left alone. */
    internal int[] bold_ranges (string text) {
        int[] ranges = {};
        int[] letter_ends = {};
        var word_start = -1;
        var index = 0;
        unichar character;

        for ( ;; ) {
            var position = index;
            var has_character = text.get_next_char (ref index, out character);
            var in_word = word_start >= 0;

            if (has_character && character.isalnum ()) {
                if (!in_word) {
                    word_start = position;
                }

                letter_ends += index;
                continue;
            }

            if (has_character && in_word) {
                if (character.ismark ()) {
                    // Accents belong to the letter before them
                    letter_ends[letter_ends.length - 1] = index;
                    continue;
                }

                if (is_apostrophe (character) && is_alnum_at (text, index)) {
                    continue;
                }
            }

            if (letter_ends.length >= 2) {
                var bold_letters = int.min (letter_ends.length / 2 + 1, letter_ends.length);
                ranges += word_start;
                ranges += letter_ends[bold_letters - 1];
            }

            word_start = -1;
            letter_ends = {};

            if (!has_character) {
                return ranges;
            }
        }
    }

    bool is_apostrophe (unichar character) {
        return character == '\'' || character == 0x2019;
    }

    bool is_alnum_at (string text, int index) {
        unichar next;
        return text.get_next_char (ref index, out next) && next.isalnum ();
    }
}
