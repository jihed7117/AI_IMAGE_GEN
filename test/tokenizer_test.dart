import 'dart:convert';
import 'dart:io';

import 'package:aiimagegen/tokenizer.dart';
import 'package:flutter_test/flutter_test.dart';

/// Writes a tiny but self-consistent CLIP vocab/merges pair into [dir] and
/// returns a tokenizer over it.
///
/// The BPE rules:  /// c u -> cu (rank 0)
  /// cu t -> cut (rank 1)
  /// cut e + word-end marker -> cute + word-end marker (rank 2)
  /// c a -> ca (rank 3)
  /// ca t + word-end marker -> cat + word-end marker (rank 4)
ClipTokenizer _fixture(Directory dir) {
  File('${dir.path}/vocab.json').writeAsStringSync(
    jsonEncode({
      '<|startoftext|>': 49406,
      '<|endoftext|>': 49407,
      'a</w>': 100,
      'cute</w>': 101,
      'cat</w>': 102,
      'Ġ': 103, // byte-encoded space char, present in real vocabs
      'c': 104,
      'u': 105,
      't': 106,
      'e</w>': 107,
      'i</w>': 108,
    }),
  );
  File('${dir.path}/merges.txt').writeAsStringSync(
    '#version: 0.2\n'
    'c u\n'
    'cu t\n'
    'cut e</w>\n'
    'c a\n'
    'ca t</w>\n',
  );
  return ClipTokenizer.loadFromDir(dir.path);
}

void main() {
  late Directory dir;
  late ClipTokenizer tok;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('aiimagegen_tok');
    tok = _fixture(dir);
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  List<int> content(List<int> ids) => ids.sublist(0, ids.indexOf(49407));

  test('tokenizes words via greedy BPE with </w> markers', () {
    // "cute cat" -> [BOS, cute</w>, cat</w>, EOS]
    expect(content(tok.encode('cute cat')), [49406, 101, 102]);
  });

  test('lowercases and collapses whitespace like the reference pipeline', () {
    final a = tok.encode('CUTE   CAT');
    final b = tok.encode('cute cat');
    expect(a, b);
    expect(content(a), [49406, 101, 102]);
  });

  test('special tokens survive lowercase preprocessing', () {
    // encode() adds BOS; a literal <|startoftext|> inside the text also maps
    // to 49406 (matching the reference implementation), so both appear, and
    // the literal <|endoftext|> keeps its own id before the padding.
    final ids = tok.encode('<|startoftext|>a<|endoftext|>');
    expect(ids.take(4).toList(), [49406, 49406, 100, 49407]);
  });

  test('byte mapping is identity for ASCII, Ġ for space', () {
    // Encoding must not produce the buggy char(256+byte) mapping, which maps
    // 'c' to a char not present in the vocab (id 0). Instead words must map
    // through the real CLIP table where printable ASCII stays itself.
    final ids = tok.encode('cute');
    expect(content(ids), [49406, 101]);
    expect(ids.contains(0), isFalse);
  });
}
