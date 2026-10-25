----------------------------- MODULE Admission -----------------------------
EXTENDS Naturals, FiniteSets

(* One fresh nonce at one broker, concurrent attest requests, immutable pinned
   policy. A check result abstracts the real verifier/hash/policy predicate.
   Consume is atomic and occurs BEFORE the slow external verifier call.
   Expiry does not cancel requests which have already consumed the nonce. *)
CONSTANTS Requests, AtomicConsume, RequiredChecks
Checks == {"evidence", "reportData", "kms", "osImage", "workload"}
ASSUME /\ Requests # {} /\ AtomicConsume \in BOOLEAN
       /\ RequiredChecks \subseteq Checks

VARIABLES live, stage, results, granted, consumed
vars == <<live, stage, results, granted, consumed>>

Init == /\ live = TRUE
        /\ stage = [r \in Requests |-> "new"]
        /\ results \in [Requests -> SUBSET Checks]
        /\ granted = {} /\ consumed = {}

Consume(r) ==
    /\ stage[r] = "new" /\ live
    /\ stage' = [stage EXCEPT ![r] = "consumed"]
    /\ live' = IF AtomicConsume THEN FALSE ELSE live
    /\ consumed' = consumed \cup {r}
    /\ UNCHANGED <<results, granted>>

Verify(r) ==
    /\ stage[r] = "consumed"
    /\ stage' = [stage EXCEPT ![r] =
         IF RequiredChecks \subseteq results[r] THEN "verified" ELSE "rejected"]
    /\ UNCHANGED <<live, results, granted, consumed>>

Issue(r) == /\ stage[r] = "verified"
            /\ stage' = [stage EXCEPT ![r] = "issued"]
            /\ granted' = granted \cup {r}
            /\ UNCHANGED <<live, results, consumed>>

(* An external verifier/issuer error consumes the nonce but grants nothing. *)
ExternalFailure(r) ==
    /\ stage[r] \in {"consumed", "verified"}
    /\ stage' = [stage EXCEPT ![r] = "rejected"]
    /\ UNCHANGED <<live, results, granted, consumed>>

ExpireOrRestart == /\ live' = FALSE
                   /\ UNCHANGED <<stage, results, granted, consumed>>

Next == \/ \E r \in Requests : Consume(r) \/ Verify(r) \/ Issue(r) \/ ExternalFailure(r)
        \/ ExpireOrRestart
Spec == Init /\ [][Next]_vars
TypeOK == /\ live \in BOOLEAN
          /\ stage \in [Requests -> {"new", "consumed", "verified", "rejected", "issued"}]
          /\ results \in [Requests -> SUBSET Checks]
          /\ granted \subseteq Requests /\ consumed \subseteq Requests
AtMostOneConsumption == Cardinality(consumed) <= 1
AtMostOneGrant == Cardinality(granted) <= 1
AllChecksRequired == \A r \in granted : Checks \subseteq results[r]
GrantRequiresConsumption == granted \subseteq consumed
(* Expected to fail: authorized evidence must be capable of obtaining a token. *)
NoGrants == granted = {}
=============================================================================
