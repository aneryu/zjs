function stringLoop(iterations) {
  var text = "";
  for (var i = 0; i < iterations; i++) {
    text += String.fromCharCode(97 + (i % 26));
    if (text.length > 64) text = text.slice(16);
  }
  return text.length + text.charCodeAt(0) + text.charCodeAt(text.length - 1);
}

print(stringLoop(5000));
