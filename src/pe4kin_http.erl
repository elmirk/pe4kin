%% @doc abstract API for HTTP client

-module(pe4kin_http).

-export([start_pool/0, stop_pool/0]).
-export([open/0, open/2, get/1, post/3]).

-type response() :: {non_neg_integer(), [{binary(), binary()}], iodata()}.
-type path() :: iodata().
-type req_headers() :: [{binary(), iodata()}].
-type disposition() ::
        {Disposition :: binary(), Params :: [{binary(), iodata()}]}.
-type multipart() ::
        {file, file:name_all(), disposition(), req_headers()} |
        {Name :: binary(), Payload :: binary(), disposition(), req_headers()} |
        {Name :: binary(), Payload :: binary()}.
-type req_body() :: binary() |
                    iodata() |
                    {form, #{binary() => binary()}} |
                    {json, pe4kin:json_value()} |
                    {multipart, multipart()}.

open() ->
  {ok, Endpoint} = pe4kin:get_env(api_server_endpoint),
  case pe4kin:get_env(api_proxy_server_endpoint) of
    undefined ->
      {ok, Opts} = pe4kin:get_env(api_server_conn_opts),
      open(Endpoint, Opts);
    {ok, ProxyEndpoint} ->
      {ok, Opts} = pe4kin:get_env(api_proxy_server_conn_opts),
      {ok, Pid} = open(ProxyEndpoint, Opts),
      %% TBD connect may fail and return for example {response,
      %% nofin,503, _Headers} and other Status codes
      {response, fin, 200, _} = connect(Endpoint, Pid),
      {ok, Pid}
  end.

open(Endpoint, Opts) ->
  {Transport, Host, Port} = parse_endpoint(Endpoint),
  {ok, Pid} = gun:open(Host, Port, Opts#{transport => Transport}),
  _Protocol = gun:await_up(Pid),
  {ok, Pid}.

connect(Endpoint, Pid) ->
  {Transport, Host, Port} = parse_endpoint(Endpoint),
  {ok, OrigOpts} = pe4kin:get_env(api_server_conn_opts),
  Opts = maps:merge(#{host => Host, port => Port, transport => Transport}, OrigOpts),
  Ref = gun:connect(Pid, Opts),
  gun:await(Pid, Ref).

-spec get(iodata()) -> response() | {error, any()}.
get(Path) ->
    with_conn(
      fun(C) ->
              await(C, gun:get(C, Path, [], #{reply_to => self()}))
      end).

-spec post(path(), req_headers(), req_body()) -> response() | {error, any()}.
post(Path, Headers, Body) when is_binary(Body);
                               is_list(Body) ->
    with_conn(
      fun(C) ->
              await(C, gun:post(C, Path, Headers, Body, #{reply_to => self()}))
      end);
post(Path, Headers, {form, KV}) ->
    post(Path, Headers, cow_qs:qs(maps:to_list(KV)));
post(Path, Headers, {json, Struct}) ->
    post(Path, Headers, jiffy:encode(Struct));
post(Path, Headers0, {multipart, Multipart}) ->
    with_conn(
      fun(C) ->
              Boundary = cow_multipart:boundary(),
              {value, {_, <<"multipart/form-data">>}, Headers1} =
                  lists:keytake(<<"content-type">>, 1, Headers0),
              Headers = [{<<"content-type">>,
                          [<<"multipart/form-data;boundary=">>, Boundary]}
                        | Headers1],
              Ref = gun:post(C, Path, Headers, <<>>, #{reply_to => self()}),
              multipart_stream(C, Ref, Boundary, Multipart),
              await(C, Ref)
      end).


await(C, Ref) ->
    case gun:await(C, Ref, pe4kin:get_env(http_timeout, 5000)) of
        {response, fin, Status, Headers} ->
            {Status, Headers, []};
        {response, nofin, Status, Headers} ->
            {ok, Body} = gun:await_body(C, Ref, pe4kin:get_env(http_timeout, 5000)),
            {Status, Headers, Body};
        {error, _} = Err ->
            Err
    end.

multipart_stream(C, Ref, Boundary, Multipart) ->
    ok = lists:foreach(
          fun({file, Path, Disposition, Hdrs0}) ->
                  {ok, Bin} = file:read_file(Path),
                  Hdrs = [{<<"content-disposition">>, encode_disposition(Disposition)}
                         | Hdrs0],
                  Chunk = cow_multipart:part(Boundary, Hdrs),
                  ok = gun:data(C, Ref, nofin, [Chunk, Bin]);
             ({_Name, Payload, Disposition, Hdrs0}) ->
                  Hdrs = [{<<"content-disposition">>, encode_disposition(Disposition)}
                         | Hdrs0],
                  Chunk = cow_multipart:part(Boundary, Hdrs),
                  ok = gun:data(C, Ref, nofin, [Chunk, Payload]);
             ({Name, Value}) ->
                  Hdrs = [{<<"content-disposition">>,
                           encode_disposition({<<"form-data">>,
                                               [{<<"name">>, Name}]})}],
                  Chunk = cow_multipart:part(Boundary, Hdrs),
                  ok = gun:data(C, Ref, nofin, [Chunk, Value])
          end, Multipart),
    Closing = cow_multipart:close(Boundary),
    ok = gun:data(C, Ref, fin, Closing).

encode_disposition({Disposition, Params}) ->
    [Disposition
     | [[";", K, "=\"", V, "\""] || {K, V} <- Params]].

%% Pool

start_pool() ->
    {ok, Opts} = pe4kin:get_env(keepalive_pool),
    PoolOpts = [{name, ?MODULE},
                {start_mfa, {pe4kin_gun_srv, start_link, []}}
               | Opts],
    {ok, _Pid} = pooler:new_pool(PoolOpts).

stop_pool() ->
    ok = pooler:rm_pool(?MODULE).

parse_endpoint(Uri) ->
    Parts = case Uri of
                <<"https://", Rest/binary>> ->
                    [tls | binary:split(Rest, <<":">>)];
                <<"http://", Rest/binary>> ->
                    [tcp | binary:split(Rest, <<":">>)]
            end,
    case Parts of
        [tls, Host] ->
            {tls, binary_to_list(Host), 443};
        [tcp, Host] ->
            {tcp, binary_to_list(Host), 80};
        [Transport, Host, Port] ->
            {Transport, binary_to_list(Host), binary_to_integer(Port)}
    end.


with_conn(Fun) ->
    C = pooler:take_member(?MODULE, {5, sec}),
    (C =/= error_no_members)
        orelse error(pool_overflow),
    Res =
        try Fun(pe4kin_gun_srv:get_gun_conn(C))
        catch Err:Reason:Stack ->
                pooler:return_member(?MODULE, C, fail),
                erlang:raise(Err, Reason, Stack)
        end,
    pooler:return_member(?MODULE, C, ok),
    Res.
