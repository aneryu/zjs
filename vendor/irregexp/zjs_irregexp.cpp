#include "irregexp/zjs_irregexp.h"

#include "irregexp/RegExpShim.h"
#include "irregexp/imported/regexp-ast.h"
#include "irregexp/imported/regexp-bytecode-generator.h"
#include "irregexp/imported/regexp-compiler.h"
#include "irregexp/imported/regexp-error.h"
#include "irregexp/imported/regexp-flags.h"
#include "irregexp/imported/regexp-interpreter.h"
#include "irregexp/imported/regexp-macro-assembler.h"
#include "irregexp/imported/regexp-parser.h"
#include "irregexp/imported/regexp.h"

#include <cstring>
#include <string>
#include <vector>

namespace {

using v8::internal::DirectHandle;
using v8::internal::DisallowGarbageCollection;
using v8::internal::Factory;
using v8::internal::HandleScope;
using v8::internal::IrRegExpData;
using v8::internal::Isolate;
using v8::internal::JSRegExp;
using v8::internal::RegExpData;
using v8::internal::String;
using v8::internal::Tagged;
using v8::internal::TrustedByteArray;
using v8::internal::Zone;

constexpr uint32_t kMagic = 0x58525249u;  // 'IRRX' little-endian
constexpr uint16_t kVersion = 1;

constexpr uint16_t kZjsGlobal = 1 << 0;
constexpr uint16_t kZjsIgnoreCase = 1 << 1;
constexpr uint16_t kZjsMultiline = 1 << 2;
constexpr uint16_t kZjsDotAll = 1 << 3;
constexpr uint16_t kZjsUnicode = 1 << 4;
constexpr uint16_t kZjsSticky = 1 << 5;
constexpr uint16_t kZjsIndices = 1 << 6;
constexpr uint16_t kZjsNamedGroups = 1 << 7;
constexpr uint16_t kZjsUnicodeSets = 1 << 8;

struct BlobHeader {
  uint32_t magic;
  uint16_t version;
  uint16_t zjs_flags;
  uint16_t capture_count;    // including group 0
  uint16_t register_count;
  uint16_t name_count;
  uint16_t pad;
  uint32_t latin1_off;
  uint32_t latin1_len;
  uint32_t uc16_off;
  uint32_t uc16_len;
};

static_assert(sizeof(BlobHeader) == 32, "blob header is 32 bytes");

uint16_t ReadU16(const uint8_t* p) {
  return static_cast<uint16_t>(p[0] | (static_cast<uint16_t>(p[1]) << 8));
}

uint32_t ReadU32(const uint8_t* p) {
  return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) |
         (static_cast<uint32_t>(p[2]) << 16) | (static_cast<uint32_t>(p[3]) << 24);
}

void WriteU16(std::vector<uint8_t>* out, uint16_t v) {
  out->push_back(static_cast<uint8_t>(v));
  out->push_back(static_cast<uint8_t>(v >> 8));
}

void WriteU32(std::vector<uint8_t>* out, uint32_t v) {
  out->push_back(static_cast<uint8_t>(v));
  out->push_back(static_cast<uint8_t>(v >> 8));
  out->push_back(static_cast<uint8_t>(v >> 16));
  out->push_back(static_cast<uint8_t>(v >> 24));
}

bool ParseHeader(const uint8_t* blob, size_t blob_len, BlobHeader* h) {
  if (blob == nullptr || blob_len < sizeof(BlobHeader)) return false;
  h->magic = ReadU32(blob + 0);
  h->version = ReadU16(blob + 4);
  h->zjs_flags = ReadU16(blob + 6);
  h->capture_count = ReadU16(blob + 8);
  h->register_count = ReadU16(blob + 10);
  h->name_count = ReadU16(blob + 12);
  h->pad = ReadU16(blob + 14);
  h->latin1_off = ReadU32(blob + 16);
  h->latin1_len = ReadU32(blob + 20);
  h->uc16_off = ReadU32(blob + 24);
  h->uc16_len = ReadU32(blob + 28);
  if (h->magic != kMagic || h->version != kVersion) return false;
  if (h->latin1_len != 0 &&
      (static_cast<size_t>(h->latin1_off) + h->latin1_len > blob_len)) {
    return false;
  }
  if (h->uc16_len != 0 &&
      (static_cast<size_t>(h->uc16_off) + h->uc16_len > blob_len)) {
    return false;
  }
  return true;
}

uint16_t V8FlagsToZjs(v8::internal::regexp::Flags flags, bool named) {
  using v8::internal::regexp::IsDotAll;
  using v8::internal::regexp::IsGlobal;
  using v8::internal::regexp::IsHasIndices;
  using v8::internal::regexp::IsIgnoreCase;
  using v8::internal::regexp::IsMultiline;
  using v8::internal::regexp::IsSticky;
  using v8::internal::regexp::IsUnicode;
  using v8::internal::regexp::IsUnicodeSets;
  uint16_t z = 0;
  if (IsGlobal(flags)) z |= kZjsGlobal;
  if (IsIgnoreCase(flags)) z |= kZjsIgnoreCase;
  if (IsMultiline(flags)) z |= kZjsMultiline;
  if (IsDotAll(flags)) z |= kZjsDotAll;
  if (IsUnicode(flags)) z |= kZjsUnicode;
  if (IsSticky(flags)) z |= kZjsSticky;
  if (IsHasIndices(flags)) z |= kZjsIndices;
  if (named) z |= kZjsNamedGroups;
  if (IsUnicodeSets(flags)) z |= kZjsUnicodeSets;
  return z;
}

v8::internal::regexp::Flags FlagsFromV8Bits(uint32_t bits) {
  return v8::internal::regexp::Flags(
      static_cast<std::underlying_type_t<v8::internal::regexp::Flag>>(bits));
}

DirectHandle<String> NewPatternString(Isolate* isolate, const uint8_t* pattern,
                                      size_t pattern_len, int pattern_is_utf16) {
  if (pattern_is_utf16) {
    const size_t units = pattern_len / 2;
    std::vector<v8::base::uc16> buf(units);
    for (size_t i = 0; i < units; i++) {
      buf[i] = static_cast<v8::base::uc16>(ReadU16(pattern + i * 2));
    }
    return isolate->factory()->NewStringFromTwoByte(
        v8::base::Vector<const v8::base::uc16>(buf.data(),
                                               static_cast<int>(units)));
  }
  bool latin1 = true;
  for (size_t i = 0; i < pattern_len; i++) {
    if (pattern[i] != 0) continue;
  }
  // Byte patterns are treated as Latin-1 code units.
  (void)latin1;
  return isolate->factory()->NewStringFromOneByte(
      v8::base::Vector<const uint8_t>(pattern, static_cast<int>(pattern_len)));
}

void Utf16NameToUtf8(const v8::internal::ZoneVector<v8::base::uc16>* name,
                     std::string* out) {
  out->clear();
  for (v8::base::uc16 cu : *name) {
    const uint32_t c = static_cast<uint32_t>(cu);
    if (c < 0x80) {
      out->push_back(static_cast<char>(c));
    } else if (c < 0x800) {
      out->push_back(static_cast<char>(0xc0 | (c >> 6)));
      out->push_back(static_cast<char>(0x80 | (c & 0x3f)));
    } else {
      out->push_back(static_cast<char>(0xe0 | (c >> 12)));
      out->push_back(static_cast<char>(0x80 | ((c >> 6) & 0x3f)));
      out->push_back(static_cast<char>(0x80 | (c & 0x3f)));
    }
  }
}

bool CompileOneWidth(Isolate* isolate, Zone* zone,
                     v8::internal::regexp::CompileData* data,
                     v8::internal::regexp::Flags flags, bool is_one_byte,
                     DirectHandle<IrRegExpData> re_data,
                     std::vector<uint8_t>* bytecode_out, int* register_count) {
  using v8::internal::regexp::AnalyzeRegExp;
  using v8::internal::regexp::BytecodeGenerator;
  using v8::internal::regexp::Compiler;
  using v8::internal::regexp::Error;
  using v8::internal::regexp::IsEitherUnicode;
  using v8::internal::regexp::IsGlobal;
  using v8::internal::regexp::IsSticky;
  using v8::internal::regexp::RegExpMacroAssembler;

  data->error = Error::kNone;
  data->node = nullptr;
  data->register_count = 0;

  Compiler compiler(isolate, zone, data->capture_count, flags, is_one_byte);
  data->node = compiler.PreprocessRegExp(data, is_one_byte);
  if (data->error != Error::kNone || data->node == nullptr) return false;

  const Error analysis = AnalyzeRegExp(isolate, is_one_byte, flags, data->node);
  if (analysis != Error::kNone) {
    data->error = analysis;
    return false;
  }

  const auto mode = is_one_byte ? RegExpMacroAssembler::LATIN1
                                : RegExpMacroAssembler::UC16;
  BytecodeGenerator masm(isolate, zone, mode);

  if (data->tree != nullptr &&
      data->tree->IsCertainlyAnchoredAtEnd(v8::internal::regexp::Node::kRecursionBudget) &&
      !data->tree->IsCertainlyAnchoredAtStart(
          v8::internal::regexp::Node::kRecursionBudget) &&
      !IsSticky(flags) && data->tree->max_match() < 1024 &&
      data->tree->max_match() > 0) {
    masm.SetCurrentPositionFromEnd(data->tree->max_match());
  }

  if (IsGlobal(flags)) {
    masm.set_global_mode(IsEitherUnicode(flags)
                             ? RegExpMacroAssembler::GLOBAL_UNICODE
                             : RegExpMacroAssembler::GLOBAL);
  }

  const Compiler::CompilationResult compiled =
      compiler.Assemble(isolate, &masm, data->node, data->capture_count,
                        re_data);
  if (!compiled.Succeeded()) {
    data->error = compiled.error;
    return false;
  }

  Tagged<TrustedByteArray> array = v8::internal::Cast<TrustedByteArray>(*compiled.code);
  const uint32_t len = array->ulength().value();
  bytecode_out->assign(array->begin(), array->begin() + len);
  *register_count = compiled.num_registers;
  re_data->set_bytecode(is_one_byte, array);
  if (compiled.num_registers > re_data->max_register_count()) {
    re_data->set_max_register_count(compiled.num_registers);
  }
  return true;
}

const char* PersistError(const char* msg) {
  // ErrorString pointers are static; keep a fallback heap copy only if needed.
  return msg;
}

Isolate* ThreadExecIsolate() {
  static thread_local Isolate isolate;
  return &isolate;
}

class CurrentIsolateScope {
 public:
  explicit CurrentIsolateScope(Isolate* isolate)
      : previous_(Isolate::Current()), isolate_(isolate) {
    isolate_->MakeCurrent();
  }
  ~CurrentIsolateScope() { Isolate::SetCurrent(previous_); }

  CurrentIsolateScope(const CurrentIsolateScope&) = delete;
  CurrentIsolateScope& operator=(const CurrentIsolateScope&) = delete;

 private:
  Isolate* previous_;
  Isolate* isolate_;
};

int MapExecResult(Isolate* isolate,
                  v8::internal::regexp::IrregexpInterpreter::Result result) {
  switch (result) {
    case v8::internal::regexp::IrregexpInterpreter::SUCCESS:
      return ZJS_IRREGEXP_OK;
    case v8::internal::regexp::IrregexpInterpreter::FAILURE:
      return ZJS_IRREGEXP_NO_MATCH;
    case v8::internal::regexp::IrregexpInterpreter::EXCEPTION:
      if (isolate->interrupted()) return ZJS_IRREGEXP_TIMEOUT;
      return ZJS_IRREGEXP_STACK;
    case v8::internal::regexp::IrregexpInterpreter::RETRY:
      return ZJS_IRREGEXP_TIMEOUT;
    default:
      return ZJS_IRREGEXP_CORRUPT;
  }
}

int ExecView(Isolate* isolate, const BlobHeader& h, bool exec_one_byte,
             const uint8_t* bytecode, uint32_t bc_len, String* subject,
             int32_t* registers, int registers_per_match, int total_regs,
             size_t start_index) {
  TrustedByteArray code(bytecode, bc_len);
  IrRegExpData re_data;
  re_data.set_flags(static_cast<JSRegExp::Flags>(0));
  re_data.set_capture_count(static_cast<int>(h.capture_count) - 1);
  re_data.set_max_register_count(static_cast<int>(h.register_count));
  Tagged<TrustedByteArray> code_tagged(&code);
  re_data.set_bytecode(exec_one_byte, code_tagged);
  Tagged<String> subject_tagged(subject);
  const auto result = v8::internal::regexp::IrregexpInterpreter::MatchInternal(
      isolate, &code_tagged, &subject_tagged, registers, registers_per_match,
      total_regs, static_cast<int>(start_index),
      v8::internal::RegExp::kFromRuntime, 0);
  return MapExecResult(isolate, result);
}

}  // namespace

int zjs_irregexp_compile(const uint8_t* pattern, size_t pattern_len,
                         int pattern_is_utf16, uint32_t v8_flags,
                         zjs_irregexp_compile_out* out) {
  if (out == nullptr) return ZJS_IRREGEXP_CORRUPT;
  out->blob = nullptr;
  out->blob_len = 0;
  out->error_message = nullptr;

  if (pattern == nullptr && pattern_len != 0) return ZJS_IRREGEXP_CORRUPT;
  if (pattern_is_utf16 && (pattern_len % 2) != 0) return ZJS_IRREGEXP_CORRUPT;

  Isolate isolate;
  HandleScope scope(&isolate);
  Zone zone(&isolate);

  const v8::internal::regexp::Flags flags = FlagsFromV8Bits(v8_flags);
  DirectHandle<String> source =
      NewPatternString(&isolate, pattern, pattern_len, pattern_is_utf16);

  // Parse once per subject width. EmitClassRanges::ClampToOneByte rewrites
  // the AST CharacterSet in place, so a shared tree compiled for Latin-1
  // first would leave UC16 bytecode unable to match anything above 0xFF.
  auto parse = [&](v8::internal::regexp::CompileData* data) -> int {
    if (v8::internal::regexp::Parser::ParseRegExpFromHeapString(
            &isolate, &zone, source, flags, data)) {
      return ZJS_IRREGEXP_OK;
    }
    out->error_message = PersistError(
        v8::internal::regexp::ErrorString(data->error));
    if (v8::internal::regexp::ErrorIsStackOverflow(data->error)) {
      return ZJS_IRREGEXP_STACK;
    }
    return ZJS_IRREGEXP_SYNTAX;
  };

  v8::internal::regexp::CompileData latin1_data;
  const int parse_status = parse(&latin1_data);
  if (parse_status != ZJS_IRREGEXP_OK) return parse_status;

  DirectHandle<IrRegExpData> re_data(isolate.Adopt<IrRegExpData>(), &isolate);
  // Capture count in V8 CompileData excludes group 0.
  re_data->set_capture_count(latin1_data.capture_count);
  re_data->set_escaped_source(*source);
  re_data->set_flags(static_cast<JSRegExp::Flags>(v8_flags));

  std::vector<uint8_t> latin1_bc;
  std::vector<uint8_t> uc16_bc;
  int latin1_regs = 0;
  int uc16_regs = 0;
  const bool latin1_ok =
      CompileOneWidth(&isolate, &zone, &latin1_data, flags, true, re_data,
                      &latin1_bc, &latin1_regs);

  v8::internal::regexp::CompileData uc16_data;
  const int parse_uc16 = parse(&uc16_data);
  if (parse_uc16 != ZJS_IRREGEXP_OK) return parse_uc16;
  const bool uc16_ok =
      CompileOneWidth(&isolate, &zone, &uc16_data, flags, false, re_data,
                      &uc16_bc, &uc16_regs);
  if (!latin1_ok && !uc16_ok) {
    const auto err =
        uc16_data.error != v8::internal::regexp::Error::kNone
            ? uc16_data.error
            : latin1_data.error;
    out->error_message = PersistError(
        v8::internal::regexp::ErrorString(err));
    if (v8::internal::regexp::ErrorIsStackOverflow(err)) {
      return ZJS_IRREGEXP_STACK;
    }
    return ZJS_IRREGEXP_SYNTAX;
  }

  const int register_count = std::max(latin1_regs, uc16_regs);
  const uint16_t capture_including_zero =
      static_cast<uint16_t>(latin1_data.capture_count + 1);
  const bool named = latin1_data.named_captures != nullptr &&
                     !latin1_data.named_captures->empty();
  const uint16_t zjs_flags = V8FlagsToZjs(flags, named);

  std::vector<uint8_t> names_section;
  uint16_t name_count = 0;
  if (named) {
    std::string utf8;
    for (v8::internal::regexp::Capture* cap : *latin1_data.named_captures) {
      if (cap == nullptr || cap->name() == nullptr) continue;
      Utf16NameToUtf8(cap->name(), &utf8);
      WriteU16(&names_section, static_cast<uint16_t>(cap->index()));
      WriteU16(&names_section, static_cast<uint16_t>(utf8.size()));
      names_section.insert(names_section.end(), utf8.begin(), utf8.end());
      name_count++;
    }
  }

  std::vector<uint8_t> blob;
  blob.resize(sizeof(BlobHeader));
  blob.insert(blob.end(), names_section.begin(), names_section.end());
  auto pad4 = [&]() {
    while ((blob.size() & 3u) != 0) blob.push_back(0);
  };
  // Irregexp operand loads require 4-byte-aligned bytecode.
  pad4();
  const uint32_t latin1_off = static_cast<uint32_t>(blob.size());
  blob.insert(blob.end(), latin1_bc.begin(), latin1_bc.end());
  pad4();
  const uint32_t uc16_off = static_cast<uint32_t>(blob.size());
  blob.insert(blob.end(), uc16_bc.begin(), uc16_bc.end());

  uint8_t* hdr = blob.data();
  auto put32 = [&](size_t off, uint32_t v) {
    hdr[off] = static_cast<uint8_t>(v);
    hdr[off + 1] = static_cast<uint8_t>(v >> 8);
    hdr[off + 2] = static_cast<uint8_t>(v >> 16);
    hdr[off + 3] = static_cast<uint8_t>(v >> 24);
  };
  auto put16 = [&](size_t off, uint16_t v) {
    hdr[off] = static_cast<uint8_t>(v);
    hdr[off + 1] = static_cast<uint8_t>(v >> 8);
  };
  put32(0, kMagic);
  put16(4, kVersion);
  put16(6, zjs_flags);
  put16(8, capture_including_zero);
  put16(10, static_cast<uint16_t>(register_count));
  put16(12, name_count);
  put16(14, 0);
  put32(16, latin1_ok ? latin1_off : 0);
  put32(20, latin1_ok ? static_cast<uint32_t>(latin1_bc.size()) : 0);
  put32(24, uc16_ok ? uc16_off : 0);
  put32(28, uc16_ok ? static_cast<uint32_t>(uc16_bc.size()) : 0);

  uint8_t* raw = static_cast<uint8_t*>(std::malloc(blob.size()));
  if (!raw) return ZJS_IRREGEXP_OOM;
  std::memcpy(raw, blob.data(), blob.size());
  out->blob = raw;
  out->blob_len = blob.size();
  return ZJS_IRREGEXP_OK;
}

void zjs_irregexp_free(uint8_t* blob) { std::free(blob); }

uint16_t zjs_irregexp_blob_zjs_flags(const uint8_t* blob, size_t blob_len) {
  BlobHeader h;
  if (!ParseHeader(blob, blob_len, &h)) return 0;
  return h.zjs_flags;
}

uint16_t zjs_irregexp_blob_capture_count(const uint8_t* blob, size_t blob_len) {
  BlobHeader h;
  if (!ParseHeader(blob, blob_len, &h)) return 0;
  return h.capture_count;
}

uint16_t zjs_irregexp_blob_register_count(const uint8_t* blob,
                                          size_t blob_len) {
  BlobHeader h;
  if (!ParseHeader(blob, blob_len, &h)) return 0;
  return h.register_count;
}

int zjs_irregexp_blob_group_name(const uint8_t* blob, size_t blob_len,
                                 size_t one_based_index,
                                 const uint8_t** name_out,
                                 size_t* name_len_out) {
  if (name_out) *name_out = nullptr;
  if (name_len_out) *name_len_out = 0;
  BlobHeader h;
  if (!ParseHeader(blob, blob_len, &h)) return 0;
  size_t off = sizeof(BlobHeader);
  const size_t names_end = h.latin1_len
                               ? h.latin1_off
                               : (h.uc16_len ? h.uc16_off : blob_len);
  for (uint16_t i = 0; i < h.name_count; i++) {
    if (off + 4 > names_end) return 0;
    const uint16_t index = ReadU16(blob + off);
    const uint16_t len = ReadU16(blob + off + 2);
    off += 4;
    if (off + len > names_end) return 0;
    if (index == one_based_index) {
      if (name_out) *name_out = blob + off;
      if (name_len_out) *name_len_out = len;
      return 1;
    }
    off += len;
  }
  return 0;
}

int zjs_irregexp_exec(const uint8_t* blob, size_t blob_len, const void* subject,
                      size_t subject_len, int subject_width, size_t start_index,
                      int32_t* registers, size_t register_count,
                      zjs_irregexp_interrupt_fn interrupt,
                      void* interrupt_opaque) {
  BlobHeader h;
  if (!ParseHeader(blob, blob_len, &h)) return ZJS_IRREGEXP_CORRUPT;
  if (registers == nullptr && register_count != 0) return ZJS_IRREGEXP_CORRUPT;
  if (start_index > subject_len) return ZJS_IRREGEXP_NO_MATCH;
  if (subject_len != 0 && subject == nullptr) return ZJS_IRREGEXP_CORRUPT;

  const bool want_latin1 = subject_width == ZJS_IRREGEXP_LATIN1;
  uint32_t bc_off = want_latin1 ? h.latin1_off : h.uc16_off;
  uint32_t bc_len = want_latin1 ? h.latin1_len : h.uc16_len;

  std::vector<v8::base::uc16> widened;
  const void* exec_subject = subject;
  size_t exec_len = subject_len;
  bool exec_one_byte = want_latin1;

  if (bc_len == 0) {
    if (!want_latin1 || h.uc16_len == 0) return ZJS_IRREGEXP_CORRUPT;
    // Widen Latin-1 subject to UTF-16 and use the UC16 bytecode.
    widened.resize(subject_len);
    const auto* bytes = static_cast<const uint8_t*>(subject);
    for (size_t i = 0; i < subject_len; i++) {
      widened[i] = bytes[i];
    }
    exec_subject = widened.data();
    exec_len = subject_len;
    exec_one_byte = false;
    bc_off = h.uc16_off;
    bc_len = h.uc16_len;
  }
  if (bc_len == 0) return ZJS_IRREGEXP_CORRUPT;

  // Empty Zig slices may pass an undefined pointer with length 0.
  alignas(alignof(v8::base::uc16)) static const uint8_t kEmptySubject[2] = {0, 0};
  if (exec_len == 0) exec_subject = kEmptySubject;

  const uint8_t* bytecode = blob + bc_off;
  std::vector<uint8_t> aligned_bc;
  if ((reinterpret_cast<uintptr_t>(bytecode) & 3u) != 0) {
    aligned_bc.assign(bytecode, bytecode + bc_len);
    bytecode = aligned_bc.data();
  }

  const int captures_including_zero = static_cast<int>(h.capture_count);
  const int registers_per_match = captures_including_zero * 2;
  const int total_regs =
      std::max(static_cast<int>(h.register_count), registers_per_match);
  if (static_cast<int>(register_count) < registers_per_match) {
    return ZJS_IRREGEXP_CORRUPT;
  }

  Isolate* isolate = ThreadExecIsolate();
  CurrentIsolateScope current(isolate);
  isolate->clear_exception();
  isolate->set_interrupt(interrupt, interrupt_opaque);
  isolate->stack_guard()->Recalibrate();

  int status;
  if (exec_one_byte) {
    String subject_str(static_cast<const uint8_t*>(exec_subject),
                       static_cast<int>(exec_len));
    status = ExecView(isolate, h, true, bytecode, bc_len, &subject_str,
                      registers, registers_per_match, total_regs, start_index);
  } else {
    String subject_str(static_cast<const v8::base::uc16*>(exec_subject),
                       static_cast<int>(exec_len));
    status = ExecView(isolate, h, false, bytecode, bc_len, &subject_str,
                      registers, registers_per_match, total_regs, start_index);
  }

  isolate->set_interrupt(nullptr, nullptr);
  return status;
}
