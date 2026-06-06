summary:
  old geomean: 0.8512
  new geomean: 0.8415
  delta:        -1.1%
  compatible:   73 -> 73
  unsupported:  0 -> 0
  skipped:      0 -> 0
  sample cfg:   iters=120, warmup=15 -> iters=120, warmup=15

regressions:
  case                     category        old    new    zjs avg delta  ratio delta  winner
  json_roundtrip           json            1.16   1.26         +15.9%        +8.3%  qjs
  prop_read                object          0.52   0.72         +47.8%       +38.0%  zjs
  array_read               array           0.43   0.54         +48.6%       +27.2%  zjs
  func_call                function        0.34   0.39         +61.8%       +13.8%  zjs
  date_now                 date            1.62   1.84         +50.2%       +13.9%  qjs
  prop_write               object          1.24   1.73        +112.6%       +39.3%  qjs
  prop_create              object          1.56   1.71         +65.4%        +9.5%  qjs
  prop_delete              object          1.89   1.36         +12.2%       -28.4%  qjs
  array_write              array           1.29   1.34         +31.2%        +3.8%  qjs
  array_prop_create        array           1.11   1.39         +35.6%       +25.2%  qjs
  array_length_decr        array           1.65   1.50         +60.3%        -9.2%  qjs
  array_hole_length_decr   array           1.59   1.45         +20.0%        -8.8%  qjs
  array_push               array           1.35   1.45         +45.2%        +7.5%  qjs
  array_pop                array           1.24   1.48         +57.5%       +19.0%  qjs
  typed_array_read         typedarray      1.55   1.40         +27.5%       -10.1%  qjs
  typed_array_write        typedarray      1.29   1.29         +53.6%        -0.1%  qjs
  global_read              global          0.52   0.89         +22.5%       +71.7%  zjs
  global_write             global          1.25   1.49         +35.4%       +19.2%  qjs
  global_destruct          destructuring   1.78   1.95         +14.1%        +9.2%  qjs
  global_destruct_strict   destructuring   1.42   1.57         +11.8%       +10.5%  qjs
  closure_var              function        1.84   1.66         +20.2%        -9.5%  qjs
  map_delete               collection      0.95   1.47         +59.9%       +54.2%  tie->qjs
  weak_map_set             collection      2.10   2.11         +11.6%        +0.3%  qjs
  weak_map_delete          collection      1.57   1.41         +29.5%       -10.3%  qjs
  array_for                array           0.45   0.66         +47.0%       +44.0%  zjs
  array_for_in             array           1.37   1.26         +39.5%        -7.9%  qjs
  array_for_of             array           1.27   1.42         +81.4%       +12.1%  qjs
  object_null              object          1.81   1.47         +33.4%       -18.6%  qjs
  regexp_ascii             regexp          1.84   1.52         +20.5%       -17.1%  qjs
  string_slice1            string          1.76   2.19         +12.4%       +24.4%  qjs
  string_slice3            string          1.39   1.62         +19.0%       +16.2%  qjs
  sort_bench               sort            1.59   1.54         +12.8%        -2.6%  qjs
  float_to_string          conversion      1.29   1.91         +18.7%       +47.4%  qjs
  float_toString           conversion      2.38   1.19         +23.1%       -49.8%  qjs
  float_toFixed            conversion      1.32   1.55         +37.7%       +17.6%  qjs
  float_toPrecision        conversion      1.22   1.32         +38.4%        +8.5%  qjs
  float_toExponential      conversion      1.05   1.18         +38.3%       +12.4%  qjs
  string_to_int            conversion      1.80   1.32         +24.3%       -26.5%  qjs
  string_to_float          conversion      1.38   1.31         +49.2%        -5.2%  qjs
  bigint64_arith           bigint          1.66   2.12         +10.9%       +28.0%  qjs
  prop_read_mono           object          0.05   0.04         +23.4%       -22.3%  zjs
  prop_read_poly3          object          0.04   0.04         +20.0%        -0.5%  zjs
  global_read_loop         global          0.05   0.07         +53.5%       +45.5%  zjs
  closure_call_loop        function        0.05   0.07         +47.8%       +37.8%  zjs
  dense_array_write_read   array           0.23   0.43         +28.6%       +90.3%  zjs
  string_concat_loop       string          0.56   0.64         +33.6%       +14.3%  zjs
  map_string_keys          collection      0.78   0.64         +20.7%       -17.8%  zjs
  bigint_short_sum         bigint          0.70   1.18         +16.5%       +69.3%  zjs->qjs

improvements:
  case                     category        old    new    zjs avg delta  ratio delta  winner
  uri_decode_4byte         uri             2.13   1.21         -28.0%       -43.0%  qjs
  uri_component_decode_4byte uri             1.99   1.00         -29.9%       -49.7%  qjs->tie
  float_arith              arithmetic      1.38   1.13         -10.3%       -18.1%  qjs
  map_set                  collection      1.54   1.55         -16.5%        +0.8%  qjs
  regexp_test_cached       regexp          0.06   0.03         -19.3%       -51.5%  zjs
