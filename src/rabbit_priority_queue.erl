%%  The contents of this file are subject to the Mozilla Public License
%%  Version 1.1 (the "License"); you may not use this file except in
%%  compliance with the License. You may obtain a copy of the License
%%  at http://www.mozilla.org/MPL/
%%
%%  Software distributed under the License is distributed on an "AS IS"
%%  basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%%  the License for the specific language governing rights and
%%  limitations under the License.
%%
%%  The Original Code is RabbitMQ.
%%
%%  The Initial Developer of the Original Code is GoPivotal, Inc.
%%  Copyright (c) 2014 GoPivotal, Inc.  All rights reserved.
%%

-module(rabbit_priority_queue).

-include_lib("rabbit_common/include/rabbit.hrl").
-include_lib("rabbit_common/include/rabbit_framing.hrl").
-behaviour(rabbit_backing_queue).

-rabbit_boot_step({?MODULE,
                   [{description, "enable priority queue"},
                    {mfa,         {?MODULE, enable, []}},
                    {requires,    pre_boot},
                    {enables,     kernel_ready}]}).

-export([enable/0]).

-export([start/1, stop/0]).

-export([init/3, terminate/2, delete_and_terminate/2, purge/1, purge_acks/1,
         publish/5, publish_delivered/4, discard/3, drain_confirmed/1,
         dropwhile/2, fetchwhile/4, fetch/2, drop/2, ack/2, requeue/2,
         ackfold/4, fold/3, len/1, is_empty/1, depth/1,
         set_ram_duration_target/2, ram_duration/1, needs_timeout/1, timeout/1,
         handle_pre_hibernate/1, resume/1, msg_rates/1,
         status/1, invoke/3, is_duplicate/2]).

-record(state, {bq, bqss}).
-record(passthrough, {bq, bqs}).

%% See 'note on suffixes' below
-define(passthrough1(F), State#passthrough{bqs = BQ:F}).
-define(passthrough2(F),
        {Res, BQS1} = BQ:F, {Res, State#passthrough{bqs = BQS1}}).
-define(passthrough3(F),
        {Res1, Res2, BQS1} = BQ:F, {Res1, Res2, State#passthrough{bqs = BQS1}}).

enable() ->
    {ok, RealBQ} = application:get_env(rabbit, backing_queue_module),
    case RealBQ of
        ?MODULE -> ok;
        _       -> application:set_env(
                     rabbitmq_priority_queue, backing_queue_module, RealBQ),
                   application:set_env(rabbit, backing_queue_module, ?MODULE)
    end.

%%----------------------------------------------------------------------------

start(QNames) ->
    BQ = bq(),
    %% TODO this expand-collapse dance is a bit ridiculous but it's what
    %% rabbit_amqqueue:recover/0 expects. We could probably simplify
    %% this if we rejigged recovery a bit.
    {DupNames, ExpNames} = expand_queues(QNames),
    case BQ:start(ExpNames) of
        {ok, ExpRecovery} ->
            {ok, collapse_recovery(QNames, DupNames, ExpRecovery)};
        Else ->
            Else
    end.

stop() ->
    BQ = bq(),
    BQ:stop().

%%----------------------------------------------------------------------------

mutate_name(P, Q = #amqqueue{name = QName = #resource{name = QNameBin}}) ->
    Q#amqqueue{name = QName#resource{name = mutate_name_bin(P, QNameBin)}}.

mutate_name_bin(P, NameBin) -> <<NameBin/binary, 0, P:8>>.

expand_queues(QNames) ->
    lists:unzip(
      lists:append([expand_queue(QName) || QName <- QNames])).

expand_queue(QName = #resource{name = QNameBin}) ->
    {ok, Q} = rabbit_misc:dirty_read({rabbit_durable_queue, QName}),
    case priorities(Q) of
        none -> [{QName, QName}];
        Ps   -> [{QName, QName#resource{name = mutate_name_bin(P, QNameBin)}}
                   || P <- Ps]
    end.

collapse_recovery(QNames, DupNames, Recovery) ->
    NameToTerms = lists:foldl(fun({Name, RecTerm}, Dict) ->
                                      dict:append(Name, RecTerm, Dict)
                              end, dict:new(), lists:zip(DupNames, Recovery)),
    [dict:fetch(Name, NameToTerms) || Name <- QNames].

priorities(#amqqueue{arguments = Args}) ->
    Ints = [long, short, signedint, byte],
    case rabbit_misc:table_lookup(Args, <<"x-priorities">>) of
        {array, Array} -> case lists:usort([N || {T, N} <- Array,
                                                 lists:member(T, Ints)]) of
                              [] -> none;
                              Ps -> Ps
                          end;
        _              -> none
    end.

%%----------------------------------------------------------------------------

init(Q, Recover, AsyncCallback) ->
    BQ = bq(),
    case priorities(Q) of
        none -> #passthrough{bq  = BQ,
                             bqs = BQ:init(Q, Recover, AsyncCallback)};
        Ps   -> Init = fun (P, Term) ->
                               BQ:init(
                                 mutate_name(P, Q), Term,
                                 fun (M, F) -> AsyncCallback(M, {P, F}) end)
                       end,
                BQSs = case Recover of
                           new -> [{P, Init(P, new)} || P <- Ps];
                           _   -> PsTerms = lists:zip(Ps, Recover),
                                  [{P, Init(P, Term)} || {P, Term} <- PsTerms]
                       end,
                #state{bq   = BQ,
                       bqss = BQSs}
    end.

terminate(Reason, State = #state{bq = BQ}) ->
    foreach1(fun (_P, BQSN) -> BQ:terminate(Reason, BQSN) end, State);
terminate(Reason, State = #passthrough{bq = BQ, bqs = BQS}) ->
    ?passthrough1(terminate(Reason, BQS)).

delete_and_terminate(Reason, State = #state{bq = BQ}) ->
    foreach1(fun (_P, BQSN) ->
                     BQ:delete_and_terminate(Reason, BQSN)
             end, State);
delete_and_terminate(Reason, State = #passthrough{bq = BQ, bqs = BQS}) ->
    ?passthrough1(delete_and_terminate(Reason, BQS)).

purge(State = #state{bq = BQ}) ->
    fold_add2(fun (_P, BQSN) -> BQ:purge(BQSN) end, State);
purge(State = #passthrough{bq = BQ, bqs = BQS}) ->
    ?passthrough2(purge(BQS)).

purge_acks(State = #state{bq = BQ}) ->
    foreach1(fun (_P, BQSN) -> BQ:purge_acks(BQSN) end, State);
purge_acks(State = #passthrough{bq = BQ, bqs = BQS}) ->
    ?passthrough1(purge_acks(BQS)).

publish(Msg, MsgProps, IsDelivered, ChPid, State = #state{bq = BQ}) ->
    pick1(fun (_P, BQSN) ->
                  BQ:publish(Msg, MsgProps, IsDelivered, ChPid, BQSN)
          end, Msg, State);
publish(Msg, MsgProps, IsDelivered, ChPid,
        State = #passthrough{bq = BQ, bqs = BQS}) ->
    ?passthrough1(publish(Msg, MsgProps, IsDelivered, ChPid, BQS)).

publish_delivered(Msg, MsgProps, ChPid, State = #state{bq = BQ}) ->
    pick2(fun (P, BQSN) ->
                  {AckTag, BQSN1} = BQ:publish_delivered(
                                      Msg, MsgProps, ChPid, BQSN),
                  {{P, AckTag}, BQSN1}
          end, Msg, State);
publish_delivered(Msg, MsgProps, ChPid,
                  State = #passthrough{bq = BQ, bqs = BQS}) ->
    ?passthrough2(publish_delivered(Msg, MsgProps, ChPid, BQS)).

%% TODO this is a hack. The BQ api does not give us enough information
%% here - if we had the Msg we could look at its priority and forward
%% to the appropriate sub-BQ. But we don't so we are stuck.
%%
%% But fortunately VQ ignores discard/3, so we can too, *assuming we
%% are talking to VQ*. discard/3 is used by HA, but that's "above" us
%% (if in use) so we don't break that either, just some hypothetical
%% alternate BQ implementation.
discard(_MsgId, _ChPid, State = #state{}) ->
    State;
    %% We should have something a bit like this here:
    %% pick1(fun (_P, BQSN) ->
    %%               BQ:discard(MsgId, ChPid, BQSN)
    %%       end, Msg, State);
discard(MsgId, ChPid, State = #passthrough{bq = BQ, bqs = BQS}) ->
    ?passthrough1(discard(MsgId, ChPid, BQS)).

drain_confirmed(State = #state{bq = BQ}) ->
    fold_append2(fun (_P, BQSN) -> BQ:drain_confirmed(BQSN) end, State);
drain_confirmed(State = #passthrough{bq = BQ, bqs = BQS}) ->
    ?passthrough2(drain_confirmed(BQS)).

dropwhile(Pred, State = #state{bq = BQ}) ->
    find2(fun (_P, BQSN) -> BQ:dropwhile(Pred, BQSN) end, undefined, State);
dropwhile(Pred, State = #passthrough{bq = BQ, bqs = BQS}) ->
    ?passthrough2(dropwhile(Pred, BQS)).

%% TODO this is a bit nasty. In the one place where fetchwhile/4 is
%% actually used the accumulator is a list of acktags, which of course
%% we need to mutate - so we do that although we are encoding an
%% assumption here.
fetchwhile(Pred, Fun, Acc, State = #state{bq = BQ}) ->
    findfold3(
      fun (P, BQSN, AccN) ->
              {Res, AccN1, BQSN1} = BQ:fetchwhile(Pred, Fun, AccN, BQSN),
              {Res, [case Tag of
                         _ when is_integer(Tag) -> {P, Tag};
                         _                      -> Tag
                     end || Tag <- AccN1], BQSN1}
      end, Acc, undefined, State);
fetchwhile(Pred, Fun, Acc, State = #passthrough{bq = BQ, bqs = BQS}) ->
    ?passthrough3(fetchwhile(Pred, Fun, Acc, BQS)).

fetch(AckRequired, State = #state{bq = BQ}) ->
    find2(
      fun (P, BQSN) ->
              case BQ:fetch(AckRequired, BQSN) of
                  {empty,            BQSN1} -> {empty, BQSN1};
                  {{Msg, Del, ATag}, BQSN1} -> {{Msg, Del, {P, ATag}}, BQSN1}
              end
      end, empty, State);
fetch(AckRequired, State = #passthrough{bq = BQ, bqs = BQS}) ->
    ?passthrough2(fetch(AckRequired, BQS)).

drop(AckRequired, State = #state{bq = BQ}) ->
    find2(fun (P, BQSN) ->
                  case BQ:drop(AckRequired, BQSN) of
                      {empty,           BQSN1} -> {empty, BQSN1};
                      {{MsgId, AckTag}, BQSN1} -> {{MsgId, {P, AckTag}}, BQSN1}
                  end
          end, empty, State);
drop(AckRequired, State = #passthrough{bq = BQ, bqs = BQS}) ->
    ?passthrough2(drop(AckRequired, BQS)).

ack(AckTags, State = #state{bq = BQ}) ->
    fold_by_acktags2(fun (AckTagsN, BQSN) ->
                             BQ:ack(AckTagsN, BQSN)
                     end, AckTags, State);
ack(AckTags, State = #passthrough{bq = BQ, bqs = BQS}) ->
    ?passthrough2(ack(AckTags, BQS)).

requeue(AckTags, State = #state{bq = BQ}) ->
    fold_by_acktags2(fun (AckTagsN, BQSN) ->
                             BQ:requeue(AckTagsN, BQSN)
                     end, AckTags, State);
requeue(AckTags, State = #passthrough{bq = BQ, bqs = BQS}) ->
    ?passthrough2(requeue(AckTags, BQS)).

ackfold(MsgFun, Acc, State = #state{bq = BQ}, AckTags) ->
    AckTagsByPriority = partition_acktags(AckTags),
    fold2(
      fun (P, BQSN, AccN) ->
              case orddict:find(P, AckTagsByPriority) of
                  {ok, AckTagsN} -> BQ:ackfold(MsgFun, AccN, BQSN, AckTagsN);
                  error          -> {AccN, BQSN}
              end
      end, Acc, State);
ackfold(MsgFun, Acc, State = #passthrough{bq = BQ, bqs = BQS}, AckTags) ->
    ?passthrough2(ackfold(MsgFun, Acc, BQS, AckTags)).

fold(Fun, Acc, State = #state{bq = BQ}) ->
    fold2(fun (_P, BQSN, AccN) -> BQ:fold(Fun, AccN, BQSN) end, Acc, State);
fold(Fun, Acc, State = #passthrough{bq = BQ, bqs = BQS}) ->
    ?passthrough2(fold(Fun, Acc, BQS)).

len(#state{bq = BQ, bqss = BQSs}) ->
    add0(fun (_P, BQSN) -> BQ:len(BQSN) end, BQSs);
len(#passthrough{bq = BQ, bqs = BQS}) ->
    BQ:len(BQS).

is_empty(#state{bq = BQ, bqss = BQSs}) ->
    all0(fun (_P, BQSN) -> BQ:is_empty(BQSN) end, BQSs);
is_empty(#passthrough{bq = BQ, bqs = BQS}) ->
    BQ:is_empty(BQS).

depth(#state{bq = BQ, bqss = BQSs}) ->
    add0(fun (_P, BQSN) -> BQ:depth(BQSN) end, BQSs);
depth(#passthrough{bq = BQ, bqs = BQS}) ->
    BQ:depth(BQS).

set_ram_duration_target(DurationTarget, State = #state{bq = BQ}) ->
    foreach1(fun (_P, BQSN) ->
                     BQ:set_ram_duration_target(DurationTarget, BQSN)
             end, State);
set_ram_duration_target(DurationTarget,
                        State = #passthrough{bq = BQ, bqs = BQS}) ->
    ?passthrough1(set_ram_duration_target(DurationTarget, BQS)).

ram_duration(State = #state{bq = BQ}) ->
    fold_add2(fun (_P, BQSN) -> BQ:ram_duration(BQSN) end, State);
ram_duration(State = #passthrough{bq = BQ, bqs = BQS}) ->
    ?passthrough2(ram_duration(BQS)).

needs_timeout(#state{bq = BQ, bqss = BQSs}) ->
    fold0(fun (_P, _BQSN, timed) -> timed;
              (_P, BQSN,  idle)  -> case BQ:needs_timeout(BQSN) of
                                        timed -> timed;
                                        _     -> idle
                                    end;
              (_P, BQSN,  false) -> BQ:needs_timeout(BQSN)
          end, false, BQSs);
needs_timeout(#passthrough{bq = BQ, bqs = BQS}) ->
    BQ:needs_timeout(BQS).

timeout(State = #state{bq = BQ}) ->
    foreach1(fun (_P, BQSN) -> BQ:timeout(BQSN) end, State);
timeout(State = #passthrough{bq = BQ, bqs = BQS}) ->
    ?passthrough1(timeout(BQS)).

handle_pre_hibernate(State = #state{bq = BQ}) ->
    foreach1(fun (_P, BQSN) ->
                  BQ:handle_pre_hibernate(BQSN)
          end, State);
handle_pre_hibernate(State = #passthrough{bq = BQ, bqs = BQS}) ->
    ?passthrough1(handle_pre_hibernate(BQS)).

resume(State = #state{bq = BQ}) ->
    foreach1(fun (_P, BQSN) -> BQ:resume(BQSN) end, State);
resume(State = #passthrough{bq = BQ, bqs = BQS}) ->
    ?passthrough1(resume(BQS)).

msg_rates(#state{bq = BQ, bqss = BQSs}) ->
    fold0(fun(_P, BQSN, {InN, OutN}) ->
                  {In, Out} = BQ:msg_rates(BQSN),
                  {InN + In, OutN + Out}
          end, {0.0, 0.0}, BQSs);
msg_rates(#passthrough{bq = BQ, bqs = BQS}) ->
    BQ:msg_rates(BQS).

status(#state{bq = BQ, bqss = BQSs}) ->
    [[{priority, P},
      {status,   BQ:status(BQSN)}] || {P, BQSN} <- BQSs];
status(#passthrough{bq = BQ, bqs = BQS}) ->
    BQ:status(BQS).

invoke(Mod, {P, Fun}, State = #state{bq = BQ}) ->
    pick1(fun (_P, BQSN) -> BQ:invoke(Mod, Fun, BQSN) end, P, State);
invoke(Mod, Fun, State = #passthrough{bq = BQ, bqs = BQS}) ->
    ?passthrough1(invoke(Mod, Fun, BQS)).

is_duplicate(Msg, State = #state{bq = BQ}) ->
    pick2(fun (_P, BQSN) -> BQ:is_duplicate(Msg, BQSN) end, Msg, State);
is_duplicate(Msg, State = #passthrough{bq = BQ, bqs = BQS}) ->
    ?passthrough2(is_duplicate(Msg, BQS)).

%%----------------------------------------------------------------------------

bq() ->
    {ok, RealBQ} = application:get_env(
                     rabbitmq_priority_queue, backing_queue_module),
    RealBQ.

%% Note on suffixes: Many utility functions here have suffixes telling
%% you the arity of the return type of the BQ function they are
%% designed to work with.
%%
%% 0 - BQ function returns a value and does not modify state
%% 1 - BQ function just returns a new state
%% 2 - BQ function returns a 2-tuple of {Result, NewState}
%% 3 - BQ function returns a 3-tuple of {Result1, Result2, NewState}

%% Fold over results
fold0(Fun,  Acc, [{P, BQSN} | Rest]) -> fold0(Fun, Fun(P, BQSN, Acc), Rest);
fold0(_Fun, Acc, [])                 -> Acc.

%% Do all BQs match?
all0(Pred, BQSs) -> fold0(fun (_P, _BQSN, false) -> false;
                              (P,  BQSN,  true)  -> Pred(P, BQSN)
                          end, true, BQSs).

%% Sum results
add0(Fun, BQSs) -> fold0(fun (P, BQSN, Acc) -> Acc + Fun(P, BQSN) end, 0, BQSs).

%% Apply for all states
foreach1(Fun, State = #state{bqss = BQSs}) ->
    State#state{bqss = foreach1(Fun, BQSs, [])}.
foreach1(Fun, [{P, BQSN} | Rest], BQSAcc) ->
    BQSN1 = Fun(P, BQSN),
    foreach1(Fun, Rest, [{P, BQSN1} | BQSAcc]);
foreach1(_Fun, [], BQSAcc) ->
    lists:reverse(BQSAcc).

%% For a given thing, just go to its BQ
pick1(Fun, Prioritisable, #state{bqss = BQSs} = State) ->
    {P, BQSN} = priority(Prioritisable, BQSs),
    State#state{bqss = orddict:store(P, Fun(P, BQSN), BQSs)}.

%% Fold over results
fold2(Fun, Acc, State = #state{bqss = BQSs}) ->
    {Res, BQSs1} = fold2(Fun, Acc, BQSs, []),
    {Res, State#state{bqss = BQSs1}}.
fold2(Fun, Acc, [{P, BQSN} | Rest], BQSAcc) ->
    {Acc1, BQSN1} = Fun(P, BQSN, Acc),
    fold2(Fun, Acc1, Rest, [{P, BQSN1} | BQSAcc]);
fold2(_Fun, Acc, [], BQSAcc) ->
    {Acc, lists:reverse(BQSAcc)}.

%% Fold over results assuming results are lists and we want to append them
fold_append2(Fun, State) ->
    fold2(fun (P, BQSN, Acc) ->
                  {Res, BQSN1} = Fun(P, BQSN),
                  {Res ++ Acc, BQSN1}
          end, [], State).

%% Fold over results assuming results are numbers and we want to sum them
fold_add2(Fun, State) ->
    fold2(fun (P, BQSN, Acc) ->
                  {Res, BQSN1} = Fun(P, BQSN),
                  {add_maybe_infinity(Res, Acc), BQSN1}
          end, 0, State).

%% Fold over results assuming results are lists and we want to append
%% them, and also that we have some AckTags we want to pass in to each
%% invocation.
fold_by_acktags2(Fun, AckTags, State) ->
    AckTagsByPriority = partition_acktags(AckTags),
    fold_append2(fun (P, BQSN) ->
                         case orddict:find(P, AckTagsByPriority) of
                             {ok, AckTagsN} -> Fun(AckTagsN, BQSN);
                             error          -> {[], BQSN}
                         end
                 end, State).

%% For a given thing, just go to its BQ
pick2(Fun, Prioritisable, #state{bqss = BQSs} = State) ->
    {P, BQSN} = priority(Prioritisable, BQSs),
    {Res, BQSN1} = Fun(P, BQSN),
    {Res, State#state{bqss = orddict:store(P, BQSN1, BQSs)}}.

%% Run through BQs in priority order until one does not return
%% {NotFound, NewState} or we have gone through them all.
find2(Fun, NotFound, State = #state{bqss = BQSs}) ->
    {Res, BQSs1} = find2(Fun, NotFound, BQSs, []),
    {Res, State#state{bqss = BQSs1}}.
find2(Fun, NotFound, [{P, BQSN} | Rest], BQSAcc) ->
    case Fun(P, BQSN) of
        {NotFound, BQSN1} -> find2(Fun, NotFound, Rest, [{P, BQSN1} | BQSAcc]);
        {Res, BQSN1}      -> {Res, lists:reverse([{P, BQSN1} | BQSAcc]) ++ Rest}
    end;
find2(_Fun, NotFound, [], BQSAcc) ->
    {NotFound, lists:reverse(BQSAcc)}.

%% Run through BQs in priority order like find2 but also folding as we go.
findfold3(Fun, Acc, NotFound, State = #state{bqss = BQSs}) ->
    {Res, Acc1, BQSs1} = findfold3(Fun, Acc, NotFound, BQSs, []),
    {Res, Acc1, State#state{bqss = BQSs1}}.
findfold3(Fun, Acc, NotFound, [{P, BQSN} | Rest], BQSAcc) ->
    case Fun(P, BQSN, Acc) of
        {NotFound, Acc1, BQSN1} ->
            findfold3(Fun, Acc1, NotFound, Rest, [{P, BQSN1} | BQSAcc]);
        {Res, Acc1, BQSN1} ->
            {Res, Acc1, lists:reverse([{P, BQSN1} | BQSAcc]) ++ Rest}
    end;
findfold3(_Fun, Acc, NotFound, [], BQSAcc) ->
    {NotFound, Acc, lists:reverse(BQSAcc)}.

%%----------------------------------------------------------------------------

priority(P, BQSs) when is_integer(P) ->
    {P, orddict:fetch(P, BQSs)};
priority(_Msg, [{P, BQSN}]) ->
    {P, BQSN};
priority(Msg = #basic_message{content = #content{properties = Props}},
         [{P, BQSN} | Rest]) ->
    #'P_basic'{priority = Priority} = Props,
    case Priority =< P of
        true  -> {P, BQSN};
        false -> priority(Msg, Rest)
    end.

add_maybe_infinity(infinity, _) -> infinity;
add_maybe_infinity(_, infinity) -> infinity;
add_maybe_infinity(A, B)        -> A + B.

partition_acktags(AckTags) -> partition_acktags(AckTags, orddict:new()).

partition_acktags([], Partitioned) ->
    Partitioned;
partition_acktags([{P, AckTag} | Rest], Partitioned) ->
    partition_acktags(Rest, orddict:append(P, AckTag, Partitioned)).

