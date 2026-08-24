#include "irregexp/zjs_irregexp.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static void fail(const char* msg) {
  std::fprintf(stderr, "FAIL: %s\n", msg);
  std::exit(1);
}

static std::vector<uint8_t> compile_or_die(const char* pattern, uint32_t v8_flags) {
  zjs_irregexp_compile_out out{};
  const int st = zjs_irregexp_compile(
      reinterpret_cast<const uint8_t*>(pattern), std::strlen(pattern), 0,
      v8_flags, &out);
  if (st != ZJS_IRREGEXP_OK) {
    std::fprintf(stderr, "compile failed status=%d err=%s pattern=/%s/\n", st,
                 out.error_message ? out.error_message : "", pattern);
    std::exit(1);
  }
  std::vector<uint8_t> blob(out.blob, out.blob + out.blob_len);
  zjs_irregexp_free(out.blob);
  return blob;
}

static int exec_latin1(const std::vector<uint8_t>& blob, const char* subject,
                       size_t start, std::vector<int32_t>* regs) {
  const uint16_t captures = zjs_irregexp_blob_capture_count(blob.data(), blob.size());
  const uint16_t total = zjs_irregexp_blob_register_count(blob.data(), blob.size());
  const size_t need = std::max<size_t>(static_cast<size_t>(captures) * 2, total);
  regs->assign(need, -1);
  return zjs_irregexp_exec(blob.data(), blob.size(), subject, std::strlen(subject),
                           ZJS_IRREGEXP_LATIN1, start, regs->data(), regs->size(),
                           nullptr, nullptr);
}

int main() {
  // /foo/ against "xxfooyy"
  {
    auto blob = compile_or_die("foo", 0);
    if (zjs_irregexp_blob_capture_count(blob.data(), blob.size()) != 1) {
      fail("capture_count for /foo/");
    }
    std::vector<int32_t> regs;
    const int st = exec_latin1(blob, "xxfooyy", 0, &regs);
    if (st != ZJS_IRREGEXP_OK) fail("exec /foo/ on xxfooyy");
    if (regs[0] != 2 || regs[1] != 5) {
      std::fprintf(stderr, "got [%d,%d]\n", regs[0], regs[1]);
      fail("capture offsets for /foo/");
    }
    std::printf("ok /foo/ -> [%d,%d]\n", regs[0], regs[1]);
  }

  // /(a+)(b+)/ against "xxaaabb"
  {
    auto blob = compile_or_die("(a+)(b+)", 0);
    if (zjs_irregexp_blob_capture_count(blob.data(), blob.size()) != 3) {
      fail("capture_count for /(a+)(b+)/");
    }
    std::vector<int32_t> regs;
    const int st = exec_latin1(blob, "xxaaabb", 0, &regs);
    if (st != ZJS_IRREGEXP_OK) fail("exec /(a+)(b+)/");
    if (regs[0] != 2 || regs[1] != 7 || regs[2] != 2 || regs[3] != 5 ||
        regs[4] != 5 || regs[5] != 7) {
      std::fprintf(stderr, "got [%d,%d] [%d,%d] [%d,%d]\n", regs[0], regs[1],
                   regs[2], regs[3], regs[4], regs[5]);
      fail("captures for /(a+)(b+)/");
    }
    std::printf("ok /(a+)(b+)/ -> [%d,%d] (%d,%d) (%d,%d)\n", regs[0], regs[1],
                regs[2], regs[3], regs[4], regs[5]);
  }

  // no match
  {
    auto blob = compile_or_die("xyz", 0);
    std::vector<int32_t> regs;
    const int st = exec_latin1(blob, "abc", 0, &regs);
    if (st != ZJS_IRREGEXP_NO_MATCH) fail("expected no match");
    std::printf("ok /xyz/ no match\n");
  }

  // syntax error
  {
    zjs_irregexp_compile_out out{};
    const int st = zjs_irregexp_compile(
        reinterpret_cast<const uint8_t*>("("), 1, 0, 0, &out);
    if (st != ZJS_IRREGEXP_SYNTAX) fail("expected syntax error");
    std::printf("ok syntax error: %s\n",
                out.error_message ? out.error_message : "(null)");
  }

  // named group
  {
    auto blob = compile_or_die("(?<num>\\d+)", 0);
    const uint8_t* name = nullptr;
    size_t name_len = 0;
    if (!zjs_irregexp_blob_group_name(blob.data(), blob.size(), 1, &name,
                                      &name_len)) {
      fail("named group missing");
    }
    if (name_len != 3 || std::memcmp(name, "num", 3) != 0) fail("name bytes");
    if ((zjs_irregexp_blob_zjs_flags(blob.data(), blob.size()) & (1 << 7)) ==
        0) {
      fail("named_groups flag");
    }
    std::vector<int32_t> regs;
    const int st = exec_latin1(blob, "id=42!", 0, &regs);
    if (st != ZJS_IRREGEXP_OK || regs[0] != 3 || regs[1] != 5) {
      fail("named group exec");
    }
    std::printf("ok named group num -> [%d,%d]\n", regs[0], regs[1]);
  }

  // ignore-case
  {
    const uint32_t v8_ignore_case = 1u << 1;  // Flag::kIgnoreCase
    auto blob = compile_or_die("Foo", v8_ignore_case);
    std::vector<int32_t> regs;
    const int st = exec_latin1(blob, "xxFOOyy", 0, &regs);
    if (st != ZJS_IRREGEXP_OK || regs[0] != 2 || regs[1] != 5) {
      fail("ignore-case /Foo/i");
    }
    std::printf("ok /Foo/i -> [%d,%d]\n", regs[0], regs[1]);
  }

  // sticky /y does not search forward
  {
    const uint32_t v8_sticky = 1u << 3;  // Flag::kSticky
    auto blob = compile_or_die("foo", v8_sticky);
    std::vector<int32_t> regs;
    if (exec_latin1(blob, "xxfoo", 0, &regs) != ZJS_IRREGEXP_NO_MATCH) {
      fail("sticky /foo/y should miss at index 0");
    }
    if (exec_latin1(blob, "xxfoo", 2, &regs) != ZJS_IRREGEXP_OK ||
        regs[0] != 2 || regs[1] != 5) {
      fail("sticky /foo/y at index 2");
    }
    std::printf("ok /foo/y sticky\n");
  }

  // UTF-16 subject
  {
    auto blob = compile_or_die("bar", 0);
    const uint16_t subject[] = {'x', 'b', 'a', 'r', 'y'};
    const uint16_t captures =
        zjs_irregexp_blob_capture_count(blob.data(), blob.size());
    const uint16_t total =
        zjs_irregexp_blob_register_count(blob.data(), blob.size());
    const size_t need =
        std::max<size_t>(static_cast<size_t>(captures) * 2, total);
    std::vector<int32_t> regs(need, -1);
    const int st = zjs_irregexp_exec(
        blob.data(), blob.size(), subject, 5, ZJS_IRREGEXP_UTF16, 0,
        regs.data(), regs.size(), nullptr, nullptr);
    if (st != ZJS_IRREGEXP_OK || regs[0] != 1 || regs[1] != 4) {
      fail("utf16 /bar/");
    }
    std::printf("ok utf16 /bar/ -> [%d,%d]\n", regs[0], regs[1]);
  }

  // UTF-16 '.' must match non-Latin-1 code units and supplementary pairs.
  {
    auto blob = compile_or_die(".", 0);
    const uint16_t han[] = {0x4E2D};
    const uint16_t pair[] = {0xD834, 0xDF06};
    std::vector<int32_t> regs(4, -1);
    if (zjs_irregexp_exec(blob.data(), blob.size(), han, 1, ZJS_IRREGEXP_UTF16,
                          0, regs.data(), regs.size(), nullptr, nullptr) !=
            ZJS_IRREGEXP_OK ||
        regs[0] != 0 || regs[1] != 1) {
      fail("utf16 /./ on U+4E2D");
    }
    if (zjs_irregexp_exec(blob.data(), blob.size(), pair, 2, ZJS_IRREGEXP_UTF16,
                          0, regs.data(), regs.size(), nullptr, nullptr) !=
            ZJS_IRREGEXP_OK ||
        regs[0] != 0 || regs[1] != 1) {
      fail("utf16 /./ on surrogate pair");
    }
    std::printf("ok utf16 /./ non-latin1\n");
  }

  {
    const uint32_t v8_unicode = 1u << 4;
    auto blob = compile_or_die(".", v8_unicode);
    const uint16_t pair[] = {0xD834, 0xDF06};
    std::vector<int32_t> regs(4, -1);
    if (zjs_irregexp_exec(blob.data(), blob.size(), pair, 2, ZJS_IRREGEXP_UTF16,
                          0, regs.data(), regs.size(), nullptr, nullptr) !=
            ZJS_IRREGEXP_OK ||
        regs[0] != 0 || regs[1] != 2) {
      fail("utf16 /./u on surrogate pair");
    }
    std::printf("ok utf16 /./u supplementary\n");
  }

  std::printf("all smoke tests passed\n");
  return 0;
}
