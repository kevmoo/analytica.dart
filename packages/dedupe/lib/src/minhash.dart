import 'dart:math' as math;

/// Computes MinHash signatures and Locality-Sensitive Hashing (LSH) band keys
/// for fast set similarity estimation and near-miss clone candidate retrieval.
class MinHasher {
  /// Total number of hash functions in the signature (N = numBands *
  /// rowsPerBand).
  final int numHashes;

  /// Number of LSH bands.
  final int numBands;

  /// Number of rows per band.
  final int rowsPerBand;

  /// Prime modulus for universal affine hashing (2^31 - 1).
  static const int primeModulus = 0x7FFFFFFF;

  /// Deterministic pseudo-random multipliers (a_i) for universal hashing.
  final List<int> _aCoeffs;

  /// Deterministic pseudo-random addends (b_i) for universal hashing.
  final List<int> _bCoeffs;

  MinHasher({this.numBands = 8, this.rowsPerBand = 2})
    : numHashes = numBands * rowsPerBand,
      _aCoeffs = List.unmodifiable(
        _generateCoefficients(numBands * rowsPerBand, 0x1234567),
      ),
      _bCoeffs = List.unmodifiable(
        _generateCoefficients(numBands * rowsPerBand, 0x7654321),
      );

  /// Computes an N-dimensional MinHash signature for a set of [shingleHashes].
  ///
  /// Returns an empty list if [shingleHashes] is empty.
  List<int> computeSignature(Set<int> shingleHashes) {
    if (shingleHashes.isEmpty) return const [];

    final signature = List<int>.filled(numHashes, primeModulus);

    for (final shingle in shingleHashes) {
      final unsignedShingle = shingle & 0x7FFFFFFF;
      for (var i = 0; i < numHashes; i++) {
        final hashVal =
            ((_aCoeffs[i] * unsignedShingle) + _bCoeffs[i]) % primeModulus;
        if (hashVal < signature[i]) {
          signature[i] = hashVal;
        }
      }
    }

    return signature;
  }

  /// Computes [numBands] 64-bit integer band keys for Locality-Sensitive
  /// Hashing.
  List<int> computeLshBandKeys(List<int> signature) {
    if (signature.length != numHashes) return const [];

    final bandKeys = List<int>.filled(numBands, 0);
    for (var b = 0; b < numBands; b++) {
      var bandHash = b;
      final start = b * rowsPerBand;
      for (var r = 0; r < rowsPerBand; r++) {
        bandHash = Object.hash(bandHash, signature[start + r]);
      }
      bandKeys[b] = bandHash;
    }
    return bandKeys;
  }

  /// Estimates the Jaccard similarity between two MinHash [sig1] and [sig2].
  static double estimateSimilarity(List<int> sig1, List<int> sig2) {
    if (sig1.isEmpty || sig2.isEmpty || sig1.length != sig2.length) {
      return 0.0;
    }

    var matching = 0;
    for (var i = 0; i < sig1.length; i++) {
      if (sig1[i] == sig2[i]) {
        matching++;
      }
    }

    return matching / sig1.length;
  }

  /// Computes the exact Jaccard similarity between two sets: |A ∩ B| / |A ∪ B|.
  static double exactJaccard(Set<int> setA, Set<int> setB) {
    if (setA.isEmpty && setB.isEmpty) return 1.0;
    if (setA.isEmpty || setB.isEmpty) return 0.0;

    final smaller = setA.length <= setB.length ? setA : setB;
    final larger = setA.length <= setB.length ? setB : setA;

    var intersection = 0;
    for (final elem in smaller) {
      if (larger.contains(elem)) {
        intersection++;
      }
    }

    final union = setA.length + setB.length - intersection;
    return union > 0 ? intersection / union : 0.0;
  }

  static List<int> _generateCoefficients(int count, int seed) {
    final rand = math.Random(seed);
    final list = <int>[];
    for (var i = 0; i < count; i++) {
      // Non-zero multiplier in range [1, primeModulus - 1]
      final a = 1 + rand.nextInt(primeModulus - 1);
      list.add(a);
    }
    return list;
  }
}

/// Locality-Sensitive Hashing (LSH) candidate index for near-miss clone
/// pairing.
class LshIndex<T> {
  final MinHasher minHasher;
  final Map<int, List<T>> _buckets = {};

  LshIndex({MinHasher? minHasher}) : minHasher = minHasher ?? MinHasher();

  /// Inserts [item] into the LSH index given its MinHash [signature].
  void insert(T item, List<int> signature) {
    if (signature.isEmpty) return;
    final bandKeys = minHasher.computeLshBandKeys(signature);
    for (final key in bandKeys) {
      _buckets.putIfAbsent(key, () => []).add(item);
    }
  }

  /// Finds all unique candidate pairs that share at least one LSH bucket.
  List<({T item1, T item2})> findCandidatePairs() {
    final candidatePairs = <({T item1, T item2})>[];
    final seen = <int>{};

    for (final bucket in _buckets.values) {
      if (bucket.length < 2) continue;

      if (bucket.length <= 50) {
        _addSmallBucketPairs(bucket, seen, candidatePairs);
      } else {
        _addLargeBucketPairs(bucket, seen, candidatePairs);
      }
    }

    return candidatePairs;
  }

  void _addSmallBucketPairs(
    List<T> bucket,
    Set<int> seen,
    List<({T item1, T item2})> candidatePairs,
  ) {
    for (var i = 0; i < bucket.length; i++) {
      final a = bucket[i];
      for (var j = i + 1; j < bucket.length; j++) {
        final b = bucket[j];
        final pairKey = _pairHashCode(a, b);
        if (seen.add(pairKey)) {
          candidatePairs.add((item1: a, item2: b));
        }
      }
    }
  }

  void _addLargeBucketPairs(
    List<T> bucket,
    Set<int> seen,
    List<({T item1, T item2})> candidatePairs,
  ) {
    for (var i = 0; i < bucket.length - 1; i++) {
      final a = bucket[i];
      final b = bucket[i + 1];
      final pairKey = _pairHashCode(a, b);
      if (seen.add(pairKey)) {
        candidatePairs.add((item1: a, item2: b));
      }
    }
  }

  int _pairHashCode(T a, T b) {
    final hashA = a.hashCode;
    final hashB = b.hashCode;
    return hashA <= hashB
        ? Object.hash(hashA, hashB)
        : Object.hash(hashB, hashA);
  }
}
