summary:
  old geomean: 2.0627
  new geomean: 1.0158
  delta:        -50.8%
  compatible:   72 -> 72
  unsupported:  1 -> 1
  skipped:      0 -> 0
  sample cfg:   iters=30, warmup=5 -> iters=120, warmup=15

regressions:
  case                     category        old    new    zjs avg delta  ratio delta  winner
  prop_write               object          1.56   1.27         +14.2%       -18.1%  qjs
  array_write              array           1.57   1.39         +31.1%       -11.7%  qjs
  array_hole_length_decr   array           1.50   1.12         +40.1%       -24.8%  qjs
  global_destruct_strict   destructuring   1.52   1.42         +31.0%        -6.6%  qjs
  regexp_ascii             regexp          0.94   1.45         +15.6%       +53.3%  zjs->qjs
  float_toString           conversion      1.43   1.47         +14.3%        +2.3%  qjs
  string_to_int            conversion      1.17   1.14         +15.6%        -2.8%  qjs
  bigint256_arith          bigint          1.33   1.75         +33.5%       +31.7%  qjs

improvements:
  case                     category        old    new    zjs avg delta  ratio delta  winner
  int_sum                  arithmetic      3.89   2.91         -51.5%       -25.3%  qjs
  json_roundtrip           json            1.50   1.32         -37.0%       -11.8%  qjs
  empty_loop               control         0.89   0.72         -38.7%       -19.5%  zjs
  prop_read                object          5.13   1.13         -71.8%       -77.9%  qjs
  array_read               array           4.68   1.89         -76.0%       -59.5%  qjs
  func_call                function        1.78   0.39         -85.5%       -77.9%  qjs->zjs
  math_min                 math            3.72   2.05         -49.1%       -45.0%  qjs
  string_build             string          3.46   0.95         -63.7%       -72.6%  qjs->zjs
  date_now                 date            1.81   0.92         -12.1%       -49.4%  qjs->zjs
  array_prop_create        array           2.05   1.09         -46.4%       -46.9%  qjs
  array_push               array           2.79   0.81         -48.0%       -71.1%  qjs->zjs
  array_pop                array           1.06   1.01         -20.6%        -5.5%  qjs->tie
  typed_array_read         typedarray      1.62   0.65         -30.0%       -59.8%  qjs->zjs
  typed_array_write        typedarray      1.61   1.46         -16.7%        -9.5%  qjs
  global_read              global          3.71   0.40         -80.5%       -89.2%  qjs->zjs
  global_write_strict      global          1.88   0.80         -30.3%       -57.2%  qjs->zjs
  closure_var              function        2.04   1.09         -12.9%       -46.8%  qjs
  map_set                  collection      1.80   0.76         -47.0%       -58.1%  qjs->zjs
  map_delete               collection      2.14   0.93         -40.6%       -56.3%  qjs->zjs
  weak_map_set             collection      1.04   0.92         -31.4%       -11.6%  tie->zjs
  weak_map_delete          collection      2.69   0.92         -44.9%       -65.7%  qjs->zjs
  array_for                array           4.31   1.70         -70.1%       -60.6%  qjs
  array_for_in             array           1.52   0.98         -35.4%       -35.5%  qjs->tie
  array_for_of             array           1.48   1.14         -31.2%       -22.6%  qjs
  object_null              object          1.47   0.97         -30.5%       -33.8%  qjs->tie
  string_build2            string          4.07   1.23         -76.9%       -69.7%  qjs
  string_concat2           string          2.01   1.01         -22.6%       -49.7%  qjs->tie
  string_concat3           string          2.67   1.30         -23.3%       -51.5%  qjs
  string_slice1            string          2.57   0.97         -39.3%       -62.1%  qjs->tie
  string_slice3            string          1.63   0.98         -35.1%       -40.0%  qjs->tie
  sort_bench               sort            1.35   1.11         -40.2%       -17.8%  qjs
  int_to_string            conversion      1.67   1.23         -30.9%       -26.5%  qjs
  int_toString             conversion      1.61   0.76         -19.4%       -52.7%  qjs->zjs
  float_toFixed            conversion      1.48   0.86         -39.1%       -41.9%  qjs->zjs
  float_toPrecision        conversion      1.62   1.07         -32.8%       -33.7%  qjs
  float_toExponential      conversion      1.38   1.15         -27.6%       -16.5%  qjs
  bigint64_arith           bigint          2.03   0.94         -27.2%       -53.6%  qjs->zjs
  vm_int_sum_large         control         4.24   1.38         -46.5%       -67.5%  qjs
  prop_read_mono           object          4.57   2.29         -49.4%       -50.0%  qjs
  prop_read_poly3          object          4.75   1.55         -62.4%       -67.4%  qjs
  proto_read               object          4.85   2.14         -55.1%       -55.7%  qjs
  global_read_loop         global          6.57   0.06         -99.1%       -99.2%  qjs->zjs
  call2_loop               function        2.79   1.75         -34.0%       -37.1%  qjs
  closure_call_loop        function        4.01   1.87         -54.0%       -53.3%  qjs
  dense_array_write_read   array           5.03   3.53         -27.7%       -29.8%  qjs
  array_map_callback       array           0.98   0.14         -83.6%       -85.4%  tie->zjs
  string_concat_loop       string         86.46   1.06         -98.4%       -98.8%  qjs
  map_string_keys          collection      3.12   0.36         -80.4%       -88.3%  qjs->zjs
  regexp_test_cached       regexp          0.56   0.06         -89.5%       -89.5%  zjs
