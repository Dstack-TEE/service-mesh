import Std

/-! Normalized, immutable admission policy. Cryptographic evidence validation,
    JSON decoding, ACL evaluation, and implementation refinement are separate
    contracts. Lists and identifier spaces have no size bound. -/

set_option autoImplicit false

namespace AdmissionPolicy

structure KeyProvider where
  name : String
  id : String
  deriving DecidableEq, Repr

inductive Permission where
  | serviceIdentity (service : String)
  | nodeIdentity (peer cluster : String)
  | agentRead (peer : String)
  | serviceWrite (service : String)
  | keyPrefixWrite (keyPrefix : String)
  | allSessionsWrite
  deriving DecidableEq, Repr

structure Permissions where
  serviceIdentity : Option String := none
  serviceNames : List String := []
  keyPrefixes : List String := []
  sessionWrite : Bool := false
  agentReadSelf : Bool := false
  nodeIdentitySelf : Bool := false
  deriving DecidableEq, Repr

structure Workload where
  id : String
  identity : String
  peer : Option String
  composes : List String
  permissions : Permissions
  deriving DecidableEq, Repr

structure Policy where
  cluster : String
  kms : Option KeyProvider
  os : Option String
  rows : List Workload
  deriving DecidableEq, Repr

structure Request where
  identity : String
  peer : String
  deriving DecidableEq, Repr

structure Evidence where
  compose : String
  kms : Option KeyProvider
  os : Option String
  osVerified : Bool
  deriving DecidableEq, Repr

structure Grant where
  workload : String
  rights : List Permission
  deriving DecidableEq, Repr

def peerMatches (row : Workload) (request : Request) : Bool :=
  row.peer.isNone || decide (row.peer = some request.peer)

def rowMatches (row : Workload) (request : Request) (evidence : Evidence) : Bool :=
  decide (row.identity = request.identity) && row.composes.contains evidence.compose &&
    peerMatches row request

def profileMatches (policy : Policy) (evidence : Evidence) : Bool :=
  (match policy.kms with
    | none => true
    | some key => decide (evidence.kms = some key)) &&
  (match policy.os with
    | none => true
    | some image => evidence.osVerified && decide (evidence.os = some image))

def select (rows : List Workload) (request : Request) (evidence : Evidence) : Option Workload :=
  rows.find? (fun row => rowMatches row request evidence)

def selectIndexed (rows : List Workload) (request : Request) (evidence : Evidence) : Option Workload :=
  (rows.filter (fun row => decide (row.identity = request.identity))).find?
    (fun row => row.composes.contains evidence.compose && peerMatches row request)

def rights (permissions : Permissions) (peer cluster : String) : List Permission :=
  permissions.serviceIdentity.toList.map Permission.serviceIdentity ++
  (if permissions.nodeIdentitySelf then [Permission.nodeIdentity peer cluster] else []) ++
  (if permissions.agentReadSelf then [Permission.agentRead peer] else []) ++
  permissions.serviceNames.map Permission.serviceWrite ++
  permissions.keyPrefixes.map Permission.keyPrefixWrite ++
  (if permissions.sessionWrite then [Permission.allSessionsWrite] else [])

def grantFor (policy : Policy) (request : Request) (row : Workload) : Grant :=
  ⟨row.id, rights row.permissions request.peer policy.cluster⟩

def authorize (policy : Policy) (request : Request) (evidence : Evidence) : Option Grant :=
  if profileMatches policy evidence then
    (select policy.rows request evidence).map (grantFor policy request)
  else none

theorem peer_matches_spec (row : Workload) (request : Request) :
    peerMatches row request = true ↔ row.peer = none ∨ row.peer = some request.peer := by
  simp [peerMatches]

theorem row_matches_spec (row : Workload) (request : Request) (evidence : Evidence) :
    rowMatches row request evidence = true ↔
      row.identity = request.identity ∧ evidence.compose ∈ row.composes ∧
      (row.peer = none ∨ row.peer = some request.peer) := by
  simp [rowMatches, peer_matches_spec, Bool.and_assoc]

theorem profile_matches_spec (policy : Policy) (evidence : Evidence) :
    profileMatches policy evidence = true ↔
      (∀ key, policy.kms = some key → evidence.kms = some key) ∧
      (∀ image, policy.os = some image → evidence.osVerified = true ∧ evidence.os = some image) := by
  cases hk : policy.kms <;> cases ho : policy.os <;> simp [profileMatches, hk, ho]

theorem identity_index_preserves_selection
    (rows : List Workload) (request : Request) (evidence : Evidence) :
    selectIndexed rows request evidence = select rows request evidence := by
  simp [selectIndexed, select, List.find?_filter, rowMatches, Bool.and_assoc]

theorem selected_is_one_matching_row
    (rows : List Workload) (request : Request) (evidence : Evidence) (row : Workload)
    (selected : select rows request evidence = some row) :
    row ∈ rows ∧ rowMatches row request evidence = true := by
  exact ⟨List.mem_of_find?_eq_some (p := fun r => rowMatches r request evidence) selected,
    List.find?_some (p := fun r => rowMatches r request evidence) selected⟩

theorem selection_is_first_match
    (rows : List Workload) (request : Request) (evidence : Evidence) (row : Workload) :
    select rows request evidence = some row ↔
      rowMatches row request evidence = true ∧
      ∃ before after, rows = before ++ row :: after ∧
        ∀ previous ∈ before, rowMatches previous request evidence = false := by
  simpa [select] using (List.find?_eq_some_iff_append
    (xs := rows) (p := fun r => rowMatches r request evidence) (b := row))

theorem rejection_iff_no_matching_row
    (rows : List Workload) (request : Request) (evidence : Evidence) :
    select rows request evidence = none ↔
      ∀ row ∈ rows, rowMatches row request evidence = false := by
  simp [select]

theorem authorization_iff
    (policy : Policy) (request : Request) (evidence : Evidence) (grant : Grant) :
    authorize policy request evidence = some grant ↔
      profileMatches policy evidence = true ∧
      ∃ row, select policy.rows request evidence = some row ∧
        grantFor policy request row = grant := by
  cases h : profileMatches policy evidence <;> simp [authorize, h]

theorem authorization_sound
    (policy : Policy) (request : Request) (evidence : Evidence) (grant : Grant)
    (accepted : authorize policy request evidence = some grant) :
    profileMatches policy evidence = true ∧
      ∃ row ∈ policy.rows,
        row.identity = request.identity ∧ evidence.compose ∈ row.composes ∧
        (row.peer = none ∨ row.peer = some request.peer) ∧
        grant.workload = row.id ∧
        grant.rights = rights row.permissions request.peer policy.cluster := by
  obtain ⟨profile, row, selected, rfl⟩ := (authorization_iff ..).mp accepted
  obtain ⟨member, matching⟩ := selected_is_one_matching_row _ _ _ _ selected
  obtain ⟨identity, compose, peer⟩ := (row_matches_spec ..).mp matching
  exact ⟨profile, row, member, identity, compose, peer, rfl, rfl⟩

theorem authorization_rejection_iff
    (policy : Policy) (request : Request) (evidence : Evidence) :
    authorize policy request evidence = none ↔
      profileMatches policy evidence = false ∨
      ∀ row ∈ policy.rows, rowMatches row request evidence = false := by
  cases h : profileMatches policy evidence <;>
    simp [authorize, h, rejection_iff_no_matching_row]

theorem pinned_kms_required
    (policy : Policy) (request : Request) (evidence : Evidence) (key : KeyProvider)
    (pinned : policy.kms = some key) (mismatch : evidence.kms ≠ some key) :
    authorize policy request evidence = none := by
  apply (authorization_rejection_iff ..).mpr
  left
  simp [profileMatches, pinned, mismatch]

theorem pinned_os_requires_verification
    (policy : Policy) (request : Request) (evidence : Evidence) (image : String)
    (pinned : policy.os = some image) (unverified : evidence.osVerified = false) :
    authorize policy request evidence = none := by
  apply (authorization_rejection_iff ..).mpr
  left
  simp [profileMatches, pinned, unverified]

theorem pinned_os_rejects_mismatch
    (policy : Policy) (request : Request) (evidence : Evidence) (image : String)
    (pinned : policy.os = some image) (mismatch : evidence.os ≠ some image) :
    authorize policy request evidence = none := by
  apply (authorization_rejection_iff ..).mpr
  left
  simp [profileMatches, pinned, mismatch]

theorem disabled_profile_accepts_any_measurements
    (policy : Policy) (evidence : Evidence)
    (noKMS : policy.kms = none) (noOS : policy.os = none) :
    profileMatches policy evidence = true := by
  simp [profileMatches, noKMS, noOS]

theorem wildcard_matches_any_peer
    (row : Workload) (request : Request) (wildcard : row.peer = none) :
    peerMatches row request = true := by
  simp [peerMatches, wildcard]

theorem pinned_peer_cannot_be_retargeted
    (row : Workload) (request : Request) (evidence : Evidence) (peer : String)
    (pinned : row.peer = some peer) (other : peer ≠ request.peer) :
    rowMatches row request evidence = false := by
  simp [rowMatches, peerMatches, pinned, other]

theorem first_matching_row_controls_overlap
    (wildcard exactRow : Workload) (request : Request) (evidence : Evidence)
    (broad : rowMatches wildcard request evidence = true)
    (narrow : rowMatches exactRow request evidence = true) :
    select [wildcard, exactRow] request evidence = some wildcard ∧
      select [exactRow, wildcard] request evidence = some exactRow := by
  simp [select, broad, narrow]

theorem self_node_identity_is_confined
    (permissions : Permissions) (requestPeer cluster peer targetCluster : String)
    (member : Permission.nodeIdentity peer targetCluster ∈ rights permissions requestPeer cluster) :
    peer = requestPeer ∧ targetCluster = cluster := by
  simp [rights] at member
  exact member.2

theorem self_agent_read_is_confined
    (permissions : Permissions) (requestPeer cluster peer : String)
    (member : Permission.agentRead peer ∈ rights permissions requestPeer cluster) :
    peer = requestPeer := by
  simp [rights] at member
  exact member.2

theorem issued_node_identity_is_confined
    (policy : Policy) (request : Request) (evidence : Evidence) (grant : Grant)
    (peer cluster : String)
    (accepted : authorize policy request evidence = some grant)
    (member : Permission.nodeIdentity peer cluster ∈ grant.rights) :
    peer = request.peer ∧ cluster = policy.cluster := by
  obtain ⟨_, row, _, _, _, _, _, scope⟩ := authorization_sound _ _ _ _ accepted
  rw [scope] at member
  exact self_node_identity_is_confined row.permissions _ _ _ _ member

theorem issued_agent_read_is_confined
    (policy : Policy) (request : Request) (evidence : Evidence) (grant : Grant)
    (peer : String)
    (accepted : authorize policy request evidence = some grant)
    (member : Permission.agentRead peer ∈ grant.rights) :
    peer = request.peer := by
  obtain ⟨_, row, _, _, _, _, _, scope⟩ := authorization_sound _ _ _ _ accepted
  rw [scope] at member
  exact self_agent_read_is_confined row.permissions _ _ _ member

/- Concrete, kernel-checked counterexamples to stronger but incorrect policy
   interpretations. These are witnesses about the specified policy rules. -/
def demoRequest : Request := ⟨"service", "peer-1"⟩
def demoEvidence : Evidence :=
  ⟨"1111111111111111111111111111111111111111111111111111111111111111", none, none, false⟩
def broadRow : Workload :=
  ⟨"broad", "service", none, [demoEvidence.compose], { serviceNames := ["admin"] }⟩
def exactRow : Workload :=
  ⟨"exact", "service", some "peer-1", [demoEvidence.compose], { serviceNames := ["reader"] }⟩
def demoPolicy (rows : List Workload) : Policy := ⟨"cluster", none, none, rows⟩

theorem wildcard_shadowing_changes_grant :
    authorize (demoPolicy [broadRow, exactRow]) demoRequest demoEvidence ≠
      authorize (demoPolicy [exactRow, broadRow]) demoRequest demoEvidence := by
  decide

def wrongIdentityRow : Workload :=
  ⟨"other", "other-service", some "peer-1", [demoEvidence.compose], { serviceNames := ["reader"] }⟩
def wrongRevisionRow : Workload :=
  ⟨"old", "service", some "peer-1",
    ["2222222222222222222222222222222222222222222222222222222222222222"],
    { serviceNames := ["reader"] }⟩

theorem cross_row_evidence_mixing_is_rejected :
    (∃ row ∈ [wrongIdentityRow, wrongRevisionRow], row.identity = demoRequest.identity) ∧
    (∃ row ∈ [wrongIdentityRow, wrongRevisionRow], demoEvidence.compose ∈ row.composes) ∧
    (∃ row ∈ [wrongIdentityRow, wrongRevisionRow], row.peer = some demoRequest.peer) ∧
    authorize (demoPolicy [wrongIdentityRow, wrongRevisionRow]) demoRequest demoEvidence = none := by
  decide

theorem authorized_shared_revision_peers_are_distinct :
    authorize (demoPolicy [exactRow]) demoRequest demoEvidence ≠ none ∧
    authorize (demoPolicy [exactRow]) { demoRequest with peer := "peer-2" } demoEvidence = none := by
  decide

end AdmissionPolicy
