------------------------- MODULE CandidateLifetime -------------------------
EXTENDS Naturals, TLC

(***************************************************************************)
(* Environmental negative control, outside the signaling-state proof.       *)
(* Both credentials and the gathered candidate are delivered exactly once,  *)
(* without stale epochs or loss. Even the earliest possible check can use   *)
(* an expired mapping. Mapping lifetime and delivery time are explicit       *)
(* constants, not measured guarantees. Tick cannot postpone a due action.   *)
(***************************************************************************)
CONSTANTS Lifetime, PeerDelay, SignalDelay, DeferGather
ASSUME /\ Lifetime > 0
       /\ PeerDelay \in Nat
       /\ SignalDelay \in Nat
       /\ DeferGather \in BOOLEAN

VARIABLES now, phase, gatheredAt, delivered, attempted, connected
vars == <<now, phase, gatheredAt, delivered, attempted, connected>>

Init == /\ now = 0
        /\ phase = "waiting"
        /\ gatheredAt = 0
        /\ delivered = FALSE
        /\ attempted = FALSE
        /\ connected = FALSE

Tick == /\ \/ /\ phase = "waiting"
              /\ now < PeerDelay
           \/ /\ phase = "exchange"
              /\ now < PeerDelay + SignalDelay
        /\ now' = now + 1
        /\ UNCHANGED <<phase, gatheredAt, delivered, attempted, connected>>

PeerReady == /\ phase = "waiting"
             /\ now = PeerDelay
             /\ phase' = "exchange"
             /\ gatheredAt' = IF DeferGather THEN now ELSE gatheredAt
             /\ UNCHANGED <<now, delivered, attempted, connected>>

FirstCheck == /\ phase = "exchange"
              /\ now = PeerDelay + SignalDelay
              /\ delivered' = TRUE
              /\ attempted' = TRUE
              /\ connected' = (now < gatheredAt + Lifetime)
              /\ phase' = "done"
              /\ UNCHANGED <<now, gatheredAt>>

Next == Tick \/ PeerReady \/ FirstCheck
Spec == Init /\ [][Next]_vars

TypeOK == /\ now \in Nat
          /\ phase \in {"waiting", "exchange", "done"}
          /\ gatheredAt \in Nat
          /\ delivered \in BOOLEAN
          /\ attempted \in BOOLEAN
          /\ connected \in BOOLEAN

DeliveryIntact == attempted => delivered
AttemptWorks == attempted => connected
NoConnection == ~connected
=============================================================================
