/// Throwaway probe. Deleted before merge.
library;

/// Deliberately convoluted; scores well above a threshold of 15.
int probe(int x) {
  if (x > 0) {
    for (var i = 0; i < x; i++) {
      if (i % 2 == 0) {
        x++;
      } else {
        x--;
      }
    }
    if (x > 1) {
      for (var i = 0; i < x; i++) {
        if (i % 2 == 0) {
          x++;
        } else {
          x--;
        }
      }
      if (x > 2) {
        for (var i = 0; i < x; i++) {
          if (i % 2 == 0) {
            x++;
          } else {
            x--;
          }
        }
      }
    }
  }
  return x;
}
