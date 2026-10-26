---------------------------- MODULE SlotOwnership ----------------------------
EXTENDS Integers, FiniteSets

(* Dynamic claimOrdinal protocol, with consistent Consul reads and atomic
   create-if-absent CAS, process retirement/reboot, lost replies, and requests that can outlive
   their originating process. External cleanup is a separate modeled action.
   The current scan rereads after failed CAS; disabling that guard retains
   the previous algorithm as a regression control.
   This is not the Terraform named-slot allocation protocol. *)
CONSTANTS Processes, SlotCount, MaxRestarts, UniqueInstances,
          AtomicCAS, AllowCleanup, RetireBeforeCleanup, RecheckAfterCASFailure
ASSUME /\ Processes # {} /\ SlotCount > 0 /\ MaxRestarts \in Nat
       /\ UniqueInstances \in BOOLEAN /\ AtomicCAS \in BOOLEAN
       /\ AllowCleanup \in BOOLEAN /\ RetireBeforeCleanup \in BOOLEAN
       /\ RecheckAfterCASFailure \in BOOLEAN
       /\ "none" \notin Processes

Slots == 0..(SlotCount - 1)
NoClaim == -1
Instance == IF UniqueInstances THEN [p \in Processes |-> p]
            ELSE [p \in Processes |-> CHOOSE q \in Processes : TRUE]
RequestType == [client : Processes, epoch : 0..MaxRestarts, slot : Slots]
ResponseType == [client : Processes, epoch : 0..MaxRestarts, slot : Slots, ok : BOOLEAN]

VARIABLES owner, active, epoch, pc, cursor, loaded, claimed, requests, responses, rejoined
vars == <<owner, active, epoch, pc, cursor, loaded, claimed, requests, responses, rejoined>>

Init ==
    /\ owner = [s \in Slots |-> "none"]
    /\ active = [p \in Processes |-> TRUE]
    /\ epoch = [p \in Processes |-> 0]
    /\ pc = [p \in Processes |-> "read"]
    /\ cursor = [p \in Processes |-> 0]
    /\ loaded = [p \in Processes |-> "none"]
    /\ claimed = [p \in Processes |-> NoClaim]
    /\ requests = {} /\ responses = {} /\ rejoined = FALSE

Read(p) ==
    /\ active[p] /\ pc[p] = "read"
    /\ loaded' = [loaded EXCEPT ![p] = owner[cursor[p]]]
    /\ pc' = [pc EXCEPT ![p] = "decide"]
    /\ UNCHANGED <<owner, active, epoch, cursor, claimed, requests, responses, rejoined>>

AcceptOwn(p) ==
    /\ active[p] /\ pc[p] = "decide" /\ loaded[p] = Instance[p]
    /\ claimed' = [claimed EXCEPT ![p] = cursor[p]]
    /\ pc' = [pc EXCEPT ![p] = "done"]
    /\ rejoined' = TRUE
    /\ UNCHANGED <<owner, active, epoch, cursor, loaded, requests, responses>>

PrepareCAS(p) ==
    /\ active[p] /\ pc[p] = "decide" /\ loaded[p] = "none"
    /\ pc' = [pc EXCEPT ![p] = "cas"]
    /\ UNCHANGED <<owner, active, epoch, cursor, loaded, claimed, requests, responses, rejoined>>

Advance(p) ==
    /\ cursor' = [cursor EXCEPT ![p] = IF cursor[p] + 1 < SlotCount THEN cursor[p] + 1 ELSE cursor[p]]
    /\ pc' = [pc EXCEPT ![p] = IF cursor[p] + 1 < SlotCount THEN "read" ELSE "exhausted"]

SkipOccupied(p) ==
    /\ active[p] /\ pc[p] = "decide" /\ loaded[p] \notin {"none", Instance[p]}
    /\ Advance(p)
    /\ UNCHANGED <<owner, active, epoch, loaded, claimed, requests, responses, rejoined>>

SendCAS(p) ==
    /\ active[p] /\ pc[p] = "cas"
    /\ requests' = requests \cup {[client |-> p, epoch |-> epoch[p], slot |-> cursor[p]]}
    /\ pc' = [pc EXCEPT ![p] = "wait"]
    /\ UNCHANGED <<owner, active, epoch, cursor, loaded, claimed, responses, rejoined>>

(* The server may commit a captured request after the caller retires. *)
DeliverCAS(message) ==
    /\ message \in requests
    /\ LET success == ~AtomicCAS \/ owner[message.slot] = "none"
       IN /\ owner' = IF success THEN [owner EXCEPT ![message.slot] = Instance[message.client]] ELSE owner
          /\ responses' = responses \cup {[client |-> message.client, epoch |-> message.epoch,
                                            slot |-> message.slot, ok |-> success]}
    /\ requests' = requests \ {message}
    /\ UNCHANGED <<active, epoch, pc, cursor, loaded, claimed, rejoined>>

ApplySuccess(message) ==
    /\ message \in responses /\ message.ok
    /\ LET p == message.client IN
       /\ active[p] /\ epoch[p] = message.epoch /\ pc[p] = "wait" /\ cursor[p] = message.slot
       /\ pc' = [pc EXCEPT ![p] = "done"]
       /\ claimed' = [claimed EXCEPT ![p] = message.slot]
    /\ responses' = responses \ {message}
    /\ UNCHANGED <<owner, active, epoch, cursor, loaded, requests, rejoined>>

ApplyFailure(message) ==
    /\ message \in responses /\ ~message.ok
    /\ LET p == message.client IN
       /\ active[p] /\ epoch[p] = message.epoch /\ pc[p] = "wait" /\ cursor[p] = message.slot
       /\ IF RecheckAfterCASFailure
          THEN /\ pc' = [pc EXCEPT ![p] = "read"] /\ UNCHANGED cursor
          ELSE Advance(p)
    /\ responses' = responses \ {message}
    /\ UNCHANGED <<owner, active, epoch, loaded, claimed, requests, rejoined>>

LoseRequest(message) ==
    /\ message \in requests /\ requests' = requests \ {message}
    /\ UNCHANGED <<owner, active, epoch, pc, cursor, loaded, claimed, responses, rejoined>>
LoseResponse(message) ==
    /\ message \in responses /\ responses' = responses \ {message}
    /\ UNCHANGED <<owner, active, epoch, pc, cursor, loaded, claimed, requests, rejoined>>

Retire(p) ==
    /\ active[p] /\ active' = [active EXCEPT ![p] = FALSE]
    /\ pc' = [pc EXCEPT ![p] = "retired"]
    /\ UNCHANGED <<owner, epoch, cursor, loaded, claimed, requests, responses, rejoined>>
Boot(p) ==
    /\ ~active[p] /\ epoch[p] < MaxRestarts
    /\ active' = [active EXCEPT ![p] = TRUE]
    /\ epoch' = [epoch EXCEPT ![p] = @ + 1]
    /\ pc' = [pc EXCEPT ![p] = "read"]
    /\ cursor' = [cursor EXCEPT ![p] = 0]
    /\ loaded' = [loaded EXCEPT ![p] = "none"]
    /\ claimed' = [claimed EXCEPT ![p] = NoClaim]
    /\ UNCHANGED <<owner, requests, responses, rejoined>>

Cleanup(s) ==
    /\ AllowCleanup /\ owner[s] \in Processes
    /\ (~RetireBeforeCleanup \/ \A p \in Processes : active[p] => Instance[p] # owner[s])
    /\ owner' = [owner EXCEPT ![s] = "none"]
    /\ UNCHANGED <<active, epoch, pc, cursor, loaded, claimed, requests, responses, rejoined>>

Next == \/ \E p \in Processes : Read(p) \/ AcceptOwn(p) \/ PrepareCAS(p) \/ SkipOccupied(p)
                              \/ SendCAS(p) \/ Retire(p) \/ Boot(p)
        \/ \E message \in requests : DeliverCAS(message) \/ LoseRequest(message)
        \/ \E message \in responses : ApplySuccess(message) \/ ApplyFailure(message) \/ LoseResponse(message)
        \/ \E s \in Slots : Cleanup(s)
Spec == Init /\ [][Next]_vars

TypeOK == /\ owner \in [Slots -> Processes \cup {"none"}]
          /\ active \in [Processes -> BOOLEAN] /\ epoch \in [Processes -> 0..MaxRestarts]
          /\ pc \in [Processes -> {"read", "decide", "cas", "wait", "done", "exhausted", "retired"}]
          /\ cursor \in [Processes -> Slots] /\ loaded \in [Processes -> Processes \cup {"none"}]
          /\ claimed \in [Processes -> Slots \cup {NoClaim}]
          /\ requests \subseteq RequestType /\ responses \subseteq ResponseType /\ rejoined \in BOOLEAN
ReportedClaimOwned == \A p \in Processes : active[p] /\ claimed[p] \in Slots => owner[claimed[p]] = Instance[p]
NoLiveAlias == \A p, q \in Processes :
                active[p] /\ active[q] /\ claimed[p] \in Slots /\ claimed[p] = claimed[q] => p = q
InstanceHasOneSlot == \A s, t \in Slots : owner[s] \in Processes /\ owner[s] = owner[t] => s = t
NoRejoin == ~rejoined
NoBothClaimed == ~(\A p \in Processes : active[p] /\ claimed[p] \in Slots)
=============================================================================
