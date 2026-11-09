import Std

/-! The corrected ordered CAS scan, without deletion or replacement of owned
    slots. Historical requests are ghost state: any captured request may be
    delivered or replayed after an arbitrary reset. No finite-state bound or
    fairness premise is used. This is a protocol proof, not a runtime fix. -/

set_option autoImplicit false

namespace SlotAllocation

inductive Phase where
  | read | observed | ready | waiting | done | retired
  deriving DecidableEq, Repr

structure Client where
  ownerId : Nat
  cursor : Nat
  phase : Phase
  observed : Option Nat
  deriving DecidableEq, Repr

structure Request where
  ownerId : Nat
  slot : Nat
  deriving DecidableEq, Repr

structure State where
  store : Nat → Option Nat
  clients : Nat → Client
  history : List Request

def initial (instances : Nat → Nat) : State :=
  ⟨fun _ => none, fun c => ⟨instances c, 0, .read, none⟩, []⟩

def withClient (state : State) (id : Nat) (client : Client) : State :=
  { state with clients := fun c => if c = id then client else state.clients c }

def inserted (state : State) (request : Request) : State :=
  { state with store := fun slot =>
      if slot = request.slot then some request.ownerId else state.store slot }

def Prefix (store : Nat → Option Nat) (ownerId limit : Nat) : Prop :=
  ∀ slot, slot < limit → ∃ other, store slot = some other ∧ other ≠ ownerId

structure Invariant (state : State) : Prop where
  cursors : ∀ c, Prefix state.store (state.clients c).ownerId (state.clients c).cursor
  observations : ∀ c value, (state.clients c).phase = .observed →
    (state.clients c).observed = some value → state.store (state.clients c).cursor = some value
  requests : ∀ request ∈ state.history, Prefix state.store request.ownerId request.slot
  stored : ∀ slot ownerId, state.store slot = some ownerId → Prefix state.store ownerId slot

inductive Step : State → State → Prop where
  | reset (s : State) (c ownerId : Nat) :
      Step s (withClient s c ⟨ownerId, 0, .read, none⟩)
  | retire (s : State) (c : Nat) :
      Step s (withClient s c { s.clients c with phase := .retired })
  | read (s : State) (c : Nat) (phase : (s.clients c).phase = .read) :
      Step s (withClient s c { s.clients c with phase := .observed, observed := s.store (s.clients c).cursor })
  | prepare (s : State) (c : Nat) (phase : (s.clients c).phase = .observed)
      (empty : (s.clients c).observed = none) :
      Step s (withClient s c { s.clients c with phase := .ready })
  | advance (s : State) (c other : Nat) (phase : (s.clients c).phase = .observed)
      (occupied : (s.clients c).observed = some other) (foreign : other ≠ (s.clients c).ownerId) :
      Step s (withClient s c { s.clients c with cursor := (s.clients c).cursor + 1, phase := .read, observed := none })
  | capture (s : State) (c : Nat) (phase : (s.clients c).phase = .ready) :
      Step s (withClient { s with history := ⟨(s.clients c).ownerId, (s.clients c).cursor⟩ :: s.history }
        c { s.clients c with phase := .waiting })
  | recheck (s : State) (c : Nat) (phase : (s.clients c).phase = .waiting) :
      Step s (withClient s c { s.clients c with phase := .read, observed := none })
  | accept (s : State) (c : Nat) (phase : (s.clients c).phase = .observed)
      (own : (s.clients c).observed = some (s.clients c).ownerId) :
      Step s (withClient s c { s.clients c with phase := .done })
  | commit (s : State) (request : Request) (captured : request ∈ s.history)
      (empty : s.store request.slot = none) : Step s (inserted s request)
  | stutter (s : State) : Step s s

theorem prefix_zero (store : Nat → Option Nat) (ownerId : Nat) : Prefix store ownerId 0 := by
  intro slot impossible
  omega

theorem initial_invariant (instances : Nat → Nat) : Invariant (initial instances) := by
  constructor
  · intro c
    exact prefix_zero _ _
  · intro c value phase
    cases phase
  · simp [initial]
  · simp [initial]

theorem replace_client_preserves (s : State) (c : Nat) (client : Client)
    (valid : Invariant s) (earlier : Prefix s.store client.ownerId client.cursor)
    (observation : ∀ value, client.phase = .observed →
      client.observed = some value → s.store client.cursor = some value) :
    Invariant (withClient s c client) := by
  constructor
  · intro id
    by_cases same : id = c
    · simpa [withClient, same] using earlier
    · simpa [withClient, same] using valid.cursors id
  · intro id value
    by_cases same : id = c
    · simpa [withClient, same] using observation value
    · simpa [withClient, same] using valid.observations id value
  · exact valid.requests
  · exact valid.stored

theorem insertion_preserves_existing (s : State) (request : Request)
    (empty : s.store request.slot = none) (slot ownerId : Nat)
    (existing : s.store slot = some ownerId) :
    (inserted s request).store slot = some ownerId := by
  by_cases same : slot = request.slot
  · subst slot
    rw [empty] at existing
    cases existing
  · simp [inserted, same, existing]

theorem prefix_preserved_by_insertion (s : State) (request : Request)
    (empty : s.store request.slot = none) (ownerId limit : Nat)
    (earlier : Prefix s.store ownerId limit) :
    Prefix (inserted s request).store ownerId limit := by
  intro slot smaller
  obtain ⟨other, existing, foreign⟩ := earlier slot smaller
  exact ⟨other, insertion_preserves_existing _ _ empty _ _ existing, foreign⟩

theorem commit_preserves (s : State) (request : Request)
    (valid : Invariant s) (captured : request ∈ s.history)
    (empty : s.store request.slot = none) : Invariant (inserted s request) := by
  constructor
  · intro c
    exact prefix_preserved_by_insertion s request empty _ _ (valid.cursors c)
  · intro c value phase observed
    exact insertion_preserves_existing s request empty _ _
      (valid.observations c value phase observed)
  · intro old member
    exact prefix_preserved_by_insertion s request empty _ _ (valid.requests old member)
  · intro slot ownerId occupied
    by_cases same : slot = request.slot
    · subst slot
      have instanceEq : request.ownerId = ownerId := by
        simpa [inserted] using occupied
      subst ownerId
      exact prefix_preserved_by_insertion s request empty _ _ (valid.requests request captured)
    · have old : s.store slot = some ownerId := by simpa [inserted, same] using occupied
      exact prefix_preserved_by_insertion s request empty _ _ (valid.stored _ _ old)

theorem advance_preserves (s : State) (c other : Nat) (valid : Invariant s)
    (phase : (s.clients c).phase = .observed)
    (occupied : (s.clients c).observed = some other) (foreign : other ≠ (s.clients c).ownerId) :
    Invariant (withClient s c { s.clients c with cursor := (s.clients c).cursor + 1, phase := .read, observed := none }) := by
  apply replace_client_preserves _ _ _ valid
  · intro slot smaller
    change slot < (s.clients c).cursor + 1 at smaller
    by_cases before : slot < (s.clients c).cursor
    · exact valid.cursors c slot before
    · have same : slot = (s.clients c).cursor := by omega
      subst slot
      exact ⟨other, valid.observations c other phase occupied, foreign⟩
  · intro value impossible
    cases impossible

theorem capture_preserves (s : State) (c : Nat) (valid : Invariant s) :
    Invariant (withClient { s with history := ⟨(s.clients c).ownerId, (s.clients c).cursor⟩ :: s.history }
      c { s.clients c with phase := .waiting }) := by
  have historyValid : Invariant { s with history :=
      ⟨(s.clients c).ownerId, (s.clients c).cursor⟩ :: s.history } := by
    constructor
    · exact valid.cursors
    · exact valid.observations
    · intro request member
      simp only [List.mem_cons] at member
      rcases member with rfl | old
      · exact valid.cursors c
      · exact valid.requests request old
    · exact valid.stored
  apply replace_client_preserves _ _ _ historyValid
  · exact valid.cursors c
  · intro value impossible
    cases impossible

theorem step_preserves {s t : State} (valid : Invariant s) (step : Step s t) : Invariant t := by
  cases step with
  | reset c ownerId =>
      apply replace_client_preserves _ _ _ valid (prefix_zero _ _)
      intro value impossible
      cases impossible
  | retire c =>
      apply replace_client_preserves _ _ _ valid
      · exact valid.cursors c
      · intro value impossible
        cases impossible
  | read c phase =>
      apply replace_client_preserves _ _ _ valid
      · exact valid.cursors c
      · intro value _ observed
        exact observed
  | prepare c phase empty =>
      apply replace_client_preserves _ _ _ valid
      · exact valid.cursors c
      · intro value impossible
        cases impossible
  | advance c other phase occupied foreign =>
      exact advance_preserves _ _ _ valid phase occupied foreign
  | capture c phase => exact capture_preserves s c valid
  | recheck c phase =>
      apply replace_client_preserves _ _ _ valid
      · exact valid.cursors c
      · intro value impossible
        cases impossible
  | accept c phase own =>
      apply replace_client_preserves _ _ _ valid
      · exact valid.cursors c
      · intro value impossible
        cases impossible
  | commit request captured empty => exact commit_preserves s request valid captured empty
  | stutter => exact valid

theorem trace_invariant (instances : Nat → Nat) (trace : Nat → State)
    (start : trace 0 = initial instances) (steps : ∀ n, Step (trace n) (trace (n + 1))) :
    ∀ n, Invariant (trace n) := by
  intro n
  induction n with
  | zero => rw [start]; exact initial_invariant instances
  | succ n ih => exact step_preserves ih (steps n)

theorem one_slot_per_instance (state : State) (valid : Invariant state)
    (ownerId a b : Nat) (first : state.store a = some ownerId) (second : state.store b = some ownerId) :
    a = b := by
  by_cases smaller : a < b
  · obtain ⟨other, seen, foreign⟩ := valid.stored b ownerId second a smaller
    have same : other = ownerId := Option.some.inj (seen.symm.trans first)
    exact False.elim (foreign same)
  · by_cases same : a = b
    · exact same
    · have smaller : b < a := by omega
      obtain ⟨other, seen, foreign⟩ := valid.stored a ownerId first b smaller
      have equal : other = ownerId := Option.some.inj (seen.symm.trans second)
      exact False.elim (foreign equal)

theorem corrected_allocation_never_duplicates (instances : Nat → Nat) (trace : Nat → State)
    (start : trace 0 = initial instances) (steps : ∀ n, Step (trace n) (trace (n + 1))) :
    ∀ n ownerId a b, (trace n).store a = some ownerId →
      (trace n).store b = some ownerId → a = b := by
  intro n ownerId a b first second
  exact one_slot_per_instance _ (trace_invariant instances trace start steps n) _ _ _ first second

inductive Reachable (instances : Nat → Nat) : State → Prop where
  | initial : Reachable instances (initial instances)
  | step {s t : State} : Reachable instances s → Step s t → Reachable instances t

theorem reachable_invariant {instances : Nat → Nat} {state : State}
    (reachable : Reachable instances state) : Invariant state := by
  induction reachable with
  | initial => exact initial_invariant instances
  | step _ transition ih => exact step_preserves ih transition

theorem old_request_can_commit_after_reset (ownerId : Nat) :
    ∃ state, Reachable (fun _ => ownerId) state ∧ state.store 0 = some ownerId ∧
      (state.clients 0).phase = .read ∧ ⟨ownerId, 0⟩ ∈ state.history := by
  let s0 := initial (fun _ => ownerId)
  let s1 := withClient s0 0 { s0.clients 0 with phase := .observed, observed := s0.store 0 }
  let s2 := withClient s1 0 { s1.clients 0 with phase := .ready }
  let request : Request := ⟨ownerId, 0⟩
  let s3 := withClient { s2 with history := request :: s2.history } 0
    { s2.clients 0 with phase := .waiting }
  let s4 := withClient s3 0 ⟨ownerId, 0, .read, none⟩
  have h1 : Reachable (fun _ => ownerId) s1 := .step .initial (.read s0 0 rfl)
  have h2 : Reachable (fun _ => ownerId) s2 := .step h1 (.prepare s1 0 rfl rfl)
  have h3 : Reachable (fun _ => ownerId) s3 := .step h2 (.capture s2 0 rfl)
  have h4 : Reachable (fun _ => ownerId) s4 := .step h3 (.reset s3 0 ownerId)
  have member : request ∈ s4.history := by simp [s4, s3, withClient]
  have empty : s4.store request.slot = none := rfl
  refine ⟨inserted s4 request, .step h4 (.commit s4 request member empty), ?_, rfl, member⟩
  simp [inserted, request]

end SlotAllocation
