%% @private
-module(kafka_tests).

-include_lib("eunit/include/eunit.hrl").
-include("src/brod_int.hrl").
-include("src/kafka.hrl").

-define(PORT, 1234).

-define(i8(I),   I:8/integer).
-define(i16(I),  I:16/integer).
-define(i16s(I), I:16/signed-integer).
-define(i32(I),  I:32/integer).
-define(i32s(I), I:32/signed-integer).
-define(i64(I),  I:64/integer).
-define(i64s(I), I:64/signed-integer).

-define(l2b(L), erlang:list_to_binary(L)).

api_key_test() ->
  ?assertMatch(?API_KEY_METADATA, kafka:api_key(#metadata_request{})),
  ?assertMatch(?API_KEY_PRODUCE, kafka:api_key(#produce_request{})),
  ?assertMatch(?API_KEY_OFFSET, kafka:api_key(#offset_request{})),
  ?assertMatch(?API_KEY_FETCH, kafka:api_key(#fetch_request{})),
  ?assertError(function_clause, kafka:api_key(foo)),
  ok.

parse_stream_test() ->
  D0 = dict:new(),
  ?assertMatch({<<>>, [], D0}, kafka:parse_stream(<<>>, D0)),
  ?assertMatch({<<"foo">>, [], D0}, kafka:parse_stream(<<"foo">>, D0)),
  D1 = dict:store(1, ?API_KEY_METADATA, D0),
  ?assertMatch({<<"foo">>, [], D1}, kafka:parse_stream(<<"foo">>, D1)),
  ok.

encode_metadata_test() ->
  ?assertMatch(<<?i32(0), ?i16s(-1)>>, kafka:encode(#metadata_request{})),
  R = #metadata_request{topics = [<<"FOO">>, <<"BARR">>]},
  ?assertMatch(<<?i32(2), ?i16(4), "BARR", ?i16(3), "FOO">>, kafka:encode(R)),
  ok.

decode_metadata_test() ->
  %% array: 32b length (number of items), [item]
  %% metadata response: array of brokers, array of topics
  %% broker: 32b node id, 16b host size, host, 32b port
  %% topic: 16b error code, 16b name size, name, array of partitions
  %% partition: 16b error code, 32b partition, 32b leader,
  %%            array of replicas, array of in-sync-replicas
  %% replica: 32b node id
  %% isr: 32b node id
  Bin1 = <<?i32(0), ?i32(0)>>,
  ?assertMatch(#metadata_response{brokers = [], topics = []},
               kafka:decode(?API_KEY_METADATA, Bin1)),
  Host = "localhost",
  Brokers = [ #broker_metadata{node_id = 1, host = Host, port = ?PORT}
            , #broker_metadata{node_id = 0, host = Host, port = ?PORT}],
  BrokersBin = <<?i32(2),
                 ?i32(0), ?i16((length(Host))),
                 (?l2b(Host))/binary, ?i32(?PORT),
                 ?i32(1), ?i16((length(Host))),
                 (?l2b(Host))/binary, ?i32(?PORT)>>,
  Partitions = [ #partition_metadata{ error_code = 2
                                    , id = 1
                                    , leader_id = 2
                                    , replicas = []
                                    , isrs = []}
               , #partition_metadata{ error_code = 1
                                    , id = 0
                                    , leader_id = 1
                                    , replicas = [1,2,3]
                                    , isrs = [1,2]}],
  T1 = <<"t1">>,
  T2 = <<"t2">>,
  Topics = [ #topic_metadata{name = T2, error_code = -1,
                             partitions = Partitions}
           , #topic_metadata{name = T1, error_code = 0, partitions = []}],
  TopicsBin = <<?i32(2),
                ?i16s(0), ?i16((size(T1))), T1/binary, ?i32(0),
                ?i16s(-1), ?i16((size(T2))), T2/binary, ?i32(2),
                ?i16s(1), ?i32(0), ?i32s(1),
                ?i32(3), ?i32(3), ?i32(2), ?i32(1),
                ?i32(2), ?i32(2), ?i32(1),
                ?i16s(2), ?i32(1), ?i32s(2), ?i32(0), ?i32(0)
              >>,
  Bin2 = <<BrokersBin/binary, TopicsBin/binary>>,
  ?assertMatch(#metadata_response{brokers = Brokers, topics = Topics},
               kafka:decode(?API_KEY_METADATA, Bin2)),
  ok.

%% make it print full binaries on tty when a test fails
%% to simplify debugging
-undef(assertEqual).
-define(assertEqual(Expect, Expr),
  ((fun (__X) ->
      case (Expr) of
    __X -> ok;
    __V -> .erlang:error({assertEqual_failed,
              [{module, ?MODULE},
               {line, ?LINE},
               {expression, (??Expr)},
               {expected, lists:flatten(io_lib:format("~1000p", [__X]))},
               {value, lists:flatten(io_lib:format("~1000p", [__V]))}]})
      end
    end)(Expect))).

encode_produce_test() ->
  R1 = #produce_request{acks = -1, timeout = 1, data = []},
  ?assertMatch(<<?i16s(-1), ?i32(1), ?i32(0)>>, kafka:encode(R1)),
  T1 = <<"t1">>,
  T2 = <<"t2">>,
  T3 = <<"topic3">>,
  Data = [ {{T1, 0}, []}
         , {{T1, 1}, [{<<>>, <<>>}]}
         , {{T2, 0}, [{<<?i32(1)>>, <<?i32(2)>>}]}
         , {{T1, 2}, []}
         , {{T1, 2}, [{<<"foo">>, <<"bar">>}]}
         , {{T2, 0}, []}
         , {{T1, 1}, [{<<>>, <<>>}, {<<>>, <<?i16(3)>>}]}
         , {{T2, 0}, [{<<>>, <<"foobar">>}]}
         , {{T3, 0}, []}],
  R2 = #produce_request{acks = 0, timeout = 10, data = Data},
  Crc1 = erlang:crc32(<<?i8(?MAGIC_BYTE), ?i8(?COMPRESS_NONE),
                        ?i32s(-1), ?i32s(-1)>>),
  Crc2 = erlang:crc32(<<?i8(?MAGIC_BYTE), ?i8(?COMPRESS_NONE),
                        ?i32s(3), "foo", ?i32s(3), "bar">>),
  Crc3 = erlang:crc32(<<?i8(?MAGIC_BYTE), ?i8(?COMPRESS_NONE),
                        ?i32s(4), ?i32(1), ?i32s(4), ?i32(2)>>),
  Crc4 = erlang:crc32(<<?i8(?MAGIC_BYTE), ?i8(?COMPRESS_NONE),
                        ?i32s(-1), ?i32s(2), ?i16(3)>>),
  Crc5 = erlang:crc32(<<?i8(?MAGIC_BYTE), ?i8(?COMPRESS_NONE),
                        ?i32s(-1), ?i32s(6), "foobar">>),
  %% metadata: 16b acks, 32b timeout, 32b topics count, topics
  %% topic: 16b name size, name, 32b partitions count, partitions
  %% partition: 32b id, 32b msg set size, msg set
  %% message set: [message]
  %% message: 64b offset, 32b message size, CRC32,
  %%          8b magic byte, 8b compress mode,
  %%          32b key size, key, 32b value size, value
  ?assertEqual(<<?i16s(0), ?i32(10), ?i32(3),    % metadata
                 ?i16(2), T1/binary, ?i32(3),    % t1 start
                 ?i32(0), ?i32(0),               % p0 start/end
                 %% in kafka:group_by_topics/2 dict puts p2 before p0
                 ?i32(2), ?i32(32),              % p2 start
                                                 % message set start
                 ?i64(0), ?i32(20), ?i32(Crc2),  % msg1
                 ?i8(?MAGIC_BYTE), ?i8(?COMPRESS_NONE),
                 ?i32s(3), "foo", ?i32s(3), "bar",
                                                 % message set end
                                                 % p2 end
                 ?i32(1), ?i32(80),              % p1 start
                                                 % message set start
                 ?i64(0), ?i32(14), ?i32(Crc1),  % msg1
                 ?i8(?MAGIC_BYTE), ?i8(?COMPRESS_NONE),
                 ?i32s(-1), ?i32s(-1),
                 ?i64(0), ?i32(14), ?i32(Crc1),  % msg2
                 ?i8(?MAGIC_BYTE), ?i8(?COMPRESS_NONE),
                 ?i32s(-1), ?i32s(-1),
                 ?i64(0), ?i32(16), ?i32(Crc4),  % msg3
                 ?i8(?MAGIC_BYTE), ?i8(?COMPRESS_NONE),
                 ?i32s(-1), ?i32s(2), ?i16(3),
                                                 % message set end
                                                 % p1 end
                                                 % t1 end
                 ?i16(2), T2/binary, ?i32(1),    % t2 start
                 ?i32(0), ?i32(66),              % p0 start
                                                 % message set start
                 ?i64(0), ?i32(22), ?i32(Crc3),  % msg1
                 ?i8(?MAGIC_BYTE), ?i8(?COMPRESS_NONE),
                 ?i32s(4), ?i32(1), ?i32s(4), ?i32(2),
                 ?i64(0), ?i32(20), ?i32(Crc5),  % msg2
                 ?i8(?MAGIC_BYTE), ?i8(?COMPRESS_NONE),
                 ?i32s(-1), ?i32s(6), "foobar",
                                                 % message set end
                                                 % p0 end
                                                 % t2 end
                 ?i16(6), T3/binary, ?i32(1),    % t3 start
                 ?i32(0), ?i32(0),               % p0 start/end
                                                 % t3 end
                 <<>>/binary
               >>, kafka:encode(R2)),
  ok.

decode_produce_test() ->
  %% array: 32b length (number of items), [item]
  %% produce response: array of topics
  %% topic: 16b name size, name, array of offsets
  %% offset: 32b partition, 16b error code, 64b offset
  ?assertEqual(#produce_response{topics = []},
               kafka:decode(?API_KEY_PRODUCE, <<?i32(0)>>)),
  Topic1 = <<"t1">>,
  Offset1 = 2 bsl 63 - 1,
  ProduceOffset1 = #produce_offset{ partition = 0
                                  , error_code = -1
                                  , offset = Offset1},
  ProduceTopic1 = #produce_topic{ topic = Topic1
                                , offsets = [ProduceOffset1]},
  Bin1 = <<?i32(1), ?i16(2), Topic1/binary, ?i32(1),
           ?i32(0), ?i16s(-1), ?i64(Offset1)>>,
  ?assertEqual(#produce_response{topics = [ProduceTopic1]},
              kafka:decode(?API_KEY_PRODUCE, Bin1)),

  Topic2 = <<"t2">>,
  Topic3 = <<"t3">>,
  Offset2 = 0,
  Offset3 = 1,
  ProduceOffset2 = #produce_offset{ partition = 0
                                  , error_code = 1
                                  , offset = Offset2},
  ProduceOffset3 = #produce_offset{ partition = 2
                                  , error_code = 2
                                  , offset = Offset3},
  ProduceTopic2 = #produce_topic{ topic = Topic2
                                , offsets = [ ProduceOffset3
                                            , ProduceOffset2]},
  ProduceTopic3 = #produce_topic{ topic = Topic3
                                , offsets = []},
  Bin2 = <<?i32(2),
           ?i16(2), Topic2/binary, ?i32(2),
           ?i32(0), ?i16s(1), ?i64(Offset2),
           ?i32(2), ?i16s(2), ?i64(Offset3),
           ?i16(2), Topic3/binary, ?i32(0)
         >>,
  ?assertEqual(#produce_response{topics = [ProduceTopic3, ProduceTopic2]},
              kafka:decode(?API_KEY_PRODUCE, Bin2)),
  ok.

encode_offset_test() ->
  Topic = <<"topic">>,
  Partition = 0,
  Time1 = -1,
  MaxNOffsets = 1,
  R1 = #offset_request{ topic = Topic
                      , partition = Partition
                      , time = Time1
                      , max_n_offsets = MaxNOffsets},
  Bin1 = <<?i32s(?REPLICA_ID), ?i32(1), ?i16((size(Topic))), Topic/binary,
         ?i32(1), ?i32(Partition), ?i64s(Time1), ?i32(MaxNOffsets)>>,
  ?assertEqual(Bin1, kafka:encode(R1)),
  Time2 = 2 bsl 63 - 1,
  R2 = R1#offset_request{time = Time2},
  Bin2 = <<?i32s(?REPLICA_ID), ?i32(1), ?i16((size(Topic))), Topic/binary,
         ?i32(1), ?i32(Partition), ?i64s(Time2), ?i32(MaxNOffsets)>>,
  ?assertEqual(Bin2, kafka:encode(R2)),
  ok.

decode_offset_test() ->
  %% array: 32b length (number of items), [item]
  %% offset response: array of topics
  %% topic: 16b name size, name, array of partitions
  %% partition: 32b partition, 16b error code, array of offsets
  %% offset: 64b int
  ?assertEqual(#offset_response{topics = []},
               kafka:decode(?API_KEY_OFFSET, <<?i32(0)>>)),
  Topic = <<"t1">>,
  Partition = 0,
  ErrorCode = -1,
  Offsets = [0, 1, 2 bsl 63 - 1, 3],
  OffsetsBin = << << ?i64(X) >> || X <- lists:reverse(Offsets) >>,
  Partitions = [#partition_offsets{ partition = Partition
                                  , error_code = ErrorCode
                                  , offsets = Offsets}],
  R = #offset_response{topics = [#offset_topic{ topic = Topic
                                              , partitions = Partitions}]},
  Bin = <<?i32(1), ?i16((size(Topic))), Topic/binary, ?i32(1),
        ?i32(Partition), ?i16s(ErrorCode), ?i32((length(Offsets))),
        OffsetsBin/binary>>,
  ?assertEqual(R, kafka:decode(?API_KEY_OFFSET, Bin)),
  ok.

%%% Local Variables:
%%% erlang-indent-level: 2
%%% End:
