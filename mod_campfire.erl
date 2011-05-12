%% Author: sylvain niles
%% Created: Apr 29, 2011
%% Description: Establishes a connection to campfire, gets a list of rooms, then sets up streamng listeners to each room. 
-module(mod_campfire).

-behavior(gen_server).
-behavior(gen_mod).

%%
%% Include files
%%

-include("ejabberd.hrl").
-include("jlib.hrl").

-define(PROCNAME, campfire).
-define(TOKEN, "8bc13f0202886b5a8847a0dc3fbe65bf3d0903d7").

-record(room_tracker, {roomid, streamid, server, counter, roomname}).
-record(listener, {listenerpid, roomid}).
-record(idler, {roomid, idletime}).


%%
%% Exported Functions
%%

-export([start_link/2, cf_listener/3]).

-export([start/2,
         stop/1,
         init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

start_link(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:start_link({local, Proc}, ?MODULE, [Host, Opts], []).


start(Host, Opts) ->
       	?INFO_MSG("mod_campfire starting", []),
	Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    	ChildSpec = {Proc,
        {?MODULE, start_link, [Host, Opts]},
        temporary,
        1000,
        worker,
        [?MODULE]},
	mnesia:create_table(room_tracker, [{ram_copies, [node()]}, {type, set}, {attributes, record_info(fields, room_tracker)}, {index, [roomname]}]),
	mnesia:create_table(listener, [{ram_copies, [node()]}, {type, set}, {attributes, record_info(fields, listener)}]),
	mnesia:create_table(idler, [{ram_copies, [node()]}, {type, set}, {attributes, record_info(fields, idler)}]),
    	supervisor:start_child(ejabberd_sup, ChildSpec).

stop(Host) ->
       	?INFO_MSG("mod_campfire stopping", []),
    	Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    	gen_server:call(Proc, stop),
    	supervisor:terminate_child(ejabberd_sup, Proc),
    	supervisor:delete_child(ejabberd_sup, Proc).


init([Host, _Opts]) ->
	IBrowse = ibrowse:start(),
	process_flag(trap_exit, true),
        net_kernel:monitor_nodes(true),
	Rooms = cf_joinrooms(),
{ok, Host}.



handle_call(stop, _From, Host) ->
    {stop, normal, ok, Host}.

handle_cast(_Msg, Host) ->
    {noreply, Host}.

handle_info({reset_counter, RoomID}, State) ->
	F = fun() ->
		[{_, ORID, OSID, OSRV, Octr, OName}]  = mnesia:read(room_tracker, RoomID),
		mnesia:write(#room_tracker{roomid = RoomID, streamid = OSID, server = OSRV, counter = 0, roomname = OName})
	end,
	mnesia:transaction(F),
	{noreply, State};
	
handle_info({rejoin_room, RoomID}, State) ->
	join_cfroom(RoomID),
	{noreply, State};

handle_info({'EXIT', ListenerPid, _Reason}, State) ->
	ListenRec = mnesia:dirty_read(listener, ListenerPid),
	RoomID = lists:nth(3, tuple_to_list(lists:nth(1, ListenRec))),
	?INFO_MSG("Listener died, restarting.", []),
        cf_listener_start(RoomID),
        {noreply, State};

handle_info({ibrowse_async_response_end, EndPacket}, State) ->
	?INFO_MSG("async_response_end = ~p~n", [EndPacket]),
	{noreply, State};

handle_info({ibrowse_async_response, StreamID, {error,req_timedout}}, State) -> 
	%% TODO retry logic for connection
	?INFO_MSG("Timeout on listener ~p~n", []),
	MatchHead = #room_tracker{roomid='$1', streamid=StreamID, _='_', _='_', _='_'},
	Result = '$1',
	Restart = mnesia:dirty_select(room_tracker, [{MatchHead, [], [Result]}]),
	?INFO_MSG("Restarting listener for room ~p~n", [Restart]),
	{noreply, State};

handle_info({ibrowse_async_response, _StreamID, " "}, State) ->
	{noreply, State};

handle_info({ibrowse_async_response, _StreamID, {error, connection_closed}}, State) ->
	?INFO_MSG("Campfire connection closed.", []),
	{noreply, State};

%% Parse body of messages
handle_info({ibrowse_async_response, _StreamID, Msg}, State) ->
	MSGS = string:tokens(Msg, "\r"),
	lists:foreach(
		fun(Message) ->
			%MSG = re:replace(Message, "\r", "", [{return, list}]),
        		{struct, [{"room_id", RoomID}, _, {"body", Body}, _, _, _]} = mochijson:decode(Message),
			?INFO_MSG("Body = ~p~n", [Body]),
			case Body of
				null 	-> none;
				_	->
					process_macro(RoomID, Body, State)
			end
		end, MSGS),
	{noreply, State};

handle_info({nodedown, _Node}, State) ->
	[{room_tracker, _, _, Master, _, _}] = mnesia:dirty_read(room_tracker, mnesia:dirty_first(room_tracker)),
	case Master /= node() of
		true ->
			F = fun() ->
				mnesia:clear_table(room_tracker),
				mnesia:clear_table(listeners)
			end,
			mnesia:transaction(F),
			cf_joinrooms();
		false ->
		none
	end,
	?INFO_MSG("Node down.", []),
	{noreply, State};
		
handle_info(Info, State) ->
	?INFO_MSG("Unexpected info ~p", [Info]),
	{noreply, State}.



terminate(_Reason, _Host) ->
    ok.

code_change(_OldVsn, Host, _Extra) ->
    {ok, Host}.

%%
%% Local Functions
%%

cf_joinrooms() ->
	{ok, "200", NewHeaders, JRoomList} = ibrowse:send_req("https://cascadeo.campfirenow.com/rooms.json", [], get, [], [{basic_auth, {?TOKEN, "X"}}]),
	RoomList = mochijson:decode(JRoomList),
	?INFO_MSG("Got list of rooms: ~p~n", [RoomList]),
	{struct,[{"rooms", {array,RL}}]} = RoomList,
	lists:foreach(
		fun({struct, Room}) ->
			ID = lists:nth(5, Room),
			Na = lists:nth(1, Room),
			{"name", Nam} = Na,
			Name = re:replace(Nam, ["\""], "", [global, {return, list}]),
			{"id", IDV} = ID,
			RoomID = integer_to_list(IDV),
			case nodes() of
				[] ->
					join_cfroom(RoomID),
					cf_listener_start(RoomID, Name);
				_ -> none
			end
		end, RL).

join_cfroom(RoomID) ->
	U = "https://cascadeo.campfirenow.com/room/",
	UR = string:concat(U, RoomID),
	URL = string:concat(UR, "/speak.xml"),
	JURL = string:concat(UR, "/join.json"),
	Header = {"Content-Type", "application/xml"},
	JHeader = {"Content-Type", "application/json"},
	Join = ibrowse:send_req(JURL, [JHeader], post, [], [{basic_auth, {?TOKEN, "X"}}]),
	timer:send_after(900000, {rejoin_room, RoomID}).

cf_sendmessage(RoomID, Message) ->
        U = "https://cascadeo.campfirenow.com/room/",
        UR = string:concat(U, RoomID),
        URL = string:concat(UR, "/speak.xml"),
        Header = {"Content-Type", "application/xml"},
	Result = ibrowse:send_req(URL, [Header], post, [Message], [{basic_auth, {?TOKEN, "X"}}]).

cf_listener_start(RoomID) -> 
	C = mnesia:dirty_read(room_tracker, RoomID),
	Co = tuple_to_list(lists:nth(1, C)),
	[_, _, _, _, _, RoomName] = Co,
	cf_listener_start(RoomID, RoomName).

cf_listener_start(RoomID, Name) ->
	?INFO_MSG("Launching listener for room ~p~n", [Name]),
	ListenerPid = spawn_link(?MODULE, cf_listener, [RoomID, self(), Name]),
	?INFO_MSG("ListenerPID = ~p~n", [ListenerPid]),
	mnesia:dirty_write(#idler{roomid = RoomID, idletime = now()}),
	mnesia:dirty_write(#listener{listenerpid = ListenerPid, roomid = RoomID}).

cf_listener(RoomID, Parent, Name) ->
	U = "https://streaming.campfirenow.com/room/",
	UR = string:concat(U, RoomID),
	URL = string:concat(UR, "/live.json"),
	Header = {"Content-Type", "application/json"},
	{ibrowse_req_id, StreamID} = ibrowse:send_req(URL, [Header], get, [], [{basic_auth, {?TOKEN, "X"}}, {stream_to, {Parent, once}}], infinity),
	?INFO_MSG("Listener StreamID = ~p~n", [StreamID]),
	?INFO_MSG("Recording listener PID in DB for room ~p~n", [Name]),
	mnesia:dirty_write(#room_tracker{roomid = RoomID, streamid = StreamID, server = node(), counter = 0, roomname = Name}),
	listen_loop(StreamID).

listen_loop(StreamID) ->
	timer:sleep(1000),
	ibrowse:stream_next(StreamID),
	listen_loop(StreamID).
	

cf_create_message(Msg) ->
	Pre = "<message><type>TextMessage</type><body>",
	Post = "</body></message>",
	Mess = string:concat(Pre, Msg),
	Message = string:concat(Mess, Post),
	?INFO_MSG("CF Message = ~p~n", [Message]),
	Message.

cf_create_message(Msg, Type) ->
	Pre = "<message><type>",
	PT = string:concat(Pre, Type),
	PTY = string:concat(PT, "</type><body>"),
	Mess = string:concat(PTY, Msg),
	Post = "</body></message>",
        Message = string:concat(Mess, Post),
        ?INFO_MSG("CF Message = ~p~n", [Message]),
        Message.

cf_usage() ->
	Usage = "Welcome to the Cascadeo OSS, you may call me COSS.

Available macros:

[ACTIVE]

SMS:
-------- 
.sms [username] descriptive text

Example:
.sms [jared] your pants are on fire

[EXAMPLES]

Zendesk
------------
.zd [create|update, client=clientname, assignee=username, priority=low|normal|high|urgent|emergency, subject=\"descriptive text here\"] As much detail as you'd like here.

Example:
.zd [create, client=mte, assignee=ophir, priority=urgent,subject=\"discuss NOC checklist\"] need a gdoc form that dumps to a chklist.

Reports:
------------
.report [dept|client, hours|budget, date range]

Example:
.report [noc, hours, 1/1/10-2/1/10]",
	Usage.

process_macro(RID, Body, State) ->
	RoomID = integer_to_list(RID),
	case parse_macro(Body) of
		".help" ->
             		cf_sendmessage(RoomID, cf_create_message(cf_usage(), "PasteMessage"));
              	".sms"  ->
		% Test for Args
		case string:chr(Body, $[) of
			0 -> none;
			_ ->
                	User = parse_args(Body),
                       	SmsMsg = parse_body(Body),
                       	mod_sms:send_sms(User, SmsMsg),
                       	cf_sendmessage(RoomID, cf_create_message(string:concat("SMS sent to ", User)))
			end;
       		_       ->
		% traffic cop does his thing
		C = mnesia:dirty_read(room_tracker, RoomID),
		Co = tuple_to_list(lists:nth(1, C)),
		[_, _, _, _, Counter, RoomName] = Co,
		IT = mnesia:dirty_read(idler, RoomID),
		?INFO_MSG("IT = ~p~n", [IT]),
		IdT = tuple_to_list(lists:nth(1, IT)),
		[_, _, {_, IdleTime, _}] = IdT,
		{_, Now, _} = now(),
		Diff = Now - IdleTime,
		% If ten minutes have passed since last activity in the room, notify the Operations room.
		case Diff > 600 of
			true ->
				case Counter of 
                			0 -> 	F = fun() ->
					[{_, ORID, OSID, OSRV, Octr, OName}]  = mnesia:read(room_tracker, RoomID),
					mnesia:write(#room_tracker{roomid = RoomID, streamid = OSID, server = OSRV, counter = 1, roomname = OName})
					end,
					mnesia:transaction(F),
					% send cop message
					% change "Operations to whatever room you'd like the notifications in."
					O = mnesia:dirty_index_read(room_tracker, "Operations", roomname),
					Op = tuple_to_list(lists:nth(1, O)),
					[_, OpsRoom, _, _, _, _] = Op,
					% Ignore the opsroom
					case RoomID /= OpsRoom of
						true -> 
							cf_sendmessage(OpsRoom, cf_create_message(string:concat(string:concat("Activity observed in the ", RoomName), " room, someone there needs assistance."))),
							timer:send_after(60000, {reset_counter, RoomID});
						false -> none
					end;
						_ -> 	none
				end,
				mnesia:dirty_write(#idler{roomid = RoomID, idletime = now()});
			false ->
               			{noreply, State}
		end
end.


parse_macro(Body) ->
	Macro = lists:nth(1, string:tokens(Body, " ")),
	?INFO_MSG("Macro = ~p~n", [Macro]),
	Macro.

parse_args(Body) ->
	M = string:tokens(Body, "["),
	MS = string:tokens(lists:nth(2, M), "]"),
	Args = lists:nth(2, [lists:nth(1, M) |MS]),
	?INFO_MSG("Args = ~p~n", [Args]),
	Args.
	
parse_body(Body) ->
	M = string:tokens(Body, "["),
	MS = string:tokens(lists:nth(2, M), "]"),
	MSG = string:strip(lists:nth(3, [lists:nth(1, M) |MS]), left),
	?INFO_MSG("SMS Msg = ~p~n", [MSG]),
	MSG.
