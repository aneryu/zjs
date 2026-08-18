pub const ProfileConfig = struct {
    name: []const u8,
    desc: []const u8,
    script: []const u8,
    expect_stdout: []const u8,
    expect_opcodes: []const []const u8,
    // Minimum gates: an all-zero profile must never pass (the 2026-07-31
    // regression survived precisely because 0 <= max is vacuous).
    expect_opcode_mins: []const []const u8 = &.{},
};

pub const runtime_profiles = [_]ProfileConfig{
    .{
        .name = "perf-uri-profile",
        .desc = "Record a zjs runtime profile for the URI 4-byte decode benchmark script",
        .script = "uri_decode_4byte",
        .expect_stdout = "65536\n",
        // Exact dispatch-count pins recalibrated 2026-07-31 against the
        // restored total-dispatch counting (D0). A drop or rise must be
        // acknowledged by recalibrating, never by loosening to a vacuum.
        .expect_opcodes = &.{
            "get_var=988211",
            "get_var_ref0=0",
            "put_var=396322",
            "push_i16=396320",
            "goto16=66576",
            "add=527360",
            "if_false8=65536",
        },
        .expect_opcode_mins = &.{
            "get_var=988211",
            "put_var=396322",
            "push_i16=396320",
            "goto16=66576",
            "add=527360",
            "if_false8=65536",
        },
    },
    .{
        .name = "perf-uri-component-profile",
        .desc = "Record a zjs runtime profile for the URI component 4-byte decode benchmark script",
        .script = "uri_component_decode_4byte",
        .expect_stdout = "65536\n",
        // Exact dispatch-count pins recalibrated 2026-07-31 against the
        // restored total-dispatch counting (D0). A drop or rise must be
        // acknowledged by recalibrating, never by loosening to a vacuum.
        .expect_opcodes = &.{
            "get_var=988211",
            "get_var_ref0=0",
            "put_var=396322",
            "push_i16=396320",
            "goto16=66576",
            "add=527360",
            "if_false8=65536",
        },
        .expect_opcode_mins = &.{
            "get_var=988211",
            "put_var=396322",
            "push_i16=396320",
            "goto16=66576",
            "add=527360",
            "if_false8=65536",
        },
    },
    .{
        .name = "perf-prop-global-profile",
        .desc = "Record a zjs runtime profile for the global property read benchmark script",
        .script = "prop_read_global_mono",
        .expect_stdout = "1000000\n",
        // Exact dispatch-count pins recalibrated 2026-07-31 against the
        // restored total-dispatch counting (D0). A drop or rise must be
        // acknowledged by recalibrating, never by loosening to a vacuum.
        .expect_opcodes = &.{
            "get_field=1000000",
            "add=1000000",
            "goto8=1000000",
        },
        .expect_opcode_mins = &.{
            "get_field=1000000",
            "add=1000000",
            "goto8=1000000",
        },
    },
    .{
        .name = "perf-proto-global-profile",
        .desc = "Record a zjs runtime profile for the global prototype read benchmark script",
        .script = "proto_read_global",
        .expect_stdout = "1000000\n",
        // Exact dispatch-count pins recalibrated 2026-07-31 against the
        // restored total-dispatch counting (D0). A drop or rise must be
        // acknowledged by recalibrating, never by loosening to a vacuum.
        .expect_opcodes = &.{
            "get_field=1000000",
            "add=1000000",
            "goto8=1000000",
        },
        .expect_opcode_mins = &.{
            "get_field=1000000",
            "add=1000000",
            "goto8=1000000",
        },
    },
    .{
        .name = "perf-prop-poly3-profile",
        .desc = "Record a zjs runtime profile for the global polymorphic property read benchmark script",
        .script = "prop_read_poly3_global",
        .expect_stdout = "1000000\n",
        // Exact dispatch-count pins recalibrated 2026-07-31 against the
        // restored total-dispatch counting (D0). A drop or rise must be
        // acknowledged by recalibrating, never by loosening to a vacuum.
        .expect_opcodes = &.{
            "get_array_el=1000000",
            "get_field=1000000",
            "mod=1000000",
            "add=1000000",
            "goto8=1000000",
        },
        .expect_opcode_mins = &.{
            "get_array_el=1000000",
            "get_field=1000000",
            "mod=1000000",
            "add=1000000",
            "goto8=1000000",
        },
    },
    .{
        .name = "perf-call2-global-profile",
        .desc = "Record a zjs runtime profile for the global call2 loop benchmark script",
        .script = "call2_loop_global",
        .expect_stdout = "500000500000\n",
        // Exact dispatch-count pins recalibrated 2026-07-31 against the
        // restored total-dispatch counting (D0). A drop or rise must be
        // acknowledged by recalibrating, never by loosening to a vacuum.
        .expect_opcodes = &.{
            "call2=1000000",
            "add=2000000",
            "post_inc=1000000",
            "goto8=1000000",
        },
        .expect_opcode_mins = &.{
            "call2=1000000",
            "add=2000000",
            "post_inc=1000000",
            "goto8=1000000",
        },
    },
    .{
        .name = "perf-closure-call-global-profile",
        .desc = "Record a zjs runtime profile for the global closure call loop benchmark script",
        .script = "closure_call_loop_global",
        .expect_stdout = "500000500000\n",
        // Exact dispatch-count pins recalibrated 2026-07-31 against the
        // restored total-dispatch counting (D0). A drop or rise must be
        // acknowledged by recalibrating, never by loosening to a vacuum.
        .expect_opcodes = &.{
            "add=2000000",
            "post_inc=1000000",
            "goto8=1000000",
        },
        .expect_opcode_mins = &.{
            "add=2000000",
            "post_inc=1000000",
            "goto8=1000000",
        },
    },
    .{
        .name = "perf-string-loop-profile",
        .desc = "Record a zjs runtime profile for the string microbench loop script",
        .script = "string_loop",
        .expect_stdout = "261\n",
        // Exact dispatch-count pins recalibrated 2026-07-31 against the
        // restored total-dispatch counting (D0). A drop or rise must be
        // acknowledged by recalibrating, never by loosening to a vacuum.
        .expect_opcodes = &.{
            "get_var=5002",
            "get_length=5002",
            "push_i8=15309",
            "gt=5000",
            "get_field2=5311",
            "call_method=5311",
            "get_loc0=5313",
            "get_loc1=10001",
            "add=10002",
            "get_arg0=5001",
            "lt=5001",
            "if_false8=10001",
            "post_inc=0",
            "goto8=5000",
            "put_loc1=1",
            "drop=0",
        },
        .expect_opcode_mins = &.{
            "get_var=5002",
            "get_length=5002",
            "push_i8=15309",
            "gt=5000",
            "get_field2=5311",
            "call_method=5311",
            "get_loc0=5313",
            "get_loc1=10001",
            "add=10002",
            "get_arg0=5001",
            "lt=5001",
            "if_false8=10001",
            "goto8=5000",
            "put_loc1=1",
        },
    },
    .{
        .name = "perf-empty-loop-profile",
        .desc = "Record a zjs runtime profile for the empty int32 for-loop benchmark script",
        .script = "empty_loop",
        .expect_stdout = "0\n",
        .expect_opcodes = &.{},
    },
};
