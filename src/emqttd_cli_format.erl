-module (emqttd_cli_format).

-behavior(clique_writer).

%% API
-export([write/1]).

write([{text, Text}]) ->
    Json = jsx:encode([{text, any2b(lists:flatten(Text))}]),
    {io_lib:format("~p~n", [Json]), []};

write([{table, Table}]) ->
    Json = jsx:encode(format_table(Table, [])),
    {io_lib:format("~p~n", [Json]), []};

write([{list, Key, [Value]}| Tail]) ->
    Table = lists:reverse(write(Tail, [{Key, any2b(Value)}])),
    Json = jsx:encode(Table),
    {io_lib:format("~p~n", [Json]), []};

write(_) ->
    {io_lib:format("error~n", []), []}.

write([], Acc) ->
    Acc;
write([{list, Key, [Value]}| Tail], Acc) ->
    write(Tail, [{Key, any2b(Value)}| Acc]).

format_table([], Acc) ->
    lists:reverse(Acc);
format_table([Head| Tail], Acc) when is_list(Head) ->
    format_table(Tail, [format_table(Head, [])|Acc]);
format_table([{Key, V}| Tail], Acc) ->
    format_table(Tail, [{Key, any2b(V)}| Acc]).

any2b(A) when is_atom(A)    -> list_to_binary(atom_to_list(A));
any2b(L) when is_list(L)    -> iolist_to_binary(L);
any2b(I) when is_integer(I) -> I;
any2b(F) when is_float(F)   -> F;
any2b(B) when is_binary(B)  -> B.