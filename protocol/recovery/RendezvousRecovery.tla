------------------------ MODULE RendezvousRecovery ------------------------
EXTENDS Naturals, FiniteSets

(* Composition work in progress. Unlike OfferAnswer, this model has explicit
   independent brokers, leases, request/response lifetimes, process incarnations,
   Lamport clocks, buffered remote credentials/candidates, and auth changes.

   Bounded=TRUE checks safety of finite prefixes only. Its step/clock/attempt
   limits are NOT used to claim liveness. Bounded=FALSE leaves clocks unbounded
   and removes the step limit; RecoverySpec/EventuallyConnected are specified
   below, but have not been exhaustively checked or proved.

   Candidate payloads are a Boolean witness for one valid direct candidate per
   auth. Go channel/lock and ICE internals are abstracted; CandidateReplay checks
   the separate asynchronous ownership cut. One live process per logical ID. *)
CONSTANTS Brokers, CommonBroker, LeaseTicks, Bounded, ClockLimit, MaxSteps,
          BindOffers, StartConnected
ASSUME /\ Brokers # {} /\ CommonBroker \in Brokers /\ LeaseTicks >= 2
       /\ Bounded \in BOOLEAN /\ BindOffers \in BOOLEAN
       /\ StartConnected \in BOOLEAN
       /\ ClockLimit > 0 /\ MaxSteps > 0

Peers == {1, 2}
Other(p) == 3 - p
Boots == 1..2
Slots == [peer : Peers, broker : Brokers, boot : Boots]
None == [clock |-> 0, boot |-> 0, auth |-> 0, offer |-> 0, candidate |-> FALSE]
SeedRecord == [clock |-> 2, boot |-> 1, auth |-> 1, offer |-> 1, candidate |-> TRUE]
EmptyResponse == [p \in Peers |-> None]
NoRequest == [present |-> FALSE, payload |-> None]
NoResponse == [present |-> FALSE, records |-> EmptyResponse]
Newer(a, b) == a.clock > b.clock \/ (a.clock = b.clock /\ a.boot > b.boot)
Max(a, b) == IF a > b THEN a ELSE b

VARIABLES boots, clocks, generations, offers, gathered, seen, remoteAuth,
          appliedOffer, buffered, consumed, retry, up, stores, leases,
          requests, responses, online, stable, synced, steps,
          observed, lastPublication, observedAtPublication
state == <<boots, clocks, generations, offers, gathered, seen, remoteAuth,
           appliedOffer, buffered, consumed, retry, up, stores, leases,
           requests, responses, online, stable, synced,
           observed, lastPublication, observedAtPublication>>
vars == <<state, steps>>
AuthID(b, g) == 2^(b - 1) * (2 * g - 1)
Auth(p) == IF generations[p] = 0 THEN 0 ELSE AuthID(boots[p], generations[p])
Payload(p, n) == IF Auth(p) = 0 THEN None ELSE
    [clock |-> n, boot |-> boots[p], auth |-> Auth(p),
     offer |-> offers[p], candidate |-> gathered[p]]
CanIncrement(p) == ~Bounded \/ clocks[p] < ClockLimit
CanRetry(p) == ~Bounded \/ generations[p] < 2

Init == /\ boots = [p \in Peers |-> 1]
        /\ clocks = [p \in Peers |-> IF StartConnected THEN 2 ELSE 0]
        /\ generations = [p \in Peers |-> IF StartConnected \/ p = 1 THEN 1 ELSE 0]
        /\ offers = [p \in Peers |-> IF StartConnected \/ p = 1 THEN 1 ELSE 0]
        /\ gathered = [p \in Peers |-> StartConnected]
        /\ seen = [p \in Peers |-> IF StartConnected THEN SeedRecord ELSE None]
        /\ remoteAuth = [p \in Peers |-> IF StartConnected THEN 1 ELSE 0]
        /\ appliedOffer = remoteAuth
        /\ buffered = [p \in Peers |-> StartConnected]
        /\ consumed = remoteAuth /\ retry = [p \in Peers |-> FALSE] /\ up = buffered
        /\ stores = [b \in Brokers |-> [p \in Peers |-> IF StartConnected THEN SeedRecord ELSE None]]
        /\ leases = [b \in Brokers |-> [p \in Peers |-> IF StartConnected THEN LeaseTicks ELSE 0]]
        /\ requests = [s \in Slots |-> NoRequest]
        /\ responses = [s \in Slots |-> NoResponse]
        /\ online = Brokers /\ stable = FALSE /\ synced = {} /\ steps = 0
        /\ observed = clocks /\ lastPublication = clocks
        /\ observedAtPublication = [p \in Peers |-> IF StartConnected THEN 1 ELSE 0]

Send(p, b) ==
    LET s == [peer |-> p, broker |-> b, boot |-> boots[p]]
        n == clocks[p] + 1
    IN /\ CanIncrement(p)
       /\ ~requests[s].present /\ ~responses[s].present
       /\ requests' = [requests EXCEPT ![s] = [present |-> TRUE, payload |-> Payload(p, n)]]
       /\ clocks' = [clocks EXCEPT ![p] = n]
       /\ lastPublication' = [lastPublication EXCEPT ![p] = n]
       /\ observedAtPublication' = [observedAtPublication EXCEPT ![p] = observed[p]]
       /\ UNCHANGED <<boots, generations, offers, gathered, seen, remoteAuth,
                       appliedOffer, buffered, consumed, retry, up, stores, leases,
                       responses, online, stable, synced, observed>>

(* Server processing is atomic under the broker mutex. A request can survive
   its source process; a restarted client uses a different boot-indexed slot. *)
Serve(s) ==
    /\ s.broker \in online /\ requests[s].present
    /\ LET b == s.broker
           p == s.peer
           r == requests[s].payload
           clean == [q \in Peers |-> IF leases[b][q] = 0 THEN None ELSE stores[b][q]]
           write == r # None /\ Newer(r, clean[p])
           after == [clean EXCEPT ![p] = IF write THEN r ELSE @]
       IN /\ stores' = [stores EXCEPT ![b] = after]
          /\ leases' = [leases EXCEPT ![b][p] = IF write THEN LeaseTicks ELSE @]
          /\ responses' = [responses EXCEPT ![s] = [present |-> TRUE, records |-> after]]
    /\ requests' = [requests EXCEPT ![s] = NoRequest]
    /\ UNCHANGED <<boots, clocks, generations, offers, gathered, seen, remoteAuth,
                    appliedOffer, buffered, consumed, retry, up, online, stable,
                    synced, observed, lastPublication, observedAtPublication>>

Deliver(s) ==
    /\ responses[s].present
    /\ LET p == s.peer
           ours == s.boot = boots[p]
           own == responses[s].records[p]
           r == responses[s].records[Other(p)]
           fresh == ours /\ r # None /\ Newer(r, seen[p])
           apply == fresh /\ (p = 2 \/ ~BindOffers \/ r.offer = offers[p])
           changed == apply /\ r.auth # remoteAuth[p]
           cancel == changed /\ (consumed[p] # 0 \/
                (p = 2 /\ offers[p] # 0 /\ offers[p] # r.offer))
           learned == Max(own.clock, r.clock)
       IN /\ clocks' = [clocks EXCEPT ![p] = IF ours THEN Max(@, learned) ELSE @]
          /\ observed' = [observed EXCEPT ![p] = IF ours THEN Max(@, learned) ELSE @]
          /\ seen' = [seen EXCEPT ![p] = IF fresh THEN r ELSE @]
          /\ remoteAuth' = [remoteAuth EXCEPT ![p] = IF apply THEN r.auth ELSE @]
          /\ appliedOffer' = [appliedOffer EXCEPT ![p] = IF apply THEN r.offer ELSE @]
          /\ buffered' = [buffered EXCEPT ![p] =
                IF changed THEN r.candidate ELSE IF apply THEN @ \/ r.candidate ELSE @]
          /\ retry' = [retry EXCEPT ![p] = @ \/ cancel]
          /\ up' = [up EXCEPT ![p] = IF cancel THEN FALSE ELSE @]
          /\ synced' = IF ours /\ s.broker = CommonBroker THEN synced \cup {p} ELSE synced
    /\ responses' = [responses EXCEPT ![s] = NoResponse]
    /\ UNCHANGED <<boots, generations, offers, gathered, consumed, requests,
                    stores, leases, online, stable, lastPublication, observedAtPublication>>

(* Lost calls/responses are allowed before the finite-failure suffix. A timed
   out request still processed later in the SAME process is not modeled; old
   process requests do remain in their distinct incarnation slots. *)
LoseRequest(s) ==
    /\ ~stable /\ requests[s].present
    /\ requests' = [requests EXCEPT ![s] = NoRequest]
    /\ UNCHANGED <<boots, clocks, generations, offers, gathered, seen, remoteAuth,
                    appliedOffer, buffered, consumed, retry, up, stores, leases,
                    responses, online, stable, synced, observed,
                    lastPublication, observedAtPublication>>
LoseResponse(s) ==
    /\ ~stable /\ responses[s].present
    /\ responses' = [responses EXCEPT ![s] = NoResponse]
    /\ UNCHANGED <<boots, clocks, generations, offers, gathered, seen, remoteAuth,
                    appliedOffer, buffered, consumed, retry, up, stores, leases,
                    requests, online, stable, synced, observed,
                    lastPublication, observedAtPublication>>

Gather(p) == /\ Auth(p) # 0 /\ ~gathered[p]
             /\ gathered' = [gathered EXCEPT ![p] = TRUE]
             /\ UNCHANGED <<boots, clocks, generations, offers, seen, remoteAuth,
                             appliedOffer, buffered, consumed, retry, up, stores,
                             leases, requests, responses, online, stable, synced,
                             observed, lastPublication, observedAtPublication>>

Answer == /\ remoteAuth[2] # 0
          /\ (generations[2] = 0 \/ offers[2] # remoteAuth[2] \/ retry[2])
          /\ CanRetry(2)
          /\ generations' = [generations EXCEPT ![2] = @ + 1]
          /\ offers' = [offers EXCEPT ![2] = remoteAuth[2]]
          /\ gathered' = [gathered EXCEPT ![2] = FALSE]
          /\ consumed' = [consumed EXCEPT ![2] = 0]
          /\ retry' = [retry EXCEPT ![2] = FALSE]
          /\ up' = [up EXCEPT ![2] = FALSE]
          /\ UNCHANGED <<boots, clocks, seen, remoteAuth, appliedOffer, buffered,
                          stores, leases, requests, responses, online, stable, synced,
                          observed, lastPublication, observedAtPublication>>

RetryInitiator ==
    /\ retry[1] /\ CanRetry(1)
    /\ generations' = [generations EXCEPT ![1] = @ + 1]
    /\ offers' = [offers EXCEPT ![1] = AuthID(boots[1], generations[1] + 1)]
    /\ gathered' = [gathered EXCEPT ![1] = FALSE]
    /\ remoteAuth' = [remoteAuth EXCEPT ![1] = 0]
    /\ appliedOffer' = [appliedOffer EXCEPT ![1] = 0]
    /\ buffered' = [buffered EXCEPT ![1] = FALSE]
    /\ consumed' = [consumed EXCEPT ![1] = 0]
    /\ retry' = [retry EXCEPT ![1] = FALSE]
    /\ up' = [up EXCEPT ![1] = FALSE]
    /\ UNCHANGED <<boots, clocks, seen, stores, leases, requests, responses,
                    online, stable, synced, observed, lastPublication, observedAtPublication>>

Consume(p) == /\ remoteAuth[p] # 0 /\ ~retry[p]
              /\ (p = 1 \/ offers[p] = remoteAuth[p])
              /\ consumed' = [consumed EXCEPT ![p] = remoteAuth[p]]
              /\ UNCHANGED <<boots, clocks, generations, offers, gathered, seen,
                              remoteAuth, appliedOffer, buffered, retry, up, stores,
                              leases, requests, responses, online, stable, synced,
                              observed, lastPublication, observedAtPublication>>

Connect == /\ \A p \in Peers : gathered[p] /\ buffered[p] /\ ~retry[p]
                               /\ consumed[p] = Auth(Other(p)) /\ Auth(p) # 0
           /\ offers[2] = offers[1]
           /\ up' = [p \in Peers |-> TRUE]
           /\ UNCHANGED <<boots, clocks, generations, offers, gathered, seen,
                           remoteAuth, appliedOffer, buffered, consumed, retry,
                           stores, leases, requests, responses, online, stable,
                           synced, observed, lastPublication, observedAtPublication>>

Restart(p) ==
    /\ ~stable /\ boots[p] = 1
    /\ boots' = [boots EXCEPT ![p] = 2]
    /\ clocks' = [clocks EXCEPT ![p] = 0]
    /\ generations' = [generations EXCEPT ![p] = IF p = 1 THEN 1 ELSE 0]
    /\ offers' = [offers EXCEPT ![p] = IF p = 1 THEN AuthID(2, 1) ELSE 0]
    /\ gathered' = [gathered EXCEPT ![p] = FALSE]
    /\ seen' = [seen EXCEPT ![p] = None]
    /\ remoteAuth' = [remoteAuth EXCEPT ![p] = 0]
    /\ appliedOffer' = [appliedOffer EXCEPT ![p] = 0]
    /\ buffered' = [buffered EXCEPT ![p] = FALSE]
    /\ consumed' = [consumed EXCEPT ![p] = 0]
    /\ retry' = [retry EXCEPT ![p] = FALSE]
    /\ up' = [up EXCEPT ![p] = FALSE]
    /\ observed' = [observed EXCEPT ![p] = 0]
    /\ lastPublication' = [lastPublication EXCEPT ![p] = 0]
    /\ observedAtPublication' = [observedAtPublication EXCEPT ![p] = 0]
    /\ synced' = synced \ {p}
    /\ UNCHANGED <<stores, leases, requests, responses, online, stable>>

BrokerFault(b) ==
    /\ ~stable
    /\ stores' = [stores EXCEPT ![b] = [p \in Peers |-> None]]
    /\ leases' = [leases EXCEPT ![b] = [p \in Peers |-> 0]]
    /\ online' = online \ {b}
    /\ UNCHANGED <<boots, clocks, generations, offers, gathered, seen, remoteAuth,
                    appliedOffer, buffered, consumed, retry, up, requests, responses,
                    stable, synced, observed, lastPublication, observedAtPublication>>

BrokerRecover(b) ==
    /\ ~stable /\ online' = online \cup {b}
    /\ UNCHANGED <<boots, clocks, generations, offers, gathered, seen, remoteAuth,
                    appliedOffer, buffered, consumed, retry, up, stores, leases,
                    requests, responses, stable, synced, observed, lastPublication, observedAtPublication>>

Stabilize == /\ ~stable /\ stable' = TRUE /\ online' = online \cup {CommonBroker}
             /\ synced' = {}
             /\ UNCHANGED <<boots, clocks, generations, offers, gathered, seen,
                             remoteAuth, appliedOffer, buffered, consumed, retry,
                             up, stores, leases, requests, responses,
                             observed, lastPublication, observedAtPublication>>

(* A successful sync by both peers within a lease tick is an explicit timely
   common-broker assumption after stabilization. It requires no handshake. *)
Tick == /\ (~stable \/ synced = Peers)
        /\ leases' = [b \in Brokers |-> [p \in Peers |->
             IF leases[b][p] > 0 THEN leases[b][p] - 1 ELSE 0]]
        /\ synced' = {}
        /\ UNCHANGED <<boots, clocks, generations, offers, gathered, seen,
                        remoteAuth, appliedOffer, buffered, consumed, retry, up,
                        stores, requests, responses, online, stable,
                        observed, lastPublication, observedAtPublication>>

ProtocolNext == \/ \E p \in Peers, b \in Brokers : Send(p, b)
                \/ \E s \in Slots : Serve(s) \/ Deliver(s) \/ LoseRequest(s) \/ LoseResponse(s)
                \/ \E p \in Peers : Gather(p) \/ Consume(p) \/ Restart(p)
                \/ \E b \in Brokers : BrokerFault(b) \/ BrokerRecover(b)
                \/ Answer \/ RetryInitiator \/ Connect \/ Stabilize \/ Tick
Next == ProtocolNext /\ IF Bounded THEN steps < MaxSteps /\ steps' = steps + 1
                       ELSE UNCHANGED steps
Spec == Init /\ [][Next]_vars

(* Progress obligation only: NOT checked by the bounded safety configs. *)
RecoverySpec == Spec /\ WF_vars(Stabilize) /\ WF_vars(Answer)
                /\ WF_vars(RetryInitiator) /\ WF_vars(Connect) /\ WF_vars(Tick)
                /\ \A p \in Peers : WF_vars(Gather(p)) /\ WF_vars(Consume(p))
                     /\ WF_vars(Send(p, CommonBroker))
                /\ \A s \in Slots : s.broker = CommonBroker =>
                     WF_vars(Serve(s)) /\ WF_vars(Deliver(s))
EventuallyConnected == stable ~> (\A p \in Peers : up[p])

RecordOK(r) == /\ r.clock \in Nat /\ r.boot \in 0..2 /\ r.auth \in Nat
               /\ r.offer \in Nat /\ r.candidate \in BOOLEAN
TypeOK == /\ boots \in [Peers -> Boots] /\ clocks \in [Peers -> Nat]
          /\ generations \in [Peers -> Nat] /\ offers \in [Peers -> Nat]
          /\ remoteAuth \in [Peers -> Nat] /\ appliedOffer \in [Peers -> Nat]
          /\ consumed \in [Peers -> Nat]
          /\ gathered \in [Peers -> BOOLEAN] /\ buffered \in [Peers -> BOOLEAN]
          /\ retry \in [Peers -> BOOLEAN] /\ up \in [Peers -> BOOLEAN]
          /\ online \subseteq Brokers /\ synced \subseteq Peers /\ stable \in BOOLEAN
          /\ leases \in [Brokers -> [Peers -> 0..LeaseTicks]] /\ steps \in Nat
          /\ \A p \in Peers : RecordOK(seen[p])
          /\ \A b \in Brokers, p \in Peers : RecordOK(stores[b][p])
          /\ \A s \in Slots : /\ requests[s].present \in BOOLEAN
                               /\ RecordOK(requests[s].payload)
                               /\ responses[s].present \in BOOLEAN
                               /\ \A p \in Peers : RecordOK(responses[s].records[p])
AnswerBinding == remoteAuth[1] = 0 \/ appliedOffer[1] = offers[1]
PublicationFreshness == \A p \in Peers :
    lastPublication[p] = 0 \/ lastPublication[p] > observedAtPublication[p]
StableBrokerReachable == stable => CommonBroker \in online
(* Expected reachability violations: packets really can outlive a process. *)
NoOldRequests == \A s \in Slots : requests[s].present => s.boot = boots[s.peer]
NoOldResponses == \A s \in Slots : responses[s].present => s.boot = boots[s.peer]
=============================================================================
