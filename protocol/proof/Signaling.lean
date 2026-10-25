import Std

/-! Protocol-level proofs over unbounded natural-number traces.
    Authentication and fresh identifiers are primitive assumptions.
    No implementation or attestation theorem is claimed here. -/

set_option autoImplicit false
set_option maxRecDepth 4096
set_option maxHeartbeats 4000000

namespace Signaling

def Eventually (p : Nat → Prop) : Prop := ∃ start, ∀ t, start ≤ t → p t
def InfOften (p : Nat → Prop) : Prop := ∀ start, ∃ t, start ≤ t ∧ p t

theorem monotone_suffix (f : Nat → Nat) (start : Nat)
    (step : ∀ t, start ≤ t → f t ≤ f (t + 1))
    {a b : Nat} (ha : start ≤ a) (hab : a ≤ b) : f a ≤ f b := by
  induction b with
  | zero =>
      have h : a = 0 := by omega
      subst a
      exact Nat.le_refl _
  | succ b ih =>
      by_cases h : a ≤ b
      · exact Nat.le_trans (ih h) (step b (by omega))
      · have heq : a = b + 1 := by omega
        subst a
        exact Nat.le_refl _

theorem constant_suffix {α : Type} (f : Nat → α) (start : Nat)
    (step : ∀ t, start ≤ t → f (t + 1) = f t) :
    ∀ t, start ≤ t → f t = f start := by
  have aux : ∀ d, f (start + d) = f start := by
    intro d
    induction d with
    | zero => simp
    | succ d ih =>
        rw [show start + (d + 1) = (start + d) + 1 by omega]
        exact (step (start + d) (by omega)).trans ih
  intro t ht
  have heq : start + (t - start) = t := by omega
  rw [← heq]
  exact aux (t - start)

theorem eventually_and (p q : Nat → Prop)
    (hp : Eventually p) (hq : Eventually q) : Eventually (fun t => p t ∧ q t) := by
  obtain ⟨a, ha⟩ := hp
  obtain ⟨b, hb⟩ := hq
  refine ⟨max a b, ?_⟩
  intro t ht
  exact ⟨ha t (by omega), hb t (by omega)⟩

theorem eventually_finite (n : Nat) (p : Fin n → Nat → Prop)
    (each : ∀ i, Eventually (p i)) : Eventually (fun t => ∀ i, p i t) := by
  induction n with
  | zero => exact ⟨0, fun _ _ i => Fin.elim0 i⟩
  | succ n ih =>
      obtain ⟨a, ha⟩ := each 0
      obtain ⟨b, hb⟩ := ih (fun i => p i.succ) (fun i => each i.succ)
      refine ⟨max a b, ?_⟩
      intro t ht i
      exact Fin.cases (ha t (by omega)) (fun j => hb t (by omega) j) i

/- Version selection is the exact lexicographic (clock, boot) operation. -/
structure Version where
  clock : Nat
  boot : Nat
  deriving DecidableEq, Repr

def Newer (a b : Version) : Prop :=
  b.clock < a.clock ∨ (a.clock = b.clock ∧ b.boot < a.boot)

def VersionLE (a b : Version) : Prop :=
  a.clock < b.clock ∨ (a.clock = b.clock ∧ a.boot ≤ b.boot)

instance (a b : Version) : Decidable (Newer a b) := inferInstanceAs
  (Decidable (b.clock < a.clock ∨ (a.clock = b.clock ∧ b.boot < a.boot)))

def pick (incoming old : Version) : Version := if Newer incoming old then incoming else old

theorem version_refl (a : Version) : VersionLE a a := by
  simp [VersionLE]

theorem version_trans {a b c : Version}
    (hab : VersionLE a b) (hbc : VersionLE b c) : VersionLE a c := by
  unfold VersionLE at *
  omega

theorem version_total (a b : Version) : VersionLE a b ∨ VersionLE b a := by
  unfold VersionLE
  omega

theorem pick_ge_old (incoming old : Version) : VersionLE old (pick incoming old) := by
  unfold pick
  split
  · unfold Newer at *
    unfold VersionLE
    omega
  · exact version_refl old

theorem pick_ge_incoming (incoming old : Version) : VersionLE incoming (pick incoming old) := by
  unfold pick
  split
  · exact version_refl incoming
  · unfold Newer at *
    unfold VersionLE
    omega

theorem pick_idempotent (a : Version) : pick a a = a := by
  simp [pick, Newer]

theorem clock_dominates_boot (a b : Version) (h : b.clock < a.clock) :
    Newer a b := Or.inl h

/- Publish increments; every valid received record, including one's own old
   incarnation, takes a maximum. Restart is allowed in the arbitrary prefix. -/
inductive ClockEvent where
  | publish
  | receive (observed : Nat)
  | idle
  deriving DecidableEq, Repr

def clockNext (clock : Nat) : ClockEvent → Nat
  | .publish => clock + 1
  | .receive observed => max clock observed
  | .idle => clock

theorem clockNext_mono (c : Nat) (e : ClockEvent) : c ≤ clockNext c e := by
  cases e <;> simp [clockNext] <;> omega

theorem clock_receive_covers (c seen : Nat) : seen ≤ clockNext c (.receive seen) := by
  simp [clockNext]
  omega

theorem publish_above_observation (c seen : Nat) :
    seen < clockNext (clockNext c (.receive seen)) .publish := by
  simp [clockNext]
  omega

theorem monotone_progress_unbounded (clock : Nat → Nat) (start : Nat)
    (mono : ∀ t, start ≤ t → clock t ≤ clock (t + 1))
    (progress : ∀ t, start ≤ t → ∃ u, t ≤ u ∧ clock t < clock u) :
    ∀ bound, Eventually (fun t => bound < clock t) := by
  have grows : ∀ k, ∃ t, start ≤ t ∧ k ≤ clock t := by
    intro k
    induction k with
    | zero => exact ⟨start, Nat.le_refl _, Nat.zero_le _⟩
    | succ k ih =>
        obtain ⟨t, ht, hvalue⟩ := ih
        obtain ⟨u, htu, hinc⟩ := progress t ht
        exact ⟨u, by omega, by omega⟩
  intro bound
  obtain ⟨t, ht, hvalue⟩ := grows (bound + 1)
  refine ⟨t, ?_⟩
  intro u htu
  have hm := monotone_suffix clock start mono ht htu
  omega

theorem publication_clock_unbounded
    (clock : Nat → Nat) (event : Nat → ClockEvent) (start : Nat)
    (run : ∀ t, start ≤ t → clock (t + 1) = clockNext (clock t) (event t))
    (publishes : InfOften (fun t => start ≤ t ∧ event t = .publish)) :
    ∀ obsoleteBound, Eventually (fun t => obsoleteBound < clock t) := by
  have mono : ∀ t, start ≤ t → clock t ≤ clock (t + 1) := by
    intro t ht
    rw [run t ht]
    exact clockNext_mono _ _
  apply monotone_progress_unbounded clock start mono
  intro t ht
  obtain ⟨u, htu, hu, hevent⟩ := publishes t
  have hmono := monotone_suffix clock start mono ht htu
  have hpublish : clock (u + 1) = clock u + 1 := by
    rw [run u hu, hevent]
    rfl
  exact ⟨u + 1, by omega, by omega⟩

def prefixMax (f : Nat → Nat) : Nat → Nat
  | 0 => f 0
  | n + 1 => max (prefixMax f n) (f (n + 1))

theorem prefixMax_covers (f : Nat → Nat) {t cutoff : Nat} (ht : t ≤ cutoff) :
    f t ≤ prefixMax f cutoff := by
  induction cutoff with
  | zero =>
      have heq : t = 0 := by omega
      subst t
      exact Nat.le_refl _
  | succ cutoff ih =>
      by_cases h : t ≤ cutoff
      · have hp := ih h
        simp only [prefixMax]
        omega
      · have heq : t = cutoff + 1 := by omega
        subst t
        simp only [prefixMax]
        omega

theorem restart_clock_dominates_all_obsolete
    (clock : Nat → Nat) (event : Nat → ClockEvent) (cutoff : Nat)
    (run : ∀ t, cutoff ≤ t → clock (t + 1) = clockNext (clock t) (event t))
    (publishes : InfOften (fun t => cutoff ≤ t ∧ event t = .publish)) :
    Eventually (fun t => ∀ born, born ≤ cutoff → clock born < clock t) := by
  obtain ⟨start, hstart⟩ := publication_clock_unbounded clock event cutoff run publishes
    (prefixMax clock cutoff)
  refine ⟨start, ?_⟩
  intro t ht born hborn
  have hold := prefixMax_covers clock hborn
  have hnew := hstart t ht
  omega

/- A generic causal convergence lemma used by the handshake proof: each
   renegotiation allocates a fresh ID above the finite-failure barrier, and
   such a fresh offer cannot trigger another renegotiation. -/
theorem eventual_constant_of_fresh_stability (offer : Nat → Nat) (barrier : Nat)
    (step : ∀ t, barrier ≤ t →
      offer (t + 1) = offer t ∨ offer (t + 1) = t + 1)
    (freshStable : ∀ t, barrier ≤ t → barrier < offer t → offer (t + 1) = offer t) :
    ∃ start, barrier ≤ start ∧ ∀ t, start ≤ t → offer t = offer start := by
  classical
  by_cases fresh : ∃ t, barrier ≤ t ∧ barrier < offer t
  · obtain ⟨start, hstart, hfresh⟩ := fresh
    have persists : ∀ d, offer (start + d) = offer start := by
      intro d
      induction d with
      | zero => simp
      | succ d ih =>
          rw [show start + (d + 1) = (start + d) + 1 by omega]
          exact (freshStable (start + d) (by omega) (by omega)).trans ih
    refine ⟨start, hstart, ?_⟩
    intro t ht
    have heq : start + (t - start) = t := by omega
    rw [← heq]
    exact persists (t - start)
  · refine ⟨barrier, Nat.le_refl _, constant_suffix offer barrier ?_⟩
    intro t ht
    rcases step t ht with same | changed
    · exact same
    · have hnot : ¬(barrier ≤ t + 1 ∧ barrier < offer (t + 1)) := by
        intro h
        exact fresh ⟨t + 1, h⟩
      omega

theorem version_clock_le {a b : Version} (h : VersionLE a b) : a.clock ≤ b.clock := by
  unfold VersionLE at h
  omega

structure Snapshot where
  version : Version
  /-- Ghost ordinal in this sender's entire publication history. -/
  born : Nat
  /-- Ghost global execution index; neither ghost field is a wire requirement. -/
  event : Nat
  created : Nat
  offer : Nat
  auth : Nat
  candidates : List Nat
  deriving DecidableEq, Repr

structure Cell where
  record : Snapshot
  expires : Nat
  deriving DecidableEq, Repr

def expire (now : Nat) : Option Cell → Option Cell
  | none => none
  | some cell => if now < cell.expires then some cell else none

def brokerSync (now lease : Nat) (incoming : Option Snapshot) (old : Option Cell) : Option Cell :=
  match incoming, expire now old with
  | none, cell => cell
  | some record, none => some ⟨record, now + lease⟩
  | some record, some cell =>
      if Newer record.version cell.record.version then some ⟨record, now + lease⟩
      else some cell

def Published (history : Nat → Snapshot) (record : Snapshot) : Prop :=
  history record.born = record

def CellValid (history : Nat → Snapshot) (lease : Nat) (cell : Cell) : Prop :=
  Published history cell.record ∧ cell.record.created + lease ≤ cell.expires

theorem brokerSync_provenance (history : Nat → Snapshot) (now lease : Nat)
    (incoming : Option Snapshot) (old : Option Cell)
    (hin : ∀ record, incoming = some record → Published history record ∧ record.created ≤ now)
    (hold : ∀ cell, old = some cell → CellValid history lease cell) :
    ∀ cell, brokerSync now lease incoming old = some cell → CellValid history lease cell := by
  intro cell hcell
  cases old with
  | none =>
      cases incoming with
      | none => simp [brokerSync, expire] at hcell
      | some record =>
          simp only [brokerSync, expire, Option.some.injEq] at hcell
          subst cell
          obtain ⟨hp, ht⟩ := hin record rfl
          exact ⟨hp, by change record.created + lease ≤ now + lease; omega⟩
  | some previous =>
      have hp := hold previous rfl
      by_cases alive : now < previous.expires
      · cases incoming with
        | none =>
            simp only [brokerSync, expire, alive, ↓reduceIte, Option.some.injEq] at hcell
            subst cell
            exact hp
        | some record =>
            by_cases fresh : Newer record.version previous.record.version
            · simp only [brokerSync, expire, alive, fresh, ↓reduceIte, Option.some.injEq] at hcell
              subst cell
              obtain ⟨hpub, ht⟩ := hin record rfl
              exact ⟨hpub, by change record.created + lease ≤ now + lease; omega⟩
            · simp only [brokerSync, expire, alive, fresh, ↓reduceIte, Option.some.injEq] at hcell
              subst cell
              exact hp
      · cases incoming with
        | none => simp [brokerSync, expire, alive] at hcell
        | some record =>
            simp only [brokerSync, expire, alive, ↓reduceIte, Option.some.injEq] at hcell
            subst cell
            obtain ⟨hpub, ht⟩ := hin record rfl
            exact ⟨hpub, by change record.created + lease ≤ now + lease; omega⟩

theorem brokerSync_covers_publication (now lease : Nat) (record : Snapshot) (old : Option Cell) :
    ∃ cell, brokerSync now lease (some record) old = some cell ∧
      VersionLE record.version cell.record.version := by
  cases old with
  | none => exact ⟨⟨record, now + lease⟩, rfl, version_refl _⟩
  | some previous =>
      by_cases alive : now < previous.expires
      · by_cases fresh : Newer record.version previous.record.version
        · refine ⟨⟨record, now + lease⟩, ?_, version_refl _⟩
          simp [brokerSync, expire, alive, fresh]
        · refine ⟨previous, ?_, ?_⟩
          · simp [brokerSync, expire, alive, fresh]
          · unfold Newer at fresh
            unfold VersionLE
            omega
      · refine ⟨⟨record, now + lease⟩, ?_, version_refl _⟩
        simp [brokerSync, expire, alive]

theorem lease_window_step (now lease deadline : Nat) (incoming : Option Snapshot) (old : Cell)
    (unexpired : deadline < old.expires) (beforeRead : now ≤ deadline)
    (newLease : deadline < now + lease) :
    ∃ cell, brokerSync now lease incoming (some old) = some cell ∧
      VersionLE old.record.version cell.record.version ∧ deadline < cell.expires := by
  have alive : now < old.expires := by omega
  cases incoming with
  | none =>
      exact ⟨old, by simp [brokerSync, expire, alive], version_refl _, unexpired⟩
  | some record =>
      by_cases fresh : Newer record.version old.record.version
      · refine ⟨⟨record, now + lease⟩, ?_, ?_, newLease⟩
        · simp [brokerSync, expire, alive, fresh]
        · change VersionLE old.record.version record.version
          unfold Newer at fresh
          unfold VersionLE
          omega
      · exact ⟨old, by simp [brokerSync, expire, alive, fresh], version_refl _, unexpired⟩

/- A stable source's current-incarnation snapshots have increasing clocks in
   publication order. The finite obsolete prefix may have arbitrary clocks
   and arbitrary boot-ID lexical order. Provenance is an authentication premise. -/
structure SourceHistory where
  entries : Nat → Snapshot
  cutoff : Nat
  obsoleteBound : Nat
  indexed : ∀ t, (entries t).born = t
  obsolete : ∀ t, t < cutoff → (entries t).version.clock ≤ obsoleteBound
  ordered : ∀ a b, cutoff ≤ a → a < b → (entries a).version.clock < (entries b).version.clock
  eventOrdered : ∀ a b, a < b → (entries a).event < (entries b).event
  timeOrdered : ∀ a b, a ≤ b → (entries a).created ≤ (entries b).created

theorem history_newer_is_fresher (h : SourceHistory) (target other : Snapshot)
    (ht : Published h.entries target) (ho : Published h.entries other)
    (_current : h.cutoff ≤ target.born) (aboveOld : h.obsoleteBound < target.version.clock)
    (version : VersionLE target.version other.version) :
    target.born ≤ other.born ∧ target.created ≤ other.created := by
  have clockOrder := version_clock_le version
  have otherCurrent : h.cutoff ≤ other.born := by
    by_cases bad : other.born < h.cutoff
    · have old := h.obsolete other.born bad
      rw [ho] at old
      omega
    · omega
  have birthOrder : target.born ≤ other.born := by
    by_cases bad : other.born < target.born
    · have strict := h.ordered other.born target.born otherCurrent bad
      rw [ht, ho] at strict
      omega
    · omega
  have times := h.timeOrdered target.born other.born birthOrder
  rw [ht, ho] at times
  exact ⟨birthOrder, times⟩

/- Receiving an older source snapshot can never lower the cached version.
   Even if it arrives through a different broker, a newer retained snapshot is
   itself a newer publication once the finite obsolete-clock prefix is passed. -/
def clientReceive (incoming : Snapshot) (old : Option Snapshot) : Snapshot :=
  match old with
  | none => incoming
  | some old => if Newer incoming.version old.version then incoming else old

theorem clientReceive_covers (incoming : Snapshot) (old : Option Snapshot) :
    VersionLE incoming.version (clientReceive incoming old).version := by
  cases old with
  | none => exact version_refl _
  | some old =>
      by_cases fresh : Newer incoming.version old.version
      · simpa [clientReceive, fresh] using version_refl incoming.version
      · have h := pick_ge_incoming incoming.version old.version
        simpa [clientReceive, pick, fresh] using h

theorem clientReceive_retains (incoming old : Snapshot) :
    VersionLE old.version (clientReceive incoming (some old)).version := by
  have h := pick_ge_old incoming.version old.version
  by_cases fresh : Newer incoming.version old.version
  · simpa [clientReceive, pick, fresh] using h
  · simpa [clientReceive, pick, fresh] using h

theorem clientReceive_provenance (history : Nat → Snapshot) (incoming : Snapshot)
    (old : Option Snapshot) (hi : Published history incoming)
    (ho : ∀ previous, old = some previous → Published history previous) :
    Published history (clientReceive incoming old) := by
  cases old with
  | none => exact hi
  | some previous =>
      by_cases fresh : Newer incoming.version previous.version
      · simpa [clientReceive, fresh] using hi
      · simpa [clientReceive, fresh] using ho previous rfl

/- This certificate is a finite broker execution between a publication and a
   reader poll. Its timing clauses are the lease/timely-common-broker premise;
   no field asserts delivery of fresh contents or a successful handshake. -/
structure BrokerWindow (h : SourceHistory) (lease : Nat) where
  publication : Snapshot
  publicationValid : Published h.entries publication
  writerNow : Nat
  writerCausal : publication.created ≤ writerNow
  deadline : Nat
  writerBeforeRead : writerNow ≤ deadline
  timely : deadline < publication.created + lease
  initial : Option Cell
  initialValid : ∀ cell, initial = some cell → CellValid h.entries lease cell
  length : Nat
  cells : Nat → Option Cell
  first : cells 0 = brokerSync writerNow lease (some publication) initial
  incoming : Nat → Option Snapshot
  now : Nat → Nat
  within : ∀ i, i < length → writerNow ≤ now i ∧ now i ≤ deadline
  causal : ∀ i, i < length → ∀ record, incoming i = some record →
    Published h.entries record ∧ record.created ≤ now i
  transitions : ∀ i, i < length →
    cells (i + 1) = brokerSync (now i) lease (incoming i) (cells i)

structure ReadWindow (h : SourceHistory) (lease : Nat) extends BrokerWindow h lease where
  publicationCurrent : h.cutoff ≤ publication.born
  publicationAboveOld : h.obsoleteBound < publication.version.clock

theorem read_window_fresh (h : SourceHistory) (lease : Nat) (w : ReadWindow h lease) :
    ∃ cell, w.cells w.length = some cell ∧
      Published h.entries cell.record ∧ w.publication.born ≤ cell.record.born ∧
      w.deadline < cell.expires ∧ VersionLE w.publication.version cell.record.version := by
  obtain ⟨firstCell, hfirstCell, hfirstVersion⟩ :=
    brokerSync_covers_publication w.writerNow lease w.publication w.initial
  have hfirstValid : CellValid h.entries lease firstCell := by
    apply brokerSync_provenance h.entries w.writerNow lease (some w.publication) w.initial
      (fun record heq => by
        have eqrec : record = w.publication := by simpa using heq.symm
        subst record
        exact ⟨w.publicationValid, w.writerCausal⟩) w.initialValid firstCell hfirstCell
  have hfresh := history_newer_is_fresher h w.publication firstCell.record
    w.publicationValid hfirstValid.1 w.publicationCurrent w.publicationAboveOld hfirstVersion
  have hdeadline : w.deadline < firstCell.expires := by
    have causal := hfirstValid.2
    have timely := w.timely
    omega
  have preserves : ∀ n, n ≤ w.length → ∃ cell, w.cells n = some cell ∧
      CellValid h.entries lease cell ∧ VersionLE w.publication.version cell.record.version ∧
      w.deadline < cell.expires := by
    intro n
    induction n with
    | zero => exact fun _ => ⟨firstCell, w.first.trans hfirstCell, hfirstValid, hfirstVersion, hdeadline⟩
    | succ n ih =>
        intro hn
        obtain ⟨old, hold, hvalid, hversion, hdeadline⟩ := ih (by omega)
        have hwithin := w.within n (by omega)
        have hnewLease : w.deadline < w.now n + lease := by
          have timely := w.timely
          have causal := w.writerCausal
          omega
        obtain ⟨next, hnext, hnextVersion, hnextDeadline⟩ :=
          lease_window_step (w.now n) lease w.deadline (w.incoming n) old
            hdeadline hwithin.2 hnewLease
        have hresult : w.cells (n + 1) = some next := by
          rw [w.transitions n (by omega), hold]
          exact hnext
        have hnextValid : CellValid h.entries lease next := by
          apply brokerSync_provenance h.entries (w.now n) lease (w.incoming n) (some old)
            (w.causal n (by omega))
            (fun previous heq => by
              have heq' : previous = old := by simpa using heq.symm
              subst previous
              exact hvalid) next hnext
        exact ⟨next, hresult, hnextValid, version_trans hversion hnextVersion, hnextDeadline⟩
  obtain ⟨cell, hcell, hvalid, hversion, hdeadline⟩ := preserves w.length (Nat.le_refl _)
  have hfresh := history_newer_is_fresher h w.publication cell.record w.publicationValid
    hvalid.1 w.publicationCurrent w.publicationAboveOld hversion
  exact ⟨cell, hcell, hvalid.1, hfresh.1, hdeadline, hversion⟩

def receiveOption (incoming old : Option Snapshot) : Option Snapshot :=
  match incoming with
  | none => old
  | some record => some (clientReceive record old)

structure ClientRun (h : SourceHistory) where
  cutoff : Nat
  seen : Nat → Option Snapshot
  input : Nat → Option Snapshot
  initial : ∀ record, seen cutoff = some record → Published h.entries record
  inputValid : ∀ t, cutoff ≤ t → ∀ record, input t = some record → Published h.entries record
  inputCausal : ∀ t, cutoff ≤ t → ∀ record, input t = some record → record.event ≤ t
  step : ∀ t, cutoff ≤ t → seen (t + 1) = receiveOption (input t) (seen t)

theorem client_run_valid (h : SourceHistory) (c : ClientRun h) :
    ∀ t, c.cutoff ≤ t → ∀ record, c.seen t = some record → Published h.entries record := by
  have aux : ∀ d, ∀ record, c.seen (c.cutoff + d) = some record → Published h.entries record := by
    intro d
    induction d with
    | zero => simpa using c.initial
    | succ d ih =>
        intro record hrecord
        have hs := c.step (c.cutoff + d) (by omega)
        rw [show c.cutoff + (d + 1) = (c.cutoff + d) + 1 by omega, hs] at hrecord
        cases hin : c.input (c.cutoff + d) with
        | none =>
            simp only [hin, receiveOption] at hrecord
            exact ih record hrecord
        | some incoming =>
            simp only [hin, receiveOption, Option.some.injEq] at hrecord
            subst record
            exact clientReceive_provenance h.entries incoming (c.seen (c.cutoff + d))
              (c.inputValid (c.cutoff + d) (by omega) incoming hin) ih
  intro t ht
  have heq : c.cutoff + (t - c.cutoff) = t := by omega
  rw [← heq]
  exact aux (t - c.cutoff)

theorem client_run_retains (h : SourceHistory) (c : ClientRun h)
    (start : Nat) (hs : c.cutoff ≤ start) (first : Snapshot) (hfirst : c.seen start = some first) :
    ∀ t, start ≤ t → ∃ record, c.seen t = some record ∧ VersionLE first.version record.version := by
  have aux : ∀ d, ∃ record, c.seen (start + d) = some record ∧
      VersionLE first.version record.version := by
    intro d
    induction d with
    | zero => exact ⟨first, by simpa using hfirst, version_refl _⟩
    | succ d ih =>
        obtain ⟨previous, hprevious, hversion⟩ := ih
        rw [show start + (d + 1) = (start + d) + 1 by omega,
          c.step (start + d) (by omega), hprevious]
        cases hin : c.input (start + d) with
        | none => exact ⟨previous, rfl, hversion⟩
        | some incoming =>
            exact ⟨clientReceive incoming (some previous), rfl,
              version_trans hversion (clientReceive_retains incoming previous)⟩
  intro t ht
  have heq : start + (t - start) = t := by omega
  rw [← heq]
  exact aux (t - start)

theorem strict_sequence_ge_index (f : Nat → Nat) (strict : ∀ n, f n < f (n + 1)) :
    ∀ n, n ≤ f n := by
  intro n
  induction n with
  | zero => omega
  | succ n ih => have hs := strict n; omega

/- Each round is a newly generated publication followed by a common-broker
   poll within the protected lease window, with the response eventually fed
   into the client's ordinary max-register input. Windows may contain any
   number of other writes/replays. Scheduling, causality and timely lease
   overlap are premises; the returned contents being fresh is NOT a premise. -/
structure CommonSchedule (h : SourceHistory) (lease : Nat) (c : ClientRun h) where
  window : Nat → BrokerWindow h lease
  captureStrict : ∀ n, (window n).publication.born < (window (n + 1)).publication.born
  arrival : Nat → Nat
  arrivalStable : ∀ n, c.cutoff ≤ arrival n
  arrivesAfterCapture : ∀ n, (window n).publication.event ≤ arrival n
  response : ∀ n, c.input (arrival n) = ((window n).cells (window n).length).map Cell.record

theorem common_publication_unbounded (h : SourceHistory) (lease : Nat) (c : ClientRun h)
    (s : CommonSchedule h lease c) :
    ∀ bound, Eventually (fun n => bound < (s.window n).publication.version.clock) := by
  have captureBound := strict_sequence_ge_index (fun n => (s.window n).publication.born) s.captureStrict
  have mono : ∀ n, h.cutoff ≤ n →
      (s.window n).publication.version.clock ≤ (s.window (n + 1)).publication.version.clock := by
    intro n hn
    have hclock := h.ordered (s.window n).publication.born (s.window (n + 1)).publication.born
      (by have hb := captureBound n; omega) (s.captureStrict n)
    rw [(s.window n).publicationValid, (s.window (n + 1)).publicationValid] at hclock
    omega
  apply monotone_progress_unbounded (fun n => (s.window n).publication.version.clock) h.cutoff mono
  intro n hn
  have hclock := h.ordered (s.window n).publication.born (s.window (n + 1)).publication.born
    (by have hb := captureBound n; omega) (s.captureStrict n)
  rw [(s.window n).publicationValid, (s.window (n + 1)).publicationValid] at hclock
  exact ⟨n + 1, by omega, hclock⟩

theorem common_broker_delivers_every_tail (h : SourceHistory) (lease : Nat) (c : ClientRun h)
    (s : CommonSchedule h lease c) (target : Nat) :
    Eventually (fun t => ∃ record, c.seen t = some record ∧ target ≤ record.born) := by
  obtain ⟨clockRound, hclockRound⟩ := common_publication_unbounded h lease c s h.obsoleteBound
  let round := max clockRound (max h.cutoff target)
  have hbound := strict_sequence_ge_index (fun n => (s.window n).publication.born) s.captureStrict round
  have hcurrent : h.cutoff ≤ (s.window round).publication.born := by dsimp [round] at *; omega
  have habove : h.obsoleteBound < (s.window round).publication.version.clock := by
    apply hclockRound round
    dsimp [round]
    omega
  let w : ReadWindow h lease := {
    toBrokerWindow := s.window round
    publicationCurrent := hcurrent
    publicationAboveOld := habove
  }
  obtain ⟨cell, hcell, _, _, _, hfirstVersion⟩ := read_window_fresh h lease w
  have hinput : c.input (s.arrival round) = some cell.record := by
    rw [s.response round]
    change (w.cells w.length).map Cell.record = some cell.record
    rw [hcell]
    rfl
  have hseen : c.seen (s.arrival round + 1) =
      some (clientReceive cell.record (c.seen (s.arrival round))) := by
    rw [c.step (s.arrival round) (s.arrivalStable round), hinput]
    rfl
  let first := clientReceive cell.record (c.seen (s.arrival round))
  have hfirstVersion' : VersionLE w.publication.version first.version :=
    version_trans hfirstVersion (clientReceive_covers cell.record (c.seen (s.arrival round)))
  refine ⟨s.arrival round + 1, ?_⟩
  intro t ht
  obtain ⟨record, hrecord, hversion⟩ := client_run_retains h c (s.arrival round + 1)
    (by have hs := s.arrivalStable round; omega) first hseen t ht
  have valid := client_run_valid h c t (by have hs := s.arrivalStable round; omega) record hrecord
  have fresh := history_newer_is_fresher h w.publication record w.publicationValid valid
    w.publicationCurrent w.publicationAboveOld (version_trans hfirstVersion' hversion)
  refine ⟨record, hrecord, ?_⟩
  have htarget : target ≤ w.publication.born := by
    change target ≤ (s.window round).publication.born
    dsimp [round] at *
    omega
  omega

theorem transport_preserves_eventual_snapshot_property
    (h : SourceHistory) (lease : Nat) (c : ClientRun h) (s : CommonSchedule h lease c)
    (property : Snapshot → Prop)
    (sourceEventually : ∃ target, ∀ record, Published h.entries record →
      target ≤ record.born → property record) :
    Eventually (fun t => ∃ record, c.seen t = some record ∧ property record) := by
  obtain ⟨target, htarget⟩ := sourceEventually
  obtain ⟨start, hstart⟩ := common_broker_delivers_every_tail h lease c s target
  refine ⟨max start c.cutoff, ?_⟩
  intro t ht
  obtain ⟨record, hrecord, hborn⟩ := hstart t (by omega)
  exact ⟨record, hrecord, htarget record
    (client_run_valid h c t (by omega) record hrecord) hborn⟩

theorem strict_between (f : Nat → Nat) (step : ∀ n, f n < f (n + 1))
    {a b : Nat} (hab : a < b) : f a < f b := by
  have hnext := step a
  have hrest := monotone_suffix f 0 (fun n _ => Nat.le_of_lt (step n))
    (a := a + 1) (b := b) (by omega) (by omega)
  omega

/- Construct the source-history ordering facts from the actual Lamport
   operations and publication events, rather than assume clock convergence. -/
def historyFromClock
    (clock : Nat → Nat) (event : Nat → ClockEvent) (stableTime cut : Nat)
    (run : ∀ t, stableTime ≤ t → clock (t + 1) = clockNext (clock t) (event t))
    (publicationEvent : Nat → Nat)
    (publicationStep : ∀ n, event (publicationEvent n) = .publish)
    (publicationStrict : ∀ n, publicationEvent n < publicationEvent (n + 1))
    (pastFaults : stableTime ≤ publicationEvent cut)
    (wall : Nat → Nat) (wallMono : ∀ a b, a ≤ b → wall a ≤ wall b)
    (boot offer auth : Nat → Nat) (candidates : Nat → List Nat) : SourceHistory := by
  let entry := fun n => ({
    version := ⟨clock (publicationEvent n + 1), boot n⟩
    born := n
    event := publicationEvent n
    created := wall (publicationEvent n)
    offer := offer n
    auth := auth n
    candidates := candidates n
  } : Snapshot)
  have pubMono : ∀ a b, a ≤ b → publicationEvent a ≤ publicationEvent b := by
    intro a b hab
    by_cases eq : a = b
    · subst b; exact Nat.le_refl _
    · exact Nat.le_of_lt (strict_between publicationEvent publicationStrict (by omega))
  refine {
    entries := entry
    cutoff := cut
    obsoleteBound := prefixMax (fun n => clock (publicationEvent n + 1)) cut
    indexed := fun _ => rfl
    obsolete := ?_
    ordered := ?_
    eventOrdered := fun a b hab => strict_between publicationEvent publicationStrict hab
    timeOrdered := fun a b hab => wallMono _ _ (pubMono a b hab)
  }
  · intro n hn
    exact prefixMax_covers (fun k => clock (publicationEvent k + 1)) (by omega)
  · intro a b ha hab
    have hevents := strict_between publicationEvent publicationStrict hab
    have hpast : stableTime ≤ publicationEvent a := by
      have hh := pubMono cut a ha
      omega
    have mono : ∀ t, stableTime ≤ t → clock t ≤ clock (t + 1) := by
      intro t ht
      rw [run t ht]
      exact clockNext_mono _ _
    have hgap := monotone_suffix clock stableTime mono
      (a := publicationEvent a + 1) (b := publicationEvent b) (by omega) (by omega)
    have hp : clock (publicationEvent b + 1) = clock (publicationEvent b) + 1 := by
      rw [run _ (by omega), publicationStep b]
      rfl
    change clock (publicationEvent a + 1) < clock (publicationEvent b + 1)
    omega

theorem eventual_client_order (h : SourceHistory) (lease : Nat) (c : ClientRun h)
    (s : CommonSchedule h lease c) :
    ∃ start, c.cutoff ≤ start ∧ ∀ t, start ≤ t →
      ∃ record, c.seen t = some record ∧ h.cutoff ≤ record.born ∧
        h.obsoleteBound < record.version.clock ∧
        ∀ u, t ≤ u → ∃ next, c.seen u = some next ∧ record.born ≤ next.born := by
  obtain ⟨round, hround⟩ := common_publication_unbounded h lease c s h.obsoleteBound
  let target := (s.window round).publication
  have htpub : Published h.entries target := (s.window round).publicationValid
  have htclock : h.obsoleteBound < target.version.clock := hround round (Nat.le_refl _)
  have htcurrent : h.cutoff ≤ target.born := by
    by_cases old : target.born < h.cutoff
    · have bounded := h.obsolete target.born old
      rw [htpub] at bounded
      omega
    · omega
  obtain ⟨start, hstart⟩ := common_broker_delivers_every_tail h lease c s target.born
  refine ⟨max start c.cutoff, by omega, ?_⟩
  intro t ht
  obtain ⟨record, hrecord, hborn⟩ := hstart t (by omega)
  have hpub := client_run_valid h c t (by omega) record hrecord
  have hversion : VersionLE target.version record.version := by
    by_cases equal : target.born = record.born
    · have heq : target = record := by
        have hp : h.entries target.born = target := htpub
        rw [equal, hpub] at hp
        exact hp.symm
      rw [heq]
      exact version_refl _
    · have hstrict := h.ordered target.born record.born htcurrent (by omega)
      rw [htpub, hpub] at hstrict
      exact Or.inl hstrict
  have hclock := version_clock_le hversion
  refine ⟨record, hrecord, by omega, by omega, ?_⟩
  intro u htu
  obtain ⟨next, hnext, hnextVersion⟩ := client_run_retains h c t (by omega) record hrecord u htu
  have hnextPub := client_run_valid h c u (by omega) next hnext
  have hfresh := history_newer_is_fresher h record next hpub hnextPub
    (by omega) (by omega) hnextVersion
  exact ⟨next, hnext, hfresh.1⟩

/- Offer IDs below are ghost allocation times. The wire identifiers need only
   be fresh and equality-testable; the algorithm never orders their bytes. -/
structure ResponderState where
  offer : Nat
  answer : Nat
  deriving DecidableEq, Repr

def responderNext (now inputOffer : Nat) (old : ResponderState) : ResponderState :=
  if old.answer = 0 ∨ old.offer ≠ inputOffer then ⟨inputOffer, now + 1⟩ else old

theorem responderNext_offer (now inputOffer : Nat) (old : ResponderState) :
    (responderNext now inputOffer old).offer = inputOffer := by
  unfold responderNext
  split
  · rfl
  · rename_i condition
    have heq : old.offer = inputOffer := by
      by_cases eq : old.offer = inputOffer
      · exact eq
      · exact False.elim (condition (Or.inr eq))
    exact heq

theorem responderNext_active (now inputOffer : Nat) (old : ResponderState) :
    0 < (responderNext now inputOffer old).answer := by
  unfold responderNext
  split
  · change 0 < now + 1; omega
  · rename_i condition
    have hn : old.answer ≠ 0 := fun h => condition (Or.inl h)
    change 0 < old.answer
    omega

theorem responderNext_unchanged (now inputOffer : Nat) (old : ResponderState)
    (active : 0 < old.answer) (same : old.offer = inputOffer) :
    responderNext now inputOffer old = old := by
  simp [responderNext, same, Nat.ne_of_gt active]

theorem responderNext_causal (now inputOffer : Nat) (old : ResponderState)
    (inputCausal : inputOffer ≤ now) (oldCausal : old.offer ≤ now ∧ old.answer ≤ now) :
    (responderNext now inputOffer old).offer ≤ now + 1 ∧
      (responderNext now inputOffer old).answer ≤ now + 1 := by
  unfold responderNext
  split
  · change inputOffer ≤ now + 1 ∧ now + 1 ≤ now + 1
    omega
  · change old.offer ≤ now + 1 ∧ old.answer ≤ now + 1
    omega

structure ResponderRun (h : SourceHistory) (c : ClientRun h) where
  cutoff : Nat
  receiverStable : c.cutoff ≤ cutoff
  state : Nat → ResponderState
  scheduled : Nat → Bool
  fair : InfOften (fun t => cutoff ≤ t ∧ scheduled t = true)
  causal : ∀ t, (state t).offer ≤ t ∧ (state t).answer ≤ t
  step : ∀ t, cutoff ≤ t → state (t + 1) =
    if scheduled t then
      match c.seen t with
      | none => state t
      | some record => responderNext t record.offer (state t)
    else state t

/- Local controller fairness plus eventual presence of an input suffices for
   cold activation; an answer's prior existence is not assumed. -/
theorem responder_cold_activation (h : SourceHistory) (lease : Nat) (c : ClientRun h)
    (s : CommonSchedule h lease c) (r : ResponderRun h c) :
    Eventually (fun t => 0 < (r.state t).answer) := by
  obtain ⟨inputStart, hinputStart⟩ := common_broker_delivers_every_tail h lease c s 0
  obtain ⟨scheduled, hs, hcut, hscheduled⟩ := r.fair (max inputStart r.cutoff)
  obtain ⟨record, hrecord, _⟩ := hinputStart scheduled (by omega)
  have active : 0 < (r.state (scheduled + 1)).answer := by
    rw [r.step scheduled hcut, hscheduled, hrecord]
    exact responderNext_active _ _ _
  have persists : ∀ d, 0 < (r.state (scheduled + 1 + d)).answer := by
    intro d
    induction d with
    | zero => simpa using active
    | succ d ih =>
        rw [show scheduled + 1 + (d + 1) = (scheduled + 1 + d) + 1 by omega,
          r.step (scheduled + 1 + d) (by omega)]
        cases hoff : r.scheduled (scheduled + 1 + d) <;>
          simp only [Bool.false_eq_true, ↓reduceIte]
        · exact ih
        · cases hseen : c.seen (scheduled + 1 + d) with
          | none => simpa only [hseen] using ih
          | some record =>
              exact responderNext_active _ _ _
  refine ⟨scheduled + 1, ?_⟩
  intro t ht
  have heq : scheduled + 1 + (t - (scheduled + 1)) = t := by omega
  rw [← heq]
  exact persists _

/- Ghost birth times make causal freshness explicit without ordering wire IDs. -/
structure OfferRun where
  offer : Nat → Nat
  initial : offer 0 = 0
  allocation : ∀ t, offer (t + 1) = offer t ∨ offer (t + 1) = t + 1

theorem offer_causal (a : OfferRun) : ∀ t, a.offer t ≤ t := by
  intro t
  induction t with
  | zero => simp [a.initial]
  | succ t ih => rcases a.allocation t with h | h <;> rw [h] <;> omega

theorem offer_monotone (a : OfferRun) {u v : Nat} (huv : u ≤ v) :
    a.offer u ≤ a.offer v := by
  apply monotone_suffix a.offer 0 _ (by omega) huv
  intro t _
  have hc := offer_causal a t
  rcases a.allocation t with h | h <;> rw [h] <;> omega

def inputOffer (h : SourceHistory) (c : ClientRun h) (t : Nat) : Nat :=
  ((c.seen t).map Snapshot.offer).getD 0

theorem eventual_input_order (a : OfferRun) (h : SourceHistory) (lease : Nat)
    (c : ClientRun h) (s : CommonSchedule h lease c)
    (body : ∀ n, (h.entries n).offer = a.offer (h.entries n).event) :
    ∃ start, c.cutoff ≤ start ∧
      (∀ t, start ≤ t → ∃ record, c.seen t = some record) ∧
      (∀ u v, start ≤ u → u ≤ v → inputOffer h c u ≤ inputOffer h c v) := by
  obtain ⟨start, hcut, hs⟩ := eventual_client_order h lease c s
  refine ⟨start, hcut, ?_, ?_⟩
  · intro t ht
    obtain ⟨record, hr, _⟩ := hs t ht
    exact ⟨record, hr⟩
  · intro u v hu huv
    obtain ⟨left, hl, _, _, hafter⟩ := hs u hu
    obtain ⟨right, hr, hborn⟩ := hafter v huv
    have lp := client_run_valid h c u (by omega) left hl
    have rp := client_run_valid h c v (by omega) right hr
    have hevent : left.event ≤ right.event := by
      by_cases eq : left.born = right.born
      · have heq : left = right := lp.symm.trans (eq ▸ rp)
        rw [heq]
        exact Nat.le_refl _
      · have strict := h.eventOrdered left.born right.born (by omega)
        rw [lp, rp] at strict
        omega
    have lb := body left.born
    have rb := body right.born
    rw [lp] at lb
    rw [rp] at rb
    simpa only [inputOffer, hl, hr, Option.map_some, Option.getD_some, lb, rb] using
      offer_monotone a hevent

/- After one scheduled follow, the responder cannot move backward through a
   monotone sequence of offers. Repeated credentials do not create an answer. -/
theorem responder_ordered_suffix (h : SourceHistory) (c : ClientRun h)
    (r : ResponderRun h c) (inputStart : Nat)
    (present : ∀ t, inputStart ≤ t → ∃ record, c.seen t = some record)
    (mono : ∀ u v, inputStart ≤ u → u ≤ v → inputOffer h c u ≤ inputOffer h c v) :
    ∃ start, r.cutoff ≤ start ∧
      (∀ t, start ≤ t → 0 < (r.state t).answer ∧ (r.state t).offer ≤ inputOffer h c t) ∧
      (∀ t, start ≤ t → (r.state t).offer ≤ (r.state (t + 1)).offer) ∧
      (∀ t, start ≤ t → (r.state (t + 1)).offer = (r.state t).offer →
        (r.state (t + 1)).answer = (r.state t).answer) := by
  obtain ⟨first, hf, hcut, hscheduled⟩ := r.fair (max inputStart r.cutoff)
  have firstInput := present first (by omega)
  obtain ⟨record, hrecord⟩ := firstInput
  have firstState : r.state (first + 1) = responderNext first record.offer (r.state first) := by
    simp only [r.step first hcut, hscheduled, hrecord, ↓reduceIte]
  have firstOffer : (r.state (first + 1)).offer = inputOffer h c first := by
    rw [firstState, responderNext_offer]
    simp only [inputOffer, hrecord, Option.map_some, Option.getD_some]
  have transition : ∀ t, max inputStart r.cutoff ≤ t →
      0 < (r.state t).answer ∧ (r.state t).offer ≤ inputOffer h c t →
      (0 < (r.state (t + 1)).answer ∧ (r.state (t + 1)).offer ≤ inputOffer h c (t + 1)) ∧
      (r.state t).offer ≤ (r.state (t + 1)).offer ∧
      ((r.state (t + 1)).offer = (r.state t).offer →
        (r.state (t + 1)).answer = (r.state t).answer) := by
    intro t ht ⟨active, below⟩
    have nextInput := mono t (t + 1) (by omega) (by omega)
    obtain ⟨rec, hrec⟩ := present t (by omega)
    have hi : inputOffer h c t = rec.offer := by simp [inputOffer, hrec]
    rw [r.step t (by omega)]
    cases scheduled : r.scheduled t <;> simp only [Bool.false_eq_true, ↓reduceIte]
    · exact ⟨⟨active, by omega⟩, Nat.le_refl _, fun _ => True.intro⟩
    · simp only [hrec]
      refine ⟨⟨responderNext_active _ _ _, ?_⟩, ?_, ?_⟩
      · rw [responderNext_offer]; omega
      · rw [responderNext_offer]; omega
      · intro same
        have eq : (r.state t).offer = rec.offer := by
          rw [responderNext_offer] at same
          exact same.symm
        rw [responderNext_unchanged t rec.offer (r.state t) active eq]
  have inv : ∀ d, 0 < (r.state (first + 1 + d)).answer ∧
      (r.state (first + 1 + d)).offer ≤ inputOffer h c (first + 1 + d) := by
    intro d
    induction d with
    | zero =>
        refine ⟨?_, ?_⟩
        · simpa only [Nat.add_zero, firstState] using responderNext_active first record.offer (r.state first)
        · simpa only [Nat.add_zero, firstOffer] using mono first (first + 1) (by omega) (by omega)
    | succ d ih =>
        have next := (transition (first + 1 + d) (by omega) ih).1
        simpa only [Nat.add_assoc] using next
  have invariant : ∀ t, first + 1 ≤ t →
      0 < (r.state t).answer ∧ (r.state t).offer ≤ inputOffer h c t := by
    intro t ht
    have eq : first + 1 + (t - (first + 1)) = t := by omega
    simpa only [eq] using inv (t - (first + 1))
  refine ⟨first + 1, by omega, invariant, ?_, ?_⟩
  · intro t ht; exact (transition t (by omega) (invariant t ht)).2.1
  · intro t ht; exact (transition t (by omega) (invariant t ht)).2.2

/- A single offer has at most one answer anywhere in the ordered suffix,
   even when arbitrarily old genuine messages are replayed. -/
theorem answer_unique_between (state : Nat → ResponderState) (start : Nat)
    (mono : ∀ t, start ≤ t → (state t).offer ≤ (state (t + 1)).offer)
    (same : ∀ t, start ≤ t → (state (t + 1)).offer = (state t).offer →
      (state (t + 1)).answer = (state t).answer)
    (u v : Nat) (hu : start ≤ u) (hv : start ≤ v)
    (eq : (state u).offer = (state v).offer) : (state u).answer = (state v).answer := by
  have forward : ∀ left right, start ≤ left → left ≤ right →
      (state left).offer = (state right).offer → (state left).answer = (state right).answer := by
    intro left right hl hlr heq
    have flat : ∀ t, left ≤ t → t ≤ right → (state t).offer = (state left).offer := by
      intro t hlt htr
      have lower := monotone_suffix (fun k => (state k).offer) start mono hl hlt
      have upper := monotone_suffix (fun k => (state k).offer) start mono (by omega) htr
      omega
    have aux : ∀ d, left + d ≤ right → (state (left + d)).answer = (state left).answer := by
      intro d
      induction d with
      | zero => simp
      | succ d ih =>
          intro hd
          have stepEq : (state (left + d + 1)).offer = (state (left + d)).offer :=
            (flat _ (by omega) (by omega)).trans (flat _ (by omega) (by omega)).symm
          have hsame := same (left + d) (by omega) stepEq
          have previous := ih (by omega)
          simpa only [Nat.add_assoc] using hsame.trans previous
    have endEq : left + (right - left) = right := by omega
    have result := aux (right - left) (by omega)
    rw [endEq] at result
    exact result.symm
  by_cases huv : u ≤ v
  · exact forward u v hu huv eq
  · exact (forward v u hv (by omega) eq.symm).symm

/- Genuine answer-change handling is deliberately nondeterministic: any two
   authenticated answers for the current offer may cause a new offer. Finite
   external agent/process resets are confined to cutoff; protocol-induced
   offer changes after it remain unrestricted by a numerical retry budget. -/
structure RenegotiationRun (a : OfferRun) (answerHistory : SourceHistory) where
  cutoff : Nat
  cause : ∀ t, cutoff ≤ t → a.offer (t + 1) ≠ a.offer t →
    ∃ left right, Published answerHistory.entries left ∧ Published answerHistory.entries right ∧
      left.offer = a.offer t ∧ right.offer = a.offer t ∧ left.auth ≠ right.auth

theorem initiator_eventually_stable
    (a : OfferRun) (ah : SourceHistory) (lease : Nat) (ac : ClientRun ah)
    (transport : CommonSchedule ah lease ac) (r : ResponderRun ah ac)
    (aBody : ∀ n, (ah.entries n).offer = a.offer (ah.entries n).event)
    (bh : SourceHistory)
    (bOffer : ∀ n, (bh.entries n).offer = (r.state (bh.entries n).event).offer)
    (bAuth : ∀ n, (bh.entries n).auth = (r.state (bh.entries n).event).answer)
    (renegotiation : RenegotiationRun a bh) :
    ∃ start, ∀ t, start ≤ t → a.offer t = a.offer start := by
  obtain ⟨inputStart, _, present, mono⟩ := eventual_input_order a ah lease ac transport aBody
  obtain ⟨orderedStart, _, _, stateMono, sameAnswer⟩ :=
    responder_ordered_suffix ah ac r inputStart present mono
  let barrier := max orderedStart renegotiation.cutoff
  have unique : ∀ left right, Published bh.entries left → Published bh.entries right →
      barrier < left.offer → left.offer = right.offer → left.auth = right.auth := by
    intro left right lp rp fresh eq
    have lo := bOffer left.born
    have ro := bOffer right.born
    have la := bAuth left.born
    have ra := bAuth right.born
    rw [lp] at lo la
    rw [rp] at ro ra
    have lc := (r.causal left.event).1
    have rc := (r.causal right.event).1
    have orderedLeft : orderedStart ≤ left.event := by dsimp [barrier] at fresh; omega
    have orderedRight : orderedStart ≤ right.event := by dsimp [barrier] at fresh; omega
    have ans := answer_unique_between r.state orderedStart stateMono sameAnswer
      left.event right.event orderedLeft orderedRight (lo.symm.trans (eq.trans ro))
    exact la.trans (ans.trans ra.symm)
  have freshStable : ∀ t, barrier ≤ t → barrier < a.offer t → a.offer (t + 1) = a.offer t := by
    intro t ht hfresh
    by_cases eq : a.offer (t + 1) = a.offer t
    · exact eq
    · obtain ⟨left, right, lp, rp, lo, ro, different⟩ :=
        renegotiation.cause t (by dsimp [barrier] at ht; omega) eq
      exact False.elim (different (unique left right lp rp (by omega) (lo.trans ro.symm)))
  obtain ⟨start, _, stable⟩ := eventual_constant_of_fresh_stability a.offer barrier
    (fun t _ => a.allocation t) freshStable
  exact ⟨start, stable⟩

/- Stable initiator credentials plus fair processing of actual transported
   snapshots makes the responder settle, including from a cold state. -/
theorem responder_follows_stable_offer
    (h : SourceHistory) (c : ClientRun h) (r : ResponderRun h c) (offer : Nat)
    (inputStable : Eventually (fun t => ∃ rec, c.seen t = some rec ∧ rec.offer = offer)) :
    ∃ start answer, 0 < answer ∧ ∀ t, start ≤ t → r.state t = ⟨offer, answer⟩ := by
  obtain ⟨inputStart, hi⟩ := inputStable
  obtain ⟨first, hf, hc, hs⟩ := r.fair (max inputStart r.cutoff)
  obtain ⟨rec, hr, ho⟩ := hi first (by omega)
  have firstState : r.state (first + 1) = responderNext first rec.offer (r.state first) := by
    simp only [r.step first hc, hs, hr, ↓reduceIte]
  have firstOffer : (r.state (first + 1)).offer = offer := by rw [firstState, responderNext_offer, ho]
  have firstActive : 0 < (r.state (first + 1)).answer := by rw [firstState]; exact responderNext_active _ _ _
  have invariant : ∀ d, r.state (first + 1 + d) = r.state (first + 1) := by
    intro d
    induction d with
    | zero => simp
    | succ d ih =>
        obtain ⟨record, hrecord, hOffer⟩ := hi (first + 1 + d) (by omega)
        rw [show first + 1 + (d + 1) = (first + 1 + d) + 1 by omega,
          r.step (first + 1 + d) (by omega)]
        cases scheduled : r.scheduled (first + 1 + d) <;>
          simp only [Bool.false_eq_true, ↓reduceIte]
        · exact ih
        · rw [hrecord]
          exact (responderNext_unchanged _ _ _
            (by rw [ih]; exact firstActive) (by rw [ih, firstOffer, hOffer])).trans ih
  have stable : ∀ t, first + 1 ≤ t → r.state t = r.state (first + 1) := by
    intro t ht
    have heq : first + 1 + (t - (first + 1)) = t := by omega
    simpa only [heq] using invariant (t - (first + 1))
  refine ⟨first + 1, (r.state (first + 1)).answer, firstActive, ?_⟩
  intro t ht
  rw [stable t ht]
  cases hv : r.state (first + 1) with
  | mk off ans => simp only [hv] at firstOffer ⊢; subst off; rfl

/- Source publication ordinals and allocation times have no finite bound. -/
theorem publication_event_ge_index (h : SourceHistory) (n : Nat) : n ≤ (h.entries n).event := by
  exact strict_sequence_ge_index (fun k => (h.entries k).event)
    (fun k => h.eventOrdered k (k + 1) (by omega)) n

theorem source_property_after_time (h : SourceHistory) (property : Snapshot → Prop)
    (start : Nat) (body : ∀ n, start ≤ (h.entries n).event → property (h.entries n)) :
    ∃ target, ∀ record, Published h.entries record → target ≤ record.born → property record := by
  refine ⟨start, ?_⟩
  intro record hp hb
  have ht := publication_event_ge_index h record.born
  have result := body record.born (by omega)
  rwa [hp] at result

/- This theorem composes the broker/clock/lease argument with both controllers.
   Transport premises are request scheduling and timing, not fresh answers or
   eventual handshake success. Arbitrary prefix failures and arbitrarily late
   replay remain possible, as do arbitrary protocol-induced offer changes. -/
theorem signaling_converges
    (a : OfferRun) (ah bh : SourceHistory) (lease : Nat)
    (ac : ClientRun ah) (bc : ClientRun bh)
    (forward : CommonSchedule ah lease ac) (backward : CommonSchedule bh lease bc)
    (r : ResponderRun ah ac)
    (aBody : ∀ n, (ah.entries n).offer = a.offer (ah.entries n).event)
    (aAuth : ∀ n, (ah.entries n).auth = (ah.entries n).offer)
    (bOffer : ∀ n, (bh.entries n).offer = (r.state (bh.entries n).event).offer)
    (bAuth : ∀ n, (bh.entries n).auth = (r.state (bh.entries n).event).answer)
    (renegotiation : RenegotiationRun a bh) :
    ∃ offer answer, 0 < answer ∧ Eventually (fun t =>
      a.offer t = offer ∧ r.state t = ⟨offer, answer⟩ ∧
      (∃ rec, ac.seen t = some rec ∧ rec.offer = offer ∧ rec.auth = offer) ∧
      (∃ rec, bc.seen t = some rec ∧ rec.offer = offer ∧ rec.auth = answer)) := by
  obtain ⟨aStart, aStable⟩ := initiator_eventually_stable a ah lease ac forward r
    aBody bh bOffer bAuth renegotiation
  let offer := a.offer aStart
  have aSource := source_property_after_time ah
    (fun rec => rec.offer = offer ∧ rec.auth = offer) aStart (by
      intro n hn
      have heq := aStable (ah.entries n).event hn
      exact ⟨(aBody n).trans heq, (aAuth n).trans ((aBody n).trans heq)⟩)
  have aReceived := transport_preserves_eventual_snapshot_property ah lease ac forward
    (fun rec => rec.offer = offer ∧ rec.auth = offer) aSource
  have inputStable : Eventually (fun t => ∃ rec, ac.seen t = some rec ∧ rec.offer = offer) := by
    obtain ⟨start, hs⟩ := aReceived
    refine ⟨start, ?_⟩
    intro t ht
    obtain ⟨rec, hr, ho, _⟩ := hs t ht
    exact ⟨rec, hr, ho⟩
  obtain ⟨bStart, answer, active, bStable⟩ := responder_follows_stable_offer ah ac r offer inputStable
  have bSource := source_property_after_time bh
    (fun rec => rec.offer = offer ∧ rec.auth = answer) bStart (by
      intro n hn
      have heq := bStable (bh.entries n).event hn
      exact ⟨(bOffer n).trans (congrArg ResponderState.offer heq),
        (bAuth n).trans (congrArg ResponderState.answer heq)⟩)
  have bReceived := transport_preserves_eventual_snapshot_property bh lease bc backward
    (fun rec => rec.offer = offer ∧ rec.auth = answer) bSource
  obtain ⟨aRead, har⟩ := aReceived
  obtain ⟨bRead, hbr⟩ := bReceived
  refine ⟨offer, answer, active, max (max aStart bStart) (max aRead bRead), ?_⟩
  intro t ht
  exact ⟨aStable t (by omega), bStable t (by omega), har t (by omega), hbr t (by omega)⟩

/- A responder's publication obligation only needs to become active when its
   first answer exists. Cold activation is derived solely from forward traffic;
   this wrapper does not assume the answer stream is live before startup. -/
theorem signaling_cold_start_converges
    (a : OfferRun) (ah bh : SourceHistory) (lease : Nat)
    (ac : ClientRun ah) (bc : ClientRun bh)
    (forward : CommonSchedule ah lease ac) (r : ResponderRun ah ac)
    (answerService : Eventually (fun t => 0 < (r.state t).answer) → CommonSchedule bh lease bc)
    (aBody : ∀ n, (ah.entries n).offer = a.offer (ah.entries n).event)
    (aAuth : ∀ n, (ah.entries n).auth = (ah.entries n).offer)
    (bOffer : ∀ n, (bh.entries n).offer = (r.state (bh.entries n).event).offer)
    (bAuth : ∀ n, (bh.entries n).auth = (r.state (bh.entries n).event).answer)
    (renegotiation : RenegotiationRun a bh) :
    ∃ offer answer, 0 < answer ∧ Eventually (fun t =>
      a.offer t = offer ∧ r.state t = ⟨offer, answer⟩ ∧
      (∃ rec, ac.seen t = some rec ∧ rec.offer = offer ∧ rec.auth = offer) ∧
      (∃ rec, bc.seen t = some rec ∧ rec.offer = offer ∧ rec.auth = answer)) := by
  have active := responder_cold_activation ah lease ac forward r
  exact signaling_converges a ah bh lease ac bc forward (answerService active) r
    aBody aAuth bOffer bAuth renegotiation

/- Candidate identity is ghost-tagged with its credential epoch. Addresses
   may be reused across epochs; an occurrence belongs to exactly one epoch. -/
structure CandidateState where
  epoch : Nat
  known : Nat → Prop

inductive CandidateEvent where
  | idle
  | switch (epoch : Nat)
  | gather (epoch candidate : Nat)

def candidateNext (state : CandidateState) : CandidateEvent → CandidateState
  | .idle => state
  | .switch epoch => if epoch = state.epoch then state else ⟨epoch, fun _ => False⟩
  | .gather epoch candidate =>
      if epoch = state.epoch then ⟨state.epoch, fun x => state.known x ∨ x = candidate⟩ else state

def CandidateValid (origin : Nat → Nat) (state : CandidateState) : Prop :=
  ∀ candidate, state.known candidate → origin candidate = state.epoch

theorem candidate_step_provenance (origin : Nat → Nat) (state : CandidateState)
    (event : CandidateEvent) (oldValid : CandidateValid origin state)
    (gatherValid : ∀ epoch candidate, event = .gather epoch candidate → origin candidate = epoch) :
    CandidateValid origin (candidateNext state event) := by
  intro candidate hc
  cases event with
  | idle => exact oldValid candidate hc
  | switch epoch =>
      by_cases eq : epoch = state.epoch
      · simp only [candidateNext, eq, ↓reduceIte] at hc ⊢
        exact oldValid candidate hc
      · simp only [candidateNext, eq, ↓reduceIte] at hc
  | gather epoch gathered =>
      by_cases eq : epoch = state.epoch
      · simp only [candidateNext, eq, ↓reduceIte] at hc ⊢
        rcases hc with previous | new
        · exact oldValid candidate previous
        · subst candidate
          exact (gatherValid epoch gathered rfl).trans eq
      · simp only [candidateNext, eq, ↓reduceIte] at hc ⊢
        exact oldValid candidate hc

theorem stale_gather_ignored (state : CandidateState) (epoch candidate : Nat)
    (stale : epoch ≠ state.epoch) : candidateNext state (.gather epoch candidate) = state := by
  simp [candidateNext, stale]

theorem candidate_epoch_retains (state : CandidateState) (event : CandidateEvent)
    (same : (candidateNext state event).epoch = state.epoch) :
    ∀ candidate, state.known candidate → (candidateNext state event).known candidate := by
  intro candidate hc
  cases event with
  | idle => exact hc
  | switch epoch =>
      by_cases eq : epoch = state.epoch
      · simpa only [candidateNext, eq, ↓reduceIte] using hc
      · simp only [candidateNext, eq, ↓reduceIte] at same
  | gather epoch gathered =>
      by_cases eq : epoch = state.epoch
      · simp only [candidateNext, eq, ↓reduceIte]
        exact Or.inl hc
      · simpa only [candidateNext, eq, ↓reduceIte] using hc

structure CandidateRun where
  state : Nat → CandidateState
  event : Nat → CandidateEvent
  cutoff : Nat
  step : ∀ t, cutoff ≤ t → state (t + 1) = candidateNext (state t) (event t)

theorem candidate_retained_in_stable_epoch (c : CandidateRun) (start epoch : Nat)
    (afterCut : c.cutoff ≤ start) (stable : ∀ t, start ≤ t → (c.state t).epoch = epoch)
    (candidate : Nat) (known : (c.state start).known candidate) :
    ∀ t, start ≤ t → (c.state t).known candidate := by
  have inv : ∀ d, (c.state (start + d)).known candidate := by
    intro d
    induction d with
    | zero => simpa using known
    | succ d ih =>
        have same : (candidateNext (c.state (start + d)) (c.event (start + d))).epoch =
            (c.state (start + d)).epoch := by
          rw [← c.step (start + d) (by omega), stable _ (by omega), stable _ (by omega)]
        have result := candidate_epoch_retains (c.state (start + d)) (c.event (start + d)) same candidate ih
        rw [← c.step (start + d) (by omega)] at result
        simpa only [Nat.add_assoc] using result
  intro t ht
  have eq : start + (t - start) = t := by omega
  simpa only [eq] using inv (t - start)

/- The receiving buffer is keyed by the atomic (offer, auth) tuple. Full
   snapshot replay merges within that epoch and clears on epoch changes. -/
structure CandidateBuffer where
  offer : Nat
  auth : Nat
  known : Nat → Prop

def mergeSnapshot (snapshot : Snapshot) (old : CandidateBuffer) : CandidateBuffer :=
  if snapshot.offer = old.offer ∧ snapshot.auth = old.auth then
    ⟨old.offer, old.auth, fun x => old.known x ∨ x ∈ snapshot.candidates⟩
  else ⟨snapshot.offer, snapshot.auth, fun x => x ∈ snapshot.candidates⟩

def acceptAnswer (currentOffer : Nat) (snapshot : Snapshot) (old : CandidateBuffer) : CandidateBuffer :=
  if snapshot.offer = currentOffer then mergeSnapshot snapshot old else old

theorem answer_gate_rejects_old_offer (currentOffer : Nat) (snapshot : Snapshot)
    (old : CandidateBuffer) (stale : snapshot.offer ≠ currentOffer) :
    acceptAnswer currentOffer snapshot old = old := by simp [acceptAnswer, stale]

theorem mergeSnapshot_keys (snapshot : Snapshot) (old : CandidateBuffer) :
    (mergeSnapshot snapshot old).offer = snapshot.offer ∧
    (mergeSnapshot snapshot old).auth = snapshot.auth := by
  unfold mergeSnapshot
  split
  · rename_i same
    exact ⟨same.1.symm, same.2.symm⟩
  · exact ⟨rfl, rfl⟩

theorem accepted_answer_binds_offer (currentOffer : Nat) (snapshot : Snapshot)
    (old : CandidateBuffer) (oldBound : old.offer = currentOffer) :
    (acceptAnswer currentOffer snapshot old).offer = currentOffer := by
  unfold acceptAnswer
  split
  · rename_i bound
    exact (mergeSnapshot_keys snapshot old).1.trans bound
  · exact oldBound

theorem mergeSnapshot_covers (snapshot : Snapshot) (old : CandidateBuffer)
    (candidate : Nat) (included : candidate ∈ snapshot.candidates) :
    (mergeSnapshot snapshot old).known candidate := by
  unfold mergeSnapshot
  split
  · exact Or.inr included
  · exact included

theorem mergeSnapshot_retains (snapshot : Snapshot) (old : CandidateBuffer)
    (same : snapshot.offer = old.offer ∧ snapshot.auth = old.auth)
    (candidate : Nat) (included : old.known candidate) :
    (mergeSnapshot snapshot old).known candidate := by
  simp only [mergeSnapshot, same]
  exact Or.inl included

theorem mergeSnapshot_provenance (origin : Nat → Nat × Nat) (snapshot : Snapshot)
    (old : CandidateBuffer)
    (oldValid : ∀ x, old.known x → origin x = (old.offer, old.auth))
    (incomingValid : ∀ x, x ∈ snapshot.candidates → origin x = (snapshot.offer, snapshot.auth)) :
    ∀ x, (mergeSnapshot snapshot old).known x →
      origin x = ((mergeSnapshot snapshot old).offer, (mergeSnapshot snapshot old).auth) := by
  intro x hx
  by_cases same : snapshot.offer = old.offer ∧ snapshot.auth = old.auth
  · simp only [mergeSnapshot, same] at hx ⊢
    rcases hx with previous | incoming
    · exact oldValid x previous
    · rw [← same.1, ← same.2]
      exact incomingValid x incoming
  · simp only [mergeSnapshot, same, ↓reduceIte] at hx ⊢
    exact incomingValid x hx

/- Receiving the same snapshot twice has exactly the same candidate knowledge;
   candidate delivery is set union, not a fresh ICE/session operation. -/
theorem mergeSnapshot_idempotent (snapshot : Snapshot) (old : CandidateBuffer) :
    ∀ x, (mergeSnapshot snapshot (mergeSnapshot snapshot old)).known x ↔
      (mergeSnapshot snapshot old).known x := by
  intro x
  have keys := mergeSnapshot_keys snapshot old
  have matched : snapshot.offer = (mergeSnapshot snapshot old).offer ∧
      snapshot.auth = (mergeSnapshot snapshot old).auth := ⟨keys.1.symm, keys.2.symm⟩
  change ((if snapshot.offer = (mergeSnapshot snapshot old).offer ∧
      snapshot.auth = (mergeSnapshot snapshot old).auth then
        ⟨(mergeSnapshot snapshot old).offer, (mergeSnapshot snapshot old).auth,
          fun y => (mergeSnapshot snapshot old).known y ∨ y ∈ snapshot.candidates⟩
      else ⟨snapshot.offer, snapshot.auth, fun y => y ∈ snapshot.candidates⟩) : CandidateBuffer).known x ↔ _
  rw [ite_eq_left matched]
  change ((mergeSnapshot snapshot old).known x ∨ x ∈ snapshot.candidates) ↔ _
  exact ⟨fun hx => hx.elim id (mergeSnapshot_covers snapshot old x), Or.inl⟩

/- A gathered candidate cannot be lost by broker loss, delayed HTTP responses,
   or replacement of a receive buffer once its credential epoch is stable. -/
theorem stable_candidate_eventually_delivered
    (h : SourceHistory) (lease : Nat) (client : ClientRun h)
    (schedule : CommonSchedule h lease client) (gather : CandidateRun)
    (epoch stableStart gatheredAt candidate : Nat)
    (pastFaults : gather.cutoff ≤ gatheredAt)
    (pastStable : stableStart ≤ gatheredAt)
    (stable : ∀ t, stableStart ≤ t → (gather.state t).epoch = epoch)
    (gathered : (gather.state gatheredAt).known candidate)
    (fullSnapshots : ∀ n x, (gather.state (h.entries n).event).known x →
      x ∈ (h.entries n).candidates) :
    Eventually (fun t => ∃ rec, client.seen t = some rec ∧ candidate ∈ rec.candidates) := by
  have retained := candidate_retained_in_stable_epoch gather gatheredAt epoch pastFaults
    (fun t ht => stable t (by omega)) candidate gathered
  apply transport_preserves_eventual_snapshot_property h lease client schedule
    (fun rec => candidate ∈ rec.candidates)
  apply source_property_after_time h (fun rec => candidate ∈ rec.candidates) gatheredAt
  intro n hn
  exact fullSnapshots n candidate (retained _ hn)

/- This result includes all candidate occurrences gathered in either stabilized
   credential epoch. It does not assume that either received candidate is a
   viable network path. Any finite collection is eventually known together. -/
theorem signaling_and_candidates_converge
    (a : OfferRun) (ah bh : SourceHistory) (lease : Nat)
    (ac : ClientRun ah) (bc : ClientRun bh)
    (forward : CommonSchedule ah lease ac)
    (r : ResponderRun ah ac)
    (answerService : Eventually (fun t => 0 < (r.state t).answer) → CommonSchedule bh lease bc)
    (aBody : ∀ n, (ah.entries n).offer = a.offer (ah.entries n).event)
    (aAuth : ∀ n, (ah.entries n).auth = (ah.entries n).offer)
    (bOffer : ∀ n, (bh.entries n).offer = (r.state (bh.entries n).event).offer)
    (bAuth : ∀ n, (bh.entries n).auth = (r.state (bh.entries n).event).answer)
    (renegotiation : RenegotiationRun a bh)
    (ag bg : CandidateRun)
    (agEpoch : ∀ t, (ag.state t).epoch = a.offer t)
    (bgEpoch : ∀ t, (bg.state t).epoch = (r.state t).answer)
    (aFull : ∀ n x, (ag.state (ah.entries n).event).known x → x ∈ (ah.entries n).candidates)
    (bFull : ∀ n x, (bg.state (bh.entries n).event).known x → x ∈ (bh.entries n).candidates) :
    ∃ offer answer start, 0 < answer ∧
      (∀ t, start ≤ t → a.offer t = offer ∧ r.state t = ⟨offer, answer⟩ ∧
        (∃ rec, ac.seen t = some rec ∧ rec.offer = offer ∧ rec.auth = offer) ∧
        (∃ rec, bc.seen t = some rec ∧ rec.offer = offer ∧ rec.auth = answer)) ∧
      (∀ generated candidate, start ≤ generated → (ag.state generated).known candidate →
        Eventually (fun t => ∃ rec, ac.seen t = some rec ∧
          rec.offer = offer ∧ rec.auth = offer ∧ candidate ∈ rec.candidates)) ∧
      (∀ generated candidate, start ≤ generated → (bg.state generated).known candidate →
        Eventually (fun t => ∃ rec, bc.seen t = some rec ∧
          rec.offer = offer ∧ rec.auth = answer ∧ candidate ∈ rec.candidates)) := by
  have active := responder_cold_activation ah lease ac forward r
  have backward := answerService active
  obtain ⟨offer, answer, answerActive, stableStart, stable⟩ := signaling_converges
    a ah bh lease ac bc forward backward r aBody aAuth bOffer bAuth renegotiation
  let start := max stableStart (max ag.cutoff bg.cutoff)
  have aStable : ∀ t, start ≤ t → (ag.state t).epoch = offer := by
    intro t ht
    exact (agEpoch t).trans (stable t (by dsimp [start] at ht; omega)).1
  have bStable : ∀ t, start ≤ t → (bg.state t).epoch = answer := by
    intro t ht
    exact (bgEpoch t).trans (congrArg ResponderState.answer (stable t (by dsimp [start] at ht; omega)).2.1)
  refine ⟨offer, answer, start, answerActive, ?_, ?_, ?_⟩
  · intro t ht; exact stable t (by dsimp [start] at ht; omega)
  · intro generated candidate hg known
    have retained := candidate_retained_in_stable_epoch ag generated offer
      (by dsimp [start] at hg; omega) (fun t ht => aStable t (by omega)) candidate known
    apply transport_preserves_eventual_snapshot_property ah lease ac forward
      (fun rec => rec.offer = offer ∧ rec.auth = offer ∧ candidate ∈ rec.candidates)
    apply source_property_after_time ah _ generated
    intro n hn
    have htime : stableStart ≤ (ah.entries n).event := by dsimp [start] at hg; omega
    have ho := (aBody n).trans (stable _ htime).1
    exact ⟨ho, (aAuth n).trans ho, aFull n candidate (retained _ hn)⟩
  · intro generated candidate hg known
    have retained := candidate_retained_in_stable_epoch bg generated answer
      (by dsimp [start] at hg; omega) (fun t ht => bStable t (by omega)) candidate known
    apply transport_preserves_eventual_snapshot_property bh lease bc backward
      (fun rec => rec.offer = offer ∧ rec.auth = answer ∧ candidate ∈ rec.candidates)
    apply source_property_after_time bh _ generated
    intro n hn
    have htime : stableStart ≤ (bh.entries n).event := by dsimp [start] at hg; omega
    have hs := (stable _ htime).2.1
    exact ⟨(bOffer n).trans (congrArg ResponderState.offer hs),
      (bAuth n).trans (congrArg ResponderState.answer hs), bFull n candidate (retained _ hn)⟩

/- Pairwise independence yields simultaneous eventual knowledge for any finite
   deployment size, not merely the two-peer TLC configurations. -/
theorem finite_mesh_converges (pairs : Nat) (settled : Fin pairs → Nat → Prop)
    (pairProof : ∀ pair, Eventually (settled pair)) :
    Eventually (fun t => ∀ pair, settled pair t) :=
  eventually_finite pairs settled pairProof

/- Prove finite external failure prefixes do not compromise local allocation
   causality. Resetting the responder to an empty state is safe at every time. -/
theorem empty_responder_causal (t : Nat) :
    (ResponderState.mk 0 0).offer ≤ t ∧ (ResponderState.mk 0 0).answer ≤ t := by
  change 0 ≤ t ∧ 0 ≤ t
  omega

theorem responder_run_causality
    (state : Nat → ResponderState)
    (initial : state 0 = ⟨0, 0⟩)
    (transition : ∀ t,
      state (t + 1) = state t ∨ state (t + 1) = ⟨0, 0⟩ ∨
      ∃ input, input ≤ t ∧ state (t + 1) = responderNext t input (state t)) :
    ∀ t, (state t).offer ≤ t ∧ (state t).answer ≤ t := by
  intro t
  induction t with
  | zero => rw [initial]; exact empty_responder_causal _
  | succ t ih =>
      rcases transition t with idle | reset | ⟨input, hc, follow⟩
      · rw [idle]; omega
      · rw [reset]; exact empty_responder_causal _
      · rw [follow]; exact responderNext_causal t input (state t) hc ih

/- Explicit initiator transition rules discharge RenegotiationRun.cause.
   Incoming answers are already authenticated source snapshots. Allocation
   uses a ghost fresh birth; no ordering test occurs in the wire protocol. -/
structure InitiatorState where
  offer : Nat
  answer : Option Snapshot

def initiatorNext (now : Nat) (input : Option Snapshot) (old : InitiatorState) : InitiatorState :=
  match input with
  | none => old
  | some rec =>
      if rec.offer ≠ old.offer then old
      else match old.answer with
      | none => ⟨old.offer, some rec⟩
      | some previous =>
          if previous.auth = rec.auth then old else ⟨now + 1, none⟩

def InitiatorValid (h : SourceHistory) (state : InitiatorState) : Prop :=
  ∀ record, state.answer = some record → Published h.entries record ∧ record.offer = state.offer

theorem initiator_transition_valid (h : SourceHistory) (now : Nat)
    (input : Option Snapshot) (old : InitiatorState) (valid : InitiatorValid h old)
    (inputValid : ∀ rec, input = some rec → Published h.entries rec) :
    InitiatorValid h (initiatorNext now input old) := by
  cases input with
  | none => exact valid
  | some rec =>
      by_cases mismatched : rec.offer ≠ old.offer
      · have eq : initiatorNext now (some rec) old = old := by simp [initiatorNext, mismatched]
        rw [eq]
        exact valid
      · have matched : rec.offer = old.offer := by omega
        cases ha : old.answer with
        | none =>
            have eq : initiatorNext now (some rec) old = ⟨old.offer, some rec⟩ := by
              simp [initiatorNext, mismatched, ha]
            rw [eq]
            intro record hr
            have heq : rec = record := Option.some.inj hr
            subst record
            exact ⟨inputValid rec rfl, matched⟩
        | some previous =>
            by_cases same : previous.auth = rec.auth
            · have eq : initiatorNext now (some rec) old = old := by
                simp [initiatorNext, mismatched, ha, same]
              rw [eq]
              exact valid
            · have eq : initiatorNext now (some rec) old = ⟨now + 1, none⟩ := by
                simp [initiatorNext, mismatched, ha, same]
              rw [eq]
              intro record hr
              cases hr

theorem initiator_change_has_conflicting_answers (h : SourceHistory) (now : Nat)
    (input : Option Snapshot) (old : InitiatorState) (valid : InitiatorValid h old)
    (inputValid : ∀ rec, input = some rec → Published h.entries rec)
    (changed : (initiatorNext now input old).offer ≠ old.offer) :
    ∃ left right, Published h.entries left ∧ Published h.entries right ∧
      left.offer = old.offer ∧ right.offer = old.offer ∧ left.auth ≠ right.auth := by
  cases input with
  | none => exact False.elim (changed rfl)
  | some rec =>
      by_cases mismatched : rec.offer ≠ old.offer
      · exact False.elim (changed (by simp [initiatorNext, mismatched]))
      · have matched : rec.offer = old.offer := by omega
        cases ha : old.answer with
        | none => exact False.elim (changed (by simp [initiatorNext, mismatched, ha]))
        | some previous =>
            by_cases same : previous.auth = rec.auth
            · exact False.elim (changed (by simp [initiatorNext, mismatched, ha, same]))
            · have vp := valid previous ha
              exact ⟨previous, rec, vp.1, inputValid rec rfl, vp.2, matched, same⟩

structure InitiatorRun (h : SourceHistory) where
  cutoff : Nat
  state : Nat → InitiatorState
  input : Nat → Option Snapshot
  initialValid : InitiatorValid h (state cutoff)
  inputValid : ∀ t, cutoff ≤ t → ∀ rec, input t = some rec → Published h.entries rec
  step : ∀ t, cutoff ≤ t → state (t + 1) = initiatorNext t (input t) (state t)

theorem initiator_run_valid (h : SourceHistory) (r : InitiatorRun h) :
    ∀ t, r.cutoff ≤ t → InitiatorValid h (r.state t) := by
  have inv : ∀ d, InitiatorValid h (r.state (r.cutoff + d)) := by
    intro d
    induction d with
    | zero => simpa only [Nat.add_zero] using r.initialValid
    | succ d ih =>
        rw [show r.cutoff + (d + 1) = (r.cutoff + d) + 1 by omega, r.step _ (by omega)]
        exact initiator_transition_valid h _ _ _ ih (r.inputValid _ (by omega))
  intro t ht
  have eq : r.cutoff + (t - r.cutoff) = t := by omega
  simpa only [eq] using inv (t - r.cutoff)

def renegotiationFromTransitions (a : OfferRun) (h : SourceHistory) (r : InitiatorRun h)
    (offers : ∀ t, (r.state t).offer = a.offer t) : RenegotiationRun a h := by
  refine ⟨r.cutoff, ?_⟩
  intro t ht changed
  have different : (initiatorNext t (r.input t) (r.state t)).offer ≠ (r.state t).offer := by
    rw [← r.step t ht, offers, offers]
    exact changed
  obtain ⟨left, right, lp, rp, lo, ro, auth⟩ := initiator_change_has_conflicting_answers h
    t (r.input t) (r.state t) (initiator_run_valid h r t ht) (r.inputValid t ht) different
  exact ⟨left, right, lp, rp, lo.trans (offers t), ro.trans (offers t), auth⟩

/- A concrete infinite execution witnesses that the composed premises can all
   hold. It starts cold, uses one ordinary broker with a one-tick lease, and
   eventually carries both descriptors and candidate occurrences. -/
def exampleHistory (offset auth : Nat) : SourceHistory where
  entries := fun n => ⟨⟨n + 1, 0⟩, n, n + offset, n + offset, 0, auth, [auth]⟩
  cutoff := 0
  obsoleteBound := 0
  indexed := fun _ => rfl
  obsolete := by intro n hn; omega
  ordered := by intro a b _ hab; change a + 1 < b + 1; omega
  eventOrdered := by intro a b hab; change a + offset < b + offset; omega
  timeOrdered := by intro a b hab; change a + offset ≤ b + offset; omega

def exampleClient (offset auth : Nat) : ClientRun (exampleHistory offset auth) where
  cutoff := 0
  input := fun t => if offset ≤ t then some ((exampleHistory offset auth).entries (t - offset)) else none
  seen := fun t => if offset < t then some ((exampleHistory offset auth).entries (t - offset - 1)) else none
  initial := by intro rec hr; simp at hr
  inputValid := by
    intro t _ rec hr
    split at hr
    · have eq := Option.some.inj hr
      subst rec
      rfl
    · cases hr
  inputCausal := by
    intro t _ rec hr
    split at hr
    · rename_i ht
      have eq := Option.some.inj hr
      subst rec
      change t - offset + offset ≤ t
      omega
    · cases hr
  step := by
    intro t _
    by_cases atOffset : offset ≤ t
    · simp only [atOffset, ↓reduceIte, receiveOption]
      have next : offset < t + 1 := by omega
      simp only [next, ↓reduceIte]
      by_cases hasPrevious : offset < t
      · simp only [hasPrevious, ↓reduceIte, clientReceive]
        have newer : Newer ((exampleHistory offset auth).entries (t - offset)).version
            ((exampleHistory offset auth).entries (t - offset - 1)).version := by
          left
          change t - offset - 1 + 1 < t - offset + 1
          omega
        simp only [newer, ↓reduceIte]
        congr 2
        omega
      · simp only [hasPrevious, ↓reduceIte, clientReceive]
        congr 2
        omega
    · have before : ¬offset < t := by omega
      have beforeNext : ¬offset < t + 1 := by omega
      simp only [atOffset, before, beforeNext, ↓reduceIte, receiveOption]

def exampleWindow (offset auth n : Nat) : BrokerWindow (exampleHistory offset auth) 1 where
  publication := (exampleHistory offset auth).entries n
  publicationValid := rfl
  writerNow := n + offset
  writerCausal := Nat.le_refl _
  deadline := n + offset
  writerBeforeRead := Nat.le_refl _
  timely := by change n + offset < n + offset + 1; omega
  initial := none
  initialValid := by intro _ impossible; cases impossible
  length := 0
  cells := fun _ => some ⟨(exampleHistory offset auth).entries n, n + offset + 1⟩
  first := rfl
  incoming := fun _ => none
  now := fun _ => n + offset
  within := by intro i hi; omega
  causal := by intro _ _ _ impossible; cases impossible
  transitions := by intro i hi; omega

def exampleSchedule (offset auth : Nat) :
    CommonSchedule (exampleHistory offset auth) 1 (exampleClient offset auth) where
  window := exampleWindow offset auth
  captureStrict := by intro n; change n < n + 1; omega
  arrival := fun n => n + offset
  arrivalStable := by intro n; change 0 ≤ n + offset; omega
  arrivesAfterCapture := fun _ => Nat.le_refl _
  response := by
    intro n
    change (if offset ≤ n + offset then some ((exampleHistory offset auth).entries (n + offset - offset))
      else none) = some ((exampleHistory offset auth).entries n)
    simp

def exampleOffer : OfferRun where
  offer := fun _ => 0
  initial := rfl
  allocation := fun _ => Or.inl rfl

def exampleResponder : ResponderRun (exampleHistory 0 0) (exampleClient 0 0) where
  cutoff := 0
  receiverStable := Nat.le_refl _
  state := fun t => if 2 ≤ t then ⟨0, 2⟩ else ⟨0, 0⟩
  scheduled := fun _ => true
  fair := by intro t; exact ⟨t, Nat.le_refl _, Nat.zero_le _, rfl⟩
  causal := by
    intro t
    split
    · change 0 ≤ t ∧ 2 ≤ t; omega
    · change 0 ≤ t ∧ 0 ≤ t; omega
  step := by
    intro t _
    change (if 2 ≤ t + 1 then ResponderState.mk 0 2 else ⟨0, 0⟩) =
      (if true then
        match (if 0 < t then some ((exampleHistory 0 0).entries (t - 0 - 1)) else none) with
        | none => if 2 ≤ t then ⟨0, 2⟩ else ⟨0, 0⟩
        | some rec => responderNext t rec.offer (if 2 ≤ t then ⟨0, 2⟩ else ⟨0, 0⟩)
      else if 2 ≤ t then ⟨0, 2⟩ else ⟨0, 0⟩)
    by_cases positive : 0 < t
    · simp only [↓reduceIte, positive]
      by_cases established : 2 ≤ t
      · have next : 2 ≤ t + 1 := by omega
        simp only [established, next, ↓reduceIte]
        exact (responderNext_unchanged t 0 ⟨0, 2⟩ (by decide) rfl).symm
      · have eq : t = 1 := by omega
        subst t
        rfl
    · have eq : t = 0 := by omega
      subst t
      rfl

def exampleRenegotiation : RenegotiationRun exampleOffer (exampleHistory 2 2) where
  cutoff := 0
  cause := by intro t _ impossible; exact False.elim (impossible rfl)

def exampleGather (epoch : Nat) : CandidateRun where
  state := fun _ => ⟨epoch, fun x => x = epoch⟩
  event := fun _ => .idle
  cutoff := 0
  step := fun _ _ => rfl

def exampleAnswerGather : CandidateRun where
  state := fun t => if 2 ≤ t then ⟨2, fun x => x = 2⟩ else ⟨0, fun _ => False⟩
  event := fun _ => .idle
  cutoff := 2
  step := by
    intro t ht
    have next : 2 ≤ t + 1 := by omega
    simp only [ht, next, ↓reduceIte, candidateNext]

/- Instantiation checks all cold-start, causal, transport, controller and
   candidate premises together, not just the final conclusion's consistency. -/
theorem composed_premises_have_infinite_execution :
    ∃ offer answer start, 0 < answer ∧
      (∀ t, start ≤ t → exampleOffer.offer t = offer ∧
        exampleResponder.state t = ⟨offer, answer⟩ ∧
        (∃ rec, (exampleClient 0 0).seen t = some rec ∧ rec.offer = offer ∧ rec.auth = offer) ∧
        (∃ rec, (exampleClient 2 2).seen t = some rec ∧ rec.offer = offer ∧ rec.auth = answer)) ∧
      (∀ generated candidate, start ≤ generated → ((exampleGather 0).state generated).known candidate →
        Eventually (fun t => ∃ rec, (exampleClient 0 0).seen t = some rec ∧
          rec.offer = offer ∧ rec.auth = offer ∧ candidate ∈ rec.candidates)) ∧
      (∀ generated candidate, start ≤ generated → (exampleAnswerGather.state generated).known candidate →
        Eventually (fun t => ∃ rec, (exampleClient 2 2).seen t = some rec ∧
          rec.offer = offer ∧ rec.auth = answer ∧ candidate ∈ rec.candidates)) := by
  apply signaling_and_candidates_converge exampleOffer (exampleHistory 0 0) (exampleHistory 2 2) 1
    (exampleClient 0 0) (exampleClient 2 2) (exampleSchedule 0 0) exampleResponder
    (fun _ => exampleSchedule 2 2)
    (fun _ => rfl) (fun _ => rfl)
    (fun n => by simp [exampleHistory, exampleResponder])
    (fun n => by simp [exampleHistory, exampleResponder])
    exampleRenegotiation (exampleGather 0) exampleAnswerGather
    (fun _ => rfl)
  · intro t
    change (if 2 ≤ t then CandidateState.mk 2 (fun x => x = 2) else ⟨0, fun _ => False⟩).epoch =
      (if 2 ≤ t then ResponderState.mk 0 2 else ⟨0, 0⟩).answer
    split <;> rfl
  · intro n x known
    exact List.mem_singleton.mpr known
  · intro n x known
    have active : 2 ≤ ((exampleHistory 2 2).entries n).event := by
      change 2 ≤ n + 2; omega
    simp only [exampleAnswerGather, active, ↓reduceIte] at known
    exact List.mem_singleton.mpr known

end Signaling
