class DictionaryEntry {
  const DictionaryEntry({
    required this.word,
    required this.translation,
    this.pos = '',
    this.phonetic = '',
  });

  final String word;
  final String translation;
  final String pos;
  final String phonetic;

  bool get isEmpty => translation.isEmpty && pos.isEmpty;

  factory DictionaryEntry.fromJson(Map<String, dynamic> json) =>
      DictionaryEntry(
        word: json['word']?.toString() ?? '',
        translation: json['translation']?.toString() ?? '',
        pos: json['pos']?.toString() ?? '',
        phonetic: json['phonetic']?.toString() ?? '',
      );

  Map<String, dynamic> toJson() => {
        'word': word,
        'translation': translation,
        'pos': pos,
        'phonetic': phonetic,
      };
}
