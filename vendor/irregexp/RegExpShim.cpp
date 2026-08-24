#include "irregexp/RegExpShim.h"

#include "irregexp/imported/regexp-flags.h"
#include "irregexp/imported/regexp-stack.h"

#include <cstdarg>

namespace v8 {

FlagList v8_flags;

namespace unibrow {

int Ecma262Canonicalize::Convert(uchar c, uchar, uchar* result, bool* cached) {
  *cached = true;
  const uint32_t canon = zjs_irregexp_canonicalize(c, 0);
  if (canon == c) return 0;
  result[0] = canon;
  return 1;
}

int Ecma262UnCanonicalize::Convert(uchar c, uchar, uchar* result,
                                   bool* cached) {
  *cached = true;
  const int n = zjs_irregexp_uncanonicalize(c, result, kMaxWidth);
  if (n <= 0) return 0;
  if (n == 1 && result[0] == c) return 0;
  return n;
}

int CanonicalizationRange::Convert(uchar c, uchar, uchar* result,
                                   bool* cached) {
  *cached = true;
  // Singleton blocks are always correct. ASCII letter runs share one block
  // so case-insensitive ranges expand without walking every code unit.
  if (c >= 'a' && c <= 'z') {
    result[0] = 'z';
    return 1;
  }
  if (c >= 'A' && c <= 'Z') {
    result[0] = 'Z';
    return 1;
  }
  return 0;
}

}  // namespace unibrow

namespace internal {

thread_local Isolate* Isolate::current_ = nullptr;

void PrintF(const char* format, ...) {
  va_list args;
  va_start(args, format);
  std::vfprintf(stdout, format, args);
  va_end(args);
}

void PrintF(FILE* out, const char* format, ...) {
  va_list args;
  va_start(args, format);
  std::vfprintf(out, format, args);
  va_end(args);
}

String::String(const uint8_t* data, int length, bool copy)
    : is_one_byte_(true), length_(length), latin1_(data), utf16_(nullptr) {
  if (copy && length > 0 && data != nullptr) {
    latin1_owned_.assign(data, data + length);
    latin1_ = latin1_owned_.data();
  } else if (length <= 0) {
    latin1_ = nullptr;
    length_ = 0;
  }
}

String::String(const base::uc16* data, int length, bool copy)
    : is_one_byte_(false), length_(length), latin1_(nullptr), utf16_(data) {
  if (copy && length > 0 && data != nullptr) {
    utf16_owned_.assign(data, data + length);
    utf16_ = utf16_owned_.data();
  } else if (length <= 0) {
    utf16_ = nullptr;
    length_ = 0;
  }
}

std::unique_ptr<char[]> String::ToCString() const {
  return ToCString(0, static_cast<uint32_t>(length_));
}

std::unique_ptr<char[]> String::ToCString(uint32_t start, uint32_t len) const {
  if (start > static_cast<uint32_t>(length_)) start = static_cast<uint32_t>(length_);
  if (start + len > static_cast<uint32_t>(length_)) {
    len = static_cast<uint32_t>(length_) - start;
  }
  auto out = std::make_unique<char[]>(static_cast<size_t>(len) + 1);
  if (is_one_byte_) {
    for (uint32_t i = 0; i < len; i++) {
      out[i] = static_cast<char>(latin1_[start + i]);
    }
  } else {
    for (uint32_t i = 0; i < len; i++) {
      const base::uc16 cu = utf16_[start + i];
      out[i] = cu < 0x80 ? static_cast<char>(cu) : '?';
    }
  }
  out[len] = '\0';
  return out;
}

DirectHandle<String> JSRegExp::StringFromFlags(Isolate* isolate, Flags flags) {
  char buf[16];
  int n = 0;
  if (flags & (1 << 0)) buf[n++] = 'g';
  if (flags & (1 << 1)) buf[n++] = 'i';
  if (flags & (1 << 2)) buf[n++] = 'm';
  if (flags & (1 << 3)) buf[n++] = 'y';
  if (flags & (1 << 4)) buf[n++] = 'u';
  if (flags & (1 << 5)) buf[n++] = 's';
  if (flags & (1 << 6)) buf[n++] = 'l';
  if (flags & (1 << 7)) buf[n++] = 'd';
  if (flags & (1 << 8)) buf[n++] = 'v';
  std::vector<uint8_t> bytes(buf, buf + n);
  return isolate->factory()->NewStringFromOneByte(
      base::Vector<const uint8_t>(bytes.data(), n));
}

Handle<TrustedByteArray> Factory::NewTrustedByteArray(uint32_t size) {
  return Handle<TrustedByteArray>(
      isolate_->Adopt<TrustedByteArray>(size), isolate_);
}

Handle<ByteArray> Factory::NewByteArray(int size, AllocationType) {
  CHECK_GE(size, 0);
  return Handle<ByteArray>(
      isolate_->Adopt<ByteArray>(static_cast<uint32_t>(size)), isolate_);
}

Handle<String> Factory::NewStringFromOneByte(base::Vector<const uint8_t> chars) {
  return Handle<String>(
      isolate_->Adopt<String>(chars.begin(), chars.length(), true), isolate_);
}

Handle<String> Factory::NewStringFromTwoByte(
    base::Vector<const base::uc16> chars) {
  return Handle<String>(
      isolate_->Adopt<String>(chars.begin(), chars.length(), true), isolate_);
}

DirectHandle<FixedUInt16Array> FixedUInt16Array::New(Isolate* isolate,
                                                     uint32_t length) {
  return DirectHandle<FixedUInt16Array>(
      isolate->Adopt<FixedUInt16Array>(length), isolate);
}

void StackGuard::Recalibrate() {
  const uintptr_t now = GetCurrentStackPosition();
  // Stacks grow down. Leave ~1MiB before we report overflow.
  constexpr uintptr_t kSlack = 1 * 1024 * 1024;
  climit_ = now > kSlack ? now - kSlack : 0;
}

StackGuard::StackGuard(Isolate* isolate) : isolate_(isolate) { Recalibrate(); }

Tagged<Object> StackGuard::HandleInterrupts() {
  if (isolate_->interrupt_fn() != nullptr) {
    const int status = isolate_->interrupt_fn()(isolate_->interrupt_opaque());
    if (status != 0) {
      isolate_->RequestInterruptException();
      return Tagged<Object>(isolate_->exception_hole());
    }
  }
  return Tagged<Object>(nullptr);
}

bool StackGuard::InterruptRequested() const {
  return isolate_->interrupt_fn() != nullptr;
}

bool StackLimitCheck::HasOverflowed() const {
  return GetCurrentStackPosition() < isolate_->stack_guard()->real_climit();
}

bool StackLimitCheck::JsHasOverflowed(uintptr_t gap) const {
  const uintptr_t now = GetCurrentStackPosition();
  const uintptr_t limit = isolate_->stack_guard()->real_climit();
  if (now < limit) return true;
  return now - limit < gap;
}

bool StackLimitCheck::InterruptRequested() const {
  return isolate_->stack_guard()->InterruptRequested();
}

Isolate::Isolate()
    : factory_(this),
      stack_guard_(this) {
  current_ = this;
  regexp_stack_ = regexp::Stack::New();
}

Isolate::~Isolate() {
  if (regexp_stack_) {
    regexp::Stack::Delete(regexp_stack_);
    regexp_stack_ = nullptr;
  }
  if (current_ == this) current_ = nullptr;
}

Isolate* Isolate::Current() { return current_; }

void Isolate::SetCurrent(Isolate* isolate) { current_ = isolate; }

void Isolate::StackOverflow() { has_exception_ = true; }

void Isolate::RequestInterruptException() {
  has_exception_ = true;
  interrupted_ = true;
}

}  // namespace internal
}  // namespace v8

namespace v8::internal::regexp {

std::ostream& operator<<(std::ostream& os, Flags flags) {
  if (IsGlobal(flags)) os << 'g';
  if (IsIgnoreCase(flags)) os << 'i';
  if (IsMultiline(flags)) os << 'm';
  if (IsSticky(flags)) os << 'y';
  if (IsUnicode(flags)) os << 'u';
  if (IsDotAll(flags)) os << 's';
  if (IsLinear(flags)) os << 'l';
  if (IsHasIndices(flags)) os << 'd';
  if (IsUnicodeSets(flags)) os << 'v';
  return os;
}

}  // namespace v8::internal::regexp

namespace v8 {
namespace internal {

Zone::Zone(Isolate* isolate)
    : isolate_(isolate), allocator_(isolate->allocator()) {}

Zone::Zone(AccountingAllocator* allocator, const char* /*name*/)
    : isolate_(Isolate::Current()), allocator_(allocator) {}

Zone::~Zone() {
  for (void* p : segments_) allocator_->FreeSegment(p);
}

void Zone::NewSegment(size_t min_size) {
  const size_t size = min_size < kSegmentSize ? kSegmentSize : min_size;
  char* mem = static_cast<char*>(allocator_->AllocateSegment(size));
  segments_.push_back(mem);
  pos_ = mem;
  end_ = mem + size;
}

void* Zone::Allocate(size_t size) {
  constexpr size_t kAlign = alignof(std::max_align_t);
  size = (size + kAlign - 1) & ~(kAlign - 1);
  if (pos_ == nullptr || pos_ + size > end_) {
    NewSegment(size);
  }
  void* p = pos_;
  pos_ += size;
  return p;
}

int Utils::AdvanceStringIndex(Tagged<String> subject, int index, bool unicode) {
  const int length = static_cast<int>(subject->length());
  if (index >= length) return index + 1;
  if (!unicode || subject->IsOneByteRepresentation()) return index + 1;
  DisallowGarbageCollection no_gc;
  base::Vector<const base::uc16> v = subject->GetCharVector<base::uc16>(no_gc);
  const base::uc16 cu = v[index];
  if (unibrow::Utf16::IsLeadSurrogate(cu) && index + 1 < length &&
      unibrow::Utf16::IsTrailSurrogate(v[index + 1])) {
    return index + 2;
  }
  return index + 1;
}

}  // namespace internal
}  // namespace v8

// Weak ASCII fallbacks. Zig may override these with strong definitions.
extern "C" __attribute__((weak)) uint32_t
zjs_irregexp_canonicalize(uint32_t c, int /*unicode*/) {
  if (c >= 'A' && c <= 'Z') return c + 32;
  return c;
}

extern "C" __attribute__((weak)) int zjs_irregexp_uncanonicalize(
    uint32_t c, uint32_t* out, int max_out) {
  if (max_out < 1) return 0;
  if (c >= 'a' && c <= 'z') {
    int n = 0;
    out[n++] = c;
    if (max_out > 1) out[n++] = c - 32;
    return n;
  }
  if (c >= 'A' && c <= 'Z') {
    int n = 0;
    out[n++] = c;
    if (max_out > 1) out[n++] = c + 32;
    return n;
  }
  out[0] = c;
  return 1;
}

extern "C" __attribute__((weak)) int zjs_irregexp_is_identifier_start(
    uint32_t c) {
  return (c == '$' || c == '_' || (c >= 'A' && c <= 'Z') ||
          (c >= 'a' && c <= 'z') || c >= 0x80)
             ? 1
             : 0;
}

extern "C" __attribute__((weak)) int zjs_irregexp_is_identifier_part(
    uint32_t c) {
  return zjs_irregexp_is_identifier_start(c) || (c >= '0' && c <= '9');
}

extern "C" __attribute__((weak)) int zjs_irregexp_is_letter(uint32_t c) {
  return ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c >= 0x80) ? 1
                                                                        : 0;
}
