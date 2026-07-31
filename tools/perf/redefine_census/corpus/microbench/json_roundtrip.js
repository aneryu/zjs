let text = JSON.stringify({ a: 1, b: [2, 3] });
let obj = JSON.parse(text);
print(obj.a);
