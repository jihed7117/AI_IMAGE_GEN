import 'dart:convert';
import 'dart:io';

/// Byte-level BPE tokenizer as used by CLIP (SD 1.5 / SDXL text encoders).
///
/// Mirrors the reference implementation (HuggingFace CLIPTokenizer, verified
/// against CLIPTokenizerFast): text is whitespace-cleaned and lowercased,
/// the regex splits it into words on the raw text, each word is byte-encoded
/// with the CLIP `bytes_to_unicode` table (printable ASCII stays itself,
/// space becomes U+0120 'Ġ', control bytes become chars 256..323), a
/// trailing word-end marker is added to its last char, and BPE merges are
/// applied greedily by rank.
class ClipTokenizer {
  final Map<String, int> _vocab;
  final List<(String, String)> _merges;
  late final Map<String, int> _mergeRanks;

  ClipTokenizer._(this._vocab, this._merges) {
    _mergeRanks = {
      for (var i = 0; i < _merges.length; i++)
        '${_merges[i].$1} ${_merges[i].$2}': i,
    };
  }

  factory ClipTokenizer.loadFromDir(String dir) {
    final vocab = (jsonDecode(File('$dir/vocab.json').readAsStringSync())
            as Map<String, dynamic>)
        .map((k, v) => MapEntry(k, v as int));
    final merges = File('$dir/merges.txt')
        .readAsStringSync()
        .split('\n')
        .skip(1) // "version 0.2" header
        .where((l) => l.trim().isNotEmpty)
        .map((l) {
      final parts = l.trim().split(' ');
      return (parts[0], parts[1]);
    }).toList();
    return ClipTokenizer._(vocab, merges);
  }

  int get startTokenId => _vocab['<|startoftext|>'] ?? 49406;
  int get endTokenId => _vocab['<|endoftext|>'] ?? 49407;

  static final RegExp _splitPattern = RegExp(
    r'''<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+''',
    unicode: true,
    caseSensitive: false,
  );

  /// The CLIP `bytes_to_unicode` table.
  ///
  /// Printable ASCII (33..126) and latin-1 letters/symbols (161..172,
  /// 174..255) map to themselves; every other byte (0..32, 127..160, 173)
  /// maps to unicode char 256+n in ascending byte order. Notably byte 32
  /// (space) becomes U+0120 'Ġ'.
  static final Map<int, int> _byteToChar = _buildByteMap();

  static Map<int, int> _buildByteMap() {
    final map = <int, int>{};
    for (var b = 33; b <= 126; b++) {
      map[b] = b;
    }
    for (var b = 161; b <= 172; b++) {
      map[b] = b;
    }
    for (var b = 174; b <= 255; b++) {
      map[b] = b;
    }
    var n = 0;
    for (var b = 0; b < 256; b++) {
      if (!map.containsKey(b)) {
        map[b] = 256 + n;
        n++;
      }
    }
    return map;
  }

  /// Byte-encodes [input]: utf8 bytes to CLIP unicode chars.
  static String _bytesToUnicode(String input) {
    final out = StringBuffer();
    for (final byte in utf8.encode(input)) {
      out.writeCharCode(_byteToChar[byte]!);
    }
    return out.toString();
  }

  /// Greedy lowest-rank BPE merge over a word, as in the reference
  /// implementation. The word's last char already carries the word-end
  /// marker (literal word-end marker).
  List<String> _mergeBpe(List<String> word) {
    if (word.length == 1) return word;
    var pairs = _getPairs(word);
    while (pairs.isNotEmpty) {
      String? bestKey;
      var bestRank = 1 << 30;
      for (final pair in pairs) {
        final rank = _mergeRanks['${pair.$1} ${pair.$2}'];
        if (rank != null && rank < bestRank) {
          bestRank = rank;
          bestKey = '${pair.$1} ${pair.$2}';
        }
      }
      if (bestKey == null) break;
      final space = bestKey.indexOf(' ');
      final first = bestKey.substring(0, space);
      final second = bestKey.substring(space + 1);
      final newWord = <String>[];
      var i = 0;
      while (i < word.length) {
        if (i < word.length - 1 &&
            word[i] == first &&
            word[i + 1] == second) {
          newWord.add(first + second);
          i += 2;
        } else {
          newWord.add(word[i]);
          i += 1;
        }
      }
      word = newWord;
      if (word.length == 1) break;
      pairs = _getPairs(word);
    }
    return word;
  }

  static Set<(String, String)> _getPairs(List<String> word) {
    final pairs = <(String, String)>{};
    for (var i = 0; i < word.length - 1; i++) {
      pairs.add((word[i], word[i + 1]));
    }
    return pairs;
  }

  /// BPE-encodes one regex token: splits into chars, appends the word-end
  /// marker to the last char, then applies greedy merges.
  List<String> _wordTokens(String token) {
    if (token.isEmpty) return const [];
    final word = <String>[
      for (var i = 0; i < token.length - 1; i++) token[i],
      '${token[token.length - 1]}</w>',
    ];
    return _mergeBpe(word);
  }

  /// Tokenizes [text] into token ids (without the BOS/EOS padding).
  List<int> _tokenize(String text) {
    final ids = <int>[];
    // whitespace_clean + lowercase, mirroring the reference pipeline.
    final cleaned =
        text.replaceAll(_whitespaceRe, ' ').trim().toLowerCase();
    for (final match in _splitPattern.allMatches(cleaned)) {
      final token = match.group(0)!;
      if (token == '<|startoftext|>') {
        ids.add(startTokenId);
        continue;
      }
      if (token == '<|endoftext|>') {
        ids.add(endTokenId);
        continue;
      }
      final encoded = _bytesToUnicode(token);
      for (final piece in _wordTokens(encoded)) {
        final id = _vocab[piece];
        ids.add(id ?? 0);
      }
    }
    return ids;
  }

  static final RegExp _whitespaceRe = RegExp(r'\s+', unicode: true);

  /// Returns token ids padded/truncated to [maxLength] with BOS and EOS.
  List<int> encode(String text, {int maxLength = 77}) {
    final ids = <int>[startTokenId, ..._tokenize(text), endTokenId];
    if (ids.length > maxLength) {
      return [...ids.sublist(0, maxLength - 1), endTokenId];
    }
    while (ids.length < maxLength) {
      ids.add(endTokenId);
    }
    return ids;
  }
}
