// Test String constructor
const s = new String("Hello");
print(s.charAt(0));
print(s.substring(0, 3));
print(s.toUpperCase());
print(typeof String([1, 2]));
print(String([1, 2]));
print(String(null));
print(String(undefined));
print(new String(null).toString());

// Test fromCharCode
print(String.fromCharCode(72, 101, 108, 108, 111));
