------------------------- MODULE AttemptOwnership -------------------------
EXTENDS Naturals

(* time.AfterFunc can start a callback before Stop(), then block waiting for
   sess.mu. Stop does not wait for a callback which has already started.
   The serial retry loop may install the next abortAttempt before it runs.
   Current Go callbacks all use peerSession.abortAgent(agent), which checks
   sess.agent == agent under the session lock. Negative configurations remove
   ownership checks to preserve the regression counterexamples. *)
CONSTANT GuardTimer, GuardICECallback
ASSUME /\ GuardTimer \in BOOLEAN /\ GuardICECallback \in BOOLEAN

Attempts == 1..2
VARIABLES current, running, finished, timer, iceCallbacks, staleCancellation
vars == <<current, running, finished, timer, iceCallbacks, staleCancellation>>

Init == /\ current = 1 /\ running = TRUE /\ finished = FALSE
        /\ timer = [a \in Attempts |-> IF a = 1 THEN "armed" ELSE "absent"]
        /\ iceCallbacks = {} /\ staleCancellation = FALSE

TimerStarts(a) ==
    /\ timer[a] = "armed"
    /\ timer' = [timer EXCEPT ![a] = "started"]
    /\ UNCHANGED <<current, running, finished, iceCallbacks, staleCancellation>>

Finish ==
    /\ current = 1 /\ ~finished
    /\ running' = FALSE /\ finished' = TRUE
    /\ timer' = [timer EXCEPT ![current] = IF @ = "armed" THEN "stopped" ELSE @]
    /\ iceCallbacks' = iceCallbacks \cup {current}
    /\ UNCHANGED <<current, staleCancellation>>

BeginNext ==
    /\ current = 1 /\ finished
    /\ current' = 2 /\ running' = TRUE /\ finished' = FALSE
    /\ timer' = [timer EXCEPT ![2] = "armed"]
    /\ UNCHANGED <<iceCallbacks, staleCancellation>>

TimerRuns(a) ==
    /\ timer[a] = "started"
    /\ LET cancels == running /\ (~GuardTimer \/ a = current)
       IN /\ running' = IF cancels THEN FALSE ELSE running
          /\ staleCancellation' = (staleCancellation \/ (cancels /\ a # current))
    /\ timer' = [timer EXCEPT ![a] = "done"]
    /\ UNCHANGED <<current, finished, iceCallbacks>>

ICECallbackRuns(a) ==
    /\ a \in iceCallbacks
    /\ LET cancels == running /\ (~GuardICECallback \/ a = current)
       IN /\ running' = IF cancels THEN FALSE ELSE running
          /\ staleCancellation' = (staleCancellation \/ (cancels /\ a # current))
    /\ iceCallbacks' = iceCallbacks \ {a}
    /\ UNCHANGED <<current, finished, timer>>

Next == \/ Finish \/ BeginNext
        \/ \E a \in Attempts : TimerStarts(a) \/ TimerRuns(a) \/ ICECallbackRuns(a)
Spec == Init /\ [][Next]_vars
TypeOK == /\ current \in Attempts /\ running \in BOOLEAN /\ finished \in BOOLEAN
          /\ timer \in [Attempts -> {"absent", "armed", "started", "stopped", "done"}]
          /\ iceCallbacks \subseteq Attempts /\ staleCancellation \in BOOLEAN
AttemptIsolation == ~staleCancellation
=============================================================================
