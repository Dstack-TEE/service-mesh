----------------------------- MODULE ReadRetry -----------------------------
EXTENDS Naturals, Sequences, TLC

(***************************************************************************)
(* Timed model of the SDK's automatic READ retry layer, not VM boot or ICE.  *)
(* Each HTTP exchange returns within RequestLatency <= RequestTimeout.      *)
(* First ThrottleResponses replies are 429; subsequent replies are 200.      *)
(* A zero ServerDelay means no usable Retry-After header. Local actions are  *)
(* urgent: Tick cannot postpone sending/handling an already-due request.     *)
(* Fairness excludes infinite stuttering, not persistent server throttling. *)
(***************************************************************************)
CONSTANTS MaxRetries, BaseDelay, MaxDelay, ServerDelay, RequestLatency,
          RequestTimeout, OperationTimeout, ThrottleResponses, RetryReads,
          HonorRetryAfter, HonorCancellation, UseRequestDeadline, CanCancel

ASSUME /\ MaxRetries \in Nat
       /\ BaseDelay > 0 /\ MaxDelay >= BaseDelay
       /\ ServerDelay \in Nat
       /\ RequestLatency > 0 /\ RequestLatency <= RequestTimeout
       /\ OperationTimeout > 0 /\ ThrottleResponses \in Nat
       /\ RetryReads \in BOOLEAN /\ HonorRetryAfter \in BOOLEAN
       /\ HonorCancellation \in BOOLEAN /\ UseRequestDeadline \in BOOLEAN
       /\ CanCancel \in BOOLEAN

Min(a, b) == IF a < b THEN a ELSE b
Backoff(n) == Min(BaseDelay * 2^(n - 1), MaxDelay)
Delay(n) == IF ServerDelay > 0 THEN ServerDelay ELSE Backoff(n)
Deadline == IF UseRequestDeadline
            THEN Min(RequestTimeout, OperationTimeout) ELSE OperationTimeout

RECURSIVE ReadyTime(_)
ReadyTime(n) == IF n = 0 THEN 0
               ELSE ReadyTime(n - 1) + RequestLatency + Delay(n)
BudgetEnough == /\ ThrottleResponses <= MaxRetries
                /\ ReadyTime(ThrottleResponses) + RequestLatency < OperationTimeout

VARIABLES now, phase, attempts, responseAt, retryAt, requiredAt,
          cancelled, sent
vars == <<now, phase, attempts, responseAt, retryAt, requiredAt, cancelled, sent>>

Active == phase \in {"ready", "request", "backoff"}
Live == /\ now < Deadline
        /\ (~cancelled \/ ~HonorCancellation)
Due == phase = "ready" \/ (phase = "backoff" /\ now >= retryAt)

Init == /\ now = 0 /\ phase = "ready" /\ attempts = 0
        /\ responseAt = 0 /\ retryAt = 0 /\ requiredAt = 0
        /\ cancelled = FALSE /\ sent = <<>>

Send == /\ Active /\ Live /\ Due
        /\ attempts' = attempts + 1 /\ phase' = "request"
        /\ responseAt' = now + RequestLatency
        /\ sent' = Append(sent, [at |-> now, earliest |-> requiredAt,
                                 live |-> ~cancelled /\ now < OperationTimeout])
        /\ UNCHANGED <<now, retryAt, requiredAt, cancelled>>

Response == /\ phase = "request" /\ Live /\ now = responseAt
            /\ IF attempts > ThrottleResponses
               THEN /\ phase' = "succeeded"
                    /\ UNCHANGED <<retryAt, requiredAt>>
               ELSE IF RetryReads /\ attempts <= MaxRetries
                    THEN /\ phase' = "backoff"
                         /\ requiredAt' = now + Delay(attempts)
                         /\ retryAt' = now + (IF HonorRetryAfter THEN Delay(attempts)
                                              ELSE Backoff(attempts))
                    ELSE /\ phase' = "failed"
                         /\ UNCHANGED <<retryAt, requiredAt>>
            /\ UNCHANGED <<now, attempts, responseAt, cancelled, sent>>

Cancel == /\ CanCancel /\ Active /\ ~cancelled
          /\ cancelled' = TRUE
          /\ UNCHANGED <<now, phase, attempts, responseAt, retryAt, requiredAt, sent>>

Stop == /\ Active
        /\ (now = Deadline \/ (cancelled /\ HonorCancellation))
        /\ phase' = "stopped"
        /\ UNCHANGED <<now, attempts, responseAt, retryAt, requiredAt, cancelled, sent>>

Tick == /\ Active /\ Live
        /\ \/ (phase = "request" /\ now < responseAt)
           \/ (phase = "backoff" /\ now < retryAt)
        /\ now' = now + 1
        /\ UNCHANGED <<phase, attempts, responseAt, retryAt, requiredAt, cancelled, sent>>

Next == Send \/ Response \/ Cancel \/ Stop \/ Tick
Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

TypeOK == /\ now \in 0..OperationTimeout
          /\ phase \in {"ready", "request", "backoff", "succeeded", "failed", "stopped"}
          /\ attempts \in 0..(MaxRetries + 1)
          /\ responseAt \in Nat /\ retryAt \in Nat /\ requiredAt \in Nat
          /\ cancelled \in BOOLEAN
          /\ sent \in Seq([at : Nat, earliest : Nat, live : BOOLEAN])

RetryLimit == Len(sent) <= MaxRetries + 1
RespectRetryAfter == \A i \in 1..Len(sent) : sent[i].at >= sent[i].earliest
NoRequestsAfterCancellation == \A i \in 1..Len(sent) : sent[i].live
EventuallyTerminal == <>~Active
Recovery == (BudgetEnough /\ []~cancelled) => <>(phase = "succeeded")
NeverSucceeded == phase # "succeeded"
=============================================================================
