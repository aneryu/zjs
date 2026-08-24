// Standalone V8-type shim for compiling Irregexp as an external embedder.
// Include path is `vendor/`, so `#include "irregexp/RegExpShim.h"` resolves here.

#ifndef IRREGEXP_REGEXP_SHIM_H_
#define IRREGEXP_REGEXP_SHIM_H_

#include <algorithm>
#include <cassert>
#include <cctype>
#include <climits>
#include <cmath>
#include <cstdarg>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <iostream>
#include <limits>
#include <map>
#include <memory>
#include <new>
#include <optional>
#include <ostream>
#include <string>
#include <string_view>
#include <type_traits>
#include <unordered_map>
#include <utility>
#include <vector>

// ---------------------------------------------------------------------------
// Compiler / language macros
// ---------------------------------------------------------------------------

#ifndef V8_EXPORT_PRIVATE
#define V8_EXPORT_PRIVATE
#endif

#ifndef V8_INLINE
#define V8_INLINE inline
#endif

#ifndef V8_NOEXCEPT
#define V8_NOEXCEPT noexcept
#endif

#ifndef V8_NODISCARD
#define V8_NODISCARD [[nodiscard]]
#endif

#ifndef V8_WARN_UNUSED_RESULT
#define V8_WARN_UNUSED_RESULT [[nodiscard]]
#endif

#ifndef V8_ALLOW_UNUSED
#define V8_ALLOW_UNUSED __attribute__((unused))
#endif

#ifndef V8_FALLTHROUGH
#define V8_FALLTHROUGH [[fallthrough]]
#endif

#ifndef V8_GSL_POINTER
#define V8_GSL_POINTER
#endif

#ifndef V8_LIFETIME_BOUND
#define V8_LIFETIME_BOUND
#endif

#ifndef V8_LIKELY
#define V8_LIKELY(x) __builtin_expect(!!(x), 1)
#endif
#ifndef V8_UNLIKELY
#define V8_UNLIKELY(x) __builtin_expect(!!(x), 0)
#endif

#ifndef V8_TARGET_LITTLE_ENDIAN
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
#define V8_TARGET_LITTLE_ENDIAN 1
#elif defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
// Big endian: leave the macro undefined.
#else
#define V8_TARGET_LITTLE_ENDIAN 1
#endif
#endif

#ifndef arraysize
#define arraysize(a) (static_cast<int>(sizeof(a) / sizeof((a)[0])))
#endif

#define IR_EXPAND(...) __VA_ARGS__
#define UNPAREN(x) IR_EXPAND x

#define GET_NTH_ARG_1(a1, ...) a1
#define GET_NTH_ARG_2(a1, a2, ...) a2
#define GET_NTH_ARG_3(a1, a2, a3, ...) a3
#define GET_NTH_ARG_4(a1, a2, a3, a4, ...) a4
#define GET_NTH_ARG_5(a1, a2, a3, a4, a5, ...) a5
#define GET_NTH_ARG(N, ...) GET_NTH_ARG_##N(__VA_ARGS__)

// True iff the varargs list is empty. `#__VA_ARGS__` is "" (size 1) when empty.
#define IS_VA_EMPTY(...) (sizeof(#__VA_ARGS__) == 1)

#define DISALLOW_COPY_AND_ASSIGN(Type) \
  Type(const Type&) = delete;          \
  void operator=(const Type&) = delete

#define DISALLOW_IMPLICIT_CONSTRUCTORS(Type) \
  Type() = delete;                           \
  DISALLOW_COPY_AND_ASSIGN(Type)

#define DISALLOW_NEW()                            \
  void* operator new(size_t) = delete;            \
  void* operator new[](size_t) = delete;          \
  void* operator new(size_t, void*) = delete;     \
  void* operator new[](size_t, void*) = delete

#define ZONE_NAME __FILE__

#ifndef kUnalignedReadSupported
static constexpr bool kUnalignedReadSupported = true;
#endif

inline void MemCopy(void* dest, const void* src, size_t n) {
  if (n == 0) return;
  std::memcpy(dest, src, n);
}

#define PROFILE(isolate, call) ((void)0)

// ---------------------------------------------------------------------------
// Assertions
// ---------------------------------------------------------------------------

[[noreturn]] inline void IrregexpFatal(const char* file, int line,
                                       const char* msg) {
  std::fprintf(stderr, "IRREGEXP FATAL %s:%d: %s\n", file, line, msg);
  std::abort();
}

#define FATAL(...) \
  IrregexpFatal(__FILE__, __LINE__, #__VA_ARGS__)

#define UNREACHABLE() FATAL("UNREACHABLE")
#define UNIMPLEMENTED() FATAL("UNIMPLEMENTED")

#define STATIC_ASSERT(cond) static_assert(cond, #cond)

#define CHECK(cond)                                           \
  do {                                                        \
    if (V8_UNLIKELY(!(cond))) {                               \
      IrregexpFatal(__FILE__, __LINE__, "CHECK(" #cond ")");  \
    }                                                         \
  } while (false)

#define CHECK_EQ(a, b) CHECK((a) == (b))
#define CHECK_NE(a, b) CHECK((a) != (b))
#define CHECK_LT(a, b) CHECK((a) < (b))
#define CHECK_LE(a, b) CHECK((a) <= (b))
#define CHECK_GT(a, b) CHECK((a) > (b))
#define CHECK_GE(a, b) CHECK((a) >= (b))
#define CHECK_NULL(p) CHECK((p) == nullptr)
#define CHECK_NOT_NULL(p) CHECK((p) != nullptr)
#define CHECK_IMPLIES(a, b) CHECK(!(a) || (b))

#ifdef DEBUG
#define DCHECK(cond) CHECK(cond)
#define CONSTEXPR_DCHECK(cond) CHECK(cond)
#define DCHECK_EQ(a, b) CHECK_EQ(a, b)
#define DCHECK_NE(a, b) CHECK_NE(a, b)
#define DCHECK_LT(a, b) CHECK_LT(a, b)
#define DCHECK_LE(a, b) CHECK_LE(a, b)
#define DCHECK_GT(a, b) CHECK_GT(a, b)
#define DCHECK_GE(a, b) CHECK_GE(a, b)
#define DCHECK_NULL(p) CHECK_NULL(p)
#define DCHECK_NOT_NULL(p) CHECK_NOT_NULL(p)
#define DCHECK_IMPLIES(a, b) CHECK_IMPLIES(a, b)
#else
#define DCHECK(cond) ((void)0)
#define CONSTEXPR_DCHECK(cond) ((void)0)
#define DCHECK_EQ(a, b) ((void)0)
#define DCHECK_NE(a, b) ((void)0)
#define DCHECK_LT(a, b) ((void)0)
#define DCHECK_LE(a, b) ((void)0)
#define DCHECK_GT(a, b) ((void)0)
#define DCHECK_GE(a, b) ((void)0)
#define DCHECK_NULL(p) ((void)0)
#define DCHECK_NOT_NULL(p) ((void)0)
#define DCHECK_IMPLIES(a, b) ((void)0)
#endif

#define SBXCHECK(cond) CHECK(cond)
#define SBXCHECK_EQ(a, b) CHECK_EQ(a, b)
#define SBXCHECK_NE(a, b) CHECK_NE(a, b)
#define SBXCHECK_LT(a, b) CHECK_LT(a, b)
#define SBXCHECK_LE(a, b) CHECK_LE(a, b)
#define SBXCHECK_GT(a, b) CHECK_GT(a, b)
#define SBXCHECK_GE(a, b) CHECK_GE(a, b)
#define SBXCHECK_NULL(p) CHECK_NULL(p)
#define SBXCHECK_NOT_NULL(p) CHECK_NOT_NULL(p)
#define SBXCHECK_IMPLIES(a, b) CHECK_IMPLIES(a, b)

// ---------------------------------------------------------------------------
// Unicode C hooks (implemented later in Zig; weak ASCII fallbacks in .cpp)
// ---------------------------------------------------------------------------

extern "C" uint32_t zjs_irregexp_canonicalize(uint32_t c, int unicode);
extern "C" int zjs_irregexp_uncanonicalize(uint32_t c, uint32_t* out,
                                           int max_out);
extern "C" int zjs_irregexp_is_identifier_start(uint32_t c);
extern "C" int zjs_irregexp_is_identifier_part(uint32_t c);
extern "C" int zjs_irregexp_is_letter(uint32_t c);

namespace v8 {

using Address = uintptr_t;
static constexpr Address kNullAddress = 0;

template <typename T>
inline T RoundDown(T x, T m) {
  DCHECK(m != 0 && (m & (m - 1)) == 0);
  return x & static_cast<T>(-m);
}

template <size_t alignment, typename T>
inline constexpr T RoundUp(T x) {
  static_assert(alignment != 0 && (alignment & (alignment - 1)) == 0);
  return static_cast<T>((x + static_cast<T>(alignment - 1)) &
                        ~static_cast<T>(alignment - 1));
}

inline constexpr bool IsAligned(Address value, size_t alignment) {
  return (value & (alignment - 1)) == 0;
}

template <typename T>
inline constexpr bool IsAligned(T value, T alignment) {
  return (static_cast<uintptr_t>(value) &
          (static_cast<uintptr_t>(alignment) - 1)) == 0;
}

template <typename T, typename A>
inline constexpr T RoundUp(T x, A alignment) {
  const auto a = static_cast<T>(alignment);
  return static_cast<T>((x + a - 1) & ~(a - 1));
}

template <typename T>
inline void USE(T&&) {}

inline uintptr_t GetCurrentStackPosition() {
  return reinterpret_cast<uintptr_t>(__builtin_frame_address(0));
}

namespace base {

using uc16 = char16_t;
using uc32 = uint32_t;
static constexpr int kUC16Size = 2;

inline int HexValue(uc32 c) {
  if (c >= '0' && c <= '9') return static_cast<int>(c - '0');
  if (c >= 'a' && c <= 'f') return static_cast<int>(c - 'a' + 10);
  if (c >= 'A' && c <= 'F') return static_cast<int>(c - 'A' + 10);
  return -1;
}

template <typename T, typename U>
inline constexpr bool IsInRange(T value, U lower, U upper) {
  return !(value < static_cast<T>(lower)) && !(static_cast<T>(upper) < value);
}

template <typename Dst, typename Src>
inline Dst saturated_cast(Src value) {
  constexpr Src min = static_cast<Src>(std::numeric_limits<Dst>::lowest());
  constexpr Src max = static_cast<Src>(std::numeric_limits<Dst>::max());
  if (value < min) return std::numeric_limits<Dst>::lowest();
  if (value > max) return std::numeric_limits<Dst>::max();
  return static_cast<Dst>(value);
}

inline size_t hash_combine_impl() { return 0; }

template <typename T>
inline size_t hash_combine_impl(const T& v) {
  return std::hash<T>{}(v);
}

template <typename T, typename... Rest>
inline size_t hash_combine_impl(const T& v, const Rest&... rest) {
  size_t seed = hash_combine_impl(rest...);
  seed ^= std::hash<T>{}(v) + 0x9e3779b9 + (seed << 6) + (seed >> 2);
  return seed;
}

template <typename... Args>
inline size_t hash_combine(const Args&... args) {
  return hash_combine_impl(args...);
}

template <typename T>
class CheckedNumeric {
 public:
  explicit CheckedNumeric(T v) : value_(v), valid_(true) {}
  CheckedNumeric& operator+=(T rhs) {
    if (!valid_) return *this;
    if (rhs > 0 && value_ > std::numeric_limits<T>::max() - rhs) {
      valid_ = false;
    } else if (rhs < 0 && value_ < std::numeric_limits<T>::lowest() - rhs) {
      valid_ = false;
    } else {
      value_ = static_cast<T>(value_ + rhs);
    }
    return *this;
  }
  bool IsValid() const { return valid_; }
  T ValueOrDie() const {
    CHECK(valid_);
    return value_;
  }
  T ValueOrDefault(T fallback) const { return valid_ ? value_ : fallback; }

 private:
  T value_;
  bool valid_;
};

namespace bits {

inline constexpr bool IsPowerOfTwo(uint32_t x) {
  return x != 0 && (x & (x - 1)) == 0;
}
inline constexpr bool IsPowerOfTwo(int x) {
  return x > 0 && (x & (x - 1)) == 0;
}
inline constexpr bool IsPowerOfTwo(size_t x) {
  return x != 0 && (x & (x - 1)) == 0;
}

inline int CountTrailingZeros(uint32_t x) {
  DCHECK_NE(x, 0u);
  return __builtin_ctz(x);
}
inline int CountTrailingZeros(uint64_t x) {
  DCHECK_NE(x, 0u);
  return __builtin_ctzll(x);
}
inline int CountLeadingZeros(uint32_t x) {
  DCHECK_NE(x, 0u);
  return __builtin_clz(x);
}
inline int CountLeadingZeros(uint64_t x) {
  DCHECK_NE(x, 0u);
  return __builtin_clzll(x);
}
inline int CountPopulation(uint32_t x) { return __builtin_popcount(x); }
inline int CountPopulation(uint64_t x) { return __builtin_popcountll(x); }

inline uint32_t RoundUpToPowerOfTwo32(uint32_t x) {
  if (x <= 1) return 1;
  return static_cast<uint32_t>(1) << (32 - CountLeadingZeros(x - 1));
}

inline size_t RoundUpToPowerOfTwo(size_t x) {
  if (x <= 1) return 1;
  if constexpr (sizeof(size_t) == 8) {
    return static_cast<size_t>(1) << (64 - CountLeadingZeros(static_cast<uint64_t>(x - 1)));
  } else {
    return RoundUpToPowerOfTwo32(static_cast<uint32_t>(x));
  }
}

}  // namespace bits

template <typename Enum>
class Flags {
 public:
  using flag_type = Enum;
  using mask_type = std::underlying_type_t<Enum>;

  constexpr Flags() : mask_(0) {}
  constexpr Flags(Enum flag) : mask_(static_cast<mask_type>(flag)) {}
  constexpr Flags(mask_type mask) : mask_(mask) {}
  constexpr operator mask_type() const { return mask_; }
  constexpr bool operator==(Flags o) const { return mask_ == o.mask_; }
  constexpr bool operator!=(Flags o) const { return mask_ != o.mask_; }
  constexpr Flags operator|(Flags o) const { return Flags(mask_ | o.mask_); }
  constexpr Flags operator&(Flags o) const { return Flags(mask_ & o.mask_); }
  constexpr Flags operator^(Flags o) const { return Flags(mask_ ^ o.mask_); }
  constexpr Flags operator|(Enum e) const { return *this | Flags(e); }
  constexpr Flags operator&(Enum e) const { return *this & Flags(e); }
  constexpr Flags operator^(Enum e) const { return *this ^ Flags(e); }
  constexpr Flags operator~() const { return Flags(~mask_); }
  Flags& operator|=(Flags o) {
    mask_ |= o.mask_;
    return *this;
  }
  Flags& operator&=(Flags o) {
    mask_ &= o.mask_;
    return *this;
  }
  Flags& operator^=(Flags o) {
    mask_ ^= o.mask_;
    return *this;
  }
  Flags& operator|=(Enum e) { return *this |= Flags(e); }
  Flags& operator&=(Enum e) { return *this &= Flags(e); }
  Flags& operator^=(Enum e) { return *this ^= Flags(e); }
  constexpr bool without_any_of(Flags o) const {
    return (mask_ & o.mask_) == 0;
  }
  constexpr bool operator==(mask_type o) const { return mask_ == o; }
  constexpr bool operator!=(mask_type o) const { return mask_ != o; }
  constexpr explicit operator bool() const { return mask_ != 0; }
  constexpr mask_type bits() const { return mask_; }
  void set(Enum flag, bool value) {
    if (value) {
      mask_ |= static_cast<mask_type>(flag);
    } else {
      mask_ &= static_cast<mask_type>(~static_cast<mask_type>(flag));
    }
  }

 private:
  mask_type mask_;
};

#define DEFINE_OPERATORS_FOR_FLAGS(Type)                                      \
  inline constexpr Type operator|(Type::flag_type a, Type::flag_type b) {     \
    return Type(a) | Type(b);                                                 \
  }                                                                           \
  inline constexpr Type operator|(Type a, Type::flag_type b) {                \
    return a | Type(b);                                                       \
  }                                                                           \
  inline constexpr Type operator|(Type::flag_type a, Type b) {                \
    return Type(a) | b;                                                       \
  }                                                                           \
  inline constexpr Type operator&(Type a, Type::flag_type b) {                \
    return a & Type(b);                                                       \
  }                                                                           \
  inline constexpr Type operator&(Type::flag_type a, Type b) {                \
    return Type(a) & b;                                                       \
  }                                                                           \
  inline constexpr bool operator==(Type a, Type::flag_type b) {               \
    return a == Type(b);                                                      \
  }                                                                           \
  inline constexpr bool operator==(Type::flag_type a, Type b) {               \
    return Type(a) == b;                                                      \
  }                                                                           \
  inline constexpr bool operator!=(Type a, Type::flag_type b) {               \
    return a != Type(b);                                                      \
  }                                                                           \
  inline constexpr bool operator!=(Type::flag_type a, Type b) {               \
    return Type(a) != b;                                                      \
  }

template <typename T, int shift, int size, typename U = uint32_t>
class BitField {
 public:
  static constexpr int kShift = shift;
  static constexpr int kSize = size;
  static constexpr U kMask = (size == 32 && shift == 0)
                                 ? ~U{0}
                                 : ((U{1} << size) - 1) << shift;

  static constexpr T decode(U value) {
    return static_cast<T>((value & kMask) >> shift);
  }
  static constexpr U encode(T value) {
    return (static_cast<U>(value) << shift) & kMask;
  }
  static constexpr U update(U previous, T value) {
    return (previous & ~kMask) | encode(value);
  }

  template <typename T2, int size2>
  using Next = BitField<T2, shift + size, size2, U>;
};

template <typename T>
class Vector {
 public:
  Vector() : start_(nullptr), length_(0) {}
  Vector(T* start, size_t length) : start_(start), length_(length) {}
  Vector(T* start, int length)
      : start_(start), length_(length < 0 ? 0 : static_cast<size_t>(length)) {}

  template <typename U, typename = std::enable_if_t<
                            std::is_convertible_v<U*, T*>>>
  Vector(const Vector<U>& other)
      : start_(other.begin()), length_(other.size()) {}

  T* begin() const { return start_; }
  T* end() const { return start_ + length_; }
  T* data() const { return start_; }
  int length() const { return static_cast<int>(length_); }
  size_t size() const { return length_; }
  bool empty() const { return length_ == 0; }
  T& operator[](int i) const {
    DCHECK_GE(i, 0);
    DCHECK_LT(i, length());
    return start_[i];
  }
  T& at(int i) const { return (*this)[i]; }

  Vector<T> SubVector(int from, int to) const {
    DCHECK_GE(from, 0);
    DCHECK_LE(to, length());
    DCHECK_LE(from, to);
    return Vector<T>(start_ + from, to - from);
  }

 private:
  T* start_;
  size_t length_;
};

template <typename T>
inline Vector<T> VectorOf(T* start, size_t length) {
  return Vector<T>(start, length);
}

template <typename T, typename Alloc>
inline Vector<T> VectorOf(std::vector<T, Alloc>& v) {
  return Vector<T>(v.data(), v.size());
}

template <typename T, size_t N>
inline Vector<T> ArrayVector(T (&arr)[N]) {
  return Vector<T>(arr, N);
}

template <typename T, size_t N>
class SmallVector {
 public:
  SmallVector() : data_(inline_ptr()), size_(0), capacity_(N), on_heap_(false) {}
  explicit SmallVector(size_t n, const T& value = T())
      : SmallVector() {
    resize(n, value);
  }
  SmallVector(const SmallVector& other) : SmallVector() {
    assign_from(other);
  }
  SmallVector(SmallVector&& other) noexcept : SmallVector() {
    move_from(std::move(other));
  }
  SmallVector& operator=(const SmallVector& other) {
    if (this != &other) assign_from(other);
    return *this;
  }
  SmallVector& operator=(SmallVector&& other) noexcept {
    if (this != &other) move_from(std::move(other));
    return *this;
  }
  ~SmallVector() { destroy_all(); }

  void push_back(const T& v) { emplace_back(v); }
  void push_back(T&& v) { emplace_back(std::move(v)); }

  template <typename... Args>
  T& emplace_back(Args&&... args) {
    grow_if_needed(size_ + 1);
    T* slot = data_ + size_;
    new (slot) T(std::forward<Args>(args)...);
    ++size_;
    return *slot;
  }

  void resize(size_t n, const T& value = T()) {
    if (n < size_) {
      for (size_t i = n; i < size_; ++i) data_[i].~T();
      size_ = n;
      return;
    }
    grow_if_needed(n);
    for (size_t i = size_; i < n; ++i) new (data_ + i) T(value);
    size_ = n;
  }

  T* data() { return data_; }
  const T* data() const { return data_; }
  T* begin() { return data_; }
  const T* begin() const { return data_; }
  T* end() { return data_ + size_; }
  const T* end() const { return data_ + size_; }
  size_t size() const { return size_; }
  bool empty() const { return size_ == 0; }
  T& operator[](size_t i) { return data_[i]; }
  const T& operator[](size_t i) const { return data_[i]; }
  T& at(size_t i) { return data_[i]; }
  const T& at(size_t i) const { return data_[i]; }
  T& back() { return data_[size_ - 1]; }
  const T& back() const { return data_[size_ - 1]; }
  void pop_back() {
    DCHECK_GT(size_, 0u);
    data_[--size_].~T();
  }
  void clear() { resize(0); }

  T* insert(T* pos, const SmallVector& other) {
    return insert(pos, other.begin(), other.end());
  }

  template <typename It>
  T* insert(T* pos, It first, It last) {
    const size_t index = static_cast<size_t>(pos - data_);
    const size_t add = static_cast<size_t>(std::distance(first, last));
    if (add == 0) return data_ + index;
    grow_if_needed(size_ + add);
    for (size_t i = size_; i > index; --i) {
      new (data_ + i + add - 1) T(std::move(data_[i - 1]));
      data_[i - 1].~T();
    }
    size_t i = index;
    for (It it = first; it != last; ++it, ++i) {
      new (data_ + i) T(*it);
    }
    size_ += add;
    return data_ + index;
  }
  void resize_no_init(size_t n) {
    grow_if_needed(n);
    if (n > size_) {
      for (size_t i = size_; i < n; ++i) new (data_ + i) T();
    } else {
      for (size_t i = n; i < size_; ++i) data_[i].~T();
    }
    size_ = n;
  }

 private:
  T* inline_ptr() { return reinterpret_cast<T*>(inline_storage_); }
  const T* inline_ptr() const {
    return reinterpret_cast<const T*>(inline_storage_);
  }

  void grow_if_needed(size_t needed) {
    if (needed <= capacity_) return;
    size_t new_cap = capacity_ < 8 ? 8 : capacity_ * 2;
    while (new_cap < needed) new_cap *= 2;
    T* fresh = static_cast<T*>(::operator new(new_cap * sizeof(T)));
    for (size_t i = 0; i < size_; ++i) {
      new (fresh + i) T(std::move(data_[i]));
      data_[i].~T();
    }
    if (on_heap_) ::operator delete(data_);
    data_ = fresh;
    capacity_ = new_cap;
    on_heap_ = true;
  }

  void destroy_all() {
    for (size_t i = 0; i < size_; ++i) data_[i].~T();
    if (on_heap_) ::operator delete(data_);
    size_ = 0;
    on_heap_ = false;
    data_ = inline_ptr();
    capacity_ = N;
  }

  void assign_from(const SmallVector& other) {
    destroy_all();
    grow_if_needed(other.size_);
    for (size_t i = 0; i < other.size_; ++i) new (data_ + i) T(other.data_[i]);
    size_ = other.size_;
  }

  void move_from(SmallVector&& other) {
    destroy_all();
    if (other.on_heap_) {
      data_ = other.data_;
      size_ = other.size_;
      capacity_ = other.capacity_;
      on_heap_ = true;
      other.data_ = other.inline_ptr();
      other.size_ = 0;
      other.capacity_ = N;
      other.on_heap_ = false;
    } else {
      grow_if_needed(other.size_);
      for (size_t i = 0; i < other.size_; ++i) {
        new (data_ + i) T(std::move(other.data_[i]));
      }
      size_ = other.size_;
    }
  }

  alignas(T) char inline_storage_[N == 0 ? 1 : N * sizeof(T)];
  T* data_;
  size_t size_;
  size_t capacity_;
  bool on_heap_;
};

template <typename T, size_t N>
inline Vector<T> VectorOf(SmallVector<T, N>& v) {
  return Vector<T>(v.data(), v.size());
}

template <typename T, size_t N>
inline Vector<const T> VectorOf(const SmallVector<T, N>& v) {
  return Vector<const T>(v.data(), v.size());
}

#define LAZY_INSTANCE_INITIALIZER \
  {}

#define DEFINE_LAZY_LEAKY_OBJECT_GETTER(Type, Name) \
  static Type* Name() {                             \
    static Type* instance = new Type();             \
    return instance;                                \
  }

template <typename T>
class LazyInstance {
 public:
  T* Pointer() {
    if (!ptr_) ptr_ = std::make_unique<T>();
    return ptr_.get();
  }
  T& Get() { return *Pointer(); }

 private:
  std::unique_ptr<T> ptr_;
};

}  // namespace base

// ---------------------------------------------------------------------------
// unibrow
// ---------------------------------------------------------------------------

namespace unibrow {

using uchar = uint32_t;

class Latin1 {
 public:
  static const uchar kMaxChar = 0xff;
};

class Utf16 {
 public:
  static const int kMaxNonSurrogateCharCode = 0xffff;
  static constexpr uchar kLeadSurrogateMin = 0xd800;
  static constexpr uchar kLeadSurrogateMax = 0xdbff;
  static constexpr uchar kTrailSurrogateMin = 0xdc00;
  static constexpr uchar kTrailSurrogateMax = 0xdfff;

  static bool IsLeadSurrogate(uchar c) {
    return c >= kLeadSurrogateMin && c <= kLeadSurrogateMax;
  }
  static bool IsTrailSurrogate(uchar c) {
    return c >= kTrailSurrogateMin && c <= kTrailSurrogateMax;
  }
  static uchar CombineSurrogatePair(uchar lead, uchar trail) {
    return 0x10000 + ((lead - kLeadSurrogateMin) << 10) +
           (trail - kTrailSurrogateMin);
  }
  static uchar LeadSurrogate(uchar c) {
    return kLeadSurrogateMin + ((c - 0x10000) >> 10);
  }
  static uchar TrailSurrogate(uchar c) {
    return kTrailSurrogateMin + ((c - 0x10000) & 0x3ff);
  }
};

template <class T>
class Mapping {
 public:
  int get(uchar c, uchar hint, uchar* result) {
    for (int i = 0; i < kCacheSize; i++) {
      if (cache_[i].from == c) {
        int n = cache_[i].len;
        for (int j = 0; j < n; j++) result[j] = cache_[i].to[j];
        return n;
      }
    }
    bool cacheable = true;
    int n = T::Convert(c, hint, result, &cacheable);
    if (cacheable && n >= 0 && n <= T::kMaxWidth) {
      CacheEntry& e = cache_[next_];
      e.from = c;
      e.len = n;
      for (int j = 0; j < n; j++) e.to[j] = result[j];
      next_ = (next_ + 1) % kCacheSize;
    }
    return n;
  }

 private:
  static constexpr int kCacheSize = 8;
  struct CacheEntry {
    uchar from = 0xffffffffu;
    uchar to[T::kMaxWidth] = {};
    int len = 0;
  };
  CacheEntry cache_[kCacheSize];
  int next_ = 0;
};

struct Ecma262Canonicalize {
  static const int kMaxWidth = 1;
  static int Convert(uchar c, uchar hint, uchar* result, bool* cached);
};

struct Ecma262UnCanonicalize {
  static const int kMaxWidth = 4;
  static int Convert(uchar c, uchar hint, uchar* result, bool* cached);
};

struct CanonicalizationRange {
  static const int kMaxWidth = 1;
  static int Convert(uchar c, uchar hint, uchar* result, bool* cached);
};

class Letter {
 public:
  static bool Is(uchar c) { return zjs_irregexp_is_letter(c) != 0; }
};

}  // namespace unibrow

namespace internal {

class Isolate;
class Zone;
class Factory;
class Heap;
class AccountingAllocator;
class String;
class ByteArray;
class TrustedByteArray;
class FixedUInt16Array;
class JSRegExp;
class RegExpData;
class IrRegExpData;
class Object;
class HeapObject;
class Smi;
class Code;
class AbstractCode;
class InstructionStream;
class ConsString;
class SlicedString;
class ThinString;
class TrustedFixedArray;
class TrustedObject;
class RegExpMatchInfo;
class AtomRegExpData;
class MacroAssembler;
class ExternalReference;
class Assembler;
class Displacement;

namespace regexp {
enum class Flag : int;
class BytecodeGenerator;
class BytecodeWriter;
class Stack;
class Node;
}  // namespace regexp

// ---------------------------------------------------------------------------
// Constants / utilities
// ---------------------------------------------------------------------------

class AllStatic {
  AllStatic() = delete;
};

class Malloced {
 public:
  void* operator new(size_t size) { return std::malloc(size); }
  void operator delete(void* p) { std::free(p); }
};

static constexpr int KB = 1024;
static constexpr int MB = 1024 * 1024;
static constexpr int kMaxInt = std::numeric_limits<int>::max();
static constexpr int kMinInt = std::numeric_limits<int>::min();
static constexpr int kSystemPointerSize = static_cast<int>(sizeof(void*));
static constexpr int kBitsPerByte = 8;
static constexpr int kBitsPerByteLog2 = 3;
static constexpr int kInt32Size = 4;
static constexpr int kInt64Size = 8;
static constexpr int kUInt32Size = 4;
static constexpr int kUInt64Size = 8;
static constexpr int kUInt16Size = 2;
static constexpr int kSystemPointerSizeLog2 = sizeof(void*) == 8 ? 3 : 2;
static constexpr uint16_t kMaxUInt16 = 0xffff;
static constexpr uint32_t kMaxUInt32 = 0xffffffffu;

struct AsUC32 {
  uint32_t c;
  template <typename T>
  AsUC32(T v) : c(static_cast<uint32_t>(v)) {}  // NOLINT
};

inline std::ostream& operator<<(std::ostream& os, AsUC32 uc) {
  const char* hex = "0123456789ABCDEF";
  os << "U+";
  for (int i = 5; i >= 0; --i) os << hex[(uc.c >> (i * 4)) & 0xF];
  return os;
}

template <typename T>
struct AsHex {
  T value;
  int width;
  AsHex(T v, int w) : value(v), width(w) {}
};

template <typename T>
inline std::ostream& operator<<(std::ostream& os, AsHex<T> h) {
  static const char kHex[] = "0123456789abcdef";
  uint64_t v = static_cast<uint64_t>(h.value);
  const int width = h.width > 0 ? h.width : 1;
  for (int i = width - 1; i >= 0; --i) {
    os << kHex[(v >> (static_cast<unsigned>(i) * 4)) & 0xF];
  }
  return os;
}

inline bool IsDecimalDigit(base::uc32 c) { return c >= '0' && c <= '9'; }
inline int AsciiAlphaToLower(base::uc32 c) {
  return static_cast<int>(c | 0x20);
}

inline bool IsIdentifierStart(base::uc32 c) {
  return zjs_irregexp_is_identifier_start(c) != 0;
}
inline bool IsIdentifierPart(base::uc32 c) {
  return zjs_irregexp_is_identifier_part(c) != 0;
}

void PrintF(const char* format, ...);
void PrintF(FILE* out, const char* format, ...);

class StdoutStream : public std::ostream {
 public:
  StdoutStream() : std::ostream(std::cout.rdbuf()) {}
};

template <typename T>
using Maybe = std::optional<T>;

template <typename T>
inline std::optional<T> Just(const T& v) {
  return std::optional<T>(v);
}
inline std::nullopt_t Nothing() { return std::nullopt; }

template <typename CharA, typename CharB>
inline int CompareChars(const CharA* a, const CharB* b, int length) {
  for (int i = 0; i < length; i++) {
    if (a[i] != b[i]) return static_cast<int>(a[i]) - static_cast<int>(b[i]);
  }
  return 0;
}

template <typename CharA, typename CharB>
inline bool CompareCharsEqual(const CharA* a, const CharB* b, int length) {
  return CompareChars(a, b, length) == 0;
}

template <typename T>
inline T* NewArray(size_t size) {
  if (size == 0) return nullptr;
  T* p = static_cast<T*>(std::malloc(size * sizeof(T)));
  if (!p) FATAL("NewArray OOM");
  return p;
}

template <typename T>
inline void DeleteArray(T* p) {
  std::free(p);
}

enum class AllocationType { kYoung, kOld };

class SafeHeapObjectSize {
 public:
  SafeHeapObjectSize() : value_(0) {}
  explicit SafeHeapObjectSize(uint32_t v) : value_(v) {}
  uint32_t value() const { return value_; }

 private:
  uint32_t value_;
};

class AccountingAllocator {
 public:
  void* AllocateSegment(size_t n) {
    void* p = std::malloc(n);
    if (!p) FATAL("AccountingAllocator OOM");
    return p;
  }
  void FreeSegment(void* p) { std::free(p); }
};

// ---------------------------------------------------------------------------
// Label (copied from V8 src/codegen/label.h, including bind_to/link_to)
// ---------------------------------------------------------------------------

class Label {
 public:
  enum Distance {
    kNear,  // near jump: 8 bit displacement (signed)
    kFar    // far jump: 32 bit displacement (signed)
  };

  Label() = default;

#ifdef DEBUG
  ~Label() { DCHECK(!is_linked()); }
#endif

  V8_INLINE void Unuse() { pos_ = 0; }
  V8_INLINE void UnuseNear() { near_link_pos_ = 0; }

  V8_INLINE bool is_bound() const { return pos_ < 0; }
  V8_INLINE bool is_unused() const { return pos_ == 0 && near_link_pos_ == 0; }
  V8_INLINE bool is_linked() const { return pos_ > 0; }
  V8_INLINE bool is_near_linked() const { return near_link_pos_ > 0; }

  int pos() const {
    if (pos_ < 0) return -pos_ - 1;
    if (pos_ > 0) return pos_ - 1;
    UNREACHABLE();
  }

  int near_link_pos() const { return near_link_pos_ - 1; }

 private:
  int pos_ = 0;
  int near_link_pos_ = 0;

  void bind_to(int pos) {
    pos_ = -pos - 1;
    DCHECK(is_bound());
  }
  void link_to(int pos, Distance distance = kFar) {
    if (distance == kNear) {
      near_link_pos_ = pos + 1;
      DCHECK(is_near_linked());
    } else {
      pos_ = pos + 1;
      DCHECK(is_linked());
    }
  }

  friend class Assembler;
  friend class Displacement;
  friend class regexp::BytecodeGenerator;
  friend class regexp::BytecodeWriter;
};

using BitField = base::BitField<uint32_t, 0, 32, uint32_t>;

// ---------------------------------------------------------------------------
// Heap objects (no GC movement)
// ---------------------------------------------------------------------------

class Object {
 public:
  virtual ~Object() = default;
  Address ptr() const { return reinterpret_cast<Address>(this); }
};

class Smi : public Object {
 public:
  explicit Smi(int v) : value_(v) {}
  int value() const { return value_; }
  static Smi* FromInt(int v) { return new Smi(v); }

 private:
  int value_;
};

class HeapObject : public Object {};

class ByteArray : public HeapObject {
 public:
  explicit ByteArray(uint32_t size) : data_(size, 0) {}
  uint8_t get(int i) const {
    DCHECK_GE(i, 0);
    DCHECK_LT(static_cast<size_t>(i), data_.size());
    return data_[static_cast<size_t>(i)];
  }
  void set(int i, int value) {
    DCHECK_GE(i, 0);
    DCHECK_LT(static_cast<size_t>(i), data_.size());
    data_[static_cast<size_t>(i)] = static_cast<uint8_t>(value);
  }
  uint8_t* begin() { return data_.data(); }
  const uint8_t* begin() const { return data_.data(); }
  SafeHeapObjectSize length() const {
    return SafeHeapObjectSize(static_cast<uint32_t>(data_.size()));
  }
  SafeHeapObjectSize ulength() const { return length(); }

 protected:
  std::vector<uint8_t> data_;
};

class TrustedByteArray : public HeapObject {
 public:
  explicit TrustedByteArray(uint32_t size) : data_(size, 0) {}
  uint8_t get(int i) const {
    DCHECK_GE(i, 0);
    DCHECK_LT(static_cast<size_t>(i), data_.size());
    return data_[static_cast<size_t>(i)];
  }
  void set(int i, int value) {
    DCHECK_GE(i, 0);
    DCHECK_LT(static_cast<size_t>(i), data_.size());
    data_[static_cast<size_t>(i)] = static_cast<uint8_t>(value);
  }
  uint8_t* begin() { return data_.data(); }
  const uint8_t* begin() const { return data_.data(); }
  uint8_t* end() { return data_.data() + data_.size(); }
  const uint8_t* end() const { return data_.data() + data_.size(); }
  SafeHeapObjectSize length() const {
    return SafeHeapObjectSize(static_cast<uint32_t>(data_.size()));
  }
  SafeHeapObjectSize ulength() const { return length(); }

 private:
  std::vector<uint8_t> data_;
};

using ByteArrayData = ByteArray;

template <typename T>
class DirectHandle;

class FixedIntegerArray : public HeapObject {
 public:
  explicit FixedIntegerArray(uint32_t n) : data_(n, 0) {}
  int get(int i) const { return data_[static_cast<size_t>(i)]; }
  void set(int i, int v) { data_[static_cast<size_t>(i)] = v; }
  SafeHeapObjectSize length() const {
    return SafeHeapObjectSize(static_cast<uint32_t>(data_.size()));
  }

 private:
  std::vector<int> data_;
};

class FixedUInt16Array : public ByteArray {
 public:
  explicit FixedUInt16Array(uint32_t elements)
      : ByteArray(elements * 2), elements_(elements) {}

  static DirectHandle<FixedUInt16Array> New(Isolate* isolate, uint32_t length);

  uint16_t get(uint32_t i) const {
    DCHECK_LT(i, elements_);
    uint16_t v;
    std::memcpy(&v, data_.data() + static_cast<size_t>(i) * 2, 2);
    return v;
  }
  void set(uint32_t i, uint16_t v) {
    DCHECK_LT(i, elements_);
    std::memcpy(data_.data() + static_cast<size_t>(i) * 2, &v, 2);
  }
  SafeHeapObjectSize length() const { return SafeHeapObjectSize(elements_); }

 private:
  uint32_t elements_;
};

// ---------------------------------------------------------------------------
// Tagged / Cast / Handle
// ---------------------------------------------------------------------------

template <typename T>
class Tagged {
 public:
  Tagged() : ptr_(nullptr) {}
  Tagged(T* p) : ptr_(p) {}  // NOLINT
  explicit Tagged(Address a) : ptr_(reinterpret_cast<T*>(a)) {}

  template <typename U, typename = std::enable_if_t<std::is_convertible_v<U*, T*>>>
  Tagged(Tagged<U> other) : ptr_(other.get()) {}

  T* operator->() const { return ptr_; }
  T* get() const { return ptr_; }
  Address ptr() const { return reinterpret_cast<Address>(ptr_); }
  Address address() const { return ptr(); }

  bool SafeEquals(Tagged<T> other) const { return ptr_ == other.ptr_; }
  bool SafeEquals(T* other) const { return ptr_ == other; }
  bool is_null() const { return ptr_ == nullptr; }

  template <typename U>
  bool operator==(Tagged<U> other) const {
    return static_cast<void*>(ptr_) == static_cast<void*>(other.get());
  }
  template <typename U>
  bool operator!=(Tagged<U> other) const {
    return !(*this == other);
  }

 private:
  T* ptr_;
};

template <typename T>
inline Tagged<T> Cast(Tagged<Object> obj) {
  return Tagged<T>(static_cast<T*>(obj.get()));
}
template <typename T, typename U>
inline Tagged<T> Cast(Tagged<U> obj) {
  return Tagged<T>(static_cast<T*>(static_cast<void*>(obj.get())));
}
template <typename T>
inline Tagged<T> UncheckedCast(Tagged<Object> obj) {
  return Cast<T>(obj);
}
template <typename T, typename U>
inline Tagged<T> UncheckedCast(Tagged<U> obj) {
  return Cast<T>(obj);
}
template <typename T>
inline Tagged<T> SbxCast(Tagged<Object> obj) {
  return Cast<T>(obj);
}
template <typename T, typename U>
inline Tagged<T> SbxCast(Tagged<U> obj) {
  return Cast<T>(obj);
}
template <typename T>
inline Tagged<T> TrustedCast(Tagged<Object> obj) {
  return Cast<T>(obj);
}
template <typename T>
inline Tagged<T> CheckedCast(Tagged<Object> obj) {
  return Cast<T>(obj);
}

class DisallowGarbageCollection {
 public:
  DisallowGarbageCollection() = default;
};
class AllowGarbageCollection {
 public:
  AllowGarbageCollection() = default;
};

template <typename T>
class DirectHandle {
 public:
  DirectHandle() : loc_(nullptr) {}
  DirectHandle(std::nullptr_t) : loc_(nullptr) {}  // NOLINT
  DirectHandle(T* p, Isolate* = nullptr) : loc_(p) {}
  template <typename U>
  DirectHandle(Tagged<U> t, Isolate* = nullptr) : loc_(static_cast<T*>(static_cast<void*>(t.get()))) {}

  template <typename U, typename = std::enable_if_t<std::is_convertible_v<U*, T*>>>
  DirectHandle(const DirectHandle<U>& other) : loc_(other.get()) {}

  T* operator->() const { return loc_; }
  Tagged<T> operator*() const { return Tagged<T>(loc_); }
  T* get() const { return loc_; }
  bool is_null() const { return loc_ == nullptr; }

 private:
  T* loc_;
};

template <typename T>
using Handle = DirectHandle<T>;
template <typename T>
using IndirectHandle = DirectHandle<T>;
template <typename T>
using MaybeHandle = DirectHandle<T>;
template <typename T>
using MaybeDirectHandle = DirectHandle<T>;

template <typename T>
inline DirectHandle<T> handle(Tagged<T> obj, Isolate* isolate) {
  return DirectHandle<T>(obj, isolate);
}
template <typename T>
inline DirectHandle<T> handle(T* obj, Isolate* isolate) {
  return DirectHandle<T>(obj, isolate);
}
template <typename T>
inline DirectHandle<T> direct_handle(Tagged<T> obj, Isolate* isolate) {
  return DirectHandle<T>(obj, isolate);
}
template <typename T>
inline DirectHandle<T> direct_handle(T* obj, Isolate* isolate) {
  return DirectHandle<T>(obj, isolate);
}

template <typename T, typename U>
inline DirectHandle<T> Cast(DirectHandle<U> h) {
  return DirectHandle<T>(Cast<T>(*h), nullptr);
}
template <typename T, typename U>
inline DirectHandle<T> CheckedCast(DirectHandle<U> h) {
  return Cast<T>(h);
}

class HandleScope {
 public:
  explicit HandleScope(Isolate*) {}
};

inline bool IsExceptionHole(Tagged<Object> obj);
inline bool IsExceptionHole(Object* obj);

// ---------------------------------------------------------------------------
// String
// ---------------------------------------------------------------------------

class String : public HeapObject {
 public:
  static constexpr int kMaxOneByteCharCode = 0xff;
  static constexpr uint32_t kMaxOneByteCharCodeU = 0xff;
  static constexpr int kMaxUtf16CodeUnit = 0xffff;
  static constexpr uint32_t kMaxUtf16CodeUnitU = 0xffff;
  static constexpr int kMaxCodePoint = 0x10ffff;

  String(const uint8_t* data, int length)
      : is_one_byte_(true), length_(length), latin1_(data, data + length) {}
  String(const base::uc16* data, int length)
      : is_one_byte_(false), length_(length), utf16_(data, data + length) {}

  uint32_t length() const { return static_cast<uint32_t>(length_); }
  bool IsFlat() const { return true; }
  bool IsOneByteRepresentation() const { return is_one_byte_; }
  static bool IsOneByteRepresentationUnderneath(Tagged<String> s) {
    return s->IsOneByteRepresentation();
  }
  static bool IsOneByteRepresentation(Tagged<String> s) {
    return s->IsOneByteRepresentation();
  }

  class FlatContent {
   public:
    explicit FlatContent(const String* s) : str_(s) {}
    bool IsOneByte() const { return str_->is_one_byte_; }
    bool IsTwoByte() const { return !str_->is_one_byte_; }
    base::Vector<const uint8_t> ToOneByteVector() const {
      DCHECK(IsOneByte());
      return base::Vector<const uint8_t>(str_->latin1_.data(), str_->length_);
    }
    base::Vector<const base::uc16> ToUC16Vector() const {
      DCHECK(IsTwoByte());
      return base::Vector<const base::uc16>(str_->utf16_.data(), str_->length_);
    }
    void UnsafeDisableChecksumVerification() {}

   private:
    const String* str_;
  };

  FlatContent GetFlatContent(const DisallowGarbageCollection&) const {
    return FlatContent(this);
  }

  template <typename Char>
  base::Vector<const Char> GetCharVector(const DisallowGarbageCollection&) const {
    if constexpr (sizeof(Char) == 1) {
      DCHECK(is_one_byte_);
      return base::Vector<const Char>(
          reinterpret_cast<const Char*>(latin1_.data()), length_);
    } else {
      DCHECK(!is_one_byte_);
      return base::Vector<const Char>(
          reinterpret_cast<const Char*>(utf16_.data()), length_);
    }
  }

  std::unique_ptr<char[]> ToCString() const;
  std::unique_ptr<char[]> ToCString(uint32_t start, uint32_t len) const;
  void Flatten() {}
  static void Flatten(Isolate*, DirectHandle<String>) {}

  const uint8_t* AddressOfCharacterAt(int index,
                                      const DisallowGarbageCollection&) const {
    if (is_one_byte_) return latin1_.data() + index;
    return reinterpret_cast<const uint8_t*>(utf16_.data() + index);
  }

 private:
  bool is_one_byte_;
  int length_;
  std::vector<uint8_t> latin1_;
  std::vector<base::uc16> utf16_;
};

class ConsString : public String {
 public:
  using String::String;
  Tagged<String> first() { return this; }
  Tagged<String> second() { return this; }
};
class SlicedString : public String {
 public:
  using String::String;
  Tagged<String> parent() { return this; }
  int offset() const { return 0; }
};
class ThinString : public String {
 public:
  using String::String;
  Tagged<String> actual() { return this; }
};

class Code : public HeapObject {};
class AbstractCode : public HeapObject {};
class InstructionStream : public HeapObject {
 public:
  Address instruction_start() const { return 0; }
  Address address() const { return ptr(); }
};
class TrustedObject : public HeapObject {};
class TrustedFixedArray : public HeapObject {};
class FixedArray : public HeapObject {};
class ResultVectorScope {};
class MacroAssembler {};
class ExternalReference {};
class Assembler {};
class Displacement {};
class Heap {};
class AtomRegExpData : public HeapObject {};
class RegExpMatchInfo : public HeapObject {};

class JSRegExp : public HeapObject {
 public:
  using Flags = int;
  static constexpr int kNoBacktrackLimit = 0;
  static constexpr int kMaxCaptures = (65536 - 1) / 2;
  static int RegistersForCaptureCount(int capture_count) {
    return (capture_count + 1) * 2;
  }
  static base::Flags<regexp::Flag> AsRegExpFlags(Flags flags) {
    return base::Flags<regexp::Flag>(
        static_cast<std::underlying_type_t<regexp::Flag>>(flags));
  }
  static Flags AsJSRegExpFlags(base::Flags<regexp::Flag> flags) {
    return static_cast<Flags>(flags.bits());
  }
  static Flags AsJSRegExpFlags(int flags) { return flags; }
  static DirectHandle<String> StringFromFlags(Isolate*, Flags);
};

class RegExpData : public HeapObject {
 public:
  static constexpr int kQuickCheckBitsetChars = 128;
  static constexpr int kQuickCheckBitsetWords = kQuickCheckBitsetChars / 32;
  static constexpr uint32_t kHasQuickCheck = 1u;

  static std::pair<int, uint32_t> QuickCheckBitsetBit(base::uc32 c) {
    const int word = static_cast<int>(c / 32);
    const uint32_t bit = uint32_t{1} << (c % 32);
    return {word, bit};
  }

  JSRegExp::Flags flags() const { return flags_; }
  void set_flags(JSRegExp::Flags f) { flags_ = f; }
  int capture_count() const { return capture_count_; }
  void set_capture_count(int n) { capture_count_ = n; }
  Tagged<String> escaped_source() const { return escaped_source_; }
  void set_escaped_source(Tagged<String> s) { escaped_source_ = s; }

  void set_quick_check_mask(uint32_t v) { qc_mask_ = v; }
  void set_quick_check_value(uint32_t v) { qc_value_ = v; }
  void set_quick_check_reject_bitset_word(int i, uint32_t v) {
    DCHECK_LT(i, kQuickCheckBitsetWords);
    qc_reject_[i] = v;
  }
  uint32_t internal_flags() const { return internal_flags_; }
  void set_internal_flags(uint32_t f) { internal_flags_ = f; }

 protected:
  JSRegExp::Flags flags_ = 0;
  int capture_count_ = 0;
  Tagged<String> escaped_source_;
  uint32_t qc_mask_ = 0;
  uint32_t qc_value_ = 0;
  uint32_t qc_reject_[kQuickCheckBitsetWords] = {};
  uint32_t internal_flags_ = 0;
};

class IrRegExpData : public RegExpData {
 public:
  bool has_bytecode(bool is_one_byte) const {
    return is_one_byte ? latin1_bc_.get() != nullptr : uc16_bc_.get() != nullptr;
  }
  Tagged<TrustedByteArray> bytecode(bool is_one_byte) const {
    return is_one_byte ? latin1_bc_ : uc16_bc_;
  }
  void set_bytecode(bool is_one_byte, Tagged<TrustedByteArray> ba) {
    if (is_one_byte) {
      latin1_bc_ = ba;
    } else {
      uc16_bc_ = ba;
    }
  }
  int max_register_count() const { return max_register_count_; }
  void set_max_register_count(int n) { max_register_count_ = n; }
  int backtrack_limit() const { return 0; }
  void TierUpTick() {}

 private:
  Tagged<TrustedByteArray> latin1_bc_;
  Tagged<TrustedByteArray> uc16_bc_;
  int max_register_count_ = 0;
};

class Factory {
 public:
  explicit Factory(Isolate* isolate) : isolate_(isolate) {}
  Handle<TrustedByteArray> NewTrustedByteArray(uint32_t size);
  Handle<ByteArray> NewByteArray(int size,
                                 AllocationType type = AllocationType::kYoung);
  Handle<String> NewStringFromOneByte(base::Vector<const uint8_t> chars);
  Handle<String> NewStringFromTwoByte(base::Vector<const base::uc16> chars);

 private:
  Isolate* isolate_;
};

class Histogram {
 public:
  void AddSample(int) {}
};

class Counters {
 public:
  Histogram* regexp_backtracks() { return &backtracks_; }

 private:
  Histogram backtracks_;
};

class StackGuard {
 public:
  explicit StackGuard(Isolate* isolate);
  uintptr_t real_climit() const { return climit_; }
  void set_climit(uintptr_t c) { climit_ = c; }
  Tagged<Object> HandleInterrupts();
  bool InterruptRequested() const;

 private:
  Isolate* isolate_;
  uintptr_t climit_;
};

class StackLimitCheck {
 public:
  explicit StackLimitCheck(Isolate* isolate) : isolate_(isolate) {}
  bool HasOverflowed() const;
  bool JsHasOverflowed() const { return HasOverflowed(); }
  bool JsHasOverflowed(uintptr_t gap) const;
  bool InterruptRequested() const;

 private:
  Isolate* isolate_;
};

class Isolate {
 public:
  Isolate();
  ~Isolate();

  static Isolate* Current();

  Factory* factory() { return &factory_; }
  class LocalHeapStub {
   public:
    void AddGCEpilogueCallback(void (*)(void*), void*) {}
    void RemoveGCEpilogueCallback(void (*)(void*), void*) {}
  };
  LocalHeapStub* main_thread_local_heap() { return &local_heap_; }
  regexp::Stack* regexp_stack() { return regexp_stack_; }
  StackGuard* stack_guard() { return &stack_guard_; }
  AccountingAllocator* allocator() { return &allocator_; }
  Counters* counters() { return &counters_; }

  void StackOverflow();
  void RequestInterruptException();
  bool has_exception() const { return has_exception_; }
  bool interrupted() const { return interrupted_; }
  void clear_exception() {
    has_exception_ = false;
    interrupted_ = false;
  }

  unibrow::Mapping<unibrow::Ecma262UnCanonicalize>* jsregexp_uncanonicalize() {
    return &uncanonicalize_;
  }
  unibrow::Mapping<unibrow::CanonicalizationRange>* jsregexp_canonrange() {
    return &canonrange_;
  }
  unibrow::Mapping<unibrow::Ecma262Canonicalize>*
  regexp_macro_assembler_canonicalize() {
    return &canonicalize_;
  }

  void set_interrupt(int (*fn)(void*), void* opaque) {
    interrupt_fn_ = fn;
    interrupt_opaque_ = opaque;
  }
  int (*interrupt_fn())(void*) { return interrupt_fn_; }
  void* interrupt_opaque() const { return interrupt_opaque_; }

  Object* exception_hole() { return &exception_hole_; }
  bool is_exception_hole(Object* obj) const { return obj == &exception_hole_; }

  template <typename T, typename... Args>
  T* Adopt(Args&&... args) {
    auto owned = std::make_unique<T>(std::forward<Args>(args)...);
    T* raw = owned.get();
    objects_.emplace_back(std::move(owned));
    return raw;
  }

 private:
  static thread_local Isolate* current_;

  LocalHeapStub local_heap_;
  AccountingAllocator allocator_;
  Factory factory_;
  StackGuard stack_guard_;
  Counters counters_;
  regexp::Stack* regexp_stack_ = nullptr;
  bool has_exception_ = false;
  bool interrupted_ = false;
  Object exception_hole_;
  int (*interrupt_fn_)(void*) = nullptr;
  void* interrupt_opaque_ = nullptr;
  unibrow::Mapping<unibrow::Ecma262Canonicalize> canonicalize_;
  unibrow::Mapping<unibrow::Ecma262UnCanonicalize> uncanonicalize_;
  unibrow::Mapping<unibrow::CanonicalizationRange> canonrange_;
  std::vector<std::unique_ptr<Object>> objects_;
};

inline bool IsExceptionHole(Tagged<Object> obj) {
  Isolate* isolate = Isolate::Current();
  return isolate && isolate->is_exception_hole(obj.get());
}
inline bool IsExceptionHole(Object* obj) {
  Isolate* isolate = Isolate::Current();
  return isolate && isolate->is_exception_hole(obj);
}

// ---------------------------------------------------------------------------
// Zone
// ---------------------------------------------------------------------------

class Zone {
 public:
  explicit Zone(Isolate* isolate);
  Zone(AccountingAllocator* allocator, const char* name);

  ~Zone();

  Isolate* isolate() const { return isolate_; }
  AccountingAllocator* allocator() const { return allocator_; }

  void* Allocate(size_t size);
  void* Allocate(size_t size, std::nothrow_t) { return Allocate(size); }

  template <typename T>
  T* AllocateArray(size_t count) {
    if (count == 0) return nullptr;
    return static_cast<T*>(Allocate(count * sizeof(T)));
  }

  template <typename T, typename... Args>
  T* New(Args&&... args) {
    void* p = Allocate(sizeof(T));
    return new (p) T(std::forward<Args>(args)...);
  }

  template <typename T>
  base::Vector<T> CloneVector(base::Vector<const T> src) {
    T* copy = AllocateArray<T>(static_cast<size_t>(src.length()));
    for (int i = 0; i < src.length(); i++) copy[i] = src[i];
    return base::Vector<T>(copy, src.length());
  }
  template <typename T>
  base::Vector<T> CloneVector(base::Vector<T> src) {
    return CloneVector(base::Vector<const T>(src.begin(), src.size()));
  }

 private:
  void NewSegment(size_t min_size);

  Isolate* isolate_;
  AccountingAllocator* allocator_;
  std::vector<void*> segments_;
  char* pos_ = nullptr;
  char* end_ = nullptr;
  static constexpr size_t kSegmentSize = 64 * 1024;
};

class ZoneObject {
 public:
  void* operator new(size_t size, Zone* zone) { return zone->Allocate(size); }
  void* operator new(size_t, void* p) { return p; }
  void operator delete(void*, size_t) {}
  void operator delete(void*, Zone*) {}
  void operator delete(void*, void*) {}
};

template <typename T>
class ZoneAllocator {
 public:
  using value_type = T;
  using pointer = T*;
  using const_pointer = const T*;
  using reference = T&;
  using const_reference = const T&;
  using size_type = size_t;
  using difference_type = ptrdiff_t;

  template <typename U>
  struct rebind {
    using other = ZoneAllocator<U>;
  };

  explicit ZoneAllocator(Zone* zone) : zone_(zone) {}
  template <typename U>
  ZoneAllocator(const ZoneAllocator<U>& other) : zone_(other.zone()) {}

  T* allocate(size_t n) { return zone_->AllocateArray<T>(n); }
  void deallocate(T*, size_t) {}
  Zone* zone() const { return zone_; }

  template <typename U>
  bool operator==(const ZoneAllocator<U>& other) const {
    return zone_ == other.zone();
  }
  template <typename U>
  bool operator!=(const ZoneAllocator<U>& other) const {
    return !(*this == other);
  }

 private:
  Zone* zone_;
};

template <typename T>
class ZoneVector : public std::vector<T, ZoneAllocator<T>> {
 public:
  explicit ZoneVector(Zone* zone)
      : std::vector<T, ZoneAllocator<T>>(ZoneAllocator<T>(zone)) {}
  ZoneVector(size_t n, Zone* zone)
      : std::vector<T, ZoneAllocator<T>>(n, T(), ZoneAllocator<T>(zone)) {}
  ZoneVector(size_t n, const T& value, Zone* zone)
      : std::vector<T, ZoneAllocator<T>>(n, value, ZoneAllocator<T>(zone)) {}
  template <typename It>
  ZoneVector(It first, It last, Zone* zone)
      : std::vector<T, ZoneAllocator<T>>(first, last, ZoneAllocator<T>(zone)) {}
};

template <typename K, typename V, typename Comp = std::less<K>>
class ZoneMap
    : public std::map<K, V, Comp, ZoneAllocator<std::pair<const K, V>>> {
 public:
  explicit ZoneMap(Zone* zone)
      : std::map<K, V, Comp, ZoneAllocator<std::pair<const K, V>>>(
            Comp(), ZoneAllocator<std::pair<const K, V>>(zone)) {}
};

template <typename K, typename V, typename Hash = std::hash<K>,
          typename Eq = std::equal_to<K>>
class ZoneUnorderedMap
    : public std::unordered_map<K, V, Hash, Eq,
                                ZoneAllocator<std::pair<const K, V>>> {
 public:
  explicit ZoneUnorderedMap(Zone* zone)
      : std::unordered_map<K, V, Hash, Eq,
                           ZoneAllocator<std::pair<const K, V>>>(
            0, Hash(), Eq(), ZoneAllocator<std::pair<const K, V>>(zone)) {}
};

template <typename T>
class ZoneDeque : public std::vector<T, ZoneAllocator<T>> {
 public:
  explicit ZoneDeque(Zone* zone)
      : std::vector<T, ZoneAllocator<T>>(ZoneAllocator<T>(zone)) {}
};

template <typename T>
class ZoneLinkedList {
 public:
  explicit ZoneLinkedList(Zone*) {}
  void push_back(const T& v) { items_.push_back(v); }
  void push_front(const T& v) { items_.insert(items_.begin(), v); }
  typename std::vector<T>::iterator begin() { return items_.begin(); }
  typename std::vector<T>::iterator end() { return items_.end(); }
  typename std::vector<T>::const_iterator begin() const {
    return items_.begin();
  }
  typename std::vector<T>::const_iterator end() const { return items_.end(); }
  bool empty() const { return items_.empty(); }
  size_t size() const { return items_.size(); }

 private:
  std::vector<T> items_;
};

template <typename T>
class ZoneList : public ZoneObject {
 public:
  ZoneList(int capacity, Zone* zone)
      : data_(nullptr), capacity_(0), length_(0) {
    if (capacity > 0) {
      data_ = zone->AllocateArray<T>(static_cast<size_t>(capacity));
      capacity_ = capacity;
    }
  }

  ZoneList(base::Vector<T> values, Zone* zone)
      : ZoneList(values.length(), zone) {
    for (int i = 0; i < values.length(); i++) Add(values[i], zone);
  }
  ZoneList(base::Vector<const T> values, Zone* zone)
      : ZoneList(values.length(), zone) {
    for (int i = 0; i < values.length(); i++) Add(values[i], zone);
  }

  void Add(const T& e, Zone* zone) {
    if (length_ >= capacity_) {
      int new_cap = capacity_ == 0 ? 4 : capacity_ * 2;
      T* fresh = zone->AllocateArray<T>(static_cast<size_t>(new_cap));
      for (int i = 0; i < length_; i++) fresh[i] = data_[i];
      data_ = fresh;
      capacity_ = new_cap;
    }
    data_[length_++] = e;
  }

  void AddAll(const ZoneList<T>& other, Zone* zone) {
    for (int i = 0; i < other.length_; i++) Add(other.data_[i], zone);
  }

  T& at(int i) {
    DCHECK_GE(i, 0);
    DCHECK_LT(i, length_);
    return data_[i];
  }
  const T& at(int i) const {
    DCHECK_GE(i, 0);
    DCHECK_LT(i, length_);
    return data_[i];
  }
  T& operator[](int i) { return at(i); }
  const T& operator[](int i) const { return at(i); }

  int length() const { return length_; }
  bool is_empty() const { return length_ == 0; }
  void Clear() { length_ = 0; }

  T RemoveLast() {
    DCHECK_GT(length_, 0);
    return data_[--length_];
  }

  void Rewind(int new_length) {
    DCHECK_GE(new_length, 0);
    DCHECK_LE(new_length, length_);
    length_ = new_length;
  }

  void Set(int i, const T& e) { at(i) = e; }

  template <typename Compare>
  void StableSort(Compare cmp, int start, int length) {
    std::stable_sort(data_ + start, data_ + start + length,
                     [&](const T& a, const T& b) { return cmp(&a, &b) < 0; });
  }
  void StableSort(int start, int length) {
    std::stable_sort(data_ + start, data_ + start + length);
  }

  T& first() { return at(0); }
  const T& first() const { return at(0); }
  T& last() { return at(length_ - 1); }
  const T& last() const { return at(length_ - 1); }

  T* begin() { return data_; }
  const T* begin() const { return data_; }
  T* end() { return data_ + length_; }
  const T* end() const { return data_ + length_; }

  bool Contains(const T& e) const {
    for (int i = 0; i < length_; i++) {
      if (data_[i] == e) return true;
    }
    return false;
  }

  base::Vector<const T> ToConstVector() const {
    return base::Vector<const T>(data_, length_);
  }
  base::Vector<T> ToVector() { return base::Vector<T>(data_, length_); }

 private:
  T* data_;
  int capacity_;
  int length_;
};

template <typename T, size_t N>
class SmallZoneVector : public base::SmallVector<T, N> {
 public:
  explicit SmallZoneVector(Zone*) : base::SmallVector<T, N>() {}
  SmallZoneVector(size_t n, Zone*) : base::SmallVector<T, N>(n) {}
};

class Utils {
 public:
  static int AdvanceStringIndex(Tagged<String> subject, int index,
                                bool unicode);
};

}  // namespace internal

// ---------------------------------------------------------------------------
// v8_flags
// ---------------------------------------------------------------------------

struct FlagList {
  bool regexp_optimization = true;
  bool regexp_quick_check = true;
  bool regexp_peephole_optimization = false;
  bool regexp_tier_up = false;
  bool regexp_simd_in_rc = false;
  bool regexp_masked_dispatch = false;
  bool regexp_unroll = true;
  bool regexp_simd = false;
  bool enable_regexp_unaligned_accesses = true;
  bool js_regexp_buffer_boundaries = false;
  bool regexp_possessive_quantifier = false;
  bool trace_regexp_exec = false;
  bool trace_regexp_parser = false;
  bool trace_regexp_graph_building = false;
  bool trace_regexp_compiler = false;
  bool trace_regexp_bytecodes = false;
  bool trace_regexp_peephole_optimization = false;
  bool trace_regexp_assembler = false;
  bool log_colour = false;
  bool enable_slow_asserts = false;
  bool slow_debug_code = false;
};

extern FlagList v8_flags;

}  // namespace v8

#endif  // IRREGEXP_REGEXP_SHIM_H_
