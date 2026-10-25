--------------------------- MODULE OfferAnswer ---------------------------
EXTENDS Naturals, FiniteSets

(* Pairwise offer/answer protocol after authenticated snapshot delivery.
   Revisions of identical auth are folded into repeated deliveries. Versions
   below order AUTH CHANGES, not HTTP refreshes or wall time. Process restarts
   and Lamport recovery belong to SnapshotStore, not this model.
   Candidate gathering and successful direct ICE/QUIC are an environment
   action; this model does not prove the ICE or QUIC implementation. *)
CONSTANTS MaxOffers, MaxAnswers, CheckOfferBinding
ASSUME /\ MaxOffers > 0 /\ MaxAnswers > 0
       /\ CheckOfferBinding \in BOOLEAN

None == [offer |-> 0, generation |-> 0]
Answers == [offer : 1..MaxOffers, generation : 1..MaxAnswers]
Rank(a) == a.offer * (MaxAnswers + 1) + a.generation

VARIABLES offer, responderSeen, responderOffer, responderGeneration,
          publishedAnswers, initiatorSeen, remoteAnswer, up, duplicateDisruption
vars == <<offer, responderSeen, responderOffer, responderGeneration,
          publishedAnswers, initiatorSeen, remoteAnswer, up, duplicateDisruption>>

CurrentAnswer == [offer |-> responderOffer, generation |-> responderGeneration]
Init == /\ offer = 1 /\ responderSeen = 0
        /\ responderOffer = 0 /\ responderGeneration = 0
        /\ publishedAnswers = {} /\ initiatorSeen = 0
        /\ remoteAnswer = None /\ up = FALSE /\ duplicateDisruption = FALSE

DeliverOffer(o) ==
    /\ o \in 1..offer
    /\ responderSeen' = IF o > responderSeen THEN o ELSE responderSeen
    /\ up' = IF o > responderSeen THEN FALSE ELSE up
    /\ UNCHANGED <<offer, responderOffer, responderGeneration,
                   publishedAnswers, initiatorSeen, remoteAnswer, duplicateDisruption>>

(* The responder waits for an offer, then echoes its ID in a fresh answer. *)
Answer == /\ responderSeen # 0 /\ responderSeen # responderOffer
          /\ responderOffer' = responderSeen /\ responderGeneration' = 1
          /\ publishedAnswers' = publishedAnswers \cup
               {[offer |-> responderSeen, generation |-> 1]}
          /\ up' = FALSE
          /\ UNCHANGED <<offer, responderSeen, initiatorSeen, remoteAnswer,
                         duplicateDisruption>>

DeliverAnswer(a) ==
    /\ a \in publishedAnswers
    /\ LET fresh == Rank(a) >= initiatorSeen
           matches == ~CheckOfferBinding \/ a.offer = offer
           applied == fresh /\ matches
           changed == applied /\ a # remoteAnswer
           newUp == IF changed THEN FALSE ELSE up
       IN /\ initiatorSeen' = IF fresh THEN Rank(a) ELSE initiatorSeen
          /\ remoteAnswer' = IF applied THEN a ELSE remoteAnswer
          /\ up' = newUp
          /\ duplicateDisruption' = (duplicateDisruption \/
                (up /\ a = remoteAnswer /\ ~newUp))
    /\ UNCHANGED <<offer, responderSeen, responderOffer,
                   responderGeneration, publishedAnswers>>

(* Bounded local transport failures create fresh auth. They may occur before
   or after connection. Finite budgets imply failures eventually stop. *)
RetryInitiator == /\ offer < MaxOffers
                  /\ offer' = offer + 1 /\ remoteAnswer' = None /\ up' = FALSE
                  /\ UNCHANGED <<responderSeen, responderOffer, responderGeneration,
                                 publishedAnswers, initiatorSeen, duplicateDisruption>>

RetryResponder ==
    /\ responderOffer # 0 /\ responderGeneration < MaxAnswers
    /\ responderOffer = responderSeen
    /\ responderGeneration' = responderGeneration + 1
    /\ publishedAnswers' = publishedAnswers \cup
         {[offer |-> responderOffer, generation |-> responderGeneration + 1]}
    /\ up' = FALSE
    /\ UNCHANGED <<offer, responderSeen, responderOffer, initiatorSeen,
                   remoteAnswer, duplicateDisruption>>

(* Successful ICE requires both live agents to agree on offer and credentials.
   Success is assumed possible on a viable direct path, never via a relay. *)
Connect == /\ responderOffer = offer /\ responderSeen = offer
           /\ remoteAnswer = CurrentAnswer /\ remoteAnswer # None
           /\ up' = TRUE
           /\ UNCHANGED <<offer, responderSeen, responderOffer,
                          responderGeneration, publishedAnswers, initiatorSeen,
                          remoteAnswer, duplicateDisruption>>

ReceiveCurrentOffer == DeliverOffer(offer)
ReceiveCurrentAnswer == DeliverAnswer(CurrentAnswer)
Next == \/ \E o \in 1..offer : DeliverOffer(o)
        \/ \E a \in publishedAnswers : DeliverAnswer(a)
        \/ Answer \/ RetryInitiator \/ RetryResponder \/ Connect
UnfairSpec == Init /\ [][Next]_vars
Spec == UnfairSpec
        /\ WF_vars(ReceiveCurrentOffer) /\ WF_vars(Answer)
        /\ WF_vars(ReceiveCurrentAnswer) /\ WF_vars(Connect)

TypeOK == /\ offer \in 1..MaxOffers /\ responderSeen \in 0..MaxOffers
          /\ responderOffer \in 0..MaxOffers
          /\ responderGeneration \in 0..MaxAnswers
          /\ publishedAnswers \subseteq Answers
          /\ initiatorSeen \in 0..(MaxOffers * (MaxAnswers + 1) + MaxAnswers)
          /\ remoteAnswer \in Answers \cup {None}
          /\ up \in BOOLEAN /\ duplicateDisruption \in BOOLEAN
AnswerBinding == remoteAnswer = None \/ remoteAnswer.offer = offer
ConnectedAgreement == up =>
    /\ responderOffer = offer /\ responderSeen = offer
    /\ remoteAnswer = CurrentAnswer
DuplicateStability == ~duplicateDisruption
EventuallyConnected == <>[]up
(* Expected to fail: connection must actually be reachable. *)
NeverConnected == ~up
=============================================================================
