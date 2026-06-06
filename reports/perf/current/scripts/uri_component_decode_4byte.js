function decimalToPercentHexString(n) {
  var hex = "0123456789ABCDEF";
  return "%" + hex[(n >> 4) & 0xf] + hex[n & 0xf];
}
var count = 0;
for (var repeat = 0; repeat < 16; repeat++) {
  for (var indexB3 = 0x80; indexB3 <= 0xBF; indexB3++) {
    var hexB1_B2_B3 = "%F0%A0" + decimalToPercentHexString(indexB3);
    for (var indexB4 = 0x80; indexB4 <= 0xBF; indexB4++) {
      var hexB1_B2_B3_B4 = hexB1_B2_B3 + decimalToPercentHexString(indexB4);
      var index = (0xF0 & 0x07) * 0x40000 + (0xA0 & 0x3F) * 0x1000 + (indexB3 & 0x3F) * 0x40 + (indexB4 & 0x3F);
      var L = ((index - 0x10000) & 0x03FF) + 0xDC00;
      var H = (((index - 0x10000) >> 10) & 0x03FF) + 0xD800;
      if (decodeURIComponent(hexB1_B2_B3_B4) === String.fromCharCode(H, L)) count++;
    }
  }
}
print(count);
