-------------------------- MODULE SnapshotStore --------------------------
EXTENDS Naturals, FiniteSets

(* One authenticated directed peer stream. Brokers do not communicate.
   Requests and responses can be replayed in any order. Observed responses
   survive broker expiry/restart. No liveness claim uses these finite clocks.
   Maxima are observer variables, independent of the implementation guards. *)
CONSTANTS Brokers, MaxClock, MaxBoot, EnforceOrdering, RecoverOwnClock
ASSUME /\ Brokers # {} /\ MaxClock > 0 /\ MaxBoot > 0
       /\ EnforceOrdering \in BOOLEAN /\ RecoverOwnClock \in BOOLEAN

None == [clock |-> 0, boot |-> 0]
Records == [clock : 1..MaxClock, boot : 1..MaxBoot]
Newer(a, b) == a.clock > b.clock \/
                (a.clock = b.clock /\ a.boot > b.boot)
Maximum(a, b) == IF Newer(a, b) THEN a ELSE b

VARIABLES boot, usedBoots, senderClock, published, responses, store, storeMax,
          accepted, acceptedMax, receiverClock, observedClock,
          lastPublication, observedAtPublication
vars == <<boot, usedBoots, senderClock, published, responses, store, storeMax,
          accepted, acceptedMax, receiverClock, observedClock,
          lastPublication, observedAtPublication>>

Init == /\ boot \in 1..MaxBoot /\ usedBoots = {boot} /\ senderClock = 0
        /\ published = {} /\ responses = {}
        /\ store = [b \in Brokers |-> None]
        /\ storeMax = store
        /\ accepted = None /\ acceptedMax = None /\ receiverClock = 0
        /\ observedClock = 0 /\ lastPublication = None /\ observedAtPublication = 0

Publish == /\ senderClock < MaxClock
           /\ senderClock' = senderClock + 1
           /\ published' = published \cup
                {[clock |-> senderClock + 1, boot |-> boot]}
           /\ lastPublication' = [clock |-> senderClock + 1, boot |-> boot]
           /\ observedAtPublication' = observedClock
           /\ UNCHANGED <<boot, usedBoots, responses, store, storeMax, accepted,
                          acceptedMax, receiverClock, observedClock>>

Write(b, r) ==
    /\ r \in published
    /\ store' = [store EXCEPT ![b] =
           IF EnforceOrdering THEN Maximum(r, @) ELSE r]
    /\ storeMax' = [storeMax EXCEPT ![b] = Maximum(r, @)]
    /\ UNCHANGED <<boot, usedBoots, senderClock, published, responses, accepted,
                   acceptedMax, receiverClock, observedClock,
                   lastPublication, observedAtPublication>>

Read(b) == /\ store[b] # None
           /\ responses' = responses \cup {store[b]}
           /\ UNCHANGED <<boot, usedBoots, senderClock, published, store, storeMax,
                          accepted, acceptedMax, receiverClock, observedClock,
                          lastPublication, observedAtPublication>>

(* Lease expiry or broker restart clears both the cell and its observer.
   A smaller version is legal after forgetting; this is not durable storage. *)
Forget(b) == /\ store' = [store EXCEPT ![b] = None]
             /\ storeMax' = [storeMax EXCEPT ![b] = None]
             /\ UNCHANGED <<boot, usedBoots, senderClock, published, responses,
                            accepted, acceptedMax, receiverClock, observedClock,
                            lastPublication, observedAtPublication>>

Receive(r) ==
    /\ r \in responses
    /\ accepted' = IF EnforceOrdering THEN Maximum(r, accepted) ELSE r
    /\ acceptedMax' = Maximum(r, acceptedMax)
    /\ receiverClock' = IF r.clock > receiverClock THEN r.clock ELSE receiverClock
    /\ UNCHANGED <<boot, usedBoots, senderClock, published, responses, store, storeMax,
                   observedClock, lastPublication, observedAtPublication>>

(* The source sees its own old records in sync responses, before attempting
   another publish. Go's receive rule takes the maximum even for own records. *)
RecoverClock(r) ==
    /\ r \in responses
    /\ senderClock' = IF RecoverOwnClock /\ r.clock > senderClock THEN r.clock ELSE senderClock
    /\ observedClock' = IF r.clock > observedClock THEN r.clock ELSE observedClock
    /\ UNCHANGED <<boot, usedBoots, published, responses, store, storeMax,
                   accepted, acceptedMax, receiverClock, lastPublication, observedAtPublication>>

(* Random boot IDs are unique but NOT chronological. Explore both lexical
   orders on restart; never assume that the new process has a greater ID. *)
RestartSender ==
    \E fresh \in (1..MaxBoot) \ usedBoots :
        /\ boot' = fresh /\ usedBoots' = usedBoots \cup {fresh}
        /\ senderClock' = 0
        /\ observedClock' = 0 /\ lastPublication' = None /\ observedAtPublication' = 0
        /\ UNCHANGED <<published, responses, store, storeMax,
                       accepted, acceptedMax, receiverClock>>

RestartReceiver == /\ accepted' = None /\ acceptedMax' = None
                   /\ receiverClock' = 0
                   /\ UNCHANGED <<boot, usedBoots, senderClock, published, responses,
                                  store, storeMax, observedClock,
                                  lastPublication, observedAtPublication>>

Next == \/ Publish \/ RestartSender \/ RestartReceiver
        \/ \E b \in Brokers : Read(b) \/ Forget(b)
        \/ \E b \in Brokers, r \in published : Write(b, r)
        \/ \E r \in responses : Receive(r) \/ RecoverClock(r)

Spec == Init /\ [][Next]_vars
TypeOK == /\ boot \in 1..MaxBoot /\ senderClock \in 0..MaxClock
          /\ usedBoots \subseteq 1..MaxBoot /\ boot \in usedBoots
          /\ receiverClock \in 0..MaxClock
          /\ published \subseteq Records /\ responses \subseteq published
          /\ store \in [Brokers -> Records \cup {None}]
          /\ storeMax \in [Brokers -> Records \cup {None}]
          /\ accepted \in Records \cup {None}
          /\ acceptedMax \in Records \cup {None}
          /\ observedClock \in 0..MaxClock
          /\ observedAtPublication \in 0..MaxClock
          /\ lastPublication \in Records \cup {None}
BrokerOrdering == store = storeMax
ClientOrdering == accepted = acceptedMax
ClockCoversAccepted == receiverClock >= accepted.clock
PublicationFreshness == lastPublication = None \/ lastPublication.clock > observedAtPublication
Provenance == /\ \A b \in Brokers : store[b] = None \/ store[b] \in published
              /\ accepted = None \/ accepted \in published
BoundedStore == Cardinality({b \in Brokers : store[b] # None}) <= Cardinality(Brokers)
(* Expected to fail: establishes that acceptance is reachable. *)
NoAcceptance == accepted = None
=============================================================================
