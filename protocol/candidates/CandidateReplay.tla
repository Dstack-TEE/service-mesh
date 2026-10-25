-------------------------- MODULE CandidateReplay --------------------------
EXTENDS Naturals, FiniteSets

(* Candidate callbacks are asynchronous. Local callbacks identify their auth;
   remote delivery captures an agent pointer while holding sess.mu, calls pion
   after unlocking, and the replacement replays the buffer. This model isolates
   one unchanged remote auth while replacing a local responder agent. It does
   not assert that old addresses are absent from an aborted ICE agent. *)
CONSTANTS GuardLocalAuth, CaptureAgent, ReplayCandidates
ASSUME /\ GuardLocalAuth \in BOOLEAN /\ CaptureAgent \in BOOLEAN
       /\ ReplayCandidates \in BOOLEAN

Agents == 1..2
Candidates == {"c1", "c2"}
Deliveries == [agent : Agents, candidate : Candidates]
LocalCandidates == [origin : Agents, candidate : Candidates]

VARIABLES localAuth, localCandidates, agent, buffer, pending, delivered,
          needsReplay, retargeted
vars == <<localAuth, localCandidates, agent, buffer, pending, delivered,
          needsReplay, retargeted>>

Init == /\ localAuth = 1 /\ localCandidates = {}
        /\ agent = 1 /\ buffer = {} /\ pending = {}
        /\ delivered = [a \in Agents |-> {}]
        /\ needsReplay = FALSE /\ retargeted = FALSE

LocalCallback(origin, c) ==
    /\ origin \in 1..localAuth /\ c \in Candidates
    /\ localCandidates' = IF GuardLocalAuth /\ origin # localAuth
         THEN localCandidates ELSE localCandidates \cup {[origin |-> origin, candidate |-> c]}
    /\ UNCHANGED <<localAuth, agent, buffer, pending, delivered, needsReplay, retargeted>>

NewLocalAuth == /\ localAuth = 1
                /\ localAuth' = 2 /\ localCandidates' = {}
                /\ UNCHANGED <<agent, buffer, pending, delivered, needsReplay, retargeted>>

Receive(c) ==
    /\ c \in Candidates
    /\ buffer' = buffer \cup {c}
    /\ pending' = IF c \in buffer THEN pending
         ELSE pending \cup {[agent |-> agent, candidate |-> c]}
    /\ UNCHANGED <<localAuth, localCandidates, agent, delivered, needsReplay, retargeted>>

ReplaceAgent == /\ agent = 1 /\ agent' = 2 /\ needsReplay' = TRUE
                /\ UNCHANGED <<localAuth, localCandidates, buffer, pending, delivered, retargeted>>

Replay ==
    /\ agent = 2 /\ needsReplay
    /\ pending' = IF ReplayCandidates THEN pending \cup
         {[agent |-> agent, candidate |-> c] : c \in buffer} ELSE pending
    /\ needsReplay' = FALSE
    /\ UNCHANGED <<localAuth, localCandidates, agent, buffer, delivered, retargeted>>

Deliver(d) ==
    /\ d \in pending
    /\ LET target == IF CaptureAgent THEN d.agent ELSE agent
       IN /\ delivered' = [delivered EXCEPT ![target] = @ \cup {d.candidate}]
          /\ retargeted' = (retargeted \/ target # d.agent)
    /\ pending' = pending \ {d}
    /\ UNCHANGED <<localAuth, localCandidates, agent, buffer, needsReplay>>

Next == \/ NewLocalAuth \/ ReplaceAgent \/ Replay
        \/ \E origin \in Agents, c \in Candidates : LocalCallback(origin, c)
        \/ \E c \in Candidates : Receive(c)
        \/ \E d \in Deliveries : Deliver(d)
Spec == Init /\ [][Next]_vars /\ WF_vars(Replay)
        /\ \A d \in Deliveries : WF_vars(Deliver(d))

TypeOK == /\ localAuth \in Agents /\ localCandidates \subseteq LocalCandidates
          /\ agent \in Agents /\ buffer \subseteq Candidates
          /\ pending \subseteq Deliveries
          /\ delivered \in [Agents -> SUBSET Candidates]
          /\ needsReplay \in BOOLEAN /\ retargeted \in BOOLEAN
LocalAuthIsolation == \A c \in localCandidates : c.origin = localAuth
CapturedAgentIsolation == ~retargeted
ReplayCoverage == (agent = 2 /\ ~needsReplay /\ pending = {}) => buffer \subseteq delivered[2]
EventuallyReplayed == (agent = 2) ~> (buffer \subseteq delivered[2])
NoSuccessfulReplay == ~(agent = 2 /\ buffer # {} /\ buffer \subseteq delivered[2])
=============================================================================
