// Typed Arrays and ArrayBuffer smoke tests
const ab = new ArrayBuffer(16);
console.log(ab.byteLength);
console.log(ab.slice(0, 8));

const int8 = new Int8Array(ab);
console.log(int8.length);
console.log(int8.byteLength);
console.log(int8.byteOffset);

const uint8 = new Uint8Array(ab);
console.log(uint8.length);

const int16 = new Int16Array(ab);
console.log(int16.length);

const uint16 = new Uint16Array(ab);
console.log(uint16.length);

const int32 = new Int32Array(ab);
console.log(int32.length);

const uint32 = new Uint32Array(ab);
console.log(uint32.length);

const float32 = new Float32Array(ab);
console.log(float32.length);

const float64 = new Float64Array(ab);
console.log(float64.length);

const dv = new DataView(ab);
console.log(dv.buffer);
console.log(dv.byteLength);
console.log(dv.byteOffset);
console.log(dv.getInt8(0));
console.log(dv.getUint8(0));
console.log(dv.getInt16(0));
console.log(dv.getUint16(0));
console.log(dv.getInt32(0));
console.log(dv.getUint32(0));
console.log(dv.getFloat32(0));
console.log(dv.getFloat64(0));
dv.setInt8(0, 1);
dv.setUint8(0, 1);
dv.setInt16(0, 1);
dv.setUint16(0, 1);
dv.setInt32(0, 1);
dv.setUint32(0, 1);
dv.setFloat32(0, 1.0);
dv.setFloat64(0, 1.0);
